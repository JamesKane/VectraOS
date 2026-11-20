// SPDX-License-Identifier: BSD-3-Clause

// Whole kernels, hand-assembled, run over a grid and compared with the
// same computation on the CPU: the shape of the compiler's own tests
// (D174 §7), and the FAU limits that the validator also checks.

import Testing

import ValhallInterp

@Test func saxpyWithABoundsCheckMatchesTheCPU() throws {
  let n = 100
  let xs = (0..<n).map { Float($0) * 0.37 - 5 }
  let ys = (0..<n).map { Float($0 % 7) * 1.25 }
  let a: Float = 2.5
  let (xb, yb, ob): (UInt64, UInt64, UInt64) = (0x1000_0000, 0x2000_0000, 0x3000_0000)
  let m = GpuMemory()
  m.write32(xb, xs.map(\.bitPattern))
  m.write32(yb, ys.map(\.bitPattern))
  m.map(ob, size: 4 * 128)
  // u0, u1, u2: the pointers; u3: n and a.
  let fau = fauPtr(xb) + fauPtr(yb) + fauPtr(ob) + [UInt32(n), a.bitPattern]
  let code: [Instr] = [
    I(.icmp, .u32, d: 4, r(60), .u(3, 0), .zero).with(\.cmp, 2).with(\.resultType, 2),  // idx >= n
    branch(r(4), to: 9, from: 1).flow(rc),
    I(.shadd, .u64, d: 6, .u(0), r(60)).with(\.widen1, 8).with(\.shiftAmount, 2),
    I(.shadd, .u64, d: 8, .u(1), r(60)).with(\.widen1, 8).with(\.shiftAmount, 2),
    loadI(3, d: 10, addr: r(6), slot: 0),
    loadI(3, d: 11, addr: r(8), slot: 1),
    I(.fma, .f32, d: 12, .u(3, 1), r(10), r(11)).flow(.wait01),
    I(.shadd, .u64, d: 14, .u(2), r(60)).with(\.widen1, 8).with(\.shiftAmount, 2),
    storeI(3, d: 12, addr: r(14)).flow(rc),
    Instr(.nop).with(\.flow, .end),
  ]
  let cfg = DispatchConfig(workgroupSize: Dim3(32), grid: Dim3(4), fau: fau)
  let report = try runDispatch(Shader(code), cfg, memory: m)
  #expect(report.workgroups == 4 && report.warps == 8)
  for i in 0..<n { #expect(m.read32(ob + UInt64(4 * i)) == (ys[i].addingProduct(a, xs[i])).bitPattern, "element \(i)") }
  for i in n..<128 { #expect(m.read32(ob + UInt64(4 * i)) == 0, "element \(i) is past n and untouched") }
}

@Test func histogramWithAtomicsMatchesTheCPU() throws {
  let hb: UInt64 = 0x4000_0000
  let m = GpuMemory()
  m.map(hb, size: 64)
  let code: [Instr] = [
    movImm(10, 7), I(.imul, .u32, d: 4, r(60), r(10)), I(.andImm, d: 4, r(4)).with(\.imm, 7), movImm(5, 0),
    I(.shadd, .u64, d: 6, .u(0), r(4)).with(\.widen1, 8).with(\.shiftAmount, 2),
    I(.atom1, d: 0, r(6)).with(\.memWidth, 3).with(\.atomOp, 0),
    Instr(.nop).with(\.flow, .wait0),
  ]
  let cfg = DispatchConfig(workgroupSize: Dim3(40), grid: Dim3(5), fau: fauPtr(hb))
  _ = try runDispatch(Shader(code + [end]), cfg, memory: m)
  var want = [UInt32](repeating: 0, count: 8)
  for gid in 0..<200 { want[(gid * 7) & 7] += 1 }
  #expect(m.read32(hb, count: 8) == want)
}

@Test func fauLimitsAreChecked() throws {
  func fault(_ code: [Instr]) -> Fault? {
    do {
      _ = try run(code, fau: [UInt32](repeating: 1, count: 16))
      return nil
    } catch let e as InterpError { return e.fault } catch { return nil }
  }
  // Two words of one slot, a word and constants, a 64-bit slot read as one operand: fine.
  #expect(fault([I(.fadd, d: 8, .u(0, 0), .u(0, 1))]) == nil)
  #expect(fault([I(.fadd, d: 8, .u(0, 0), .k(16))]) == nil)
  #expect(fault([I(.fadd, d: 8, .u(0, 0), .zero)]) == nil)
  // Three distinct words (two constants and a FAU word), two slots, or a user word with a special: not.
  if case .invalid = fault([I(.fma, d: 8, .u(0, 0), .k(16), .k(17))]) {} else { Issue.record("three words") }
  if case .invalid = fault([I(.fadd, d: 8, .u(0, 0), .u(1, 0))]) {} else { Issue.record("two slots") }
  if case .invalid = fault([I(.iadd, .u32, d: 8, .u(0, 0), .laneId)]) {} else { Issue.record("user and special") }
  // A message instruction must not read lane_id or warp_id.
  if case .invalid = fault([I(.shadd, .u64, d: 2, .zero, .zero), loadI(3, d: 8, addr: .special(page: 3, entry: 1))]) {} else {
    Issue.record("message reads a page 3 special")
  }
  // A 64-bit user source is two words of one slot.
  #expect(fault([I(.shadd, .u64, d: 2, .u(1), .zero)]) == nil)
}
