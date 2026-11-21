// SPDX-License-Identifier: BSD-3-Clause

// Control flow (valhall 13): divergence and reconvergence, loops with early
// exit, jumps, discard and helper lanes, subgroup operations, workgroup
// barriers over several warps with shared memory, and the compute ABI.

import Testing

import ValhallInterp

/// The offset a `BRANCH` at `from` needs to land on `to` (13 §13.4.4: relative to the next instruction).
func br(_ from: Int, _ to: Int) -> Int32 { Int32(to - from - 1) }

func branch(_ cond: Operand, to: Int, from: Int, not: Bool = false) -> Instr {
  var i = I(.branch, d: 0, cond)
  i.offset = br(from, to)
  i.not = not
  return i
}

/// An unconditional branch (the condition is the constant 0, inverted).
func jmp(from: Int, to: Int) -> Instr { branch(.zero, to: to, from: from, not: true) }

func movImm(_ d: Int, _ v: UInt32) -> Instr { I(.iaddImm, d: d, .zero).with(\.imm, v) }
func addImm(_ d: Int, _ s: Int, _ v: UInt32) -> Instr { I(.iaddImm, d: d, r(s)).with(\.imm, v) }
func wmask(_ d: Int, _ src: Operand = .ones, subgroup: UInt8 = 3) -> Instr { I(.wmask, d: d, src).with(\.subgroup, subgroup) }
let rc = Flow.reconverge

@Test func ifElseReconvergesAtTheJoin() throws {
  let code: [Instr] = [
    I(.mov, d: 4, .laneId),
    I(.andImm, d: 5, r(4)).with(\.imm, 1),
    branch(r(5), to: 5, from: 2),  // odd lanes take the branch
    movImm(8, 100),
    jmp(from: 4, to: 6).flow(rc),
    movImm(8, 200).flow(rc),
    wmask(9),
  ]
  let o = try run(code)
  for lane in 0..<16 {
    #expect(o[8, lane] == (lane % 2 == 0 ? 100 : 200))
    #expect(o[9, lane] == 0xFFFF, "after the join the warp is whole again")
  }
}

@Test func withoutTheFlagThePathsRunOnSeparately() throws {
  // The same shader without `reconverge`: every lane still computes its own values, but a cross-lane
  // instruction after the join sees one path's lanes at a time (even lanes first: lowest pc).
  let code: [Instr] = [
    I(.mov, d: 4, .laneId),
    I(.andImm, d: 5, r(4)).with(\.imm, 1),
    branch(r(5), to: 5, from: 2),
    movImm(8, 100),
    jmp(from: 4, to: 6),
    movImm(8, 200),
    wmask(9),
  ]
  let o = try run(code)
  for lane in 0..<16 {
    #expect(o[8, lane] == (lane % 2 == 0 ? 100 : 200))
    #expect(o[9, lane] == (lane % 2 == 0 ? 0x5555 : 0xAAAA))
  }
}

@Test func loopWithEarlyExitPerLane() throws {
  // do { sum += 3; i += 1 } while (i < lane): lane L runs max(L, 1) times; the exit lanes wait at the join.
  let code: [Instr] = [
    I(.mov, d: 4, .laneId),
    movImm(5, 0),
    movImm(8, 0).flow(rc),
    addImm(8, 8, 3),  // 3: loop header
    addImm(5, 5, 1),
    I(.icmp, .u32, d: 6, r(5), r(4), .zero).with(\.cmp, 4).with(\.resultType, 2),
    branch(r(6), to: 3, from: 6).flow(rc),
    wmask(9),
  ]
  let o = try run(code)
  for lane in 0..<16 {
    #expect(o[8, lane] == UInt32(3 * max(lane, 1)), "lane \(lane)")
    #expect(o[9, lane] == 0xFFFF)
  }
}

@Test func nestedIfInsideALoop() throws {
  let code: [Instr] = [
    I(.mov, d: 4, .laneId),
    I(.andImm, d: 4, r(4)).with(\.imm, 3),  // the last iteration index
    movImm(5, 0),
    movImm(8, 0).flow(rc),
    I(.andImm, d: 6, r(5)).with(\.imm, 1),  // 4: loop header
    branch(r(6), to: 8, from: 5),
    addImm(8, 8, 1),
    jmp(from: 7, to: 9).flow(rc),
    addImm(8, 8, 10).flow(rc),
    addImm(5, 5, 1),  // 9: join of the if
    I(.icmp, .u32, d: 7, r(5), r(4), .zero).with(\.cmp, 5).with(\.resultType, 2),
    branch(r(7), to: 4, from: 11).flow(rc),
    wmask(9),
  ]
  let o = try run(code)
  for lane in 0..<16 {
    let n = (lane & 3) + 1
    let want = (0..<n).reduce(0) { $0 + ($1 % 2 == 1 ? 10 : 1) }
    #expect(o[8, lane] == UInt32(want), "lane \(lane)")
    #expect(o[9, lane] == 0xFFFF)
  }
}

@Test func lanesThatEndEarlyLeaveTheRest() throws {
  let code: [Instr] = [
    I(.mov, d: 4, .laneId),
    I(.icmp, .u32, d: 5, r(4), .u(0), .zero).with(\.cmp, 2).with(\.resultType, 2),  // lane >= 12
    branch(r(5), to: 5, from: 2),
    movImm(8, 7),
    jmp(from: 4, to: 6),
    Instr(.nop).with(\.flow, .end),
    wmask(9),
  ]
  let o = try run(code, fau: [12, 0])
  for lane in 0..<16 {
    #expect(o[8, lane] == (lane < 12 ? 7 : 0))
    #expect(o[9, lane] == (lane < 12 ? 0x0FFF : 0), "the ended lanes are gone")
  }
}

@Test func jumpsAreAbsoluteAndAddressZeroEnds() throws {
  let code: [Instr] = [
    I(.iaddImm, d: 4, .pc).with(\.imm, 16),  // ADR: the address of instruction 3 (pc is the next one's)
    I(.jump, d: 0, .zero, r(4)).with(\.not, true),
    movImm(8, 111),
    movImm(9, 222),
  ]
  let o = try run(code)
  #expect(o[8, 0] == 0 && o[9, 0] == 222)
  let ends: [Instr] = [I(.jump, d: 0, .ones, .zero), movImm(8, 1)]
  #expect(try run(ends)[8, 0] == 0)
  // A conditional jump: lanes take it by their condition.
  let cond: [Instr] = [
    I(.mov, d: 4, .laneId), I(.andImm, d: 5, r(4)).with(\.imm, 1), I(.iaddImm, d: 6, .pc).with(\.imm, 16),
    I(.jump, d: 0, r(5), r(6)), movImm(8, 5), movImm(9, 6).flow(rc),
  ]
  let c = try run(cond)
  for lane in 0..<16 { #expect(c[8, lane] == (lane % 2 == 0 ? 5 : 0) && c[9, lane] == 6) }
}

@Test func discardFlagsLanesAndTheFlowRetiresThem() throws {
  let m = GpuMemory()
  m.map(outBase, size: 256)
  let code: [Instr] = [
    I(.mov, d: 4, .laneId),
    I(.andImm, d: 5, r(4)).with(\.imm, 1),
    I(.discard, d: 0, r(5), .zero).with(\.cmp, 3),  // ne 0: the odd lanes
    I(.mov, d: 6, .laneId), I(.shadd, .u64, d: 2, .u(0), r(6)).with(\.widen1, 8).with(\.shiftAmount, 2),
    storeI(3, d: 4, addr: r(2)),
    Instr(.nop).with(\.flow, .wait0),
    wmask(9),  // discarded lanes still run: the whole warp
    Instr(.nop).with(\.flow, .discard),
    wmask(10),
  ]
  let o = try run(code, fau: fauPtr(outBase), memory: m)
  for lane in 0..<16 {
    #expect(m.read32(outBase + UInt64(4 * lane)) == (lane % 2 == 0 ? UInt32(lane) : 0), "a discarded lane's store is suppressed")
    #expect(o[9, lane] == 0xFFFF)
    #expect(o[10, lane] == (lane % 2 == 0 ? 0x5555 : 0), "retired lanes are inactive afterwards")
  }
  // Helper lanes start discarded.
  let h = try run([wmask(9), Instr(.nop).with(\.flow, .discard), wmask(10)], helper: 0xF000)
  #expect(h[9, 0] == 0xFFFF && h[10, 0] == 0x0FFF && h[10, 15] == 0)
}

@Test func lanePermuteAndBallot() throws {
  func clper(_ op: UInt8, sub: UInt8, sel: UInt32, inactive: UInt8 = 0) throws -> [UInt32] {
    let code: [Instr] = [
      I(.mov, d: 4, .laneId), I(.iaddImm, d: 6, r(4)).with(\.imm, 100), movImm(7, sel),
      I(.clper, d: 8, r(6), r(7)).with(\.laneOp, op).with(\.subgroup, sub).with(\.widen1, 4).with(\.inactive, inactive),
    ]
    return try run(code).all(8)
  }
  #expect(try clper(0, sub: 3, sel: 5) == [UInt32](repeating: 105, count: 16))  // broadcast lane 5
  #expect(try clper(1, sub: 1, sel: 1) == (0..<16).map { UInt32(100 + ($0 ^ 1)) })  // quad neighbour in x
  #expect(try clper(1, sub: 1, sel: 2) == (0..<16).map { UInt32(100 + ($0 ^ 2)) })
  #expect(try clper(0, sub: 2, sel: 3) == (0..<16).map { UInt32(100 + ($0 & ~7) + 3) })  // lane 3 of each group of 8
  #expect(try clper(1, sub: 0, sel: 1) == (0..<16).map { UInt32(100 + ($0 ^ 1)) })
  // Inactive source lanes give the chosen constant: odd lanes only, reading their even neighbour.
  let code: [Instr] = [
    I(.mov, d: 4, .laneId), I(.andImm, d: 5, r(4)).with(\.imm, 1), movImm(7, 1),
    branch(r(5), to: 5, from: 3),
    jmp(from: 4, to: 6).flow(rc),
    I(.clper, d: 8, r(4), r(7)).with(\.laneOp, 1).with(\.subgroup, 3).with(\.widen1, 4).with(\.inactive, 1).flow(rc),
    wmask(9),
  ]
  let o = try run(code)
  for lane in 0..<16 { #expect(o[8, lane] == (lane % 2 == 1 ? 0xFFFF_FFFF : 0)) }
  // WMASK: a mask of the lanes whose value is nonzero.
  let bm = try run([I(.mov, d: 4, .laneId), I(.andImm, d: 5, r(4)).with(\.imm, 4), wmask(8, r(5))])
  #expect(bm[8, 0] == 0xF0F0)
  let sub = try run([I(.mov, d: 4, .laneId), I(.andImm, d: 5, r(4)).with(\.imm, 1), wmask(8, r(5), subgroup: 1)])
  #expect(sub[8, 0] == 0b1010 && sub[8, 5] == 0b1010)
}

// MARK: Workgroups, barriers and shared memory

private func dispatch(_ code: [Instr], _ cfg: DispatchConfig, memory: GpuMemory = GpuMemory()) throws -> RunReport {
  try runDispatch(Shader(code + [end]), cfg, memory: memory)
}

@Test func computeABIPreloadsIdsForPartialWarpsAndGrids() throws {
  // Size 5 x 3 x 2 = 30 invocations (a partial second warp), grid 2 x 2 x 1: global 10 x 6 x 2. Each
  // invocation stores one id at its global linear index; the ids come from the preloaded registers (14 §14.2.1).
  let cfg = DispatchConfig(workgroupSize: Dim3(5, 3, 2), grid: Dim3(2, 2, 1), fau: fauPtr(outBase))
  func program(_ id: Instr) -> [Instr] {
    [
      movImm(10, 6), I(.imul, .u32, d: 11, r(62), r(10)), I(.iadd, .u32, d: 11, r(11), r(61)),
      movImm(10, 10), I(.imul, .u32, d: 11, r(11), r(10)), I(.iadd, .u32, d: 12, r(11), r(60)),
      movImm(14, 16),
      I(.shadd, .u64, d: 2, .u(0), r(12)).with(\.widen1, 8).with(\.shiftAmount, 2),  // the pair r12:r13, r13 is zero
      id, storeI(3, d: 4, addr: r(2)), Instr(.nop).with(\.flow, .wait0),
    ]
  }
  let lx = I(.andImm, d: 4, r(55)).with(\.imm, 0xFFFF)
  let ly = I(.shift, .u32, d: 4, r(55), r(14), .zero).with(\.shiftOp, 0).with(\.combine, 1)  // r55 >> 16
  let kinds: [(String, Instr, (Int, Int, Int) -> Int)] = [
    ("local x", lx, { gx, _, _ in gx % 5 }), ("local y", ly, { _, gy, _ in gy % 3 }),
    ("local z", I(.mov, d: 4, r(56)), { _, _, gz in gz }),
    ("workgroup x", I(.mov, d: 4, r(57)), { gx, _, _ in gx / 5 }), ("workgroup y", I(.mov, d: 4, r(58)), { _, gy, _ in gy / 3 }),
    ("workgroup z", I(.mov, d: 4, r(59)), { _, _, _ in 0 }),
    ("global x", I(.mov, d: 4, r(60)), { gx, _, _ in gx }), ("global y", I(.mov, d: 4, r(61)), { _, gy, _ in gy }),
    ("global z", I(.mov, d: 4, r(62)), { _, _, gz in gz }),
  ]
  for (name, id, expect) in kinds {
    let m = GpuMemory()
    m.map(outBase, size: 1 << 14)
    _ = try dispatch(program(id), cfg, memory: m)
    for gz in 0..<2 {
      for gy in 0..<6 {
        for gx in 0..<10 {
          let idx = (gz * 6 + gy) * 10 + gx
          #expect(m.read32(outBase + UInt64(4 * idx)) == UInt32(expect(gx, gy, gz)), "\(name) at \(gx),\(gy),\(gz)")
        }
      }
    }
    // Nothing beyond the grid's 120 invocations is written: lanes past the workgroup size do not run.
    #expect(m.read32(outBase + UInt64(4 * 120)) == 0)
  }
}

@Test func workgroupSumThroughSharedMemoryAndBarriers() throws {
  func program(barriers: Bool) -> [Instr] {
    var c: [Instr] = [
      I(.andImm, d: 10, r(55)).with(\.imm, 0xFFFF),  // tid
      movImm(11, 1000), I(.imul, .u32, d: 12, r(57), r(11)),
      I(.iadd, .u32, d: 4, r(10), r(12)), addImm(4, 4, 1),  // value = tid + 1 + 1000 * workgroup
      I(.shadd, .u64, d: 2, .workgroupLocalPointer, r(10)).with(\.widen1, 8).with(\.shiftAmount, 2),
      storeI(3, d: 4, addr: r(2)),
      Instr(.nop).with(\.flow, .wait0),
    ]
    if barriers { c.append(Instr(.barrier).with(\.slot, 7).with(\.flow, .wait)) }
    for s in [32, 16, 8, 4, 2, 1] {
      c += [
        movImm(13, UInt32(s)),
        loadI(3, d: 5, addr: r(2), off: Int32(4 * s)), loadI(3, d: 7, addr: r(2)),
        Instr(.nop).with(\.flow, .wait0),
        I(.csel, .u32, d: 5, r(10), r(13), r(5), .zero).with(\.cmp, 4),  // tid < s ? shared[tid + s] : 0
        I(.iadd, .u32, d: 7, r(7), r(5)),
        storeI(3, d: 7, addr: r(2)),
        Instr(.nop).with(\.flow, .wait0),
      ]
      if barriers { c.append(Instr(.barrier).with(\.slot, 7).with(\.flow, .wait)) }
    }
    c += [
      loadI(3, d: 7, addr: .workgroupLocalPointer),
      I(.shadd, .u64, d: 14, .u(0), r(56)).with(\.widen1, 9).with(\.shiftAmount, 2),  // r56:r57, w1 = the workgroup id
      Instr(.nop).with(\.flow, .wait0),
      storeI(3, d: 7, addr: r(14)),
    ]
    return c
  }
  var cfg = DispatchConfig(workgroupSize: Dim3(64), grid: Dim3(3), fau: fauPtr(outBase))
  cfg.sharedBytes = 512
  let m = GpuMemory()
  m.map(outBase, size: 64)
  let report = try dispatch(program(barriers: true), cfg, memory: m)
  for wg in 0..<3 { #expect(m.read32(outBase + UInt64(4 * wg)) == UInt32(2080 + 64000 * wg), "workgroup \(wg)") }
  #expect(report.warps == 12 && report.barriers == 21)
  // Without the barriers the warps run one after another and the sum is wrong: the barrier is what orders them.
  let n = GpuMemory()
  n.map(outBase, size: 64)
  _ = try dispatch(program(barriers: false), cfg, memory: n)
  #expect(n.read32(outBase) != 2080)
}

@Test func barrierMisuseIsReported() throws {
  var cfg = DispatchConfig(workgroupSize: Dim3(32), grid: Dim3(1), fau: fauPtr(outBase))
  let m = GpuMemory()
  m.map(outBase, size: 64)
  let bar = Instr(.barrier).with(\.slot, 7).with(\.flow, .wait)
  // A store whose slot was not waited on before the barrier (the wait on the barrier itself does not count).
  do {
    _ = try dispatch([movImm(4, 1), storeI(3, d: 4), bar], cfg, memory: m)
    Issue.record("no fault")
  } catch let e as InterpError { #expect(e.fault == .barrierWithBusySlots(slots: 1)) }
  _ = try dispatch([movImm(4, 1), storeI(3, d: 4), Instr(.nop).with(\.flow, .wait0), bar], cfg, memory: m)
  // A barrier only some lanes reach.
  cfg.workgroupSize = Dim3(16)
  do {
    _ = try dispatch([I(.mov, d: 4, .laneId), I(.andImm, d: 5, r(4)).with(\.imm, 1), branch(r(5), to: 4, from: 2), jmp(from: 3, to: 5), bar], cfg)
    Issue.record("no fault")
  } catch let e as InterpError { #expect(e.fault == .barrierNotUniform) }
  // A warp that ends before the barrier while another waits at it.
  cfg.workgroupSize = Dim3(32)
  do {
    _ = try dispatch(
      [I(.andImm, d: 5, r(55)).with(\.imm, 0xFFFF), I(.icmp, .u32, d: 6, r(5), .u(0), .zero).with(\.cmp, 2).with(\.resultType, 2),
        branch(r(6), to: 4, from: 2), bar, ],
      DispatchConfig(workgroupSize: Dim3(32), grid: Dim3(1), fau: [16, 0]), memory: m)
    Issue.record("no fault")
  } catch let e as InterpError { #expect(e.fault == .barrierNotUniform) }
}

@Test func runsThatDoNotFinishAreReported() throws {
  var cfg = DispatchConfig(workgroupSize: Dim3(16), grid: Dim3(1))
  cfg.maxStepsPerWarp = 1000
  do {
    _ = try dispatch([jmp(from: 0, to: 0)], cfg)
    Issue.record("no fault")
  } catch let e as InterpError { #expect(e.fault == .stepLimit) }
  // Running off the end of the code.
  #expect(throws: InterpError.self) { _ = try runDispatch(Shader([movImm(4, 1)]), cfg, memory: GpuMemory()) }
}

@Test func specialEntriesAndTheProgramCounter() throws {
  var cfg = DispatchConfig(workgroupSize: Dim3(48), grid: Dim3(1))
  cfg.captureFirstWarp = false
  cfg.resourceTable = 0x0000_0033_4455_6677
  cfg.codeBase = 0x4000
  let m = GpuMemory()
  m.map(outBase, size: 4096)
  cfg.fau = fauPtr(outBase)
  // Warp 2 (invocations 32..47) records warp_id, the resource table pointer and pc.
  let code: [Instr] = [
    I(.mov, d: 4, .warpId), I(.mov, d: 5, .resourceTablePointer), I(.mov, d: 6, .special(page: 1, entry: 7, word: 1)),
    I(.iaddImm, d: 7, .pc).with(\.imm, 0),
    I(.shadd, .u64, d: 2, .u(0), r(60)).with(\.widen1, 8).with(\.shiftAmount, 4),
    storeI(7, d: 4, addr: r(2)), Instr(.nop).with(\.flow, .wait0),
  ]
  _ = try dispatch(code, cfg, memory: m)
  for gid in [0, 17, 40] {
    let b = outBase + UInt64(16 * gid)
    #expect(m.read32(b) == UInt32(gid / 16))
    #expect(m.read32(b + 4) == 0x4455_6677 && m.read32(b + 8) == 0x33)
    #expect(m.read32(b + 12) == 0x4000 + 8 * 4)  // the address of the instruction after the one reading pc
  }
}
