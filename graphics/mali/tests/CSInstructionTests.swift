// SPDX-License-Identifier: BSD-3-Clause

// The command-stream encoders against valhall 01's field tables, written out as
// literal words, and against the kernel's own (Mali's RingInstruction, whose words
// RingTests holds to the panthor spec).

import Mali
import MaliCore
import Testing

@Test func theKernelsInstructionsAreTheSameWordsHere() {
  #expect(CSInstruction.mov48(92, 0x1234_5678_9ABC) == RingInstruction.mov48(92, 0x1234_5678_9ABC))
  #expect(CSInstruction.mov32(94, 0xDEAD_BEEF) == RingInstruction.mov32(94, 0xDEAD_BEEF))
  #expect(CSInstruction.wait(mask: 0x00FF) == RingInstruction.wait(mask: 0x00FF))
  #expect(CSInstruction.call(address: 92, size: 94) == RingInstruction.call(address: 92, size: 94))
  #expect(CSInstruction.flushCache2(l2: .cleanInvalidate, lsc: .cleanInvalidate, other: .invalidate, flushIDRegister: 94)
    == RingInstruction.flushCache2(flushID: 94))
  #expect(CSInstruction.storeState(address: 92, state: .cycleCount) == RingInstruction.storeState(address: 92, cycles: true))
  #expect(CSInstruction.storeState(address: 92, state: .timestamp) == RingInstruction.storeState(address: 92, cycles: false))
  #expect(CSInstruction.errorBarrier == RingInstruction.errorBarrier)
  #expect(CSInstruction.syncAdd64(address: 2, value: 4, errorPropagate: true) == RingInstruction.syncAdd64(address: 2, value: 4))
}

@Test func theOpcodesAreTheTableInSection1_2() {
  #expect(CSInstruction.nop() == 0)
  #expect(CSInstruction.nop(type: 5, payload: 0x1234) == 5 << 48 | 0x1234)
  #expect(CSInstruction.mov48(6, 0xFFFF_1234_5678_9ABC) == 0x01 << 56 | 6 << 48 | 0x1234_5678_9ABC)
  #expect(CSInstruction.mov32(3, 7) == 0x02 << 56 | 3 << 48 | 7)
  #expect(CSInstruction.wait(mask: 0x0008) == 0x03 << 56 | 8 << 16)
  #expect(CSInstruction.waitIndirect == 0x03 << 56 | 1 << 33)
  #expect(CSInstruction.add32(dst: 1, src: 2, immediate: -1) == 0x10 << 56 | 1 << 48 | 2 << 40 | 0xFFFF_FFFF)
  #expect(CSInstruction.add64(dst: 4, src: 6, immediate: 8) == 0x11 << 56 | 4 << 48 | 6 << 40 | 8)
  #expect(CSInstruction.umin32(dst: 1, 2, 3) == 0x12 << 56 | 1 << 48 | 2 << 40 | 3 << 32)
  // LOGIC_OP32: mode [3:0], index flag [4], src1 [39:32], src0 [47:40], dst [55:48].
  #expect(CSInstruction.logic32(dst: 9, 10, 11, truthTable: CSInstruction.logicOR, bitIndex: true)
    == 0x13 << 56 | 9 << 48 | 10 << 40 | 11 << 32 | 0x17)
  #expect(CSInstruction.logic32(dst: 9, 10, 11, truthTable: CSInstruction.logicAndNot, bitIndex: true) & 0x1F == 0x12)
  #expect(CSInstruction.branch(.notEqual, register: 5, offset: -1) == 0x16 << 56 | 5 << 40 | 3 << 28 | 0xFFFF)
  #expect(CSInstruction.branch(.always, register: 0, offset: 2) == 0x16 << 56 | 6 << 28 | 2)
  #expect(CSInstruction.setScoreboardEntry(endpoint: 3, other: 0) == 0x17 << 56 | 3)
  #expect(CSInstruction.setScoreboardEntry(endpoint: 3, other: 1) == 0x17 << 56 | 0x13)
  #expect(CSInstruction.setExceptionHandler(type: 2, address: 4, size: 6) == 0x19 << 56 | 4 << 40 | 6 << 32 | 2)
  #expect(CSInstruction.nextScoreboardEntry(.endpoint, dst: 70) == 0x1A << 56 | 70 << 48 | 1 << 32)
  #expect(CSInstruction.nextScoreboardEntry(.deferred, mask: true, dst: 70) == 0x1A << 56 | 70 << 48 | 1 << 36 | 3 << 32)
  #expect(CSInstruction.setState(.waitMask, from: 66) == 0x1B << 56 | 66 << 40 | 9 << 32)
  #expect(CSInstruction.setState(.endpointSlot, immediate: 3) == 0x1C << 56 | 3)
  #expect(CSInstruction.setState(.streamMask, immediate: 0xFFF0) == 0x1C << 56 | 8 << 32 | 0xFFF0)
  #expect(CSInstruction.call(address: 0, size: 2) == 0x20 << 56 | 2 << 32)
  #expect(CSInstruction.jump(address: 8, size: 10) == 0x21 << 56 | 8 << 40 | 10 << 32)
  #expect(CSInstruction.requestResources(.compute) == 0x22 << 56 | 1)
  #expect(CSInstruction.requestResources(.fragment | .tiler) == 0x22 << 56 | 6)
  #expect(CSInstruction.errorBarrier == 0x2F << 56)
}

@Test func syncAndCacheInstructionsCarryTheirFields() {
  // SYNC_ADD64: error propagate [0], scope [2:1], wait mask [31:16], data [39:32], address [47:40], slot [51:48], defer [52].
  #expect(CSInstruction.syncAdd64(address: 2, value: 4, waitMask: 0x0008, signalSlot: 1, scope: .group,
                                  errorPropagate: true, deferred: true)
    == 0x33 << 56 | 1 << 52 | 1 << 48 | 2 << 40 | 4 << 32 | 8 << 16 | 2 << 1 | 1)
  #expect(CSInstruction.syncAdd32(address: 2, value: 4) == 0x25 << 56 | 2 << 40 | 4 << 32)
  #expect(CSInstruction.syncSet32(address: 2, value: 4) == 0x26 << 56 | 2 << 40 | 4 << 32)
  #expect(CSInstruction.syncSet64(address: 2, value: 4) == 0x34 << 56 | 2 << 40 | 4 << 32)
  // SYNC_WAIT: error reject [0], condition [31:28], reference [39:32], address [47:40].
  #expect(CSInstruction.syncWait64(address: 2, reference: 4, condition: .greater) == 0x35 << 56 | 2 << 40 | 4 << 32 | 1 << 28)
  #expect(CSInstruction.syncWait32(address: 2, reference: 4, condition: .lessOrEqual, errorReject: true)
    == 0x27 << 56 | 2 << 40 | 4 << 32 | 1)
  // STORE_STATE: offset [15:0], wait mask [31:16], state [39:32], address [47:40], slot [51:48].
  #expect(CSInstruction.storeState(address: 2, state: .errorStatus, offset: -8, waitMask: 1, signalSlot: 2)
    == 0x28 << 56 | 2 << 48 | 2 << 40 | 3 << 32 | 1 << 16 | 0xFFF8)
  // FLUSH_CACHE2: L2 [3:0], LSC [7:4], other [11:8], wait mask [31:16], flush id [47:40], slot [51:48], defer [52].
  #expect(CSInstruction.flushCache2(l2: .clean, lsc: .clean, flushIDRegister: 66, signalSlot: 0)
    == 0x24 << 56 | 66 << 40 | 0x11)
  #expect(CSInstruction.flushCache2(l2: .cleanInvalidate, lsc: .none, other: .invalidate, flushIDRegister: 66,
                                    waitMask: 0x4, signalSlot: 2, deferred: true)
    == 0x24 << 56 | 1 << 52 | 2 << 48 | 66 << 40 | 4 << 16 | 0x203)
}

@Test func loadAndStoreMultiplePackTheirWordsInMaskOrder() {
  // 01 section 1.4.2: registers 0, 1 and 10 to 15 at offset 64 fill eight consecutive words from byte 64.
  let mask: UInt16 = 0x0003 | 0xFC00
  let w = CSInstruction.storeMultiple(base: 20, address: 4, offset: 64, mask: mask)
  #expect(w == 0x15 << 56 | 20 << 48 | 4 << 40 | UInt64(mask) << 16 | 64)
  #expect(CSInstruction.loadMultiple(base: 20, address: 4, offset: -4, mask: 1) == 0x14 << 56 | 20 << 48 | 4 << 40 | 1 << 16 | 0xFFFC)
  let indices = (0..<16).compactMap { CSPacking.wordIndex(mask: mask, bit: $0) }
  #expect(indices == [0, 1, 2, 3, 4, 5, 6, 7])
  #expect(CSPacking.wordIndex(mask: mask, bit: 10) == 2 && CSPacking.wordIndex(mask: mask, bit: 15) == 7)
  #expect(CSPacking.wordIndex(mask: mask, bit: 2) == nil)
  // Non-adjacent registers gather to adjacent words.
  #expect(CSPacking.wordIndex(mask: 0b1000_0100_0001, bit: 6) == 1 && CSPacking.wordIndex(mask: 0b1000_0100_0001, bit: 11) == 2)
}

@Test func runComputeCarriesTheTaskAndTheRegisterSelects() {
  // Task increment [13:0], axis [15:14], Ep limit [23:16], SRT/SPD/TSD/FAU selects [41:40] to [47:46], stage [51:48].
  #expect(CSInstruction.runCompute(taskIncrement: 4, taskAxis: 1) == 0x04 << 56 | 1 << 14 | 4)
  #expect(CSInstruction.runCompute(taskIncrement: 0x7FFF, taskAxis: 2, epLimit: 8, srt: 1, spd: 2, tsd: 3, fau: 1, stage: 1)
    == 0x04 << 56 | 1 << 48 | 1 << 46 | 3 << 44 | 2 << 42 | 1 << 40 | 8 << 16 | 2 << 14 | 0x3FFF)
  #expect(CSInstruction.runComputeIndirect(workgroupsPerTask: 16) == 0x2C << 56 | 16)
  // The progress increment bit [32] is never set.
  #expect(CSInstruction.runCompute(taskIncrement: 1, taskAxis: 0) >> 32 & 1 == 0)
}
