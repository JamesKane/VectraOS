// SPDX-License-Identifier: BSD-3-Clause

// Memory (valhall 12a): loads and stores of every width, thread-local
// storage, atomics, and the message and wait model.

import Testing

import ValhallInterp

let outBase: UInt64 = 0x0000_0010_0000_0000
let inBase: UInt64 = 0x0000_0020_0000_0000

func loadI(_ width: UInt8, d: Int, addr: Operand = .u(0), lane: UInt8 = 0, off: Int32 = 0, zext: Bool = true, access: UInt8 = 0, slot: UInt8 = 0) -> Instr {
  var i = I(.load, d: d, addr)
  i.memWidth = width
  i.lane = lane
  i.offset = off
  i.zeroExtend = zext
  i.access = access
  i.slot = slot
  return i
}

func storeI(_ width: UInt8, d: Int, addr: Operand = .u(0), lane: UInt8 = 0, off: Int32 = 0, access: UInt8 = 0, slot: UInt8 = 0) -> Instr {
  var i = I(.store, d: d, addr)
  i.memWidth = width
  i.lane = lane
  i.offset = off
  i.access = access
  i.slot = slot
  return i
}

let waitAll = Instr(.nop).with(\.flow, .wait)
func fauPtr(_ a: UInt64) -> [UInt32] { [UInt32(truncatingIfNeeded: a), UInt32(a >> 32)] }

/// A memory with the bytes 0x10, 0x11, ... at `inBase`.
func patternMemory() -> GpuMemory {
  let m = GpuMemory()
  m.write(inBase, bytes: (0..<256).map { UInt8(truncatingIfNeeded: 0x80 &+ $0 &* 3) })
  m.map(outBase, size: 4096)
  return m
}

@Test func loadsOfEveryWidthAndLane() throws {
  let m = patternMemory()
  let b = m.read(inBase, count: 32)
  func le(_ n: Int, at: Int = 0) -> UInt64 { (0..<n).reduce(0) { $0 | UInt64(b[at + $1]) << UInt64(8 * $1) } }
  func go(_ i: Instr, init pre: [UInt32] = [0xAAAA_AAAA, 0xBBBB_BBBB, 0xCCCC_CCCC, 0xDDDD_DDDD]) throws -> [UInt32] {
    let o = try run([i, waitAll], inputs: [8: [pre[0]], 9: [pre[1]], 10: [pre[2]], 11: [pre[3]]], fau: fauPtr(inBase), memory: m)
    return (8..<12).map { o[$0, 0] }
  }
  let v8 = UInt32(b[0])
  // i8 into one byte keeps the rest of the register.
  for l in 0..<4 {
    let sh = UInt32(8 * l)
    #expect(try go(loadI(0, d: 8, lane: UInt8(l)))[0] == (0xAAAA_AAAA & ~(0xFF << sh)) | v8 << sh)
  }
  // i8 into a half (zero or sign extended), a word, a pair.
  let s8 = UInt32(bitPattern: Int32(Int8(bitPattern: b[0]))) & 0xFFFF
  #expect(try go(loadI(0, d: 8, lane: 4))[0] == 0xAAAA_0000 | v8)
  #expect(try go(loadI(0, d: 8, lane: 4, zext: false))[0] == 0xAAAA_0000 | s8)
  #expect(try go(loadI(0, d: 8, lane: 5, zext: false))[0] == s8 << 16 | 0xAAAA)
  #expect(try go(loadI(0, d: 8, lane: 6, zext: false))[0] == UInt32(bitPattern: Int32(Int8(bitPattern: b[0]))))
  let d0 = try go(loadI(0, d: 8, lane: 7, zext: false))
  #expect(d0[0] == UInt32(bitPattern: Int32(Int8(bitPattern: b[0]))) && d0[1] == 0xFFFF_FFFF)
  // i16: halves, word, pair.
  let v16 = UInt32(le(2))
  #expect(try go(loadI(1, d: 8, lane: 0))[0] == 0xAAAA_0000 | v16 | 0)  // h0: keeps the high half
  #expect(try go(loadI(1, d: 8, lane: 1))[0] == v16 << 16 | 0xAAAA)
  #expect(try go(loadI(1, d: 8, lane: 2, zext: false))[0] == UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: v16))))
  // i32, with and without the pair.
  #expect(try go(loadI(3, d: 8))[0] == UInt32(le(4)))
  let p = try go(loadI(3, d: 8, lane: 1, zext: false))
  #expect(p[0] == UInt32(le(4)) && p[1] == (UInt32(le(4)) >> 31 == 1 ? 0xFFFF_FFFF : 0))
  // i24, i48, i64, i96, i128.
  #expect(try go(loadI(2, d: 8))[0] == UInt32(le(3)))
  let w48 = try go(loadI(4, d: 8))
  #expect(w48[0] == UInt32(le(4)) && w48[1] == UInt32(le(6) >> 32))
  let w64 = try go(loadI(5, d: 8))
  #expect(w64[0] == UInt32(le(4)) && w64[1] == UInt32(le(8) >> 32))
  let w96 = try go(loadI(6, d: 8))
  #expect(w96 == [UInt32(le(4)), UInt32(le(4, at: 4)), UInt32(le(4, at: 8)), 0xDDDD_DDDD])
  let w128 = try go(loadI(7, d: 8))
  #expect(w128 == (0..<4).map { UInt32(le(4, at: 4 * $0)) })
  // Offset (signed 16 bits): relative to the address.
  let o = try run([loadI(3, d: 8, off: 20), waitAll], fau: fauPtr(inBase), memory: m)
  #expect(o[8, 0] == UInt32(le(4, at: 20)))
  let neg = try run([loadI(3, d: 8, off: -8), waitAll], fau: fauPtr(inBase + 16), memory: m)
  #expect(neg[8, 0] == UInt32(le(4, at: 8)))
}

@Test func addressesFromRegistersPerLane() throws {
  let m = patternMemory()
  // r2:r3 = inBase + 4 * lane: every lane loads its own word.
  let code = [
    I(.mov, d: 2, .u(0)), I(.mov, d: 3, .u(0, 1)),
    I(.shadd, .u64, d: 4, r(2), .special(page: 3, entry: 1)).with(\.shiftAmount, 2),
    loadI(3, d: 8, addr: r(4)), waitAll,
  ]
  // SHADD's B is the 64-bit lane id pair (lane_id, high word): shift 2, no widen -> the full 64-bit value.
  let o = try run(code, fau: fauPtr(inBase), memory: m)
  for lane in 0..<16 { #expect(o[8, lane] == m.read32(inBase + UInt64(4 * lane))) }
}

@Test func storesOfEveryWidthAndLane() throws {
  let m = patternMemory()
  let regs: [Int: [UInt32]] = [8: [0x0403_0201], 9: [0x0807_0605], 10: [0x0C0B_0A09], 11: [0x100F_0E0D]]
  func go(_ i: Instr, at addr: UInt64 = outBase) throws -> [UInt8] {
    m.write(addr, bytes: [UInt8](repeating: 0xEE, count: 24))
    _ = try run([i, waitAll], inputs: regs, fau: fauPtr(addr), memory: m)
    return m.read(addr, count: 18)
  }
  // Only lane 0's value matters for what remains: all lanes store the same bytes to one address.
  #expect(try go(storeI(0, d: 8, lane: 2)).prefix(3) == [0x03, 0xEE, 0xEE])
  #expect(try go(storeI(1, d: 8, lane: 1)).prefix(3) == [0x03, 0x04, 0xEE])
  #expect(try go(storeI(2, d: 8)).prefix(4) == [1, 2, 3, 0xEE])  // three bytes, not the fourth
  #expect(try go(storeI(3, d: 8)).prefix(5) == [1, 2, 3, 4, 0xEE])
  #expect(try go(storeI(4, d: 8)).prefix(7) == [1, 2, 3, 4, 5, 6, 0xEE])
  #expect(try go(storeI(5, d: 8)).prefix(9) == [1, 2, 3, 4, 5, 6, 7, 8, 0xEE])
  #expect(try go(storeI(6, d: 8)).prefix(13) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0xEE])
  #expect(try go(storeI(7, d: 8)).prefix(17) == Array(1...16) + [0xEE])
  // Offset, negative.
  let neg = storeI(3, d: 8, off: -4)
  m.write(outBase + 28, bytes: [0xEE, 0xEE, 0xEE, 0xEE, 0xEE])
  _ = try run([neg, waitAll], inputs: regs, fau: fauPtr(outBase + 32), memory: m)
  #expect(m.read(outBase + 28, count: 5) == [1, 2, 3, 4, 0xEE])
}

@Test func threadLocalStorageIsPerInvocation() throws {
  // Each lane stores its lane id through thread_local_pointer (access force) and reads it back.
  var cfg = DispatchConfig(workgroupSize: Dim3(32), grid: Dim3(2), fau: fauPtr(outBase))
  cfg.threadLocalBytes = 16
  let m = GpuMemory()
  m.map(outBase, size: 4096)
  // r60:r61 is a pair, so SHADD's B names it with w0.
  let prog: [Instr] = [
    I(.mov, d: 4, .laneId), storeI(3, d: 4, addr: .threadLocalPointer, access: 3).flow(.none),
    Instr(.nop).with(\.flow, .wait0),
    loadI(3, d: 5, addr: .threadLocalPointer, access: 3),
    I(.shadd, .u64, d: 2, .u(0), r(60)).with(\.widen1, 8).with(\.shiftAmount, 2),
    Instr(.nop).with(\.flow, .wait0),
    storeI(3, d: 5, addr: r(2)),
  ]
  _ = try runDispatch(Shader(prog + [Instr(.nop).with(\.flow, .wait0), end]), cfg, memory: m)
  for gid in 0..<64 { #expect(m.read32(outBase + UInt64(4 * gid)) == UInt32(gid % 16), "gid \(gid)") }
  // The pointers differ per invocation and the storage starts poisoned.
  let o = try run([loadI(3, d: 8, addr: .threadLocalPointer, access: 3), waitAll], fau: [], memory: m, tlsBytes: 8)
  #expect(o[8, 4] == 0xA5A5_A5A5)
}

// MARK: Atomics

private func atomicRun(_ code: [Instr], mem: UInt64 = outBase, init words: [UInt32], inputs: [Int: [UInt32]] = [:], helper: UInt16 = 0) throws -> (Out, GpuMemory) {
  let m = GpuMemory()
  m.write32(mem, words)
  let o = try run(code + [waitAll], inputs: inputs, fau: fauPtr(mem), memory: m, helper: helper)
  return (o, m)
}

private func atom(_ op: Opcode, _ width: UInt8, _ code: UInt8, d: Int = 4, w: Int = 8, off: Int32 = 0) -> Instr {
  var i = I(op, d: d, .u(0))
  i.memWidth = width
  i.atomOp = code
  i.writeReg = UInt8(w)
  i.offset = off
  return i
}

@Test func atomicsThirtyTwoBit() throws {
  // Sixteen lanes add 1: the sum is 16 and each lane's returned old value is distinct (lane order).
  let (o, m) = try atomicRun([atom(.atomReturn, 3, 2)], init: [100], inputs: [4: [1]])
  #expect(m.read32(outBase) == 116)
  #expect(o.all(8) == (0..<16).map { UInt32(100 + $0) })
  // Each operation, one lane's operand 0xF0 against memory 0x3C (lanes all do it: idempotent ones only).
  func apply(_ code: UInt8, _ mem: UInt32, _ d: UInt32) throws -> UInt32 {
    let (_, mm) = try atomicRun([atom(.atom, 3, code)], init: [mem], inputs: [4: [d]], helper: 0xFFFE)  // lane 0 only
    return mm.read32(outBase)
  }
  #expect(try apply(8, 0xFFFF_FFFE, 5) == 0xFFFF_FFFE)  // asmin: -2 < 5
  #expect(try apply(9, 0xFFFF_FFFE, 5) == 5)  // asmax
  #expect(try apply(10, 0xFFFF_FFFE, 5) == 5)  // aumin
  #expect(try apply(11, 0xFFFF_FFFE, 5) == 0xFFFF_FFFE)  // aumax
  #expect(try apply(12, 0x3C, 0xF0) == 0x30 && apply(13, 0x3C, 0xF0) == 0xFC && apply(14, 0x3C, 0xF0) == 0xCC)
  // AXCHG (a returning exchange) and wraparound at 32 bits.
  let (x, xm) = try atomicRun([atom(.atomReturn, 3, 15)], init: [7], inputs: [4: [9]], helper: 0xFFFE)
  #expect(x[8, 0] == 7 && xm.read32(outBase) == 9)
  let (_, wm) = try atomicRun([atom(.atom, 3, 2)], init: [0xFFFF_FFFF], inputs: [4: [2]], helper: 0xFFFE)
  #expect(wm.read32(outBase) == 1)
  // The offset field reaches the next word.
  let (_, om) = try atomicRun([atom(.atom, 3, 2, off: 4)], init: [10, 20], inputs: [4: [1]], helper: 0xFFFE)
  #expect(om.read32(outBase, count: 2) == [10, 21])
}

@Test func atomicsImplicitOperand() throws {
  func go(_ code: UInt8, _ mem: UInt32, returning: Bool = false) throws -> (UInt32, UInt32) {
    let (o, m) = try atomicRun([atom(returning ? .atom1Return : .atom1, 3, code, d: 8)], init: [mem], helper: 0xFFFE)
    return (m.read32(outBase), o[8, 0])
  }
  #expect(try go(0, 5).0 == 6 && go(1, 5).0 == 4 && go(1, 0).0 == 0xFFFF_FFFF)
  #expect(try go(2, 0).0 == 1 && go(2, 9).0 == 9 && go(3, 0xFFFF_FFFF).0 == 1 && go(3, 9).0 == 9)
  #expect(try go(4, 6).0 == 7)
  let r = try go(0, 41, returning: true)
  #expect(r == (42, 41))
  // All sixteen lanes incrementing: 16 distinct old values.
  let (o, m) = try atomicRun([atom(.atom1Return, 3, 0, d: 8)], init: [0])
  #expect(m.read32(outBase) == 16 && o.all(8) == (0..<16).map { UInt32($0) })
}

@Test func atomicCompareExchangeClaimsOnce() throws {
  // Lane i tries to replace 0 with i + 1: the first lane wins, every lane sees the old value.
  let code = [I(.iaddImm, d: 4, .laneId).with(\.imm, 1), I(.mov, d: 5, .zero), atom(.acmpxchg, 3, 15, d: 4, w: 8)]
  let (o, m) = try atomicRun(code, init: [0])
  #expect(m.read32(outBase) == 1)
  #expect(o.all(8) == [0] + [UInt32](repeating: 1, count: 15))
}

@Test func sixtyFourBitAtomics() throws {
  let m = GpuMemory()
  m.write64(outBase, 0xFFFF_FFFF)
  func go(_ code: UInt8, lo: UInt32, hi: UInt32 = 0, count: Int = 1) throws {
    var inputs: [Int: [UInt32]] = [4: [lo], 5: [hi]]
    inputs[6] = [0]
    _ = try run([atom(.atom, 5, code), waitAll], inputs: inputs, fau: fauPtr(outBase), memory: m, helper: UInt16(truncatingIfNeeded: ~((1 << count) - 1)))
  }
  try go(2, lo: 1, hi: 0)  // aadd
  #expect(m.read64(outBase) == 0x1_0000_0000)
  try go(0, lo: 0xFFFF_FFFF)  // aaddu: zero extended 32-bit
  #expect(m.read64(outBase) == 0x1_FFFF_FFFF)
  try go(1, lo: 0xFFFF_FFFF)  // aadds: sign extended: adds -1
  #expect(m.read64(outBase) == 0x1_FFFF_FFFE)
  try go(10, lo: 5, hi: 0)  // aumin
  #expect(m.read64(outBase) == 5)
  try go(9, lo: 0, hi: 0x8000_0000)  // asmax with a negative operand: memory stays
  #expect(m.read64(outBase) == 5)
  // Returning exchange, and compare-exchange of 64 bits.
  let r = try run(
    [atom(.atomReturn, 5, 15, d: 4, w: 8), waitAll], inputs: [4: [0xAAAA], 5: [0xBBBB]], fau: fauPtr(outBase), memory: m, helper: 0xFFFE)
  #expect(r[8, 0] == 5 && r[9, 0] == 0 && m.read64(outBase) == 0xBBBB_0000_AAAA)
  let c = try run(
    [atom(.acmpxchg, 5, 15, d: 4, w: 8), waitAll], inputs: [4: [1], 5: [2], 6: [0xAAAA], 7: [0xBBBB]], fau: fauPtr(outBase),
    memory: m, helper: 0xFFFE)
  #expect(c[8, 0] == 0xAAAA && c[9, 0] == 0xBBBB && m.read64(outBase) == 0x2_0000_0001)
}

@Test func discardedLanesDoNothingAndAtomicsReturnZero() throws {
  let m = GpuMemory()
  m.write32(outBase, [10, 0])
  // Lanes 0..7 are helpers: they neither store nor update; their atomic returns zero.
  let code: [Instr] = [
    I(.iaddImm, d: 4, .zero).with(\.imm, 1), atom(.atomReturn, 3, 2, d: 4, w: 8), storeI(3, d: 4, off: 4), waitAll,
  ]
  let o = try run(code, fau: fauPtr(outBase), memory: m, helper: 0x00FF)
  #expect(m.read32(outBase) == 10 + 8)
  #expect((0..<8).allSatisfy { o[8, $0] == 0 } && Set((8..<16).map { o[8, $0] }) == Set((10...17).map { UInt32($0) }))
  // A store with access `force` still happens in a helper lane.
  let f = try run([I(.mov, d: 4, .k(2)), storeI(3, d: 4, off: 8, access: 3), waitAll], fau: fauPtr(outBase), memory: m, helper: 0xFFFF)
  _ = f
  #expect(m.read32(outBase + 8) == 0x7FFF_FFFF)
}

// MARK: The message model

@Test func readingAResultBeforeItsSlotIsWaitedOnIsReported() throws {
  let m = patternMemory()
  let early = [loadI(3, d: 8), I(.iadd, .u32, d: 9, r(8), .zero)]
  #expect(throws: InterpError.self) { _ = try run(early, fau: fauPtr(inBase), memory: m) }
  do {
    _ = try run(early, fau: fauPtr(inBase), memory: m)
  } catch let e as InterpError {
    #expect(e.fault == .readBeforeWait(register: 8, slot: 0) && e.pc == 1)
  }
  // A wait takes effect after the instruction that carries it (the board, docs/gpu/valhall-board-findings.md): the
  // reading instruction's own wait does not cover its read, and the old saxpy's shape faults as the hardware failed.
  let own = [loadI(3, d: 8), I(.iadd, .u32, d: 9, r(8), .zero).flow(.wait0)]
  #expect(throws: InterpError.self) { _ = try run(own, fau: fauPtr(inBase), memory: m) }
  // Waiting on the slot first is fine, on another slot is not.
  let ok = [loadI(3, d: 8), Instr(.nop).with(\.flow, .wait0), I(.iadd, .u32, d: 9, r(8), .zero)]
  #expect(try run(ok, fau: fauPtr(inBase), memory: m)[9, 0] == m.read32(inBase))
  let wrong = [loadI(3, d: 8, slot: 1), Instr(.nop).with(\.flow, .wait0), I(.iadd, .u32, d: 9, r(8), .zero)]
  #expect(throws: InterpError.self) { _ = try run(wrong, fau: fauPtr(inBase), memory: m) }
  let both = [loadI(3, d: 8, slot: 2), Instr(.nop).with(\.flow, .wait02), I(.iadd, .u32, d: 9, r(8), .zero)]
  #expect(try run(both, fau: fauPtr(inBase), memory: m)[9, 0] == m.read32(inBase))
  // The wait values: wait covers 0, 1, 2 (and 6, 7).
  let all = [loadI(3, d: 8, slot: 1), Instr(.nop).with(\.flow, .wait), I(.iadd, .u32, d: 9, r(8), .zero)]
  #expect(try run(all, fau: fauPtr(inBase), memory: m)[9, 0] == m.read32(inBase))
}

@Test func overwritingARegisterWithAResultInFlightIsReported() throws {
  let m = patternMemory()
  let code = [loadI(3, d: 8), I(.mov, d: 8, .zero)]
  do {
    _ = try run(code, fau: fauPtr(inBase), memory: m)
    Issue.record("no fault")
  } catch let e as InterpError {
    #expect(e.fault == .writeBeforeWait(register: 8, slot: 0))
  }
  // Two loads into one register without a wait between them.
  #expect(throws: InterpError.self) { _ = try run([loadI(3, d: 8), loadI(3, d: 8)], fau: fauPtr(inBase), memory: m) }
  // A store's data registers are read at issue: reading them is the issue-time read, but a pending one is a fault.
  #expect(throws: InterpError.self) { _ = try run([loadI(3, d: 8), storeI(3, d: 8, addr: .u(0))], fau: fauPtr(inBase), memory: m) }
}

@Test func lastUseMarksPoisonTheRegister() throws {
  let reads = [I(.iadd, .u32, d: 9, .last(8), .zero), I(.iadd, .u32, d: 10, r(8), .zero)]
  do {
    _ = try run(reads, inputs: [8: [5]])
    Issue.record("no fault")
  } catch let e as InterpError {
    #expect(e.fault == .readAfterLastUse(register: 8) && e.pc == 1)
  }
  // Writing it again revives it; reading and overwriting in one instruction is fine; non-strict ignores marks.
  #expect(try run([I(.iadd, .u32, d: 8, .last(8), .zero), I(.iadd, .u32, d: 10, r(8), .zero)], inputs: [8: [5]])[10, 0] == 5)
  #expect(try run(reads, inputs: [8: [5]], strict: false)[10, 0] == 5)
}

@Test func unmappedAndMisalignedAndFauAccessesAreReported() throws {
  do {
    _ = try run([loadI(3, d: 8), waitAll], fau: fauPtr(0xDEAD_0000))
    Issue.record("no fault")
  } catch let e as InterpError { #expect(e.fault == .unmapped(address: 0xDEAD_0000)) }
  do {
    _ = try run([I(.mov, d: 8, .u(5))], fau: [1, 2])
    Issue.record("no fault")
  } catch let e as InterpError { #expect(e.fault == .fauOutOfRange(slot: 5)) }
  let m = GpuMemory()
  m.map(outBase, size: 64)
  do {
    _ = try run([atom(.atom, 3, 2)], inputs: [4: [1]], fau: fauPtr(outBase + 2), memory: m)
    Issue.record("no fault")
  } catch let e as InterpError { #expect(e.fault == .misaligned(address: outBase + 2)) }
}
