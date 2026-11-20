// SPDX-License-Identifier: BSD-3-Clause

// The ring writer's words against the spec's literal encodings, its space
// accounting and its completion; the VA allocators; the address-space slots.

import Mali
import Testing

private let shape = JobSequenceShape(workRegisters: 96, scoreboards: 8)

private func sequence(_ p: ProfilingKinds, flush: UInt32 = 0x1234) -> [UInt64] {
  JobSequence.build(shape, flushID: flush, streamVA: 0x0000_1234_5678_9000, streamSize: 0x240,
                    syncVA: 0xAB_C000, profilingSlot: 0x7_0000, profiling: p)
}

@Test func theRegistersComeFromTheWorkRegisterCount() {
  #expect(shape.ra == 92 && shape.rv == 94 && shape.scoreboardMask == 0xFF)
  let s = JobSequenceShape(workRegisters: 64, scoreboards: 16)
  #expect(s.ra == 60 && s.rv == 62 && s.scoreboardMask == 0xFFFF)
}

@Test func theKernelsInstructionsAreTheSpecsLiteralWords() {
  let ra: UInt64 = 92
  let rv: UInt64 = 94
  #expect(RingInstruction.mov32(94, 0xDEAD_BEEF) == 0x02 << 56 | rv << 48 | 0xDEAD_BEEF)
  #expect(RingInstruction.mov48(92, 0x1234_5678_9ABC) == 0x01 << 56 | ra << 48 | 0x1234_5678_9ABC)
  #expect(RingInstruction.flushCache2(flushID: 94) == 0x24 << 56 | rv << 40 | 0x233)
  #expect(RingInstruction.storeState(address: 92, cycles: true) == 0x28 << 56 | ra << 40 | 1 << 32)
  #expect(RingInstruction.storeState(address: 92, cycles: false) == 0x28 << 56 | ra << 40)
  #expect(RingInstruction.wait(mask: 1) == 0x03 << 56 | 0x0001 << 16)
  #expect(RingInstruction.wait(mask: 0xFF) == 0x03 << 56 | 0xFF << 16)
  #expect(RingInstruction.call(address: 92, size: 94) == 0x20 << 56 | ra << 40 | rv << 32)
  #expect(RingInstruction.syncAdd64(address: 92, value: 94) == 0x33 << 56 | ra << 40 | rv << 32 | 0x1)
  #expect(RingInstruction.errorBarrier == 0x2F << 56)
  // The spelled-out values, for one of them.
  #expect(RingInstruction.call(address: 92, size: 94) == 0x2000_5C5E_0000_0000)
  #expect(RingInstruction.flushCache2(flushID: 94) == 0x2400_5E00_0000_0233)
  // A 48-bit immediate is cut at 48 bits and doesn't reach the register.
  #expect(RingInstruction.mov48(92, UInt64.max) == 0x015C_FFFF_FFFF_FFFF)
}

@Test func theJobSequenceHasTheSpecsInstructionsInOrder() {
  let w = sequence(.none)
  #expect(w.count == 16 && JobSequence.paddedCount(.none) == 16 && JobSequence.unpaddedCount(.none) == 11)
  let expected: [UInt64] = [
    RingInstruction.mov32(94, 0x1234),
    RingInstruction.flushCache2(flushID: 94),
    RingInstruction.mov48(92, 0x0000_1234_5678_9000),
    RingInstruction.mov32(94, 0x240),
    RingInstruction.wait(mask: 0x0001),
    RingInstruction.call(address: 92, size: 94),
    RingInstruction.mov48(92, 0xAB_C000),
    RingInstruction.mov48(94, 1),
    RingInstruction.wait(mask: 0xFF),
    RingInstruction.syncAdd64(address: 92, value: 94),
    RingInstruction.errorBarrier,
  ]
  #expect(Array(w[0..<11]) == expected)
  for i in 11..<16 { #expect(w[i] == 0) }
}

@Test func profilingAddsItsRowsAndTheSequencePadsToWholeLines() {
  let cycles = sequence(ProfilingKinds(cycles: true))
  let time = sequence(ProfilingKinds(time: true))
  let both = sequence(ProfilingKinds(cycles: true, time: true))
  #expect(cycles.count == 16 && time.count == 16 && both.count == 24)
  #expect(JobSequence.unpaddedCount(ProfilingKinds(cycles: true)) == 15)
  #expect(JobSequence.unpaddedCount(ProfilingKinds(cycles: true, time: true)) == 19)
  #expect(JobSequence.paddedCount(ProfilingKinds(cycles: true, time: true)) == 24)
  // Cycles alone: rows 3-4 before the stream, 11-12 after it.
  #expect(cycles[2] == RingInstruction.mov48(92, 0x7_0000))
  #expect(cycles[3] == RingInstruction.storeState(address: 92, cycles: true))
  #expect(cycles[8] == RingInstruction.mov48(92, 0x7_0008))
  #expect(cycles[9] == RingInstruction.storeState(address: 92, cycles: true))
  // Time alone: slot +16 before, +24 after.
  #expect(time[2] == RingInstruction.mov48(92, 0x7_0010))
  #expect(time[3] == RingInstruction.storeState(address: 92, cycles: false))
  #expect(time[8] == RingInstruction.mov48(92, 0x7_0018))
  // Both: the 19 rows in order.
  #expect(both[2] == RingInstruction.mov48(92, 0x7_0000))
  #expect(both[4] == RingInstruction.mov48(92, 0x7_0010))
  #expect(both[6] == RingInstruction.mov48(92, 0x0000_1234_5678_9000))
  #expect(both[9] == RingInstruction.call(address: 92, size: 94))
  #expect(both[10] == RingInstruction.mov48(92, 0x7_0008))
  #expect(both[12] == RingInstruction.mov48(92, 0x7_0018))
  #expect(both[14] == RingInstruction.mov48(92, 0xAB_C000))
  #expect(both[18] == RingInstruction.errorBarrier)
  for i in 19..<24 { #expect(both[i] == 0) }
  for w in [cycles, time, both] { #expect(w.count * 8 % 64 == 0) }
}

@Test func theRingTakesCreditsAndGivesThemBackOnCompletion() throws {
  #expect(JobRing(size: 2048) == nil && JobRing(size: 8192 + 4096) == nil && JobRing(size: 131072) == nil)
  var r = try #require(JobRing(size: 4096))
  #expect(r.credits == 512)
  var starts: [UInt64] = []
  for i in 0..<32 {
    let _v1 = r.reserve(words: 16, tag: UInt64(i))
    let p = try #require(_v1)
    #expect(p.sequence == UInt64(i + 1))
    starts.append(p.start)
  }
  #expect(starts[1] == 128 && starts[31] == 31 * 128)
  #expect(r.credits == 0 && r.insert == 4096)
  let _v2 = r.reserve(words: 16, tag: 99)
  #expect(_v2 == nil)  // INSERT - EXTRACT stays within the size
  // The CS has reached job 3: its credits (and the first two's) return.
  let done = r.complete(SyncRecord(sequence: 3))
  #expect(done.map { $0.tag } == [0, 1, 2] && done.allSatisfy { $0.error == .none })
  #expect(r.credits == 48 && r.completedSequence == 3)
  let _v3 = r.reserve(words: 24, tag: 100)
  let p = try #require(_v3)
  #expect(p.sequence == 33 && p.start == 4096)
  // Words wrap into the ring: the 33rd job's first word lands at offset 0.
  #expect(r.byteOffset(at: p.start, word: 0) == 0)
  #expect(r.byteOffset(at: 4096 - 64, word: 8) == 0 && r.byteOffset(at: 4096 - 64, word: 9) == 8)
  #expect(r.byteOffset(at: 3 * 4096 + 64, word: 0) == 64)
}

@Test func aSyncObjectsErrorReachesTheJobTheStreamRanLast() throws {
  var r = try #require(JobRing(size: 4096))
  for i in 0..<3 { _ = r.reserve(words: 16, tag: UInt64(i)) }
  let done = r.complete(SyncRecord(sequence: 2, status: 1))
  #expect(done.map { $0.error } == [.none, .invalid])
  // A CS fault marks the job whose range holds EXTRACT; a later status adds nothing.
  var f = try #require(JobRing(size: 4096))
  for i in 0..<3 { _ = f.reserve(words: 16, tag: UInt64(i)) }
  let _v4 = f.fault(atExtract: 128 + 40)
  #expect(_v4)
  let _v5 = f.fault(atExtract: 3 * 128)
  #expect(!_v5)
  let d2 = f.complete(SyncRecord(sequence: 3, status: 1))
  #expect(d2.map { $0.error } == [.none, .invalid, .none])
}

@Test func emptyJobsWaitForEarlierOnesAndTakeNoSpace() throws {
  var r = try #require(JobRing(size: 4096))
  let _v6 = r.reserveEmpty(tag: 1)
  let first = try #require(_v6)
  #expect(first.sequence == 0 && first.isEmpty && r.credits == 512)
  _ = r.reserve(words: 16, tag: 2)
  let _v7 = r.reserveEmpty(tag: 3)
  #expect(_v7 == nil)
  let done = r.complete(SyncRecord(sequence: 1))
  #expect(done.map { $0.tag } == [2, 3] && done[1].sequence == 1)
  #expect(r.insert == 128)
}

@Test func theSyncObjectsWordsAreTheSequenceAndTheStatus() {
  let s = SyncRecord(word0: 7, word1: 0x1_0000_0003)
  #expect(s.sequence == 7 && s.status == 3)
}

// MARK: VA

@Test func theMCUWindowAllocatesGPUPagesBestFit() throws {
  var w = VARegion.mcuWindow()
  #expect(w.freeBytes == 64 << 20)
  let _v8 = w.reserve(at: 0x0400_0000, size: 0x1_0001)
  #expect(_v8)  // the interface section, rounded to 0x11000
  let _v9 = w.allocate(size: 1)
  let a = try #require(_v9)
  #expect(a == 0x0401_1000)
  let _v10 = w.allocate(size: 0x2001)
  let b = try #require(_v10)
  #expect(b == 0x0401_2000)
  // Free a hole, then a smaller request takes the hole, not the tail.
  let _v11 = w.release(at: a, size: 1)
  #expect(_v11)
  let _v12 = w.allocate(size: 0x1000)
  let c = try #require(_v12)
  #expect(c == a)
  let _v13 = w.allocate(size: 128 << 20)
  #expect(_v13 == nil)
  let _v14 = w.allocate(size: 0)
  #expect(_v14 == nil)
  let _v15 = w.reserve(at: 0x0800_0000 - 0x1000, size: 0x2000)
  #expect(!_v15)  // past the window
  let _v16 = w.reserve(at: 0x0400_0000, size: 0x1000)
  #expect(!_v16)  // taken
  // 2 MiB isn't aligned in the MCU's window (04 section 4.8.2).
  let _v17 = w.allocate(size: 2 << 20)
  let d = try #require(_v17)
  #expect(d == 0x0401_5000)
  // Releasing everything coalesces.
  let r1 = w.release(at: c, size: 0x1000)
  let r2 = w.release(at: b, size: 0x2001)
  let r3 = w.release(at: d, size: 2 << 20)
  #expect(r1 && r2 && r3)
  let _v18 = w.release(at: 0x0400_0000, size: 0x1_0001)
  #expect(_v18)
  #expect(w.freeBytes == 64 << 20)
  let _v19 = w.allocate(size: 64 << 20)
  #expect(_v19 == 0x0400_0000)
}

@Test func aUserVMsKernelRegionHoldsBigObjectsAtTwoMiB() throws {
  var l = try UserVMLayout(vaBits: 48, userSize: 0, cpuSpace: 1 << 48)
  #expect(l.kernelStart == 1 << 47)
  let _v20 = l.kernel.allocate(size: 0x1000)
  let small = try #require(_v20)
  #expect(small == 1 << 47)
  let _v21 = l.kernel.allocate(size: 3 << 20)
  let big = try #require(_v21)
  #expect(big == (1 << 47) + (2 << 20) && big & (2 << 20 - 1) == 0)
  // Best fit: the hole below `big` (4 KiB..2 MiB) serves a small request.
  let _v22 = l.kernel.allocate(size: 0x2000)
  let s2 = try #require(_v22)
  #expect(s2 == (1 << 47) + 0x1000)
}

@Test func theUserRegionsBoundaryFollowsTheSpecsRules() throws {
  // 48 bits, a CPU space smaller than the GPU's: the user region is the CPU's.
  let a = try UserVMLayout(vaBits: 48, userSize: 0, cpuSpace: 1 << 39)
  #expect(a.kernelStart == 1 << 47)  // the kernel region is the largest power of two left
  // 40 bits: half, when the CPU's is as large.
  let b = try UserVMLayout(vaBits: 40, userSize: 0, cpuSpace: 0)
  #expect(b.kernelStart == 1 << 39)
  // 32 bits: F - 256 MiB for the user, which leaves 256 MiB.
  let c = try UserVMLayout(vaBits: 32, userSize: 0, cpuSpace: 0)
  #expect(c.kernelStart == (1 << 32) - (256 << 20))
  // Asked: more than allowed is refused; a size that leaves a non-power-of-two rounds K up.
  #expect(throws: VAError.userSizeTooLarge) { try UserVMLayout(vaBits: 32, userSize: 1 << 32, cpuSpace: 0) }
  let d = try UserVMLayout(vaBits: 32, userSize: 3 << 30, cpuSpace: 0)
  #expect(d.kernelStart == 3 << 30)
  let e = try UserVMLayout(vaBits: 40, userSize: 5 << 32, cpuSpace: 0)  // 5 * 2^32 of 2^40
  #expect(e.kernelStart == (1 << 40) - (1 << 39))
  #expect(throws: VAError.vaBitsTooSmall) { try UserVMLayout(vaBits: 28, userSize: 0, cpuSpace: 0) }
}

@Test func aBindMustBeAlignedInRangeAndOutsideTheKernelRegion() throws {
  let l = try UserVMLayout(vaBits: 32, userSize: 0, cpuSpace: 0)
  let k = l.kernelStart
  try l.validateBind(va: 0x1000, size: 0x1000)
  try l.validateBind(va: k - 0x1000, size: 0x1000)
  #expect(throws: VAError.overlapsKernelRegion) { try l.validateBind(va: k - 0x1000, size: 0x2000) }
  #expect(throws: VAError.overlapsKernelRegion) { try l.validateBind(va: k, size: 0x1000) }
  #expect(throws: VAError.overflow) { try l.validateBind(va: UInt64.max - 0xFFF, size: 0x1000) }
  #expect(throws: VAError.overflow) { try l.validateBind(va: 0x1000, size: 0xFFFF_FFFF_FFFF_F000) }
  #expect(throws: VAError.unaligned) { try l.validateBind(va: 0x1800, size: 0x1000) }
  #expect(throws: VAError.unaligned) { try l.validateBind(va: 0x1000, size: 0x800) }
  #expect(throws: VAError.empty) { try l.validateBind(va: 0x1000, size: 0) }
}

// MARK: AS slots

@Test func slotZeroIsTheMCUsAndVMsTakeTheOthersLowestFirst() {
  var a = ASSlots(present: 0b1111)
  #expect(a.userSlots == 3)
  let mcu = a.activateMCU()
  #expect(mcu == 0)
  let _v23 = a.activate(vm: 10)
  #expect(_v23 == .program(slot: 1))
  let _v24 = a.activate(vm: 11)
  #expect(_v24 == .program(slot: 2))
  let _v25 = a.activate(vm: 10)
  #expect(_v25 == .resident(slot: 1))  // a second user, no register access
  #expect(a.slot(of: 11) == 2 && a.slot(of: 99) == nil)
  // Sparse AS_PRESENT is searched as a mask.
  var s = ASSlots(present: 0b10101)
  #expect(s.userSlots == 2)
  let s1 = s.activate(vm: 1)
  let s2 = s.activate(vm: 2)
  #expect(s1 == .program(slot: 2) && s2 == .program(slot: 4))
}

@Test func theLeastRecentlyIdledVMGivesUpItsSlotAndARunningOneNever() {
  var a = ASSlots(present: 0b111)
  _ = a.activateMCU()
  let _v26 = a.activate(vm: 1)
  #expect(_v26 == .program(slot: 1))
  let _v27 = a.activate(vm: 2)
  #expect(_v27 == .program(slot: 2))
  let _v28 = a.activate(vm: 3)
  #expect(_v28 == .busy)  // both running
  a.deactivate(vm: 2)
  a.deactivate(vm: 1)
  // VM 2 idled first.
  let _v29 = a.activate(vm: 3)
  #expect(_v29 == .recycle(slot: 2, from: 2))
  #expect(a.slot(of: 2) == nil && a.slot(of: 3) == 2)
  // VM 1 comes back before anyone needs its slot: no work.
  let _v30 = a.activate(vm: 1)
  #expect(_v30 == .resident(slot: 1))
  let _v31 = a.activate(vm: 4)
  #expect(_v31 == .busy)
  a.deactivate(vm: 3)
  let _v32 = a.activate(vm: 4)
  #expect(_v32 == .recycle(slot: 2, from: 3))
}

@Test func aFaultedSlotIsProgrammedAgainAndTheMCUsNeverRecycled() {
  var a = ASSlots(present: 0b11)
  _ = a.activateMCU()
  let _v33 = a.activate(vm: 1)
  #expect(_v33 == .program(slot: 1))
  a.markFaulted(slot: 1)
  a.deactivate(vm: 1)
  let _v34 = a.activate(vm: 1)
  #expect(_v34 == .program(slot: 1))
  a.deactivate(vm: 1)
  let _v35 = a.activate(vm: 2)
  #expect(_v35 == .recycle(slot: 1, from: 1))
  a.reset()
  #expect(a.slot(of: 2) == nil)
  let _v36 = a.release(vm: 2)
  #expect(_v36 == nil)
}
