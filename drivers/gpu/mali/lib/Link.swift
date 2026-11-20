// SPDX-License-Identifier: BSD-3-Clause

// The scheduler's `FirmwareLink` over the CSF interface (chinese-wall's
// panthor 07 section 7.3, 7.4, 7.9 and 7.10, 05 section 5.8): binding a
// group to a CSG slot (its CS slots first, then the slot, the state
// request, the doorbells), suspending and terminating, priorities, the
// status update, the ring's words and INSERT, the sync objects, the events a
// JOB interrupt carries and the watchdog ping. Everything but the registers
// and the page tables: it is generic over the shared section, the doorbell,
// the memory beside the interface (rings, queue control pages, sync
// objects, suspend buffers) and a clock, so the host tests run it against
// the model firmware and the driver host over its mappings. The part that
// needs the GPU's registers (an address space's programming, a full reset)
// is the driver's (Device.swift), which conforms to `FirmwareLink` by
// forwarding the rest here.

/// One queue's memory: its ring, its control area and its sync object.
public struct LinkQueueMemory<M: SharedMemory> {
  /// The ring's bytes, from offset 0, and its address in the group's VM.
  public var ring: M
  public var ringVA: UInt64
  public var ringSize: Int
  /// The 8 KiB control area at `controlOffset` of `control`: the input page
  /// first, the output page 4 KiB on; `controlVA` is its address in the MCU's VM.
  public var control: M
  public var controlOffset: Int
  public var controlVA: UInt64
  /// The queue's sync object (16 bytes) at `syncOffset` in `sync`.
  public var sync: M
  public var syncOffset: Int

  public init(ring: M, ringVA: UInt64, ringSize: Int, control: M, controlOffset: Int = 0, controlVA: UInt64, sync: M,
              syncOffset: Int) {
    self.ring = ring
    self.ringVA = ringVA
    self.ringSize = ringSize
    self.control = control
    self.controlOffset = controlOffset
    self.controlVA = controlVA
    self.sync = sync
    self.syncOffset = syncOffset
  }
}

/// The memory of the groups the link binds, by the scheduler's group id.
public protocol LinkMemory {
  associatedtype Memory: SharedMemory
  func queue(group: Int, queue: Int) -> LinkQueueMemory<Memory>?
  /// The MCU addresses of the group's normal and protected-mode suspend
  /// buffers (0: none).
  func suspendBuffers(group: Int) -> (normal: UInt64, protected: UInt64)
}

/// What every group is programmed with, and how long the firmware has.
public struct LinkPolicy: Equatable, Sendable {
  /// CSG_ALLOW_COMPUTE, CSG_ALLOW_FRAGMENT and CSG_ALLOW_OTHER (the tiler's
  /// cores): the cores a group may use (07 section 7.3.3 step 5).
  public var allowCompute: UInt64
  public var allowFragment: UInt64
  public var allowOther: UInt32
  /// CSG_EP_REQ's most cores (compute and fragment [7:0] and [15:8], tiler
  /// [19:16]).
  public var maxCompute: UInt32
  public var maxFragment: UInt32
  public var maxTiler: UInt32
  /// How long a CSG request may take: 100 ms (07 section 7.3.3 step 8).
  public var requestTimeout: Int64 = 100_000_000
  /// The watchdog's period and the wait for the answer (05 section 5.8:
  /// 12 s and 100 ms; the answer is waited for twice as long, the interrupt
  /// thread polling).
  public var pingPeriod: Int64 = 12_000_000_000
  public var pingTimeout: Int64 = 200_000_000

  public init(allowCompute: UInt64, allowFragment: UInt64, allowOther: UInt32, maxCompute: UInt32,
              maxFragment: UInt32, maxTiler: UInt32) {
    self.allowCompute = allowCompute
    self.allowFragment = allowFragment
    self.allowOther = allowOther
    self.maxCompute = maxCompute
    self.maxFragment = maxFragment
    self.maxTiler = maxTiler
  }

  /// Every shader core for compute and fragment, every tiler for the rest.
  public init(shaderPresent: UInt64, tilerPresent: UInt64) {
    self.init(allowCompute: shaderPresent, allowFragment: shaderPresent, allowOther: UInt32(truncatingIfNeeded: tilerPresent),
              maxCompute: UInt32(min(shaderPresent.nonzeroBitCount, 255)),
              maxFragment: UInt32(min(shaderPresent.nonzeroBitCount, 255)),
              maxTiler: UInt32(min(tilerPresent.nonzeroBitCount, 15)))
  }
}

public struct CSFLink<S: SharedMemory, D: CSFDoorbell, Mem: LinkMemory, C: GPUClock> {
  public private(set) var host: CSFHost<S>
  public let door: D
  public let memory: Mem
  public let clock: C
  public var policy: LinkPolicy

  /// The group each CSG slot held last (-1: none yet), its queue count, and
  /// whether the slot is bound now.
  var slotGroup: [Int]
  var slotQueues: [Int]
  var bound: [Bool]
  var pingWait: AckWait?
  var pingSent: Int64 = 0
  var nextPing: Int64
  /// What the firmware reported, oldest first with the times, for the driver's status.
  public private(set) var journal: EventLog
  /// The same, the text alone.
  public var log: [String] { journal.texts }

  /// `origin` is the clock's reading when the host started (the journal's times
  /// are since then); by default, now.
  public init(host: CSFHost<S>, door: D, memory: Mem, clock: C, policy: LinkPolicy, origin: Int64? = nil) {
    self.host = host
    self.door = door
    self.memory = memory
    self.clock = clock
    self.policy = policy
    journal = EventLog(origin: origin ?? clock.now(), capacity: 32)
    let n = host.layout.groupCount
    slotGroup = [Int](repeating: -1, count: n)
    slotQueues = [Int](repeating: 0, count: n)
    bound = [Bool](repeating: false, count: n)
    nextPing = clock.now() + policy.pingPeriod
  }

  public var csgSlotCount: Int { host.layout.groupCount }
  public var queuesPerGroup: Int { host.layout.streamCount }

  mutating func note(_ line: String) { journal.add(line, at: clock.now()) }

  /// The firmware came back after a reset: its interface is a fresh one, no
  /// slot is bound and the watchdog starts again.
  public mutating func rebooted(host: CSFHost<S>) {
    self.host = host
    for i in 0..<bound.count {
      bound[i] = false
      slotGroup[i] = -1
      slotQueues[i] = 0
    }
    pingWait = nil
    nextPing = clock.now() + policy.pingPeriod
  }

  /// Polls `w` every 10 us until it is done or `requestTimeout` passes; then
  /// once more (07 section 7.3.3 step 8).
  func wait(_ w: AckWait) -> Bool {
    let deadline = clock.now() + policy.requestTimeout
    while true {
      if host.isDone(w) { return true }
      if clock.now() >= deadline { return host.isDone(w) }
      clock.pause(nanoseconds: 10_000)
    }
  }

  func waitAll(_ waits: [AckWait]) -> Bool {
    var ok = true
    for w in waits where !wait(w) { ok = false }
    return ok
  }

  func pages(_ group: Int, _ queue: Int) -> (memory: LinkQueueMemory<Mem.Memory>, pages: RingPages<Mem.Memory>)? {
    guard let m = memory.queue(group: group, queue: queue) else { return nil }
    return (m, RingPages(memory: m.control, input: m.controlOffset, output: m.controlOffset + 0x1000))
  }

  // MARK: Binding (07 section 7.3.3)

  /// The group's CS slots, then its CSG slot, then START or RESUME, and the
  /// acknowledge. False if the firmware doesn't acknowledge in time (or the
  /// slot's last request is still open).
  public mutating func program(csg: Int, group p: LinkGroupProgram) -> Bool {
    guard csg >= 0, csg < csgSlotCount, p.queues.count >= 1, p.queues.count <= queuesPerGroup,
      !host.startPending(csg), !bound[csg]
    else { return false }
    var mask: UInt32 = 0
    for (i, q) in p.queues.enumerated() {
      guard let (m, pages) = pages(p.group, i) else { return false }
      // The input INSERT is the scheduler's (a ring written while the group
      // was off its slot published it already); EXTRACT comes from the output
      // page (syncExtract).
      m.control.store64(m.controlOffset + CSF.RingInput.insert, q.insert)
      let params = CSParams(ringBase: m.ringVA, ringSize: UInt32(m.ringSize), userInput: m.controlVA,
                            userOutput: m.controlVA + 0x1000, priority: UInt32(q.priority),
                            doorbell: UInt32(csg + 1))
      do throws(CSFError) { try host.csProgram(csg, i, params, pages: pages) } catch {
        note("CSG \(csg) CS \(i) not programmed: \(error)")
        return false
      }
      mask |= 1 << UInt32(i)
    }
    let suspend = memory.suspendBuffers(group: p.group)
    let program = CSGProgram(
      allowCompute: policy.allowCompute, allowFragment: policy.allowFragment, allowOther: policy.allowOther,
      endpoint: EndpointRequest(compute: policy.maxCompute, fragment: policy.maxFragment, tiler: policy.maxTiler,
                                priority: UInt32(p.priority)),
      addressSpace: UInt32(p.addressSpace), suspendBuffer: suspend.normal, protmSuspendBuffer: suspend.protected)
    let w: AckWait
    do throws(CSFError) { w = try host.csgStart(csg, program, streams: mask, resume: p.resume, door) } catch {
      note("CSG \(csg) not started: \(error)")
      return false
    }
    guard wait(w) else {
      note("CSG \(csg) did not acknowledge its \(p.resume ? "RESUME" : "START") in time")
      return false
    }
    slotGroup[csg] = p.group
    slotQueues[csg] = p.queues.count
    bound[csg] = true
    return true
  }

  /// 07 section 7.3.4: every priority first, the acknowledges after.
  public mutating func setPriorities(_ updates: [LinkPriorityUpdate]) -> Bool {
    var waits: [AckWait] = []
    for u in updates {
      guard u.csg >= 0, u.csg < csgSlotCount, bound[u.csg] else { return false }
      waits.append(host.csgSetPriority(u.csg, UInt32(u.priority), door))
    }
    return waitAll(waits)
  }

  mutating func leave(csg: Int, state: UInt32) -> Bool {
    guard csg >= 0, csg < csgSlotCount, bound[csg] else { return false }
    let w = host.csgSetState(csg, state, door)
    guard wait(w) else {
      note("CSG \(csg) did not acknowledge \(state == CSF.GroupState.suspend ? "SUSPEND" : "TERMINATE") in time")
      return false
    }
    // 07 section 7.3.5 step 2: each CS slot back to STOP (no doorbell, no wait).
    for s in 0..<slotQueues[csg] { host.csStop(csg, s) }
    bound[csg] = false
    return true
  }

  public mutating func suspend(csg: Int) -> Bool { leave(csg: csg, state: CSF.GroupState.suspend) }
  public mutating func terminate(csg: Int) -> Bool { leave(csg: csg, state: CSF.GroupState.terminate) }

  /// STATUS_UPDATE on the bound slots, waited for together.
  public mutating func statusUpdate() -> Bool {
    var waits: [AckWait] = []
    for csg in 0..<csgSlotCount where bound[csg] { waits.append(host.csgStatusUpdate(csg, door)) }
    return waitAll(waits)
  }

  public func queueStatus(csg: Int, queue: Int) -> LinkQueueStatus {
    guard csg >= 0, csg < csgSlotCount, slotGroup[csg] >= 0, let (_, pages) = pages(slotGroup[csg], queue) else {
      return LinkQueueStatus(extract: 0)
    }
    let st = host.csStatus(csg, queue)
    return LinkQueueStatus(blockedReason: Int(st.blockedReason), scoreboards: st.scoreboards, extract: pages.extract)
  }

  // MARK: The ring and the sync objects (07 section 7.4)

  public func storeRing(group: Int, queue: Int, byteOffset: Int, word: UInt64) {
    guard let m = memory.queue(group: group, queue: queue) else { return }
    m.ring.store64(byteOffset & (m.ringSize - 1), word)
  }

  /// After the ring's words: a write barrier, the input EXTRACT from the
  /// output, then INSERT (06 section 6.7.3).
  public func publishInsert(group: Int, queue: Int, insert: UInt64) {
    guard let (_, pages) = pages(group, queue) else { return }
    pages.publish(insert: insert)
  }

  public func readSync(group: Int, queue: Int) -> SyncRecord {
    guard let m = memory.queue(group: group, queue: queue) else { return SyncRecord(sequence: 0) }
    return SyncRecord(word0: m.sync.load64(m.syncOffset), word1: UInt64(m.sync.load32(m.syncOffset + 8)))
  }

  public func writeSync(group: Int, queue: Int, record: SyncRecord) {
    guard let m = memory.queue(group: group, queue: queue) else { return }
    m.sync.store64(m.syncOffset, record.sequence)
    m.sync.store32(m.syncOffset + 8, record.status)
    m.sync.store32(m.syncOffset + 12, 0)
    m.sync.writeBarrier()
  }

  /// The queue doorbell of a resident group: CSG slot + 1 (07 section 7.3.3 step 3).
  public func ringDoorbell(csg: Int) { door.ring(csg + 1) }

  /// 07 section 7.10.2: FAULT acknowledged, the CS's bit toggled in CSG_DB_REQ
  /// and the CSG kicked, so the stream goes on.
  public func acknowledgeFault(csg: Int, queue: Int) {
    guard csg >= 0, csg < csgSlotCount else { return }
    host.csAcknowledge(csg, queue, CSF.StreamReq.fault)
    host.toggleStreamDoorbells(csg, 1 << UInt32(queue))
    host.kickGroup(csg, door)
  }

  // MARK: Events (07 section 7.9)

  /// What a JOB interrupt's status says happened (its bits already cleared by
  /// the caller): the global interface's events and each flagged CSG's.
  /// CS events come before the CSG's own, as 7.9's steps do.
  public mutating func events(jobStatus status: UInt32) -> [LinkEvent] {
    var out: [LinkEvent] = []
    if status >> UInt32(CSF.Section.globalInterruptBit) & 1 == 1 {
      if host.glbInterrupt() & CSF.GlobalReq.idle != 0 { out.append(.globalIdle) }
    }
    for csg in 0..<csgSlotCount where status >> UInt32(csg) & 1 == 1 {
      let group = slotGroup[csg]
      var cs: [LinkEvent] = []
      var lines: [String] = []
      let h = host
      let found = h.csgInterrupt(csg, door) { slot, events in
        var acknowledge: UInt32 = 0
        if events & CSF.StreamReq.fatal != 0 {
          let e = h.csFatal(csg, slot)
          cs.append(.csFatal(csg: csg, queue: slot, unrecoverable: e.type == CSException.unrecoverable))
          lines.append("CSG \(csg) CS \(slot) FATAL \(MMUFault.exceptionName(e.type)) data \(hex(e.data)) info \(hex64(e.info))")
          acknowledge |= CSF.StreamReq.fatal
        }
        if events & CSF.StreamReq.fault != 0 {
          let e = h.csFault(csg, slot)
          var extract: UInt64 = 0
          if group >= 0, let m = self.memory.queue(group: group, queue: slot) {
            extract = RingPages(memory: m.control, input: m.controlOffset, output: m.controlOffset + 0x1000).extract
          }
          cs.append(.csFault(csg: csg, queue: slot, extract: extract))
          lines.append("CSG \(csg) CS \(slot) FAULT \(MMUFault.exceptionName(e.type)) data \(hex(e.data)) info \(hex64(e.info))"
            + " at ring offset \(extract)")
          // The scheduler acknowledges it (`acknowledgeFault`) once it has noted where.
        }
        return acknowledge
      }
      for l in lines { note(l) }
      out += cs
      if found.events & CSF.GroupReq.syncUpdate != 0 { out.append(.syncUpdate(csg: csg)) }
      if found.events & CSF.GroupReq.idle != 0 { out.append(.idle(csg: csg)) }
      if found.events & CSF.GroupReq.progressTimerEvent != 0 {
        out.append(.progressTimeout(csg: csg))
        note("CSG \(csg) progress timer expired")
      }
      if case .invalid(let state) = host.csgAckState(csg) {
        out.append(.unknownState(csg: csg))
        note("CSG \(csg) acknowledges the state \(state)")
      }
    }
    return out
  }

  /// The watchdog (05 section 5.8): a ping every `pingPeriod`, answered within
  /// `pingTimeout`, else the event that resets the GPU. Called whenever the
  /// driver looks at the firmware.
  public mutating func watchdog() -> LinkEvent? {
    let now = clock.now()
    if let w = pingWait {
      if host.isDone(w) {
        pingWait = nil
        nextPing = now + policy.pingPeriod
      } else if now - pingSent >= policy.pingTimeout {
        pingWait = nil
        nextPing = now + policy.pingPeriod
        note("the firmware did not answer a ping in \(policy.pingTimeout / 1_000_000) ms")
        return .pingTimeout
      }
    } else if now >= nextPing {
      pingWait = host.ping(door)
      pingSent = now
    }
    return nil
  }

  /// When `watchdog` next needs looking at, in the clock's time.
  public var nextWatchdog: Int64 { pingWait != nil ? pingSent + policy.pingTimeout : nextPing }
}

extension CSFHost {
  /// The MCU's stop before its power goes (06 section 6.4.5, 05 section
  /// 5.7.1): the halt requested the way the interface's version says, then
  /// MCU_STATUS read until it says HALT (and, from 4.1, the acknowledge's
  /// state), or `timeout`. Whether it halted.
  public func haltMCU<R: GPURegisterFile, C: GPUClock, B: CSFDoorbell>(
    _ control: GPUControl<R, C>, door: B, timeout: Int64
  ) -> Bool {
    requestHalt(door)
    return control.wait(timeout: timeout, interval: 100_000) {
      haltComplete(mcuStatus: control.regs.load32(GPUControlRegister.mcuStatus))
    }
  }
}
