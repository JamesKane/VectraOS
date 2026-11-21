// SPDX-License-Identifier: BSD-3-Clause

// The scheduler against a fake firmware: groups resident up to the slots,
// rotation past them, a fault or a timeout ending one group alone, a reset.

import Mali
import Testing

/// A stand-in firmware: it keeps the rings the scheduler writes, runs
/// one job a step on every queue of a bound group (reading the words
/// back, to the ERROR_BARRIER), and raises the events the real one does.
struct FakeLink: FirmwareLink {
  struct Queue {
    var words: [Int: UInt64] = [:]
    var insert: UInt64 = 0
    var extract: UInt64 = 0
    var sync = SyncRecord(sequence: 0)
    var hang = false
    var faultNext = false
    var fatalNext = false
    var stopped = false
  }

  var csgSlotCount: Int
  var queuesPerGroup = 4
  var slots: [LinkGroupProgram?]
  var queues: [Int: Queue] = [:]
  var events: [LinkEvent] = []
  var asOwner: [Int: Int] = [:]
  var failSuspend: [Int] = []  // groups whose slot never acknowledges
  var resetOK = true
  var resets = 0
  var resumes = 0
  var maxResident = 0
  var priorityClash = false
  /// The group each slot held last: its status is read after the ack.
  var lastHeld: [Int]

  init(csgSlots: Int) {
    csgSlotCount = csgSlots
    slots = [LinkGroupProgram?](repeating: nil, count: csgSlots)
    lastHeld = [Int](repeating: -1, count: csgSlots)
  }

  static func key(_ g: Int, _ q: Int) -> Int { g * 64 + q }

  mutating func setAddressSpace(slot: Int, vm: Int) { asOwner[slot] = vm }

  mutating func program(csg: Int, group: LinkGroupProgram) -> Bool {
    if slots[csg] != nil { return false }
    slots[csg] = group
    lastHeld[csg] = group.group
    if group.resume { resumes += 1 }
    for i in 0..<group.queues.count {
      let k = FakeLink.key(group.group, i)
      var q = queues[k] ?? Queue()
      q.insert = group.queues[i].insert
      q.extract = group.queues[i].extract
      queues[k] = q
    }
    checkPriorities()
    return true
  }

  mutating func checkPriorities() {
    var seen: [Int] = []
    var n = 0
    for s in slots {
      if let p = s {
        if seen.contains(p.priority) { priorityClash = true }
        seen.append(p.priority)
        n += 1
      }
    }
    if n > maxResident { maxResident = n }
  }

  mutating func setPriorities(_ updates: [LinkPriorityUpdate]) -> Bool {
    for u in updates { slots[u.csg]?.priority = u.priority }
    checkPriorities()
    return true
  }

  mutating func suspend(csg: Int) -> Bool {
    guard let g = slots[csg] else { return false }
    if failSuspend.contains(g.group) { return false }
    slots[csg] = nil
    return true
  }

  mutating func terminate(csg: Int) -> Bool {
    guard let g = slots[csg] else { return true }
    if failSuspend.contains(g.group) { return false }
    slots[csg] = nil
    return true
  }

  mutating func statusUpdate() -> Bool { true }

  func queueStatus(csg: Int, queue: Int) -> LinkQueueStatus {
    let g = lastHeld[csg]
    return LinkQueueStatus(extract: queues[FakeLink.key(g, queue)]!.extract)
  }

  mutating func storeRing(group: Int, queue: Int, byteOffset: Int, word: UInt64) {
    queues[FakeLink.key(group, queue), default: Queue()].words[byteOffset] = word
  }

  mutating func publishInsert(group: Int, queue: Int, insert: UInt64) {
    queues[FakeLink.key(group, queue), default: Queue()].insert = insert
  }

  func readSync(group: Int, queue: Int) -> SyncRecord {
    queues[FakeLink.key(group, queue)]?.sync ?? SyncRecord(sequence: 0)
  }

  mutating func writeSync(group: Int, queue: Int, record: SyncRecord) {
    queues[FakeLink.key(group, queue), default: Queue()].sync = record
  }

  mutating func ringDoorbell(csg: Int) {}
  mutating func acknowledgeFault(csg: Int, queue: Int) {}

  /// What each stream reports on a TILER_OOM, by group and queue, and the replies given.
  var oomReports: [Int: TilerOOMReport] = [:]
  var heapReplies: [(group: Int, queue: Int, chunk: UInt64)] = []
  func tilerOOMReport(csg: Int, queue: Int) -> TilerOOMReport {
    oomReports[FakeLink.key(lastHeld[csg], queue)] ?? TilerOOMReport(heapAddress: 0, vtStart: 0, vtEnd: 0, fragEnd: 0)
  }
  mutating func replyTilerHeap(csg: Int, queue: Int, chunk: UInt64) {
    heapReplies.append((lastHeld[csg], queue, chunk))
  }

  /// The firmware raises a TILER_OOM on the queue of a bound group.
  mutating func raiseTilerOOM(group: Int, queue: Int, _ report: TilerOOMReport) {
    guard let csg = slots.firstIndex(where: { $0?.group == group }) else { return }
    oomReports[FakeLink.key(group, queue)] = report
    events.append(.tilerOOM(csg: csg, queue: queue))
  }

  mutating func pollEvents() -> [LinkEvent] {
    let e = events
    events.removeAll()
    return e
  }

  var resetCauses: [String] = []

  mutating func reset(cause: String) -> Bool {
    resets += 1
    resetCauses.append(cause)
    for i in 0..<slots.count { slots[i] = nil }
    asOwner.removeAll()
    return resetOK
  }

  /// The firmware's work for one step: a job on each bound queue.
  mutating func advance(ringSize: Int = 4096) {
    for csg in 0..<slots.count {
      guard let g = slots[csg] else { continue }
      var updated = false
      var allDrained = true
      for i in 0..<g.queues.count {
        let k = FakeLink.key(g.group, i)
        var q = queues[k]!
        if q.stopped || q.hang {
          allDrained = allDrained && q.extract == q.insert
          continue
        }
        if q.extract < q.insert {
          if q.fatalNext {
            q.stopped = true
            q.fatalNext = false
            events.append(.csFatal(csg: csg, queue: i, unrecoverable: false))
            queues[k] = q
            continue
          }
          // Read the job back from the ring, to its ERROR_BARRIER.
          let start = q.extract
          var n = 0
          while true {
            let w = q.words[Int((start + UInt64(n) * 8) % UInt64(g.queues[i].ringSize))] ?? 0
            n += 1
            if w >> 56 == 0x2F { break }
          }
          n = (n + 7) & ~7
          q.extract += UInt64(n) * 8
          q.sync.sequence += 1
          if q.faultNext {
            q.faultNext = false
            q.sync.status = 1
            events.append(.csFault(csg: csg, queue: i, extract: start + 8))
          }
          updated = true
        }
        allDrained = allDrained && q.extract == q.insert
        queues[k] = q
      }
      if updated { events.append(.syncUpdate(csg: csg)) }
      if allDrained && updated { events.append(.idle(csg: csg)) }
    }
  }
}

private let ms: UInt64 = 1_000_000

private func make(csgSlots: Int, asPresent: UInt32) -> GroupScheduler<FakeLink> {
  let cfg = SchedulerConfig(asPresent: asPresent, shape: JobSequenceShape(workRegisters: 96, scoreboards: 8))
  return GroupScheduler(link: FakeLink(csgSlots: csgSlots), config: cfg)
}

private func addGroup(_ s: inout GroupScheduler<FakeLink>, vm: Int? = nil, priority: Int = 1,
                      queues: Int = 1) throws -> Int {
  let v = vm ?? s.createVM()
  var specs: [QueueSpec] = []
  for i in 0..<queues { specs.append(QueueSpec(ringSize: 4096, syncVA: 0x1000 + UInt64(i) * 16)) }
  return try s.createGroup(vm: v, priority: priority, queues: specs)
}

private func job(_ s: inout GroupScheduler<FakeLink>, _ g: Int, queue: Int = 0, tag: UInt64 = 0,
                 at t: UInt64) throws {
  _ = try s.submit(group: g, queue: queue, streamVA: 0x10000, streamSize: 64, flushID: 0, tag: tag, now: t)
}

/// Step until `done` says so (at most `steps` of 10 ms), returning every completion.
private func drive(_ s: inout GroupScheduler<FakeLink>, from start: UInt64 = 0, steps: Int = 3000,
                   until done: (Int) -> Bool) -> [Completion] {
  var all: [Completion] = []
  var t = start
  for _ in 0..<steps {
    s.link.advance()
    s.run(now: t)
    all += s.drainCompletions()
    if done(all.count) { break }
    t += 10 * ms
  }
  return all
}

@Test func groupsUpToTheSlotsAreAllResidentWithDistinctPriorities() throws {
  var s = make(csgSlots: 8, asPresent: 0xFF)
  var ids: [Int] = []
  for _ in 0..<6 { ids.append(try addGroup(&s)) }
  for g in ids { try job(&s, g, at: 0) }
  s.run(now: 0)
  #expect(s.residentCount() == 6)
  var prios: [Int] = []
  for g in ids {
    let i = try #require(s.info(g))
    #expect(i.state == .active && i.csg != nil)
    prios.append(i.csgPriority)
  }
  #expect(Set(prios).count == 6 && prios.allSatisfy { $0 >= 0 && $0 <= 15 })
  let done = drive(&s, from: 10 * ms) { $0 >= 6 }
  #expect(done.count == 6 && done.allSatisfy { $0.job.error == .none })
  #expect(s.link.maxResident == 6 && !s.link.priorityClash && s.link.resumes == 0)
}

@Test func theCSGPriorityFollowsTheUserPriorityThenTheOrder() throws {
  var s = make(csgSlots: 4, asPresent: 0xFF)
  let low = try addGroup(&s, priority: 0)
  let rt = try addGroup(&s, priority: 3)
  let mid = try addGroup(&s, priority: 1)
  for g in [low, rt, mid] { try job(&s, g, at: 0) }
  s.run(now: 0)
  let p = [low, rt, mid].map { s.info($0)!.csgPriority }
  #expect(p == [13, 15, 14])
}

@Test func fortyGroupsOverEightSlotsAllCompleteTheirJobs() throws {
  var s = make(csgSlots: 8, asPresent: 0x1FF)
  var ids: [Int] = []
  for _ in 0..<40 { ids.append(try addGroup(&s, queues: 2)) }
  var tag: UInt64 = 0
  for g in ids {
    for q in 0..<2 {
      for _ in 0..<3 {
        try job(&s, g, queue: q, tag: tag, at: 0)
        tag += 1
      }
    }
  }
  s.run(now: 0)
  #expect(s.residentCount() == 8)
  let done = drive(&s, from: 10 * ms) { $0 >= 240 }
  #expect(done.count == 240 && done.allSatisfy { $0.job.error == .none })
  var tags: [UInt64] = done.map { $0.job.tag }
  tags.sort()
  #expect(tags == (0..<240).map { UInt64($0) })
  #expect(s.link.maxResident == 8 && !s.link.priorityClash)
  for g in ids { #expect(s.info(g)!.runnable) }
  // Groups came back from a suspend, not a fresh start.
  #expect(s.link.resumes > 0)
}

@Test func moreVMsThanAddressSpacesRotateThroughTheLeastRecentlyIdled() throws {
  // Three user slots for ten VMs: at most three groups are resident.
  var s = make(csgSlots: 8, asPresent: 0b1111)
  var ids: [Int] = []
  for _ in 0..<10 { ids.append(try addGroup(&s)) }
  for g in ids { try job(&s, g, at: 0) }
  let done = drive(&s) { $0 >= 10 }
  #expect(done.count == 10 && done.allSatisfy { $0.job.error == .none })
  #expect(s.link.maxResident <= 3)
}

@Test func twoGroupsShareAVMAndOneSlot() throws {
  var s = make(csgSlots: 8, asPresent: 0b11)
  let vm = s.createVM()
  let a = try addGroup(&s, vm: vm)
  let b = try addGroup(&s, vm: vm)
  let other = try addGroup(&s)
  for g in [a, b, other] { try job(&s, g, at: 0) }
  s.run(now: 0)
  // One address space: a and b run, the other VM waits.
  #expect(s.info(a)!.csg != nil && s.info(b)!.csg != nil && s.info(other)!.csg == nil)
  let done = drive(&s, from: 10 * ms) { $0 >= 3 }
  #expect(done.count == 3)
}

@Test func moreGroupsThanSlotsRotateOnTheTick() throws {
  var s = make(csgSlots: 1, asPresent: 0xFF)
  let a = try addGroup(&s)
  let b = try addGroup(&s)
  for _ in 0..<3 {
    try job(&s, a, at: 0)
    try job(&s, b, at: 0)
  }
  s.run(now: 0)
  #expect(s.info(a)!.csg == 0 && s.info(b)!.csg == nil)
  // The next full tick suspends a and runs b.
  s.run(now: 10 * ms)
  #expect(s.info(a)!.csg == nil && s.info(b)!.csg == 0)
  #expect(s.info(a)!.state == .suspended)
  #expect(s.nextTick == 20 * ms)
}

@Test func aFatalErrorEndsOnlyItsGroup() throws {
  var s = make(csgSlots: 8, asPresent: 0xFF)
  let bad = try addGroup(&s, queues: 2)
  let good1 = try addGroup(&s)
  let good2 = try addGroup(&s)
  for g in [bad, good1, good2] { try job(&s, g, at: 0) }
  try job(&s, bad, queue: 1, tag: 77, at: 0)
  s.link.queues[FakeLink.key(bad, 0)]?.fatalNext = true
  s.link.queues[FakeLink.key(bad, 1)]?.hang = true
  let done = drive(&s, from: 0, steps: 50) { _ in false }
  let badEnd = done.filter { $0.group == bad }
  #expect(badEnd.count == 2)
  #expect(badEnd.first { $0.queue == 0 }?.job.error == .invalid)
  #expect(badEnd.first { $0.queue == 1 }?.job.error == .cancelled)
  let info = try #require(s.info(bad))
  #expect(info.state == .terminated && !info.runnable && info.fatalQueues == 1 && info.csg == nil)
  #expect(done.filter { $0.group != bad }.count == 2)
  #expect(done.filter { $0.group != bad }.allSatisfy { $0.job.error == .none })
  #expect(s.info(good1)!.runnable && s.info(good2)!.runnable && s.resets == 0)
  // The terminated group's sync object is written so that waiters are released.
  let rec = s.link.readSync(group: bad, queue: 0)
  #expect(rec.status == SyncRecord.terminatedStatus && rec.sequence == 1)
  #expect(throws: SchedError.notRunnable) { try job(&s, bad, at: 600 * ms) }
  // A new group runs afterwards.
  let fresh = try addGroup(&s)
  try job(&s, fresh, at: 600 * ms)
  let more = drive(&s, from: 600 * ms, steps: 20) { $0 >= 1 }
  #expect(more.count == 1 && more[0].group == fresh && more[0].job.error == .none)
}

@Test func anMMUFaultEndsTheGroupWhoseVMFaulted() throws {
  var s = make(csgSlots: 8, asPresent: 0xFF)
  let bad = try addGroup(&s)
  let good = try addGroup(&s)
  try job(&s, bad, at: 0)
  try job(&s, good, at: 0)
  s.link.queues[FakeLink.key(bad, 0)]?.hang = true
  s.run(now: 0)
  let as_ = try #require(s.addressSpace(of: s.vm(ofGroup: bad)!))
  s.link.events.append(.mmuFault(addressSpace: as_))
  s.run(now: ms)
  #expect(s.info(bad)!.state == .terminated && s.info(bad)!.fatalQueues == 1)
  #expect(s.info(good)!.runnable)
  let c = s.drainCompletions()
  #expect(c.contains { $0.group == bad && $0.job.error == .invalid })
}

@Test func aRecoverableFaultMarksItsJobAndTheGroupRunsOn() throws {
  var s = make(csgSlots: 4, asPresent: 0xFF)
  let g = try addGroup(&s)
  try job(&s, g, tag: 1, at: 0)
  try job(&s, g, tag: 2, at: 0)
  s.link.queues[FakeLink.key(g, 0)]?.faultNext = true
  let done = drive(&s, steps: 20) { $0 >= 2 }
  #expect(done.count == 2)
  #expect(done[0].job.error == .invalid && done[1].job.error == .none)
  #expect(s.info(g)!.runnable)
}

@Test func aJobPastItsTimeoutEndsItsGroupAlone() throws {
  var s = make(csgSlots: 8, asPresent: 0xFF)
  let hung = try addGroup(&s)
  let fine = try addGroup(&s)
  try job(&s, hung, tag: 5, at: 0)
  s.link.queues[FakeLink.key(hung, 0)]?.hang = true
  s.run(now: 0)
  #expect(s.info(hung)!.csg != nil)
  var all: [Completion] = []
  var t: UInt64 = 0
  while t < 4_990 * ms {
    t += 10 * ms
    s.run(now: t)
  }
  #expect(s.info(hung)!.runnable)  // not before 5 s
  try job(&s, fine, tag: 6, at: t)
  s.run(now: 5_000 * ms - 1)
  #expect(s.info(hung)!.runnable)
  all += drive(&s, from: 5_000 * ms, steps: 10) { _ in false }
  let info = try #require(s.info(hung))
  #expect(info.timedOut && info.state == .terminated && info.csg == nil)
  #expect(all.contains { $0.group == hung && $0.job.tag == 5 && $0.job.error == .timedOut })
  #expect(all.contains { $0.group == fine && $0.job.error == .none })
  #expect(s.info(fine)!.runnable)
}

@Test func aGroupOffItsSlotDoesNotRunDownItsTimeout() throws {
  var s = make(csgSlots: 1, asPresent: 0xFF)
  let a = try addGroup(&s)
  let b = try addGroup(&s)
  try job(&s, a, at: 0)
  try job(&s, b, at: 0)
  s.link.queues[FakeLink.key(a, 0)]?.hang = true
  s.run(now: 0)
  // a hangs and holds the slot for a tick, then rotates out; b runs;
  // 10 s of waiting off the slot must not time b out.
  var t: UInt64 = 0
  while t < 4_000 * ms {
    t += 10 * ms
    s.link.advance()
    s.run(now: t)
  }
  #expect(s.info(b)!.runnable)
  #expect(s.drainCompletions().contains { $0.group == b })
}

@Test func aFullResetKeepsTheCleanlySuspendedAndLosesTheRest() throws {
  var s = make(csgSlots: 8, asPresent: 0xFF)
  let survivor = try addGroup(&s)
  let lost = try addGroup(&s)
  let waiting = try addGroup(&s)  // never bound: no work yet
  try job(&s, survivor, tag: 1, at: 0)
  try job(&s, lost, tag: 2, at: 0)
  s.link.queues[FakeLink.key(survivor, 0)]?.hang = true  // its job is mid-flight at the reset
  s.run(now: 0)
  #expect(s.info(survivor)!.csg != nil && s.info(lost)!.csg != nil)
  s.link.failSuspend = [lost]
  s.link.events.append(.pingTimeout)
  s.run(now: 10 * ms)
  #expect(s.resets == 1 && s.link.resets == 1 && !s.deviceLost)
  let l = try #require(s.info(lost))
  #expect(l.state == .terminated && l.timedOut && l.innocent && !l.runnable)
  let done = s.drainCompletions()
  #expect(done.contains { $0.group == lost && $0.job.error == .cancelled })
  let sv = try #require(s.info(survivor))
  #expect(sv.runnable)
  #expect(s.info(waiting)!.runnable)
  // The survivor is resumed by the tick the reset ends with, and its job
  // finishes once the firmware lets it.
  #expect(sv.state == .active)
  #expect(s.link.resumes == 2)  // the survivor, and the idle group that held a slot too
  s.link.queues[FakeLink.key(survivor, 0)]?.hang = false
  let more = drive(&s, from: 20 * ms, steps: 20) { $0 >= 1 }
  #expect(more.count == 1 && more[0].group == survivor && more[0].job.error == .none)
  // Work for new groups goes on.
  try job(&s, waiting, tag: 9, at: 300 * ms)
  let last = drive(&s, from: 300 * ms, steps: 20) { $0 >= 1 }
  #expect(last.count == 1 && last[0].job.error == .none)
}

@Test func anUnrecoverableFatalErrorResetsTheGPU() throws {
  var s = make(csgSlots: 4, asPresent: 0xFF)
  let a = try addGroup(&s)
  let b = try addGroup(&s)
  try job(&s, a, at: 0)
  try job(&s, b, at: 0)
  s.link.queues[FakeLink.key(a, 0)]?.hang = true
  s.link.queues[FakeLink.key(b, 0)]?.hang = true
  s.run(now: 0)
  let csg = try #require(s.info(a)?.csg)
  s.link.events.append(.csFatal(csg: csg, queue: 0, unrecoverable: true))
  s.run(now: ms)
  #expect(s.resets == 1)
  #expect(!s.info(a)!.runnable)
  #expect(s.info(b)!.runnable)
}

@Test func aResetTheFirmwareDoesNotComeBackFromLosesTheDevice() throws {
  var s = make(csgSlots: 4, asPresent: 0xFF)
  let a = try addGroup(&s)
  try job(&s, a, at: 0)
  s.link.queues[FakeLink.key(a, 0)]?.hang = true
  s.run(now: 0)
  s.link.resetOK = false
  s.link.events.append(.pingTimeout)
  s.run(now: ms)
  #expect(s.deviceLost && s.info(a)!.state == .terminated)
  #expect(throws: SchedError.deviceLost) { try job(&s, a, at: 2 * ms) }
  #expect(throws: SchedError.deviceLost) { _ = try s.createGroup(vm: 0, priority: 0, queues: [QueueSpec(ringSize: 4096)]) }
}

@Test func anIdleGroupGivesItsSlotToWorkAndIsRebound() throws {
  var s = make(csgSlots: 2, asPresent: 0xFF)
  let a = try addGroup(&s)
  let b = try addGroup(&s)
  let c = try addGroup(&s)
  try job(&s, a, at: 0)
  try job(&s, b, at: 0)
  let d1 = drive(&s, steps: 5) { $0 >= 2 }
  #expect(d1.count == 2)
  // Both are now idle yet resident; a's new work and c's first work arrive.
  try job(&s, c, at: 100 * ms)
  try job(&s, a, at: 100 * ms)
  let d2 = drive(&s, from: 100 * ms, steps: 10) { $0 >= 2 }
  #expect(d2.count == 2)
}

@Test func groupsAndQueuesAreValidated() throws {
  var s = make(csgSlots: 8, asPresent: 0xFF)
  let vm = s.createVM()
  #expect(throws: SchedError.badQueueCount) { _ = try s.createGroup(vm: vm, priority: 1, queues: []) }
  #expect(throws: SchedError.badQueueCount) {
    _ = try s.createGroup(vm: vm, priority: 1, queues: [QueueSpec](repeating: QueueSpec(ringSize: 4096), count: 5))
  }
  #expect(throws: SchedError.badPriority) { _ = try s.createGroup(vm: vm, priority: 4, queues: [QueueSpec(ringSize: 4096)]) }
  #expect(throws: SchedError.badPriority) {
    _ = try s.createGroup(vm: vm, priority: 1, queues: [QueueSpec(ringSize: 4096, priority: 16)])
  }
  #expect(throws: SchedError.badRing) { _ = try s.createGroup(vm: vm, priority: 1, queues: [QueueSpec(ringSize: 5000)]) }
  #expect(throws: SchedError.unknownVM) { _ = try s.createGroup(vm: 9, priority: 1, queues: [QueueSpec(ringSize: 4096)]) }
  let g = try s.createGroup(vm: vm, priority: 1, queues: [QueueSpec(ringSize: 4096)])
  #expect(throws: SchedError.vmInUse) { try s.destroyVM(vm) }
  #expect(throws: SchedError.badJob) { try job(&s, g, queue: 1, at: 0) }
  #expect(throws: SchedError.badJob) {
    _ = try s.submit(group: g, queue: 0, streamVA: 0x10008, streamSize: 64, flushID: 0, tag: 0, now: 0)
  }
  #expect(throws: SchedError.badJob) {
    _ = try s.submit(group: g, queue: 0, streamVA: 0x10000, streamSize: 60, flushID: 0, tag: 0, now: 0)
  }
  #expect(throws: SchedError.badJob) {
    _ = try s.submit(group: g, queue: 0, streamVA: 0, streamSize: 64, flushID: 0, tag: 0, now: 0)
  }
  #expect(throws: SchedError.badJob) {
    _ = try s.submit(group: g, queue: 0, streamVA: 0x10000, streamSize: 64, flushID: 1 << 24, tag: 0, now: 0)
  }
  try s.destroyGroup(g)
  try s.destroyVM(vm)
  #expect(s.info(g) == nil)
}

@Test func theRingFillsAndTheClientIsToldToWait() throws {
  var s = make(csgSlots: 2, asPresent: 0xFF)
  let g = try addGroup(&s)
  for i in 0..<32 { try job(&s, g, tag: UInt64(i), at: 0) }
  #expect(throws: SchedError.ringFull) { try job(&s, g, at: 0) }
  let done = drive(&s, steps: 100) { $0 >= 32 }
  #expect(done.count == 32)
  try job(&s, g, at: 2_000 * ms)  // credits came back
}

@Test func anEmptyJobCompletesAfterTheOnesBeforeIt() throws {
  var s = make(csgSlots: 2, asPresent: 0xFF)
  let g = try addGroup(&s)
  let first = try s.submit(group: g, queue: 0, streamVA: 0, streamSize: 0, flushID: 0, tag: 1, now: 0)
  #expect(first.completed)
  try job(&s, g, tag: 2, at: 0)
  let e = try s.submit(group: g, queue: 0, streamVA: 0, streamSize: 0, flushID: 0, tag: 3, now: 0)
  #expect(!e.completed && e.sequence == 1)
  let done = drive(&s, steps: 20) { $0 >= 3 }
  #expect(done.map { $0.job.tag } == [1, 2, 3])
}

@Test func destroyingAResidentGroupTerminatesItAtTheNextTick() throws {
  var s = make(csgSlots: 2, asPresent: 0xFF)
  let g = try addGroup(&s)
  let keep = try addGroup(&s)
  try job(&s, g, tag: 1, at: 0)
  try job(&s, keep, tag: 2, at: 0)
  s.link.queues[FakeLink.key(g, 0)]?.hang = true
  s.run(now: 0)
  try s.destroyGroup(g)
  #expect(throws: SchedError.unknownGroup) { try s.destroyGroup(g) }
  s.run(now: ms)
  #expect(s.info(g) == nil && s.residentCount() <= 1)
  let c = s.drainCompletions()
  #expect(c.contains { $0.group == g && $0.job.error == .cancelled })
}

@Test func theProfilingMaskChangesAJobsCredits() throws {
  var s = make(csgSlots: 2, asPresent: 0xFF)
  s.config.profiling = ProfilingKinds(cycles: true, time: true)
  let g = try s.createGroup(vm: s.createVM(), priority: 1, queues: [QueueSpec(ringSize: 4096, syncVA: 0x1000, profilingVA: 0x9000)])
  for i in 0..<21 { try job(&s, g, tag: UInt64(i), at: 0) }  // 512 / 24
  #expect(throws: SchedError.ringFull) { try job(&s, g, at: 0) }
  let done = drive(&s, steps: 50) { $0 >= 21 }
  #expect(done.count == 21)
}

// MARK: What starts a full reset, and what the reset is told

@Test func aBusFaultWithItsTranslationFaultEndsOnlyItsGroupAndNeverResets() throws {
  var s = make(csgSlots: 4, asPresent: 0xFF)
  let bad = try addGroup(&s)
  let good = try addGroup(&s)
  try job(&s, bad, at: 0)
  try job(&s, good, at: 0)
  s.link.queues[FakeLink.key(bad, 0)]?.hang = true
  s.run(now: 0)
  let csg = try #require(s.info(bad)?.csg)
  let slot = try #require(s.link.slots[csg]?.addressSpace)
  // What the board showed: the stream's CS_BUS_FAULT (not CS_UNRECOVERABLE) and the AS's translation fault.
  s.link.events.append(.csFatal(csg: csg, queue: 0, unrecoverable: false))
  s.link.events.append(.mmuFault(addressSpace: slot))
  s.run(now: ms)
  #expect(s.resets == 0 && s.link.resets == 0 && s.lastResetCause.isEmpty)
  let info = try #require(s.info(bad))
  #expect(info.state == .terminated && !info.runnable && info.fatalQueues == 1 && info.csg == nil)
  #expect(s.info(good)!.runnable && !s.deviceLost)
}

private func resetCause(after event: LinkEvent) throws -> String {
  var s = make(csgSlots: 4, asPresent: 0xFF)
  let a = try addGroup(&s)
  try job(&s, a, at: 0)
  s.link.queues[FakeLink.key(a, 0)]?.hang = true
  s.run(now: 0)
  s.link.events.append(event)
  s.run(now: ms)
  #expect(s.resets == 1 && s.link.resets == 1)
  #expect(s.link.resetCauses == [s.lastResetCause])
  return s.lastResetCause
}

@Test func eachResetNamesItsCause() throws {
  #expect(try resetCause(after: .pingTimeout) == "the firmware did not answer the watchdog's ping")
  #expect(try resetCause(after: .csFatal(csg: 0, queue: 0, unrecoverable: true)) == "CSG 0 CS 0 reported CS_UNRECOVERABLE")
  #expect(try resetCause(after: .unknownState(csg: 0)) == "CSG 0 acknowledged a state outside 0 to 3")
  let asCause = "address space 1: AS_STATUS stays active after the command"
  #expect(try resetCause(after: .resetRequested(cause: asCause)) == asCause)
}

@Test func requestsForOneResetMergeTheirCausesInOrder() throws {
  var s = make(csgSlots: 4, asPresent: 0xFF)
  let a = try addGroup(&s)
  try job(&s, a, at: 0)
  s.link.queues[FakeLink.key(a, 0)]?.hang = true
  s.run(now: 0)
  let flush = "cache flush: no CLEAN_CACHES_COMPLETED in 100 ms"
  s.link.events.append(.resetRequested(cause: flush))
  s.link.events.append(.pingTimeout)
  s.link.events.append(.resetRequested(cause: flush))
  s.run(now: ms)
  #expect(s.resets == 1 && s.link.resets == 1)
  #expect(s.lastResetCause == flush + "; the firmware did not answer the watchdog's ping")
  // The next reset starts its list afresh.
  s.link.events.append(.pingTimeout)
  s.run(now: 5 * ms)
  #expect(s.resets == 2 && s.lastResetCause == "the firmware did not answer the watchdog's ping")
}

@Test func aSlotThatWontLeaveNamesItselfAsTheCause() throws {
  var s = make(csgSlots: 1, asPresent: 0xFF)
  let a = try addGroup(&s)
  let b = try addGroup(&s)
  for _ in 0..<3 {
    try job(&s, a, at: 0)
    try job(&s, b, at: 0)
  }
  s.run(now: 0)
  #expect(s.info(a)!.csg == 0)
  s.link.failSuspend = [a]
  s.run(now: 10 * ms)  // the tick rotates: a's SUSPEND is not acknowledged
  #expect(s.resets == 1)
  #expect(s.lastResetCause == "CSG 0 did not acknowledge SUSPEND of group \(a)")
}

@Test func aTilerOOMIsTakenOnceForAResidentGroupAndAnsweredThroughItsSlot() throws {
  var s = make(csgSlots: 2, asPresent: 0xFF)
  let a = try addGroup(&s, queues: 2)
  try job(&s, a, at: 0)
  s.link.queues[FakeLink.key(a, 0)]?.hang = true
  s.run(now: 0)
  let csg = try #require(s.info(a)?.csg)
  let report = TilerOOMReport(heapAddress: 0x4000, vtStart: 5, vtEnd: 4, fragEnd: 3)
  // Raised twice (a second interrupt of the stream names it again): one request.
  s.link.raiseTilerOOM(group: a, queue: 1, report)
  s.link.raiseTilerOOM(group: a, queue: 1, report)
  s.run(now: ms)
  let taken = s.takeTilerRequests()
  #expect(taken == [TilerRequest(group: a, queue: 1, report: report)])
  #expect(s.takeTilerRequests().isEmpty)
  let answered = s.answerTilerRequest(group: a, queue: 1, chunk: 0x1234_0200)
  #expect(answered)
  #expect(s.link.heapReplies.count == 1 && s.link.heapReplies[0].group == a && s.link.heapReplies[0].queue == 1
    && s.link.heapReplies[0].chunk == 0x1234_0200)
  #expect(s.info(a)?.csg == csg && s.info(a)?.runnable == true)
}

@Test func aTilerOOMOfAGroupThatLeftItsSlotIsDroppedAndItsReplyRefused() throws {
  var s = make(csgSlots: 2, asPresent: 0xFF)
  let a = try addGroup(&s)
  try job(&s, a, at: 0)
  s.link.queues[FakeLink.key(a, 0)]?.hang = true
  s.run(now: 0)
  s.link.raiseTilerOOM(group: a, queue: 0, TilerOOMReport(heapAddress: 0x4000, vtStart: 5, vtEnd: 4, fragEnd: 3))
  // The group is destroyed in the same pass: its event is seen, then its slot is given up.
  try s.destroyGroup(a)
  s.run(now: ms)
  let left = s.takeTilerRequests()
  let refused = !s.answerTilerRequest(group: a, queue: 0, chunk: 0x1000_0200)
  #expect(left.isEmpty && refused)
  #expect(s.link.heapReplies.isEmpty)
}

@Test func aSuspendedGroupsOOMIsNotServedUntilTheFirmwareRaisesItAgain() throws {
  var s = make(csgSlots: 1, asPresent: 0xFF)
  let a = try addGroup(&s)
  let b = try addGroup(&s)
  for g in [a, b] {
    try job(&s, g, at: 0)
    try job(&s, g, tag: 1, at: 0)
    s.link.queues[FakeLink.key(g, 0)]?.hang = true
  }
  s.run(now: 0)
  let first = try #require(s.info(a)?.csg == 0 ? a : b)
  let second = first == a ? b : a
  s.link.raiseTilerOOM(group: first, queue: 0, TilerOOMReport(heapAddress: 0x4000, vtStart: 5, vtEnd: 4, fragEnd: 3))
  // Not taken before the tick rotates the slot to the other group.
  s.run(now: 11 * ms)
  #expect(s.info(first)?.csg == nil && s.info(second)?.csg == 0)
  let left = s.takeTilerRequests()
  let refused = !s.answerTilerRequest(group: first, queue: 0, chunk: 0x1000_0200)
  #expect(left.isEmpty && refused)
}

@Test func anInvalidRequestFaultsItsQueueAndTheGroupIsTornDown() throws {
  var s = make(csgSlots: 2, asPresent: 0xFF)
  let a = try addGroup(&s, queues: 2)
  let b = try addGroup(&s)
  try job(&s, a, at: 0)
  try job(&s, b, at: 0)
  s.link.queues[FakeLink.key(a, 0)]?.hang = true
  s.link.queues[FakeLink.key(b, 0)]?.hang = true
  s.run(now: 0)
  s.failQueue(group: a, queue: 1)
  s.run(now: ms)
  let info = try #require(s.info(a))
  #expect(info.fatalQueues == 2 && !info.runnable)
  #expect(s.info(b)?.runnable == true && s.info(b)?.csg != nil)
  #expect(s.link.heapReplies.isEmpty)
}
