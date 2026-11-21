// SPDX-License-Identifier: BSD-3-Clause

// The tiler heaps (chinese-wall's panthor 08): the objects the `csf`
// capset creates (heap contexts in a pool of the VM, chunks linked through
// their headers), and the TILER_OOM event served over the scheduler and the
// service: a request validated, granted a chunk or refused, answered and
// acknowledged, the heap's limits, a heap destroyed with chunks in flight,
// a group that leaves its slot with a request open. The link's half
// (the event and the reply on the model firmware's interface) is in
// LinkTests; the model GPU here is SchedulerTests' fake.

import Mali
import MaliService
import Testing

private let chunk: UInt32 = 128 << 10

private struct HeapRig {
  var s = CSFService(backend: FakeDevice())
  var c = 0
  var vm: UInt32 = 0
  var userRange: UInt64 = 0
  var group: UInt32 = 0
  /// The scheduler's ids: the first VM and group a service makes.
  static let schedGroup = 0
  static let schedVM = 0

  /// A context with a VM and a group of one queue that is resident, its job never done.
  init() throws {
    c = s.openContext()
    let vm = try s.createVM(c, userRange: 0)
    self.vm = vm.id
    userRange = vm.userRange
    let buffer = try s.createBuffer(c, size: 4096, flags: 0).id
    try s.bind(c, vm: self.vm, buffer: buffer, offset: 0, size: 4096, address: 0x10000, flags: 0)
    group = try s.createGroup(c, vm: self.vm, queues: [(4096, 0)], priority: 1)
    try s.submit(c, group: group, jobs: [CSFJob(queue: 0, stream: 0x10000, size: 64, flush: 0)], waits: [], signals: [])
    s.scheduler.link.link.queues[FakeLink.key(HeapRig.schedGroup, 0)]!.hang = true
  }

  mutating func heap(initial: UInt32 = 1, max: UInt32 = 4, target: UInt32 = 2) throws -> (handle: UInt32, contextVA: UInt64, firstChunk: UInt64) {
    try s.createHeap(c, vm: vm, initialChunks: initial, chunkSize: chunk, maxChunks: max, targetInFlight: target)
  }

  /// The firmware reports a tiler OOM on the group's queue, and the service answers it.
  mutating func oom(_ heapAddress: UInt64, inFlight: UInt32 = 1, waiting: UInt32 = 0) {
    // VT_START - FRAG_END in flight, VT_END - FRAG_END waiting for the fragment work.
    let fragEnd: UInt32 = 10
    let report = TilerOOMReport(heapAddress: heapAddress, vtStart: fragEnd + inFlight, vtEnd: fragEnd + waiting,
                                fragEnd: fragEnd)
    s.scheduler.link.link.raiseTilerOOM(group: HeapRig.schedGroup, queue: 0, report)
    s.pump()
  }

  var replies: [UInt64] { s.scheduler.link.link.heapReplies.map { $0.chunk } }

  /// The buffer a map at `va` of the model device's VM holds.
  func buffer(at va: UInt64) -> Int? {
    for m in s.scheduler.link.maps[HeapRig.schedVM] ?? [] where m.va == va { return m.buffer }
    return nil
  }

  func word(_ va: UInt64, _ offset: UInt64 = 0) -> UInt64? {
    guard let b = buffer(at: va) else { return nil }
    return s.scheduler.link.words[b]?[offset]
  }

  func encoded(_ va: UInt64) -> UInt64 { va | UInt64(chunk >> 12) }
}

@Test func aHeapsChunksAreLinkedAndItsContextIsZeroedInThePool() throws {
  var r = try HeapRig()
  let h = try r.heap(initial: 3, max: 5)
  // The handle is the VM's and the slot's; both addresses are the driver's, above the client's range.
  #expect(h.handle == r.vm << 16)
  #expect(h.contextVA >= r.userRange && h.firstChunk >= r.userRange)
  // FakeDevice's L2 line is 64 bytes: the contexts are 64 apart in a pool of 128 of them.
  let h2 = try r.heap()
  #expect(h2.handle == r.vm << 16 | 1 && h2.contextVA == h.contextVA + 64)
  let maps = r.s.scheduler.link.maps[HeapRig.schedVM] ?? []
  #expect(maps.contains { $0.va == h.contextVA && $0.size == 8192 && $0.flags.noExec && !$0.flags.readOnly })
  // Three chunks, each its own buffer; the first reported is the last made, and each header points back.
  let made = maps.filter { $0.size == UInt64(chunk) }
  #expect(made.count == 4 && made.allSatisfy { $0.flags.noExec && !$0.flags.readOnly })
  #expect(h.firstChunk % 4096 == 0)
  let second = try #require(r.word(h.firstChunk))
  #expect(second & ~0xFFF != h.firstChunk)
  #expect(second & 0xFFF == UInt64(chunk >> 12))
  let first = try #require(r.word(second & ~0xFFF))
  #expect(first & 0xFFF == UInt64(chunk >> 12))
  // The oldest chunk ends the list: no word stored, its header is the zeroed buffer.
  #expect(r.word(first & ~0xFFF) == nil)
  // The context's 64 bytes were written as zeros.
  let pool = try #require(r.buffer(at: h.contextVA))
  for offset in stride(from: UInt64(0), to: 128, by: 8) { #expect(r.s.scheduler.link.words[pool]?[offset] == 0) }
  #expect(r.s.heapStatusLines == ["tiler heaps: 2 in 1 VMs, \((8192 + 4 * Int(chunk)) >> 10) KiB (pools and chunks); OOM events 0: granted 0, refused 0, invalid 0"])
}

@Test func aHeapsLimitsAreChecked() throws {
  var r = try HeapRig()
  func create(_ initial: UInt32, _ size: UInt32, _ max: UInt32, vm: UInt32? = nil) throws {
    _ = try r.s.createHeap(r.c, vm: vm ?? r.vm, initialChunks: initial, chunkSize: size, maxChunks: max, targetInFlight: 1)
  }
  for (initial, size, max) in [(0, chunk, 4), (3, chunk, 2), (1, chunk - 4096, 4), (1, chunk + 100, 4), (1, 16 << 20, 4),
                               (1, 8 << 20 + 4096, 4), (1, 0, 4)] as [(UInt32, UInt32, UInt32)] {
    #expect(throws: CSFServiceError.invalid) { try create(initial, size, max) }
  }
  #expect(throws: CSFServiceError.invalid) { try create(1, chunk, 1, vm: 9) }
  #expect(throws: CSFServiceError.invalid) { try create(1, chunk, 1, vm: 0) }
  // The most and the least are fine.
  try create(1, 8 << 20, 1)
  try create(2, chunk, 2)
  // 128 heaps to a VM, the 129th is EBUSY (`unavailable`); a heap's destroy frees its slot.
  for _ in 0..<126 { _ = try r.heap() }
  #expect(throws: CSFServiceError.unavailable) { _ = try r.heap() }
  try r.s.destroyHeap(r.c, heap: r.vm << 16 | 5)
  #expect(try r.heap().handle == r.vm << 16 | 5)
  // A heap of another VM is another pool.
  let other = try r.s.createVM(r.c, userRange: 0).id
  #expect(try r.s.createHeap(r.c, vm: other, initialChunks: 1, chunkSize: chunk, maxChunks: 1, targetInFlight: 0).handle
    == other << 16)
}

@Test func aHeapThatCantBeMadeLeavesNothingBehind() throws {
  var r = try HeapRig()
  let buffers = r.s.scheduler.link.buffers.count
  r.s.scheduler.link.failAllocations = true
  #expect(throws: CSFServiceError.noMemory) { _ = try r.heap() }
  r.s.scheduler.link.failAllocations = false
  // The pool is there (the first heap made it); a heap that fails after it gives its chunks back.
  _ = try r.heap()
  let held = r.s.scheduler.link.buffers.count
  #expect(held == buffers + 2)
  r.s.scheduler.link.allocationsLeft = 2
  #expect(throws: CSFServiceError.noMemory) { _ = try r.heap(initial: 3, max: 3) }
  #expect(r.s.scheduler.link.buffers.count == held)
  #expect((r.s.scheduler.link.maps[HeapRig.schedVM] ?? []).filter { $0.size == UInt64(chunk) }.count == 1)
}

@Test func aTilerOOMIsGrantedAChunkAndAcknowledged() throws {
  var r = try HeapRig()
  let h = try r.heap(initial: 1, max: 3, target: 2)
  r.oom(h.contextVA, inFlight: 2, waiting: 1)
  // One reply, the same value for both registers (the fake records it once), a chunk of its own with NEXT 0.
  #expect(r.replies.count == 1 && r.replies[0] != 0)
  let granted = r.replies[0]
  #expect(granted & 0xFFF == UInt64(chunk >> 12) && granted & ~0xFFF != h.firstChunk)
  #expect(r.s.scheduler.link.maps[HeapRig.schedVM]!.contains { $0.va == granted & ~0xFFF && $0.size == UInt64(chunk) })
  #expect(r.word(granted & ~0xFFF) == nil)
  // The group goes on: nothing faulted it.
  #expect(try r.s.groupState(r.c, r.group).state == 0)
  r.oom(h.contextVA, inFlight: 1)
  #expect(r.replies.count == 2 && r.replies[1] != 0 && r.replies[1] != granted)
  // The heap holds its most: the next is refused, answered with 0 and acknowledged all the same.
  r.oom(h.contextVA, inFlight: 1)
  #expect(r.replies.count == 3 && r.replies[2] == 0)
  #expect(try r.s.groupState(r.c, r.group).state == 0)
  #expect(r.s.heapStatusLines[0].hasSuffix("OOM events 3: granted 2, refused 1, invalid 0"))
}

@Test func theGrantPolicyIsTheTargetInFlightAndNotTheFragmentPasses() throws {
  var r = try HeapRig()
  let h = try r.heap(initial: 1, max: 9, target: 2)
  // More passes in flight than the target: refused; the pending fragment passes aren't looked at.
  r.oom(h.contextVA, inFlight: 3, waiting: 2)
  #expect(r.replies == [0])
  // At the target exactly, granted, however many wait for their fragment work.
  r.oom(h.contextVA, inFlight: 2, waiting: 1)
  #expect(r.replies.count == 2 && r.replies[1] != 0)
  r.oom(h.contextVA, inFlight: 1, waiting: 0)
  #expect(r.replies.count == 3 && r.replies[2] != 0)
}

@Test func aChunkThatCantBeMadeIsARefusalNotAFault() throws {
  var r = try HeapRig()
  let h = try r.heap(initial: 1, max: 3, target: 2)
  r.s.scheduler.link.failAllocations = true
  r.oom(h.contextVA)
  #expect(r.replies == [0])
  #expect(try r.s.groupState(r.c, r.group).state == 0 && !r.s.isLost(r.c))
}

@Test func anInvalidRequestIsNotAcknowledgedAndFaultsItsQueue() throws {
  // Each: the counters break FRAG_END <= VT_END < VT_START, the address isn't a context of the pool, or is a slot no
  // heap holds, or is between two.
  for variant in 0..<5 {
    var r = try HeapRig()
    let h = try r.heap()
    switch variant {
    case 0: r.oom(h.contextVA, inFlight: 1, waiting: 5)  // VT_END ahead of VT_START
    case 1: r.oom(h.contextVA + 64)  // no heap in slot 1
    case 2: r.oom(h.contextVA + 8)  // not a slot's start
    case 3: r.oom(0x1000)  // below the pool
    default:
      let report = TilerOOMReport(heapAddress: h.contextVA, vtStart: 4, vtEnd: 4, fragEnd: 4)  // VT_END == VT_START
      r.s.scheduler.link.link.raiseTilerOOM(group: HeapRig.schedGroup, queue: 0, report)
      r.s.pump()
    }
    #expect(r.replies.isEmpty, "variant \(variant)")
    let state = try r.s.groupState(r.c, r.group)
    #expect(state.state & 2 != 0 && state.fatalQueues == 1, "variant \(variant)")
    #expect(r.s.isLost(r.c))
    #expect(r.s.heapStatusLines[0].hasSuffix("OOM events 1: granted 0, refused 0, invalid 1"))
  }
}

@Test func aHeapDestroyedWithChunksInFlightGivesAllItsMemoryBackAtOnce() throws {
  var r = try HeapRig()
  let h = try r.heap(initial: 2, max: 4, target: 2)
  r.oom(h.contextVA)
  r.oom(h.contextVA)
  #expect(r.replies.count == 2 && !r.replies.contains(0))
  let other = try r.heap()
  let before = r.s.scheduler.link.buffers.count
  let chunks = (r.s.scheduler.link.maps[HeapRig.schedVM] ?? []).filter { $0.size == UInt64(chunk) }.count
  #expect(chunks == 2 + 2 + 1)
  try r.s.destroyHeap(r.c, heap: h.handle)
  // Its four chunks are unmapped and freed; the other heap's chunk and the pool stay.
  #expect(r.s.scheduler.link.buffers.count == before - 4)
  #expect((r.s.scheduler.link.maps[HeapRig.schedVM] ?? []).filter { $0.size == UInt64(chunk) }.count == 1)
  #expect(r.s.scheduler.link.mapped(vm: HeapRig.schedVM, va: other.firstChunk))
  #expect(!r.s.scheduler.link.mapped(vm: HeapRig.schedVM, va: r.replies[0] & ~0xFFF))
  // The group wasn't touched by it, but a request for the heap that's gone is invalid.
  #expect(try r.s.groupState(r.c, r.group).state == 0)
  #expect(throws: CSFServiceError.invalid) { try r.s.destroyHeap(r.c, heap: h.handle) }
  r.oom(h.contextVA)
  #expect(r.replies.count == 2)
  #expect(try r.s.groupState(r.c, r.group).state & 2 != 0)
  // The slot is free again, and its context zeroed again for the new heap.
  let again = try r.heap()
  #expect(again.handle == h.handle && again.contextVA == h.contextVA)
  #expect(r.s.heapStatusLines[0].contains("2 in 1 VMs"))
}

@Test func destroyingAHeapOfAVMThatNeverHadOneIsNotFound() throws {
  var r = try HeapRig()
  #expect(throws: CSFServiceError.notFound) { try r.s.destroyHeap(r.c, heap: r.vm << 16) }
  _ = try r.heap()
  #expect(throws: CSFServiceError.invalid) { try r.s.destroyHeap(r.c, heap: r.vm << 16 | 1) }
  #expect(throws: CSFServiceError.invalid) { try r.s.destroyHeap(r.c, heap: r.vm << 16 | 200) }
  #expect(throws: CSFServiceError.invalid) { try r.s.destroyHeap(r.c, heap: 7 << 16) }
}

@Test func theHeapsOfAVMGoWithItAfterItsGroups() throws {
  var r = try HeapRig()
  _ = try r.heap(initial: 2, max: 2)
  // The client's stream buffer, the pool and two chunks.
  #expect(r.s.scheduler.link.buffers.count == 4)
  // The VM's handle goes, the VM stays for its resident group, and the firmware may still write the heap context.
  try r.s.destroyVM(r.c, r.vm)
  #expect(r.s.scheduler.link.buffers.count == 4 && r.s.scheduler.link.vmsDestroyed.isEmpty)
  #expect(throws: CSFServiceError.invalid) { _ = try r.heap() }
  try r.s.destroyGroup(r.c, r.group)
  for _ in 0..<20 {
    r.s.scheduler.link.step()
    r.s.pump()
  }
  #expect(r.s.scheduler.link.vmsDestroyed == [HeapRig.schedVM])
  // Only the client's own buffer is left.
  #expect(r.s.scheduler.link.buffers.count == 1)
  #expect(r.s.heapStatusLines[0].hasPrefix("tiler heaps: 0 in 0 VMs"))
}

@Test func aContextsClosingGivesItsHeapsBack() throws {
  var r = try HeapRig()
  _ = try r.heap(initial: 3, max: 3)
  r.s.closeContext(r.c)
  for _ in 0..<20 {
    r.s.scheduler.link.step()
    r.s.pump()
  }
  #expect(r.s.scheduler.link.buffers.isEmpty)
}

