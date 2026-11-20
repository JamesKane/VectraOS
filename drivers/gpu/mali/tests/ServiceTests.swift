// SPDX-License-Identifier: BSD-3-Clause

// The `csf` server (Service.swift) over a model device: a fake firmware
// (SchedulerTests' FakeLink) that also decodes each job's ring words, finds
// the stream the kernel's sequence calls, and ends the group with a fatal
// fault if that address isn't mapped in its VM, which is what the GPU's
// MMU does. The tests: a stream's job raises its counter, waits are kept,
// a faulted group is lost and nothing else is, the validation of 10 and
// 07 section 7.13, binds' replacing and buffers' lifetimes, a VM that
// outlives its handle for its groups, a context's close.

import Mali
import MaliService
import Testing

private let ms: UInt64 = 1_000_000

struct FakeDevice: CSFBackend {
  var link: FakeLink
  var device = CSFDeviceInfo(
    gpuID: 0xA867_0000, asPresent: 0xFF, vaBits: 48, groupSlots: 8, queuesPerGroup: 4, workRegisters: 96,
    scoreboards: 8)
  var clock: UInt64 = 0
  var userAddressSpace: UInt64 = 0
  var nanoseconds: UInt64 { clock }

  var nextKey = 1
  var buffers: [Int: UInt64] = [:]
  var freedBuffers: [Int] = []
  var failAllocations = false
  struct Map { var va: UInt64; var size: UInt64; var buffer: Int; var flags: CSFMapFlags }
  var maps: [Int: [Map]] = [:]
  var vmsCreated: [Int] = []
  var vmsDestroyed: [Int] = []
  var groupVM: [Int: Int] = [:]
  var attached: [Int: [CSFQueueMemory]] = [:]
  var detached: [Int] = []
  var counters: [UInt32: UInt64] = [:]
  var closedCounters: [UInt32] = []
  /// Streams the model GPU called: group and address.
  var ran: [(group: Int, va: UInt64)] = []

  init(csgSlots: Int = 8) { link = FakeLink(csgSlots: csgSlots) }

  var csgSlotCount: Int { link.csgSlotCount }
  var queuesPerGroup: Int { link.queuesPerGroup }
  mutating func setAddressSpace(slot: Int, vm: Int) { link.setAddressSpace(slot: slot, vm: vm) }
  mutating func program(csg: Int, group: LinkGroupProgram) -> Bool { link.program(csg: csg, group: group) }
  mutating func setPriorities(_ updates: [LinkPriorityUpdate]) -> Bool { link.setPriorities(updates) }
  mutating func suspend(csg: Int) -> Bool { link.suspend(csg: csg) }
  mutating func terminate(csg: Int) -> Bool { link.terminate(csg: csg) }
  mutating func statusUpdate() -> Bool { link.statusUpdate() }
  func queueStatus(csg: Int, queue: Int) -> LinkQueueStatus { link.queueStatus(csg: csg, queue: queue) }
  mutating func storeRing(group: Int, queue: Int, byteOffset: Int, word: UInt64) {
    link.storeRing(group: group, queue: queue, byteOffset: byteOffset, word: word)
  }
  mutating func publishInsert(group: Int, queue: Int, insert: UInt64) {
    link.publishInsert(group: group, queue: queue, insert: insert)
  }
  func readSync(group: Int, queue: Int) -> SyncRecord { link.readSync(group: group, queue: queue) }
  mutating func writeSync(group: Int, queue: Int, record: SyncRecord) {
    link.writeSync(group: group, queue: queue, record: record)
  }
  mutating func ringDoorbell(csg: Int) { link.ringDoorbell(csg: csg) }
  mutating func acknowledgeFault(csg: Int, queue: Int) { link.acknowledgeFault(csg: csg, queue: queue) }
  mutating func pollEvents() -> [LinkEvent] { link.pollEvents() }
  mutating func reset() -> Bool { link.reset() }

  mutating func allocateBuffer(size: UInt64) -> Int? {
    if failAllocations { return nil }
    let k = nextKey
    nextKey += 1
    buffers[k] = size
    return k
  }
  mutating func freeBuffer(_ buffer: Int) {
    buffers[buffer] = nil
    freedBuffers.append(buffer)
  }
  mutating func createVM(_ vm: Int) -> Bool {
    vmsCreated.append(vm)
    maps[vm] = []
    return true
  }
  mutating func destroyVM(_ vm: Int) {
    vmsDestroyed.append(vm)
    maps[vm] = nil
  }
  mutating func map(vm: Int, buffer: Int, offset: UInt64, size: UInt64, va: UInt64, flags: CSFMapFlags) -> Bool {
    maps[vm, default: []].append(Map(va: va, size: size, buffer: buffer, flags: flags))
    return true
  }
  mutating func unmap(vm: Int, va: UInt64, size: UInt64) {
    var kept: [Map] = []
    for m in maps[vm] ?? [] {
      if m.va + m.size <= va || m.va >= va + size {
        kept.append(m)
        continue
      }
      if m.va < va { kept.append(Map(va: m.va, size: va - m.va, buffer: m.buffer, flags: m.flags)) }
      if va + size < m.va + m.size {
        kept.append(Map(va: va + size, size: m.va + m.size - (va + size), buffer: m.buffer, flags: m.flags))
      }
    }
    maps[vm] = kept
  }
  mutating func attachGroup(group: Int, vm: Int, queues: [CSFQueueMemory]) -> Bool {
    groupVM[group] = vm
    attached[group] = queues
    return true
  }
  mutating func detachGroup(group: Int) {
    detached.append(group)
    attached[group] = nil
    groupVM[group] = nil
  }
  func counterValue(_ counter: UInt32) -> UInt64 { counters[counter] ?? 0 }
  mutating func raiseCounter(_ counter: UInt32, to value: UInt64) {
    counters[counter] = max(counters[counter] ?? 0, value)
  }
  mutating func closeCounter(_ counter: UInt32) { closedCounters.append(counter) }

  func mapped(vm: Int, va: UInt64) -> Bool {
    for m in maps[vm] ?? [] where m.va <= va && va < m.va + m.size { return true }
    return false
  }

  /// One step of the model GPU: the call each queue's job makes is read
  /// from the ring (07 section 7.4.4's sequence: MOV48 of the stream's
  /// address, then CALL), and a call to an address its VM doesn't map is a
  /// fatal fault; then the firmware's own step.
  mutating func step() {
    for csg in 0..<link.slots.count {
      guard let g = link.slots[csg], let vm = groupVM[g.group] else { continue }
      for i in 0..<g.queues.count {
        let k = FakeLink.key(g.group, i)
        guard let q = link.queues[k], q.extract < q.insert, !q.fatalNext, !q.stopped, !q.hang else { continue }
        var at = q.extract
        var address: UInt64 = 0
        var called: UInt64?
        while true {
          let w = q.words[Int(at % UInt64(g.queues[i].ringSize))] ?? 0
          at += 8
          if w >> 56 == 0x01 { address = w & 0xFFFF_FFFF_FFFF }
          if w >> 56 == 0x20 { called = address }
          if w >> 56 == 0x2F { break }
        }
        if let a = called {
          if mapped(vm: vm, va: a) {
            ran.append((g.group, a))
          } else {
            link.queues[k]!.fatalNext = true
          }
        }
      }
    }
    link.advance()
    clock += 10 * ms
  }
}

typealias Service = CSFService<FakeDevice>

private func make(csgSlots: Int = 8) -> Service { Service(backend: FakeDevice(csgSlots: csgSlots)) }

/// Step the model and the service until `done`.
private func drive(_ s: inout Service, steps: Int = 300, until done: (Service) -> Bool) {
  for _ in 0..<steps {
    s.scheduler.link.step()
    s.pump()
    if done(s) { return }
  }
}

private struct Rig {
  var s = make()
  var c = 0
  var vm: UInt32 = 0
  var buffer: UInt32 = 0
  var group: UInt32 = 0
  var sync: UInt32 = 0
  static let counter: UInt32 = 100
  static let streamVA: UInt64 = 0x10000

  /// A context with a VM, a buffer bound at `streamVA`, a group of one
  /// queue and a sync on counter 100.
  init(priority: UInt32 = 1) throws {
    c = s.openContext()
    vm = try s.createVM(c, userRange: 0).id
    buffer = try s.createBuffer(c, size: 8192, flags: 0).id
    try s.bind(c, vm: vm, buffer: buffer, offset: 0, size: 8192, address: Rig.streamVA, flags: 0)
    group = try s.createGroup(c, vm: vm, queues: [(4096, 0)], priority: priority)
    sync = try s.addSync(c, counter: Rig.counter)
  }
}

@Test func aStreamRunsAndRaisesItsCounter() throws {
  var r = try Rig()
  try r.s.submit(r.c, group: r.group, jobs: [CSFJob(queue: 0, stream: Rig.streamVA, size: 64, flush: 0)], waits: [],
                 signals: [CSFSync(id: r.sync, value: 1)])
  drive(&r.s) { $0.scheduler.link.counters[Rig.counter] ?? 0 >= 1 }
  #expect(r.s.scheduler.link.counters[Rig.counter] == 1)
  #expect(r.s.scheduler.link.ran.count == 1 && r.s.scheduler.link.ran[0].va == Rig.streamVA)
  let state = try r.s.groupState(r.c, r.group)
  #expect(state.state == 0 && state.fatalQueues == 0)
  #expect(!r.s.isLost(r.c))
  // The kernel's memory is in the VM's kernel region, apart from the client's.
  let q = try #require(r.s.scheduler.link.attached.values.first?.first)
  let vm = try r.s.createVM(r.c, userRange: 0)
  #expect(q.ringVA >= vm.userRange && q.syncVA >= vm.userRange)
}

@Test func theSignalComesWhenTheLastJobOfTheCallIsDone() throws {
  var r = try Rig()
  let jobs = (0..<3).map { _ in CSFJob(queue: 0, stream: Rig.streamVA, size: 64, flush: 0) }
  try r.s.submit(r.c, group: r.group, jobs: jobs, waits: [], signals: [CSFSync(id: r.sync, value: 7)])
  #expect((r.s.scheduler.link.counters[Rig.counter] ?? 0) == 0)
  drive(&r.s) { $0.scheduler.link.counters[Rig.counter] ?? 0 >= 7 }
  #expect(r.s.scheduler.link.counters[Rig.counter] == 7)
  #expect(r.s.scheduler.link.ran.count == 3)
}

@Test func anEmptyJobIsASyncPoint() throws {
  var r = try Rig()
  try r.s.submit(r.c, group: r.group, jobs: [CSFJob(queue: 0, stream: 0, size: 0, flush: 0)], waits: [],
                 signals: [CSFSync(id: r.sync, value: 1)])
  #expect(r.s.scheduler.link.counters[Rig.counter] == 1)
  #expect(r.s.scheduler.link.ran.isEmpty)
  // A call with no jobs at all signals once its waits are met.
  try r.s.submit(r.c, group: r.group, jobs: [], waits: [], signals: [CSFSync(id: r.sync, value: 2)])
  #expect(r.s.scheduler.link.counters[Rig.counter] == 2)
}

@Test func aJobWaitsForItsCounterAndTheOnesBehindItWaitToo() throws {
  var r = try Rig()
  let gate = try r.s.addSync(r.c, counter: 200)
  let first = CSFJob(queue: 0, stream: Rig.streamVA, size: 64, flush: 0)
  try r.s.submit(r.c, group: r.group, jobs: [first], waits: [CSFSync(id: gate, value: 1)],
                 signals: [CSFSync(id: r.sync, value: 1)])
  // A later call on the group keeps its place behind the first.
  try r.s.submit(r.c, group: r.group, jobs: [first], waits: [], signals: [CSFSync(id: r.sync, value: 2)])
  drive(&r.s, steps: 20) { _ in false }
  #expect(r.s.scheduler.link.ran.isEmpty && (r.s.scheduler.link.counters[Rig.counter] ?? 0) == 0)
  #expect(r.s.nextWake != nil)
  r.s.scheduler.link.counters[200] = 1
  drive(&r.s) { $0.scheduler.link.counters[Rig.counter] ?? 0 >= 2 }
  #expect(r.s.scheduler.link.counters[Rig.counter] == 2 && r.s.scheduler.link.ran.count == 2)
}

@Test func aFaultedGroupIsLostAndOnlyItsContext() throws {
  var r = try Rig()
  let c2 = r.s.openContext()
  let vm2 = try r.s.createVM(c2, userRange: 0).id
  let buf2 = try r.s.createBuffer(c2, size: 4096, flags: 0).id
  try r.s.bind(c2, vm: vm2, buffer: buf2, offset: 0, size: 4096, address: Rig.streamVA, flags: 0)
  let g2 = try r.s.createGroup(c2, vm: vm2, queues: [(4096, 0)], priority: 1)
  let s2 = try r.s.addSync(c2, counter: 300)

  // A CALL to an address nothing maps.
  let bad = CSFJob(queue: 0, stream: 0x40_0000, size: 64, flush: 0)
  try r.s.submit(r.c, group: r.group, jobs: [bad], waits: [], signals: [CSFSync(id: r.sync, value: 1)])
  drive(&r.s) { $0.isLost(r.c) && ($0.scheduler.link.counters[Rig.counter] ?? 0) >= 1 }
  #expect(r.s.isLost(r.c))
  // Its counter rises all the same, so a waiter isn't left.
  #expect(r.s.scheduler.link.counters[Rig.counter] == 1)
  let state = try r.s.groupState(r.c, r.group)
  #expect(state.state & 2 != 0 && state.fatalQueues == 1)
  let ok = CSFJob(queue: 0, stream: Rig.streamVA, size: 64, flush: 0)
  #expect(throws: CSFError.lost) { try r.s.submit(r.c, group: r.group, jobs: [ok], waits: [], signals: []) }
  #expect(throws: CSFError.lost) {
    _ = try r.s.createGroup(r.c, vm: r.vm, queues: [(4096, 0)], priority: 1)
  }
  // The handles still work to clean up.
  try r.s.destroyGroup(r.c, r.group)

  // The other context's stream runs.
  #expect(!r.s.isLost(c2))
  try r.s.submit(c2, group: g2, jobs: [ok], waits: [], signals: [CSFSync(id: s2, value: 1)])
  drive(&r.s) { $0.scheduler.link.counters[300] ?? 0 >= 1 }
  #expect(r.s.scheduler.link.counters[300] == 1)
  #expect(!r.s.isLost(c2))
}

@Test func theGroupOfAClosedContextIsReapedAndItsKernelMemoryReturned() throws {
  var r = try Rig()
  let first = try #require(r.s.scheduler.link.attached.values.first?.first)
  try r.s.submit(r.c, group: r.group, jobs: [CSFJob(queue: 0, stream: Rig.streamVA, size: 64, flush: 0)], waits: [],
                 signals: [CSFSync(id: r.sync, value: 1)])
  r.s.closeContext(r.c)
  #expect(r.s.scheduler.link.closedCounters == [Rig.counter])
  drive(&r.s) { !$0.scheduler.link.detached.isEmpty && !$0.scheduler.link.vmsDestroyed.isEmpty }
  #expect(r.s.scheduler.link.detached.count == 1 && r.s.scheduler.link.vmsDestroyed.count == 1)
  #expect(r.s.scheduler.link.freedBuffers.count == 1)
  // A new context gets the same kernel addresses: they went back.
  let c = r.s.openContext()
  let vm = try r.s.createVM(c, userRange: 0).id
  _ = try r.s.createGroup(c, vm: vm, queues: [(4096, 0)], priority: 1)
  let second = try #require(r.s.scheduler.link.attached.values.first?.first)
  #expect(second.ringVA == first.ringVA)
}

@Test func aVMOutlivesItsHandleForItsGroups() throws {
  var r = try Rig()
  try r.s.destroyVM(r.c, r.vm)
  #expect(r.s.scheduler.link.vmsDestroyed.isEmpty)
  // Its handle is gone at once, and so are its mappings.
  #expect(throws: CSFError.invalid) { _ = try r.s.createGroup(r.c, vm: r.vm, queues: [(4096, 0)], priority: 1) }
  #expect(r.s.scheduler.link.maps[0]?.isEmpty == true)
  try r.s.destroyGroup(r.c, r.group)
  drive(&r.s) { !$0.scheduler.link.vmsDestroyed.isEmpty }
  #expect(r.s.scheduler.link.vmsDestroyed == [0])
  // Work on a VM whose mappings went faults.
  var q = try Rig()
  try q.s.submit(q.c, group: q.group, jobs: [CSFJob(queue: 0, stream: Rig.streamVA, size: 64, flush: 0)], waits: [],
                 signals: [CSFSync(id: q.sync, value: 1)])
  try q.s.destroyVM(q.c, q.vm)
  drive(&q.s) { $0.scheduler.link.counters[Rig.counter] ?? 0 >= 1 }
  #expect(q.s.isLost(q.c) && q.s.scheduler.link.counters[Rig.counter] == 1)
}

@Test func bindsReplaceAndSplitAndABufferGoesWhenNothingMapsIt() throws {
  var s = make()
  let c = s.openContext()
  let vm = try s.createVM(c, userRange: 0).id
  let a = try s.createBuffer(c, size: 16384, flags: 0)
  let b = try s.createBuffer(c, size: 4096, flags: 0)
  #expect(a.size == 16384)
  try s.bind(c, vm: vm, buffer: a.id, offset: 0, size: 16384, address: 0x10000, flags: 0)
  // B over the middle of A's range: A is cut in two.
  try s.bind(c, vm: vm, buffer: b.id, offset: 0, size: 4096, address: 0x12000, flags: 0b101)
  let maps = s.scheduler.link.maps[0] ?? []
  #expect(maps.contains { $0.buffer == b.key && $0.va == 0x12000 && $0.flags.readOnly && $0.flags.uncached && !$0.flags.noExec })
  #expect(s.scheduler.link.mapped(vm: 0, va: 0x11000) && s.scheduler.link.mapped(vm: 0, va: 0x13000))
  try s.destroyBuffer(c, a.id)
  #expect(s.scheduler.link.freedBuffers.isEmpty)  // two pieces still map it
  try s.unbind(c, vm: vm, address: 0x10000, size: 0x2000)
  #expect(s.scheduler.link.freedBuffers.isEmpty)  // one piece
  try s.unbind(c, vm: vm, address: 0x13000, size: 0x1000)
  #expect(s.scheduler.link.freedBuffers == [a.key])
  #expect(throws: CSFError.notFound) { try s.destroyBuffer(c, a.id) }
  // A closed buffer can't be bound.
  #expect(throws: CSFError.invalid) { try s.bind(c, vm: vm, buffer: a.id, offset: 0, size: 4096, address: 0x20000, flags: 0) }
  // Whatever is in the range goes; unmapping nothing is fine.
  try s.unbind(c, vm: vm, address: 0x100000, size: 0x1000)
  try s.destroyBuffer(c, b.id)
  #expect(s.scheduler.link.freedBuffers.count == 1)  // B is still mapped
  try s.destroyVM(c, vm)
  #expect(s.scheduler.link.freedBuffers.count == 2)
}

@Test func theVMsRangesAndTheClientsSizeFollowPanthor10() throws {
  var s = make()
  let c = s.openContext()
  // The client's range is the first half of 48 bits by default; the kernel's a power of two above it.
  let d = try s.createVM(c, userRange: 0)
  #expect(d.userRange == 1 << 47)
  let small = try s.createVM(c, userRange: 1 << 32)
  // Asked for less, the client still gets the kernel region's power-of-two start.
  #expect(small.userRange == 1 << 47)
  #expect(throws: CSFError.invalid) { _ = try s.createVM(c, userRange: (1 << 48) - (255 << 20)) }
  let max = try s.createVM(c, userRange: (1 << 48) - (256 << 20))
  #expect(max.userRange == (1 << 48) - (256 << 20))
  #expect(d.id == 1 && small.id == 2 && max.id == 3)
}

@Test func validationFollowsPanthor10And7_13() throws {
  var r = try Rig()
  func group(_ queues: [(ringSize: UInt32, priority: UInt32)], _ priority: UInt32 = 1, vm: UInt32? = nil) throws -> UInt32 {
    try r.s.createGroup(r.c, vm: vm ?? r.vm, queues: queues, priority: priority)
  }
  #expect(throws: CSFError.invalid) { _ = try group([]) }
  #expect(throws: CSFError.invalid) { _ = try group([(4096, 0), (4096, 0), (4096, 0), (4096, 0), (4096, 0)]) }
  #expect(throws: CSFError.invalid) { _ = try group([(4096, 0)], 4) }
  // High and realtime need a privilege no context has.
  #expect(throws: CSFError.invalid) { _ = try group([(4096, 0)], 3) }
  for size: UInt32 in [0, 2048, 3000, 4097, 8191, 131072] {
    #expect(throws: CSFError.invalid) { _ = try group([(size, 0)]) }
  }
  #expect(throws: CSFError.invalid) { _ = try group([(4096, 16)]) }
  #expect(throws: CSFError.invalid) { _ = try group([(4096, 0)], vm: 9) }
  #expect(throws: CSFError.invalid) { _ = try group([(4096, 0)], vm: 0) }
  for size: UInt32 in [4096, 8192, 65536] { _ = try group([(size, 15)]) }

  // Binds.
  let big = try r.s.createBuffer(r.c, size: 8192, flags: 0).id
  let range = try r.s.createVM(r.c, userRange: 1 << 30)
  func bind(_ off: UInt64, _ size: UInt64, _ at: UInt64, _ flags: UInt32 = 0, buffer: UInt32? = nil) throws {
    try r.s.bind(r.c, vm: range.id, buffer: buffer ?? big, offset: off, size: size, address: at, flags: flags)
  }
  #expect(throws: CSFError.invalid) { try bind(0, 4096, 0x1001) }
  #expect(throws: CSFError.invalid) { try bind(0, 4095, 0x1000) }
  #expect(throws: CSFError.invalid) { try bind(0, 0, 0x1000) }
  #expect(throws: CSFError.invalid) { try bind(1, 4096, 0x1000) }
  #expect(throws: CSFError.invalid) { try bind(4096, 8192, 0x1000) }
  #expect(throws: CSFError.invalid) { try bind(0, 12288, 0x1000) }
  #expect(throws: CSFError.invalid) { try bind(0, 4096, range.userRange) }
  #expect(throws: CSFError.invalid) { try bind(0, 4096, UInt64.max - 4095) }
  #expect(throws: CSFError.invalid) { try bind(0, 4096, 0x1000, 0b1000) }
  #expect(throws: CSFError.invalid) { try bind(0, 4096, 0x1000, buffer: 77) }
  try bind(0, 4096, range.userRange - 4096)  // the last page
  #expect(throws: CSFError.invalid) { try r.s.unbind(r.c, vm: range.id, address: 0x1001, size: 4096) }
  #expect(throws: CSFError.invalid) { try r.s.unbind(r.c, vm: 12, address: 0x1000, size: 4096) }
  #expect(throws: CSFError.invalid) { _ = try r.s.createBuffer(r.c, size: 0, flags: 0) }
  #expect(throws: CSFError.invalid) { _ = try r.s.createBuffer(r.c, size: 4096, flags: 1) }
  #expect(throws: CSFError.invalid) { _ = try r.s.createBuffer(r.c, size: (1 << 32) + 1, flags: 0) }
  r.s.scheduler.link.failAllocations = true
  #expect(throws: CSFError.noMemory) { _ = try r.s.createBuffer(r.c, size: 4096, flags: 0) }
  r.s.scheduler.link.failAllocations = false

  // Submissions.
  let ok = CSFJob(queue: 0, stream: Rig.streamVA, size: 64, flush: 0)
  func submit(_ jobs: [CSFJob], waits: [CSFSync] = [], signals: [CSFSync] = [], group: UInt32? = nil) throws {
    try r.s.submit(r.c, group: group ?? r.group, jobs: jobs, waits: waits, signals: signals)
  }
  #expect(throws: CSFError.invalid) { try submit([CSFJob(queue: 1, stream: Rig.streamVA, size: 64, flush: 0)]) }
  #expect(throws: CSFError.invalid) { try submit([CSFJob(queue: 0, stream: Rig.streamVA + 4, size: 64, flush: 0)]) }
  #expect(throws: CSFError.invalid) { try submit([CSFJob(queue: 0, stream: Rig.streamVA, size: 60, flush: 0)]) }
  #expect(throws: CSFError.invalid) { try submit([CSFJob(queue: 0, stream: Rig.streamVA, size: 0, flush: 0)]) }
  #expect(throws: CSFError.invalid) { try submit([CSFJob(queue: 0, stream: 0, size: 64, flush: 0)]) }
  #expect(throws: CSFError.invalid) { try submit([CSFJob(queue: 0, stream: Rig.streamVA, size: 64, flush: 1 << 24)]) }
  try submit([CSFJob(queue: 0, stream: Rig.streamVA, size: 64, flush: 1 << 31)])  // bit 31 is allowed
  #expect(throws: CSFError.invalid) { try submit([ok], group: 99) }
  #expect(throws: CSFError.invalid) { try submit([ok], group: 0) }
  #expect(throws: CSFError.notFound) { try submit([ok], waits: [CSFSync(id: 99, value: 1)]) }
  #expect(throws: CSFError.notFound) { try submit([ok], signals: [CSFSync(id: 99, value: 1)]) }
  #expect(throws: CSFError.invalid) { try submit(Array(repeating: ok, count: 257)) }
  try submit([])  // a no-op
  // Nothing that failed was queued: only the flush-bit-31 job and the no-op.
  drive(&r.s) { $0.scheduler.link.ran.count >= 1 }
  #expect(r.s.scheduler.link.ran.count == 1)
  #expect(throws: CSFError.invalid) { _ = try r.s.groupState(r.c, 99) }
  #expect(throws: CSFError.invalid) { _ = try r.s.groupState(r.c + 5, r.group) }
}

@Test func theTablesHaveTheirLimits() throws {
  var s = make()
  let c = s.openContext()
  var vms: [UInt32] = []
  for _ in 0..<32 { vms.append(try s.createVM(c, userRange: 1 << 30).id) }
  #expect(vms == Array(1...32))
  #expect(throws: CSFError.unavailable) { _ = try s.createVM(c, userRange: 1 << 30) }
  // A handle goes back to its table when it is let go of.
  try s.destroyVM(c, 5)
  #expect(try s.createVM(c, userRange: 1 << 30).id == 5)

  var groups = 0
  for _ in 0..<128 {
    _ = try s.createGroup(c, vm: 1, queues: [(4096, 0)], priority: 0)
    groups += 1
  }
  #expect(groups == 128)
  #expect(throws: CSFError.unavailable) { _ = try s.createGroup(c, vm: 1, queues: [(4096, 0)], priority: 0) }
  // The 129th group of another context is fine: the limit is the client's.
  let c2 = s.openContext()
  let v = try s.createVM(c2, userRange: 0).id
  _ = try s.createGroup(c2, vm: v, queues: [(4096, 0)], priority: 0)
  #expect(throws: CSFError.invalid) { _ = try s.createVM(c2 + 9, userRange: 0) }
}

@Test func moreGroupsThanSlotsAllRunTheirJobs() throws {
  var r = try Rig()
  var groups: [UInt32] = [r.group]
  for _ in 0..<19 { groups.append(try r.s.createGroup(r.c, vm: r.vm, queues: [(4096, 0)], priority: 1)) }
  for g in groups {
    try r.s.submit(r.c, group: g, jobs: [CSFJob(queue: 0, stream: Rig.streamVA, size: 64, flush: 0)], waits: [],
                   signals: [CSFSync(id: r.sync, value: UInt64(g))])
  }
  drive(&r.s, steps: 3000) { $0.scheduler.link.ran.count == 20 }
  #expect(r.s.scheduler.link.ran.count == 20)
  #expect(r.s.scheduler.link.counters[Rig.counter] == 20)  // raised to the greatest, never lowered
  #expect(!r.s.isLost(r.c))
}
