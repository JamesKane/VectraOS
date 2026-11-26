// SPDX-License-Identifier: BSD-3-Clause

// The GLSL.std.450 angle conversions and geometric functions (Radians, Degrees, Length, Distance, Cross, Normalize,
// FaceForward, Reflect, Refract), written out in the IR's own operations as GLSL.std.450's definitions say: a length is
// the square root of the dot product, a normalized vector the vector times the reciprocal square root of it, and so on.
// The dot products are a multiply and fused multiply-adds, as OpDot's are (LowerOps.swift).

extension Lowerer {
  private mutating func dotLanes(_ a: [ValueID], _ b: [ValueID], _ et: IRType) -> ValueID {
    var acc = emit(.fmul, et, [a[0], b[0]])
    for k in 1..<a.count { acc = emit(.fma, et, [a[k], b[k], acc]) }
    return acc
  }

  /// Radians (11), Degrees (12) and Length (66) to Refract (72); nil for any other instruction.
  mutating func lowerGeometricExt(_ n: Int, _ a: [ValueID], _ r: IRType, _ name: String, _ i: SPIRVInstruction)
    throws(CompileError) -> ValueID?
  {
    guard n == 11 || n == 12 || (66...72).contains(n) else { return nil }
    guard let k = r.scalarKind, k.isFloat else { throw fail(i, "GLSL.std.450 \(name) needs float operands") }
    let want = [11: 1, 12: 1, 66: 1, 67: 2, 68: 2, 69: 1, 70: 3, 71: 2, 72: 3][n]!
    guard a.count == want else { throw fail(i, "GLSL.std.450 \(name) takes \(want) operands") }
    let vt = f.type(a[0])
    let et = vt.element
    func same(_ j: Int) throws(CompileError) {
      guard f.type(a[j]) == vt else { throw fail(i, "operand \(j) has type \(f.type(a[j]).name), expected \(vt.name)") }
    }
    switch n {
    case 11, 12:
      guard vt == r else { throw fail(i, "operand 0 has type \(vt.name), expected \(r.name)") }
      return emit(.fmul, r, [a[0], fc(r, n == 11 ? Double.pi / 180 : 180 / Double.pi)])
    case 66:
      guard r == et else { throw fail(i, "GLSL.std.450 Length's result is the operand's component type") }
      if !vt.isVector { return emit(.fabs, r, [a[0]]) }
      let l = lanes(a[0])
      return emit(.fsqrt, r, [dotLanes(l, l, et)])
    case 67:
      try same(1)
      guard r == et else { throw fail(i, "GLSL.std.450 Distance's result is the operands' component type") }
      let d = emit(.fsub, vt, [a[0], a[1]])
      if !vt.isVector { return emit(.fabs, r, [d]) }
      let l = lanes(d)
      return emit(.fsqrt, r, [dotLanes(l, l, et)])
    case 68:
      try same(1)
      guard case .vector(_, 3) = vt, vt == r else { throw fail(i, "GLSL.std.450 Cross takes and gives 3-component vectors") }
      let x = lanes(a[0])
      let y = lanes(a[1])
      var c: [ValueID] = []
      for (p, q) in [(1, 2), (2, 0), (0, 1)] {
        let t = emit(.fmul, et, [x[q], y[p]])
        c.append(emit(.fma, et, [x[p], y[q], emit(.fneg, et, [t])]))
      }
      return makeVector(c)
    case 69:
      guard vt == r else { throw fail(i, "operand 0 has type \(vt.name), expected \(r.name)") }
      if !vt.isVector {
        // The sign: 1 or -1 (a zero gives a NaN, as 0 * inversesqrt(0) does).
        return emit(.fmul, r, [a[0], emit(.frsq, r, [emit(.fmul, r, [a[0], a[0]])])])
      }
      let l = lanes(a[0])
      let s = emit(.frsq, et, [dotLanes(l, l, et)])
      return emit(.fmul, r, [a[0], splatValue(s, to: r)])
    case 70:
      // N if dot(Nref, I) < 0, else -N.
      try same(1)
      try same(2)
      guard vt == r else { throw fail(i, "operand 0 has type \(vt.name), expected \(r.name)") }
      let d = dotLanes(lanes(a[2]), lanes(a[1]), et)
      let neg = emit(.fcmp, et.with(.bool), [d, fc(et, 0)], imm: FCmpPred.olt)
      let c = vt.isVector ? makeVector([ValueID](repeating: neg, count: lanes(a[0]).count)) : neg
      return emit(.select, r, [c, a[0], emit(.fneg, r, [a[0]])])
    case 71:
      // I - 2 dot(N, I) N.
      try same(1)
      guard vt == r else { throw fail(i, "operand 0 has type \(vt.name), expected \(r.name)") }
      let d = dotLanes(lanes(a[1]), lanes(a[0]), et)
      let d2 = splatValue(emit(.fmul, et, [d, fc(et, -2)]), to: r)
      return emit(.fma, r, [d2, a[1], a[0]])
    default:
      // 72: k = 1 - eta^2 (1 - dot(N, I)^2); 0 if k < 0, else eta I - (eta dot(N, I) + sqrt(k)) N.
      try same(1)
      guard vt == r, f.type(a[2]) == et else { throw fail(i, "GLSL.std.450 Refract takes I and N of one type and a scalar eta") }
      let eta = a[2]
      let d = dotLanes(lanes(a[1]), lanes(a[0]), et)
      let one = fc(et, 1)
      let dd = emit(.fsub, et, [one, emit(.fmul, et, [d, d])])
      let k = emit(.fsub, et, [one, emit(.fmul, et, [emit(.fmul, et, [eta, eta]), dd])])
      let t = emit(.fma, et, [eta, d, emit(.fsqrt, et, [k])])
      let v = emit(.fsub, r, [emit(.fmul, r, [splatValue(eta, to: r), a[0]]), emit(.fmul, r, [splatValue(t, to: r), a[1]])])
      let neg = emit(.fcmp, et.with(.bool), [k, fc(et, 0)], imm: FCmpPred.olt)
      let c = vt.isVector ? makeVector([ValueID](repeating: neg, count: lanes(a[0]).count)) : neg
      return emit(.select, r, [c, fc(r, 0), v])
    }
  }
}
