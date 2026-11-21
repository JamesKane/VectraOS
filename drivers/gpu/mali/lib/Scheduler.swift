// SPDX-License-Identifier: BSD-3-Clause

// The scheduler's decisions: which groups hold the firmware's CSG slots
// and at what priority, when a group's job has run too long, what a fault
// or a full reset ends (chinese-wall's panthor 07 section 7.3 and 7.5 to
// 7.11). It makes decisions and never touches a register: everything it
// asks of the firmware goes through `FirmwareLink`, which the CSF
// interface implements and the tests fake. Time is a parameter, in
// nanoseconds, so a test owns the clock.

/// What the scheduler needs of the firmware's interface. A bound group
/// is addressed by its CSG slot, its memory (rings, sync objects) by
/// group and queue.
public protocol FirmwareLink {
  /// CSG slots the firmware has.
  var csgSlotCount: Int { get }
  /// CS slots in each.
  var queuesPerGroup: Int { get }

  /// Program MMU address-space `slot` with the VM (a recycle disables the
  /// old VM's first); 04 section 4.3.
  mutating func setAddressSpace(slot: Int, vm: Int)
  /// Bind the group to the CSG slot, program its queues then the slot,
  /// and request START or RESUME with an endpoint config (07 section
  /// 7.3.3). False if the firmware didn't acknowledge in time.
  mutating func program(csg: Int, group: LinkGroupProgram) -> Bool
  /// Change resident groups' CSG priorities, all at once (07 section
  /// 7.3.4 and 7.6.4): the firmware never sees two with the same one.
  mutating func setPriorities(_ updates: [LinkPriorityUpdate]) -> Bool
  /// SUSPEND or TERMINATE the slot's group (07 section 7.3.5). False if
  /// the acknowledge didn't come.
  mutating func suspend(csg: Int) -> Bool
  mutating func terminate(csg: Int) -> Bool
  /// Toggle STATUS_UPDATE on the occupied slots and wait for them.
  mutating func statusUpdate() -> Bool
  func queueStatus(csg: Int, queue: Int) -> LinkQueueStatus

  /// One word of the ring (the memory the CS reads), by byte offset.
  mutating func storeRing(group: Int, queue: Int, byteOffset: Int, word: UInt64)
  /// After a write barrier: the input EXTRACT := output EXTRACT, and the
  /// input INSERT := `insert`.
  mutating func publishInsert(group: Int, queue: Int, insert: UInt64)
  func readSync(group: Int, queue: Int) -> SyncRecord
  mutating func writeSync(group: Int, queue: Int, record: SyncRecord)
  /// The queue doorbell of a resident group.
  mutating func ringDoorbell(csg: Int)
  /// Acknowledge a CS fault so the stream resumes (07 section 7.10.2).
  mutating func acknowledgeFault(csg: Int, queue: Int)
  /// What a TILER_OOM of the stream reports (06 section 6.6.5).
  func tilerOOMReport(csg: Int, queue: Int) -> TilerOOMReport
  /// The reply to a TILER_OOM (08 section 8.4.2 steps 7 and 8): `chunk` (0
  /// for none) in both heap registers, the event acknowledged, the stream's
  /// bit toggled in CSG_DB_REQ and the group kicked.
  mutating func replyTilerHeap(csg: Int, queue: Int, chunk: UInt64)
  /// The events raised since the last call, in order.
  mutating func pollEvents() -> [LinkEvent]
  /// A full GPU reset and the firmware's reboot (07 section 7.11). False
  /// if it did not come back.
  mutating func reset(cause: String) -> Bool
}

public struct LinkQueueProgram: Equatable, Sendable {
  public var ringSize: Int
  /// Monotonic; the input INSERT.
  public var insert: UInt64
  /// The output EXTRACT copied to the input.
  public var extract: UInt64
  public var priority: Int
  public init(ringSize: Int, insert: UInt64, extract: UInt64, priority: Int) {
    self.ringSize = ringSize
    self.insert = insert
    self.extract = extract
    self.priority = priority
  }
}

public struct LinkGroupProgram: Equatable, Sendable {
  public var group: Int
  public var addressSpace: Int
  /// CSG_EP_REQ's priority, 0 to 15 (15 the highest).
  public var priority: Int
  /// RESUME from the suspend buffer, else START.
  public var resume: Bool
  public var queues: [LinkQueueProgram]
  public init(group: Int, addressSpace: Int, priority: Int, resume: Bool, queues: [LinkQueueProgram]) {
    self.group = group
    self.addressSpace = addressSpace
    self.priority = priority
    self.resume = resume
    self.queues = queues
  }
}

public struct LinkPriorityUpdate: Equatable, Sendable {
  public var csg: Int
  public var priority: Int
  public init(csg: Int, priority: Int) {
    self.csg = csg
    self.priority = priority
  }
}

public struct LinkQueueStatus: Equatable, Sendable {
  /// CS_STATUS_BLOCKED_REASON: 0 unblocked, 3 sync wait.
  public var blockedReason: Int
  public var scoreboards: UInt32
  /// The output EXTRACT.
  public var extract: UInt64
  public init(blockedReason: Int = 0, scoreboards: UInt32 = 0, extract: UInt64) {
    self.blockedReason = blockedReason
    self.scoreboards = scoreboards
    self.extract = extract
  }
}

public enum LinkEvent: Equatable, Sendable {
  case syncUpdate(csg: Int)
  case idle(csg: Int)
  case globalIdle
  case progressTimeout(csg: Int)
  case csFatal(csg: Int, queue: Int, unrecoverable: Bool)
  case csFault(csg: Int, queue: Int, extract: UInt64)
  /// A tiler heap ran out of memory; left unacknowledged until the reply (08 section 8.4.2 step 2).
  case tilerOOM(csg: Int, queue: Int)
  case mmuFault(addressSpace: Int)
  /// CSG_ACK.STATE outside 0 to 3.
  case unknownState(csg: Int)
  case pingTimeout
  /// The driver's own step failed in a way 07 section 7.11 and 03 section 3.9.1 answer with a full reset (an address-space
  /// command or a cache flush that timed out); `cause` says which.
  case resetRequested(cause: String)
}

public enum GroupState: Equatable, Sendable {
  case created
  case active
  case suspended
  case terminated
  case unknown
}

public struct QueueSpec: Sendable {
  /// Bytes, a power of two from 4 KiB to 64 KiB.
  public var ringSize: Int
  public var priority: Int
  /// The group VM's addresses of the queue's kernel sync object and its
  /// profiling slots (ceil(ringSize / 128) of 32 bytes).
  public var syncVA: UInt64
  public var profilingVA: UInt64
  public init(ringSize: Int, priority: Int = 0, syncVA: UInt64 = 0, profilingVA: UInt64 = 0) {
    self.ringSize = ringSize
    self.priority = priority
    self.syncVA = syncVA
    self.profilingVA = profilingVA
  }
}

public enum SchedError: Error, Equatable, Sendable {
  case tooManyGroups
  case badQueueCount
  case badPriority
  case badRing
  case unknownVM
  case unknownGroup
  case vmInUse
  /// The group can no longer run (07 section 7.13).
  case notRunnable
  case badJob
  case ringFull
  case deviceLost
}

public struct SchedulerConfig: Sendable {
  public var asPresent: UInt32
  /// 07 section 7.10.3: 5 s. [POLICY]
  public var jobTimeout: UInt64 = 5_000_000_000
  /// 07 section 7.6.2: 10 ms.
  public var tickPeriod: UInt64 = 10_000_000
  public var profiling = ProfilingKinds.none
  public var shape: JobSequenceShape
  /// 128 groups per client (07 section 7.13), here per scheduler.
  public var maxGroups = 128
  public init(asPresent: UInt32, shape: JobSequenceShape) {
    self.asPresent = asPresent
    self.shape = shape
  }
}

/// A fence that signalled.
public struct Completion: Equatable, Sendable {
  public var group: Int
  public var queue: Int
  public var job: FinishedJob
}

/// A tiler OOM the firmware raised that no one has answered (08 section
/// 8.4): the group and queue, and what the stream reported.
public struct TilerRequest: Equatable, Sendable {
  public var group: Int
  public var queue: Int
  public var report: TilerOOMReport

  public init(group: Int, queue: Int, report: TilerOOMReport) {
    self.group = group
    self.queue = queue
    self.report = report
  }
}

public struct GroupInfo: Equatable, Sendable {
  public var state: GroupState
  /// The CSG slot, if resident.
  public var csg: Int?
  /// CSG_EP_REQ's priority last programmed.
  public var csgPriority: Int
  public var timedOut: Bool
  public var innocent: Bool
  public var fatalQueues: UInt32
  public var runnable: Bool
}

struct QueueState: Sendable {
  var ring: JobRing
  var spec: QueueSpec
  var idle = true
  var blocked = false
  var deadline: UInt64?
  /// Time left on the timer while the group is off its slot.
  var paused: UInt64?
  var profilingSlot = 0
}

struct GroupRecord: Sendable {
  var vm = 0
  var priority = 0
  var queues: [QueueState] = []
  var state = GroupState.created
  var exists = false
  var destroyed = false
  var timedOut = false
  var innocent = false
  var fatalMask: UInt32 = 0
  var csg = -1
  var csgPriority = 0
  /// FIFO place within the lists: larger is later.
  var stamp: UInt64 = 0
  var cleaned = false

  var canRun: Bool {
    state != .terminated && state != .unknown && !destroyed && fatalMask == 0 && !timedOut
  }
  /// Every queue idle or blocked (07 section 7.6.1).
  var isIdle: Bool {
    for q in queues where !(q.idle || q.blocked) { return false }
    return true
  }
}

struct Selection {
  var ids: [Int] = []
  var vms: [Int] = []
  let maxGroups: Int
  let maxVMs: Int

  func has(_ g: Int) -> Bool {
    for i in ids where i == g { return true }
    return false
  }
  /// 07 section 7.6.3 step 5: room in slots, and the distinct VMs within
  /// the address spaces.
  mutating func tryAdd(_ g: Int, vm: Int) -> Bool {
    if ids.count >= maxGroups || has(g) { return false }
    var known = false
    for v in vms where v == vm { known = true }
    if !known {
      if vms.count >= maxVMs { return false }
      vms.append(vm)
    }
    ids.append(g)
    return true
  }
}

public struct GroupScheduler<Link: FirmwareLink> {
  public var link: Link
  public var config: SchedulerConfig
  var groups: [GroupRecord] = []
  var vmAlive: [Bool] = []
  var asSlots: ASSlots
  /// Group in each CSG slot, or -1.
  var slotOwner: [Int]
  var maxResident: Int
  var stampCounter: UInt64 = 0
  var now: UInt64 = 0
  var lastTick: UInt64?
  var ticking = false
  var tickRequested = false
  var resetPending = false
  /// Why the reset pending was asked for, in the order the requests came (requests merge, 03 section 3.9.1).
  var resetCauses: [String] = []
  var liveGroups = 0
  var completions: [Completion] = []
  /// Tiler OOMs raised and not yet taken, as group and queue.
  var oomRaised: [(group: Int, queue: Int)] = []

  public private(set) var deviceLost = false
  public private(set) var resets = 0
  /// The cause of the last full reset: every request it merged.
  public private(set) var lastResetCause = ""
  /// Whether any selected group had work at the last tick (the device
  /// holds its power reference, 07 section 7.6.3 step 8).
  public private(set) var busy = false

  public init(link: Link, config: SchedulerConfig) {
    self.link = link
    self.config = config
    asSlots = ASSlots(present: config.asPresent)
    _ = asSlots.activateMCU()
    maxResident = min(link.csgSlotCount, 16)
    slotOwner = [Int](repeating: -1, count: link.csgSlotCount)
  }

  // MARK: VMs and groups

  public mutating func createVM() -> Int {
    vmAlive.append(true)
    return vmAlive.count - 1
  }

  /// A VM with a group left can't be torn down: the firmware writes into
  /// it when the group suspends (07 section 7.3.6).
  public mutating func destroyVM(_ vm: Int) throws(SchedError) {
    guard vm >= 0, vm < vmAlive.count, vmAlive[vm] else { throw .unknownVM }
    for g in groups where g.exists && g.vm == vm { throw .vmInUse }
    vmAlive[vm] = false
    if let s = asSlots.release(vm: vm) { link.setAddressSpace(slot: s, vm: -1) }
  }

  /// 07 section 7.13's validation, then 7.3.2: every queue idle, on the
  /// idle list; it takes no slot until it has work.
  public mutating func createGroup(vm: Int, priority: Int, queues: [QueueSpec]) throws(SchedError) -> Int {
    if deviceLost { throw .deviceLost }
    guard vm >= 0, vm < vmAlive.count, vmAlive[vm] else { throw .unknownVM }
    if liveGroups >= config.maxGroups { throw .tooManyGroups }
    let maxQueues = min(32, link.queuesPerGroup)
    if queues.count < 1 || queues.count > maxQueues { throw .badQueueCount }
    if priority < 0 || priority > 3 { throw .badPriority }
    var states: [QueueState] = []
    for q in queues {
      if q.priority < 0 || q.priority > 15 { throw .badPriority }
      guard let ring = JobRing(size: q.ringSize) else { throw .badRing }
      states.append(QueueState(ring: ring, spec: q))
    }
    var g = GroupRecord()
    g.vm = vm
    g.priority = priority
    g.queues = states
    g.exists = true
    g.stamp = nextStamp()
    var id = -1
    for i in 0..<groups.count where !groups[i].exists {
      id = i
      break
    }
    if id < 0 {
      groups.append(g)
      id = groups.count - 1
    } else {
      groups[id] = g
    }
    liveGroups += 1
    return id
  }

  /// The handle goes at once; a resident group is terminated by the next
  /// tick, which runs now (07 section 7.3.6).
  public mutating func destroyGroup(_ g: Int) throws(SchedError) {
    guard g >= 0, g < groups.count, groups[g].exists, !groups[g].destroyed else { throw .unknownGroup }
    groups[g].destroyed = true
    if groups[g].csg >= 0 {
      tickRequested = true
    } else {
      groups[g].state = .terminated
      cleanup(g)
    }
  }

  public func info(_ g: Int) -> GroupInfo? {
    guard g >= 0, g < groups.count, groups[g].exists else { return nil }
    let x = groups[g]
    return GroupInfo(state: x.state, csg: x.csg >= 0 ? x.csg : nil, csgPriority: x.csgPriority,
                     timedOut: x.timedOut, innocent: x.innocent, fatalQueues: x.fatalMask,
                     runnable: x.canRun)
  }

  /// Fences that signalled since the last call.
  public mutating func drainCompletions() -> [Completion] {
    let c = completions
    completions.removeAll()
    return c
  }

  public func residentCount() -> Int {
    var n = 0
    for s in slotOwner where s >= 0 { n += 1 }
    return n
  }

  public func vm(ofGroup g: Int) -> Int? { groups.indices.contains(g) && groups[g].exists ? groups[g].vm : nil }

  /// The AS slot a VM holds, if any.
  public func addressSpace(of vm: Int) -> Int? { asSlots.slot(of: vm) }

  /// When the next periodic tick is due, if ticking.
  public var nextTick: UInt64? {
    if !ticking { return nil }
    return (lastTick ?? 0) &+ config.tickPeriod
  }

  // MARK: Submission

  public struct Submitted: Equatable, Sendable {
    /// The fence number the job raises on its queue's sync object.
    public var sequence: UInt64
    /// Done at once (an empty job with nothing before it).
    public var completed: Bool
  }

  /// A job: a stream (64-byte aligned, a multiple of 8 bytes) run on a
  /// queue; size 0 with address 0 is the empty job (07 section 7.4.1).
  public mutating func submit(
    group g: Int, queue: Int, streamVA: UInt64, streamSize: UInt32, flushID: UInt32,
    tag: UInt64, now t: UInt64
  ) throws(SchedError) -> Submitted {
    if deviceLost { throw .deviceLost }
    now = t
    guard g >= 0, g < groups.count, groups[g].exists else { throw .unknownGroup }
    guard queue >= 0, queue < groups[g].queues.count else { throw .badJob }
    if !groups[g].canRun { throw .notRunnable }
    if (streamVA == 0) != (streamSize == 0) { throw .badJob }
    if streamVA & 63 != 0 || streamSize & 7 != 0 || flushID >> 24 & 0x7F != 0 { throw .badJob }

    if streamSize == 0 {
      if let f = groups[g].queues[queue].ring.reserveEmpty(tag: tag) {
        completions.append(Completion(group: g, queue: queue, job: f))
        return Submitted(sequence: f.sequence, completed: true)
      }
      return Submitted(sequence: groups[g].queues[queue].ring.lastSequence, completed: false)
    }

    let spec = groups[g].queues[queue].spec
    let prof = config.profiling
    let words = JobSequence.paddedCount(prof)
    guard groups[g].queues[queue].ring.credits >= words else { throw .ringFull }
    let slots = (spec.ringSize + 127) / 128
    let slot = groups[g].queues[queue].profilingSlot
    let seq = JobSequence.build(
      config.shape, flushID: flushID, streamVA: streamVA, streamSize: streamSize, syncVA: spec.syncVA,
      profilingSlot: spec.profilingVA &+ UInt64(slot) &* 32, profiling: prof)
    guard let place = groups[g].queues[queue].ring.reserve(words: seq.count, tag: tag) else {
      throw .ringFull
    }
    if prof.cycles || prof.time { groups[g].queues[queue].profilingSlot = (slot + 1) % slots }
    let ring = groups[g].queues[queue].ring
    for i in 0..<seq.count {
      link.storeRing(group: g, queue: queue, byteOffset: ring.byteOffset(at: place.start, word: i),
                     word: seq[i])
    }
    link.publishInsert(group: g, queue: queue, insert: ring.insert)

    let wasIdle = groups[g].isIdle
    groups[g].queues[queue].idle = false
    groups[g].queues[queue].blocked = false
    let csg = groups[g].csg
    if groups[g].queues[queue].deadline == nil && groups[g].queues[queue].paused == nil {
      if csg >= 0 {
        groups[g].queues[queue].deadline = now &+ config.jobTimeout
      } else {
        groups[g].queues[queue].paused = config.jobTimeout
      }
    }
    if csg >= 0 {
      link.ringDoorbell(csg: csg)
    } else if wasIdle {
      groups[g].stamp = nextStamp()  // to the runnable list's tail
    }
    wake(g)
    return Submitted(sequence: place.sequence, completed: false)
  }

  /// 07 section 7.6.5: when new work needs a tick now.
  private mutating func wake(_ g: Int) {
    var freeSlots = false
    var residentIdle = false
    var n = 0
    for s in slotOwner {
      if s >= 0 {
        n += 1
        if groups[s].isIdle { residentIdle = true }
      }
    }
    if n < maxResident { freeSlots = true }
    if groups[g].csg >= 0 {
      if !ticking { ticking = true }
      return
    }
    if groups[g].priority == 3 || residentIdle || freeSlots {
      tickRequested = true
    }
    ticking = true
  }

  // MARK: The loop

  /// Take the firmware's events, judge the timers, and run the tick and
  /// the reset that are due.
  public mutating func run(now t: UInt64) {
    now = t
    if deviceLost { return }
    for e in link.pollEvents() { handle(e) }
    checkTimeouts()
    var rounds = 0
    while rounds < 4 {
      rounds += 1
      if resetPending {
        fullReset()
        if deviceLost { return }
      }
      var due = tickRequested
      if ticking, let n = nextTick, now >= n { due = true }
      if lastTick == nil && ticking { due = true }
      if !due { break }
      tick()
      if !resetPending { break }
    }
  }

  /// A full reset is due (07 section 7.11), for `cause`; requests merge.
  private mutating func requestReset(_ cause: String) {
    resetPending = true
    var known = false
    for c in resetCauses where c.utf8.elementsEqual(cause.utf8) { known = true }
    if !known { resetCauses.append(cause) }
  }

  private func groupAt(csg: Int) -> Int? {
    guard csg >= 0, csg < slotOwner.count, slotOwner[csg] >= 0 else { return nil }
    return slotOwner[csg]
  }

  private mutating func handle(_ e: LinkEvent) {
    switch e {
    case .syncUpdate(let csg):
      if let g = groupAt(csg: csg) { collect(g) }
    case .idle, .globalIdle:
      tickRequested = true
    case .progressTimeout(let csg):
      if let g = groupAt(csg: csg) {
        groups[g].timedOut = true
        tickRequested = true
      }
    case .csFatal(let csg, let q, let unrecoverable):
      if let g = groupAt(csg: csg), q >= 0, q < groups[g].queues.count {
        groups[g].fatalMask |= 1 << UInt32(q)
        if unrecoverable {
          requestReset("CSG \(csg) CS \(q) reported CS_UNRECOVERABLE")
        } else {
          tickRequested = true
        }
      }
    case .tilerOOM(let csg, let q):
      if let g = groupAt(csg: csg), q >= 0, q < groups[g].queues.count, groups[g].canRun,
        !oomRaised.contains(where: { $0.group == g && $0.queue == q }) {
        oomRaised.append((g, q))
      }
    case .csFault(let csg, let q, let extract):
      if let g = groupAt(csg: csg), q >= 0, q < groups[g].queues.count {
        groups[g].queues[q].ring.fault(atExtract: extract)
        link.acknowledgeFault(csg: csg, queue: q)
      }
    case .mmuFault(let a):
      for g in 0..<groups.count where groups[g].exists && groups[g].csg >= 0 {
        if asSlots.slot(of: groups[g].vm) == a {
          // 07 section 7.10.7: fatal unless the firmware already said so.
          if groups[g].fatalMask == 0 { groups[g].fatalMask = (1 << UInt32(groups[g].queues.count)) &- 1 }
        }
      }
      asSlots.markFaulted(slot: a)
      tickRequested = true
    case .unknownState(let csg):
      if let g = groupAt(csg: csg) { groups[g].state = .unknown }
      requestReset("CSG \(csg) acknowledged a state outside 0 to 3")
    case .pingTimeout:
      requestReset("the firmware did not answer the watchdog's ping")
    case .resetRequested(let cause):
      requestReset(cause)
    }
  }

  // MARK: Tiler OOM (08 section 8.4)

  /// The OOMs raised since the last call for groups still on a slot, with
  /// what each reports (08 section 8.4.2 steps 3 and 4). A group that left
  /// its slot has none: the firmware raises the event again after its resume.
  public mutating func takeTilerRequests() -> [TilerRequest] {
    var out: [TilerRequest] = []
    for r in oomRaised {
      guard groups[r.group].csg >= 0 else { continue }
      out.append(TilerRequest(group: r.group, queue: r.queue,
                              report: link.tilerOOMReport(csg: groups[r.group].csg, queue: r.queue)))
    }
    oomRaised = []
    return out
  }

  /// 08 section 8.4.2 steps 7 and 8: the reply (a chunk's pointer, or 0 for
  /// none) and the acknowledge. False, nothing done, if the group is no
  /// longer on a slot (step 9): the caller takes the chunk back.
  public mutating func answerTilerRequest(group g: Int, queue: Int, chunk: UInt64) -> Bool {
    guard g >= 0, g < groups.count, groups[g].exists, groups[g].csg >= 0, groups[g].canRun else { return false }
    link.replyTilerHeap(csg: groups[g].csg, queue: queue, chunk: chunk)
    return true
  }

  /// 08 section 8.4.2 step 10: an invalid request is not acknowledged; the
  /// queue is faulted fatally and the group torn down at the next tick.
  public mutating func failQueue(group g: Int, queue: Int) {
    guard g >= 0, g < groups.count, groups[g].exists, queue >= 0, queue < groups[g].queues.count else { return }
    groups[g].fatalMask |= 1 << UInt32(queue)
    tickRequested = true
  }

  // MARK: Completion and timers

  /// Completion detection for a bound group (07 section 7.4.6).
  private mutating func collect(_ g: Int) {
    for q in 0..<groups[g].queues.count where groups[g].queues[q].ring.inFlight > 0 {
      let rec = link.readSync(group: g, queue: q)
      let done = groups[g].queues[q].ring.complete(rec)
      if done.isEmpty { continue }
      for f in done { completions.append(Completion(group: g, queue: q, job: f)) }
      // The timer restarts on a completion, and stops with nothing left.
      let left = groups[g].queues[q].ring.inFlight > 0
      if groups[g].csg >= 0 {
        groups[g].queues[q].deadline = left ? now &+ config.jobTimeout : nil
      } else {
        groups[g].queues[q].paused = left ? config.jobTimeout : nil
      }
    }
  }

  /// 07 section 7.10.3. A timer runs only while the group is on a slot;
  /// on expiry completions are checked first.
  ///
  /// [POLICY] The spec's exception (a queue blocked on a sync wait in an
  /// idle group keeps its timer off its slot) is not modelled: the
  /// timer pauses with the slot, and sync waits are left to the firmware.
  private mutating func checkTimeouts() {
    for g in 0..<groups.count where groups[g].exists && groups[g].csg >= 0 {
      var expired = false
      for q in groups[g].queues {
        if let d = q.deadline, d <= now { expired = true }
      }
      if !expired { continue }
      collect(g)
      for q in 0..<groups[g].queues.count {
        if let d = groups[g].queues[q].deadline, d <= now {
          groups[g].timedOut = true
          groups[g].queues[q].deadline = nil
          tickRequested = true
        }
      }
    }
  }

  private mutating func nextStamp() -> UInt64 {
    stampCounter += 1
    return stampCounter
  }

  // MARK: The tick

  private mutating func updateStatus(_ g: Int) {
    let csg = groups[g].csg
    for q in 0..<groups[g].queues.count {
      let st = link.queueStatus(csg: csg, queue: q)
      groups[g].queues[q].ring.observe(extract: st.extract)
      let ring = groups[g].queues[q].ring
      groups[g].queues[q].idle = st.blockedReason == 0 && ring.insert == ring.extract && st.scoreboards == 0
      groups[g].queues[q].blocked = st.blockedReason == 3 && st.scoreboards == 0
    }
  }

  /// Step 1 of 07 section 7.6.3: every bound group's queues, current.
  private mutating func refresh() -> Bool {
    if residentCount() == 0 { return true }
    if !link.statusUpdate() {
      requestReset("STATUS_UPDATE was not acknowledged")
      return false
    }
    for s in slotOwner where s >= 0 { updateStatus(s) }
    return true
  }

  /// Bound groups of one userspace priority, highest CSG priority first.
  private func residents(priority p: Int) -> [Int] {
    var out: [Int] = []
    for s in slotOwner where s >= 0 && groups[s].priority == p {
      var i = out.count
      out.append(s)
      while i > 0 && groups[out[i - 1]].csgPriority < groups[s].csgPriority {
        out[i] = out[i - 1]
        i -= 1
        out[i] = s
      }
    }
    return out
  }

  /// Unbound groups that can run, of one priority, in FIFO order; `idle`
  /// picks the idle list or the runnable one.
  private func waiting(priority p: Int, idle: Bool) -> [Int] {
    var out: [Int] = []
    for g in 0..<groups.count {
      let x = groups[g]
      if !x.exists || x.csg >= 0 || x.priority != p || !x.canRun || x.isIdle != idle { continue }
      var i = out.count
      out.append(g)
      while i > 0 && groups[out[i - 1]].stamp > x.stamp {
        out[i] = out[i - 1]
        i -= 1
        out[i] = g
      }
    }
    return out
  }

  private mutating func tick() {
    tickRequested = false
    let full = lastTick == nil || now &- lastTick! >= config.tickPeriod
    lastTick = now
    if !refresh() { return }

    var sel = Selection(maxGroups: maxResident, maxVMs: max(1, asSlots.userSlots))
    var prev: [[Int]] = []
    for p in 0...3 { prev.append(residents(priority: p)) }

    // Mid-slice: only realtime work preempts (steps 2).
    if !full {
      var p = 3
      while p >= 0 {
        for g in prev[p] where groups[g].canRun && !groups[g].isIdle { _ = sel.tryAdd(g, vm: groups[g].vm) }
        if p == 3 {
          for g in waiting(priority: 3, idle: false) { _ = sel.tryAdd(g, vm: groups[g].vm) }
        }
        p -= 1
      }
    }
    // The non-idle pass (step 3), realtime down.
    var p = 3
    while p >= 0 {
      var running: [Int] = []
      for g in prev[p] where groups[g].canRun && !groups[g].isIdle { running.append(g) }
      // The resident group of highest CSG priority is the rotation candidate:
      // it goes behind the others, so it gets the lowest priority next.
      let candidate = full && !running.isEmpty ? running[0] : -1
      for g in running where g != candidate { _ = sel.tryAdd(g, vm: groups[g].vm) }
      for g in waiting(priority: p, idle: false) { _ = sel.tryAdd(g, vm: groups[g].vm) }
      if candidate >= 0 { _ = sel.tryAdd(candidate, vm: groups[candidate].vm) }
      p -= 1
    }
    // The idle pass (step 4): bound ones first, to avoid reprogramming.
    p = 3
    while p >= 0 {
      for g in prev[p] where groups[g].canRun && groups[g].isIdle { _ = sel.tryAdd(g, vm: groups[g].vm) }
      for g in waiting(priority: p, idle: true) { _ = sel.tryAdd(g, vm: groups[g].vm) }
      p -= 1
    }

    // CSG priorities: by userspace priority, then selection order; 15 down.
    var order: [Int] = []
    p = 3
    while p >= 0 {
      for g in sel.ids where groups[g].priority == p { order.append(g) }
      p -= 1
    }
    var newPriority = [Int](repeating: 0, count: groups.count)
    for i in 0..<order.count { newPriority[order[i]] = 15 - i }

    // Apply (07 section 7.6.4): the unselected leave first.
    for s in slotOwner where s >= 0 && !sel.has(s) {
      if !evict(s) { return }
    }
    var updates: [LinkPriorityUpdate] = []
    for g in order where groups[g].csg >= 0 && groups[g].csgPriority != newPriority[g] {
      updates.append(LinkPriorityUpdate(csg: groups[g].csg, priority: newPriority[g]))
    }
    if !updates.isEmpty {
      if !link.setPriorities(updates) {
        requestReset("the CSG priority update was not acknowledged")
        return
      }
      for g in order where groups[g].csg >= 0 { groups[g].csgPriority = newPriority[g] }
    }
    for g in order where groups[g].csg < 0 {
      var slot = 0
      while slot < slotOwner.count && slotOwner[slot] >= 0 { slot += 1 }
      if slot >= slotOwner.count || !bind(g, csg: slot, priority: newPriority[g]) {
        requestReset(slot >= slotOwner.count ? "no free CSG slot for group \(g)" : "group \(g) did not start on CSG \(slot)")
        return
      }
    }

    // Step 6 and 8: keep ticking only where there is something to rotate.
    var more = false
    busy = false
    var counts = [0, 0, 0, 0]
    for g in sel.ids where !groups[g].isIdle {
      busy = true
      counts[groups[g].priority] += 1
    }
    for c in counts where c >= 2 { more = true }
    // [POLICY] The spec stops ticking unless two selected non-idle groups
    // share a priority. With fewer slots than that (one slot) rotation
    // would never start, so a non-idle group left waiting at the priority
    // of a selected one counts as something to rotate too.
    if !more {
      for g in 0..<groups.count where groups[g].exists && groups[g].csg < 0 && groups[g].canRun && !groups[g].isIdle {
        if counts[groups[g].priority] >= 1 { more = true }
      }
    }
    ticking = more
  }

  /// Take a group off its slot: SUSPEND if it can still run, else
  /// TERMINATE (07 section 7.3.5). False if the firmware didn't answer,
  /// when a reset is pending.
  private mutating func evict(_ g: Int) -> Bool {
    let csg = groups[g].csg
    let runnable = groups[g].canRun
    let ok = runnable ? link.suspend(csg: csg) : link.terminate(csg: csg)
    if !ok {
      requestReset("CSG \(csg) did not acknowledge \(runnable ? "SUSPEND" : "TERMINATE") of group \(g)")
      return false
    }
    collect(g)
    if runnable {
      updateStatus(g)
      groups[g].state = .suspended
    } else {
      groups[g].state = .terminated
    }
    unbind(g)
    if runnable {
      groups[g].stamp = nextStamp()  // back at the list's tail
    } else {
      cleanup(g)
    }
    return true
  }

  private mutating func unbind(_ g: Int) {
    // 07 section 7.3.5: the group's pending OOM work is dropped; the firmware raises it again after the resume.
    oomRaised.removeAll { $0.group == g }
    let csg = groups[g].csg
    if csg >= 0 { slotOwner[csg] = -1 }
    groups[g].csg = -1
    asSlots.deactivate(vm: groups[g].vm)
    for q in 0..<groups[g].queues.count {
      if let d = groups[g].queues[q].deadline {
        groups[g].queues[q].paused = d > now ? d - now : 0
        groups[g].queues[q].deadline = nil
      }
    }
  }

  private mutating func bind(_ g: Int, csg: Int, priority: Int) -> Bool {
    let as_: Int
    switch asSlots.activate(vm: groups[g].vm) {
    case .resident(let s):
      as_ = s
    case .program(let s):
      link.setAddressSpace(slot: s, vm: groups[g].vm)
      as_ = s
    case .recycle(let s, _):
      link.setAddressSpace(slot: s, vm: groups[g].vm)
      as_ = s
    case .busy:
      return false
    }
    var qs: [LinkQueueProgram] = []
    for q in groups[g].queues {
      qs.append(LinkQueueProgram(ringSize: q.ring.size, insert: q.ring.insert, extract: q.ring.extract,
                                 priority: q.spec.priority))
    }
    let program = LinkGroupProgram(group: g, addressSpace: as_, priority: priority,
                                   resume: groups[g].state == .suspended, queues: qs)
    if !link.program(csg: csg, group: program) {
      asSlots.deactivate(vm: groups[g].vm)
      return false
    }
    slotOwner[csg] = g
    groups[g].csg = csg
    groups[g].csgPriority = priority
    groups[g].state = .active
    for q in 0..<groups[g].queues.count where groups[g].queues[q].ring.inFlight > 0 {
      groups[g].queues[q].deadline = now &+ (groups[g].queues[q].paused ?? config.jobTimeout)
      groups[g].queues[q].paused = nil
    }
    return true
  }

  /// 07 section 7.10.5, for a group that can't run and is off its slot:
  /// every job in flight signals, the sync objects are written so that
  /// anything waiting on them is released.
  private mutating func cleanup(_ g: Int) {
    if groups[g].cleaned { return }
    groups[g].cleaned = true
    for q in 0..<groups[g].queues.count {
      var error = FenceError.cancelled
      if groups[g].timedOut && !groups[g].innocent { error = .timedOut }
      if groups[g].fatalMask >> UInt32(q) & 1 == 1 { error = .invalid }
      for f in groups[g].queues[q].ring.abort(error: error) {
        completions.append(Completion(group: g, queue: q, job: f))
      }
      groups[g].queues[q].deadline = nil
      groups[g].queues[q].paused = nil
      link.writeSync(group: g, queue: q,
                     record: SyncRecord(sequence: groups[g].queues[q].ring.lastSequence,
                                        status: SyncRecord.terminatedStatus))
    }
    if groups[g].destroyed {
      groups[g].exists = false
      liveGroups -= 1
    }
  }

  // MARK: Full reset (07 section 7.11)

  private mutating func fullReset() {
    // Suspend what is resident, as before a power-off (7.12.1).
    for csg in 0..<slotOwner.count where slotOwner[csg] >= 0 {
      let g = slotOwner[csg]
      let runnable = groups[g].canRun
      if (runnable ? link.suspend(csg: csg) : link.terminate(csg: csg)) {
        collect(g)
        if runnable {
          updateStatus(g)
          groups[g].state = .suspended
        } else {
          groups[g].state = .terminated
        }
      } else {
        // Lost: marked timed out, and innocent if it could have run on.
        groups[g].timedOut = true
        if runnable { groups[g].innocent = true }
        _ = link.terminate(csg: csg)
        groups[g].state = .terminated
      }
      unbind(g)
    }
    let cause = resetCauses.isEmpty ? "unspecified" : resetCauses.joined(separator: "; ")
    lastResetCause = cause
    resetCauses = []
    let ok = link.reset(cause: cause)
    asSlots.reset()
    _ = asSlots.activateMCU()
    resets += 1
    resetPending = false
    if !ok {
      deviceLost = true
      for g in 0..<groups.count where groups[g].exists { groups[g].state = .terminated }
    }
    for g in 0..<groups.count where groups[g].exists && !groups[g].canRun {
      cleanup(g)
    }
    // The survivors come back through the normal selection.
    for g in 0..<groups.count where groups[g].exists {
      for q in 0..<groups[g].queues.count where groups[g].queues[q].ring.inFlight == 0 {
        groups[g].queues[q].paused = nil
      }
    }
    oomRaised = []
    lastTick = nil
    tickRequested = !deviceLost
  }
}
