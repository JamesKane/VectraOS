// SPDX-License-Identifier: BSD-3-Clause

// Float instructions (valhall 11a, 11c conversions and special functions),
// against values computed independently in Swift.

import Testing

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

import ValhallInterp

/// Runs `ins` (sources r0, r1, r2, r3; destination r8) over any number of lanes, 16 at a time.
func runLanes(_ ins: Instr, _ a: [UInt32], _ b: [UInt32] = [0], _ c: [UInt32] = [0], _ d: [UInt32] = [0], ftz: Bool = false)
  throws -> [UInt32]
{
  var out: [UInt32] = []
  var i = 0
  while i < a.count {
    let n = min(16, a.count - i)
    func slice(_ v: [UInt32]) -> [UInt32] { (0..<16).map { v.count == 1 ? v[0] : v[min(i + $0, v.count - 1)] } }
    let o = try run([ins], inputs: [0: slice(a), 1: slice(b), 2: slice(c), 3: slice(d)], ftz: ftz)
    out += (0..<n).map { o[8, $0] }
    i += 16
  }
  return out
}

func fadd(_ t: DataType = .f32) -> Instr { I(.fadd, t, d: 8, r(0), r(1)) }
func fma(_ t: DataType = .f32) -> Instr { I(.fma, t, d: 8, r(0), r(1), r(2)) }

/// The nearest Float to the exact Double `d` under a directed rounding mode: the reference for the
/// directed modes, built from Float's own conversion (nearest even) and a correction.
func directed(_ d: Double, _ mode: Round) -> Float {
  var f = Float(d)
  if f.isNaN || f.isInfinite && !d.isInfinite {
    if mode == .up && d > 0 || mode == .down && d < 0 { return d > 0 ? .infinity : -.infinity }
    if mode == .zero || mode == .up || mode == .down { return d > 0 ? .greatestFiniteMagnitude : -.greatestFiniteMagnitude }
    return f
  }
  switch mode {
  case .up: if Double(f) < d { f = f.nextUp }
  case .down: if Double(f) > d { f = f.nextDown }
  case .zero:
    if d > 0 && Double(f) > d { f = f.nextDown }
    if d < 0 && Double(f) < d { f = f.nextUp }
  default: break
  }
  return f
}

// MARK: FADD

@Test func faddMatchesNativeNearestEven() throws {
  let c = floatCorpus(640)
  let a = c
  let b = c.indices.map { c[($0 * 7 + 3) % c.count] }
  let got = try runLanes(fadd(), a, b)
  for i in a.indices {
    #expect(sameFloat(got[i], fb(bf(a[i]) + bf(b[i]))), "\(bf(a[i])) + \(bf(b[i])) = \(bf(got[i]))")
  }
}

@Test func faddSpecialValues() throws {
  let inf = fb(.infinity)
  let cases: [(UInt32, UInt32, UInt32)] = [
    (inf, fb(-.infinity), fb(.nan)), (inf, fb(1), inf), (fb(0), fb(-0.0), fb(0)), (fb(-0.0), fb(-0.0), fb(-0.0)),
    (fb(2.5), fb(-2.5), fb(0)), (fb(.nan), fb(1), fb(.nan)),
  ]
  let got = try runLanes(fadd(), cases.map { $0.0 }, cases.map { $0.1 })
  for (i, c) in cases.enumerated() { #expect(sameFloat(got[i], c.2), "case \(i)") }
}

@Test func faddRoundDownMakesNegativeZeroFromCancellation() throws {
  let g = try runLanes(fadd().with(\.round, 2), [fb(2.5), fb(0), fb(-0.0)], [fb(-2.5), fb(-0.0), fb(-0.0)])
  #expect(g == [fb(-0.0), fb(-0.0), fb(-0.0)])
  let n = try runLanes(fadd(), [fb(2.5), fb(0)], [fb(-2.5), fb(-0.0)])
  #expect(n == [fb(0), fb(0)])
}

@Test func faddDirectedRoundingMatchesExactReference() throws {
  var g = Lcg(s: 7)
  var a: [UInt32] = []
  var b: [UInt32] = []
  for _ in 0..<512 {
    func v() -> UInt32 {
      let x = g.next()
      return (x & 0x807F_FFFF) | (UInt32(120 + Int(x >> 9 & 15)) << 23)
    }
    a.append(v())
    b.append(v())
  }
  for mode in [Round.nearestEven, .up, .down, .zero] {
    let got = try runLanes(fadd().with(\.round, mode.rawValue), a, b)
    for i in a.indices {
      let exact = Double(bf(a[i])) + Double(bf(b[i]))
      let want = exact == 0 ? Float(0) : directed(exact, mode)
      if exact != 0 { #expect(got[i] == fb(want), "\(mode) \(bf(a[i])) + \(bf(b[i]))") }
    }
  }
}

@Test func faddOverflowPerRoundingMode() throws {
  let big = fb(.greatestFiniteMagnitude)
  let nbig = fb(-.greatestFiniteMagnitude)
  let inf = fb(.infinity)
  let ninf = fb(-.infinity)
  // The sum overflows: [none, up, down, zero] for +max + +max, then for -max + -max.
  let pos = try (0..<4).map { try runLanes(fadd().with(\.round, UInt8($0)), [big], [big])[0] }
  #expect(pos == [inf, inf, big, big])
  let neg = try (0..<4).map { try runLanes(fadd().with(\.round, UInt8($0)), [nbig], [nbig])[0] }
  #expect(neg == [ninf, nbig, ninf, nbig])
}

@Test func faddWidenNegAbs() throws {
  // r0 = 1.0 (low half 0x3C00) in the low half, 2.0 in the high half; r1 = 0.5.
  let h = UInt32(0x4000) << 16 | 0x3C00
  let lo = try runLanes(fadd().with(\.widen0, 1), [h], [fb(0.5)])
  let hi = try runLanes(fadd().with(\.widen0, 2), [h], [fb(0.5)])
  #expect(lo == [fb(1.5)] && hi == [fb(2.5)])
  let na = try runLanes(fadd().with(\.neg, 3).with(\.abs, 2), [fb(3)], [fb(-4)])  // 3 + -(|-4|)... neg0, neg1, abs1
  #expect(na == [fb(-3 - 4)])
}

@Test func faddClampModes() throws {
  let a: [UInt32] = [fb(2), fb(-2), fb(0.25), fb(.nan), fb(-.infinity), fb(.infinity)]
  let z = [UInt32](repeating: 0, count: 6)
  func clamp(_ m: UInt8) throws -> [Float] { try runLanes(fadd().with(\.clamp, m), a, z).map(bf) }
  #expect(try clamp(0).prefix(3) == [2, -2, 0.25])
  #expect(try clamp(1).prefix(3) == [2, 0, 0.25] && clamp(1)[5] == .infinity && clamp(1)[4] == 0)
  #expect(try clamp(2).prefix(3) == [1, -1, 0.25])
  #expect(try clamp(3) == [1, 0, 0.25, 0, 0, 1])
  #expect(try clamp(2)[3] == -1)  // a NaN becomes the lower bound
}

@Test func faddFlushToZero() throws {
  let sub = fb(.leastNonzeroMagnitude)
  #expect(try runLanes(fadd(), [sub], [fb(0)]) == [sub])
  #expect(try runLanes(fadd(), [sub], [fb(0)], ftz: true) == [0])
  // A result that is subnormal flushes too: 1.5 x 2^-126 - 2^-126 is 2^-127.
  let a = fb(.leastNormalMagnitude * 1.5)
  let b = fb(-.leastNormalMagnitude)
  #expect(try runLanes(fadd(), [a], [b]) == [fb(.leastNormalMagnitude / 2)])
  #expect(try runLanes(fadd(), [a], [b], ftz: true) == [0])
}

@Test func faddNarrowingDestinationWritesAHalf() throws {
  // f32 1.0 + 0 into the high half of r8, whose low half keeps 0xBEEF.
  let out = try run([I(.mov, d: 8, .k(1)).w(3)] + [fadd().w(2).sources(r(0), .zero).with(\.neg, 2)], inputs: [0: [fb(1)]])
  #expect(out[8, 0] >> 16 == 0x3C00)
  #expect(out[8, 0] & 0xFFFF == 0xFFFF)
  // Rounds once from the exact value: 1 + 2^-11 (a tie in half) rounds to even, up and down differ.
  let x = fb(1 + 0x1p-11)
  func narrow(_ m: UInt8) throws -> UInt32 {
    try runLanes(fadd().w(1).sources(r(0), .zero).with(\.round, m).with(\.neg, 2), [x])[0] & 0xFFFF
  }
  #expect(try narrow(0) == 0x3C00 && narrow(1) == 0x3C01 && narrow(2) == 0x3C00 && narrow(3) == 0x3C00)
}

@Test func faddV2f16() throws {
  func pack(_ lo: UInt16, _ hi: UInt16) -> UInt32 { UInt32(lo) | UInt32(hi) << 16 }
  let one: UInt16 = 0x3C00
  let two: UInt16 = 0x4000
  let got = try runLanes(fadd(.v2f16), [pack(one, two)], [pack(two, two)])
  #expect(got == [pack(0x4200, 0x4400)])  // 3 and 4
  // Swizzle h11 on source 0 and h10 on source 1.
  let sw = try runLanes(fadd(.v2f16).with(\.widen0, 3).with(\.widen1, 1), [pack(one, two)], [pack(one, two)])
  #expect(sw == [pack(0x4400, 0x4200)])  // (2 + 2), (2 + 1)
  // 65504 + 65504 overflows to infinity; nearest tie at the largest halfs.
  #expect(try runLanes(fadd(.v2f16), [pack(0x7BFF, 0x0001)], [pack(0x7BFF, 0x0001)]) == [pack(0x7C00, 0x0002)])
  // Half-subnormals flush with ftz.
  #expect(try runLanes(fadd(.v2f16), [pack(0x0001, 0)], [pack(0, 0)], ftz: true) == [0])
}

// MARK: FMA, FMUL

@Test func fmaIsFusedAndMatchesNative() throws {
  let c = floatCorpus(480, seed: 3)
  let a = c
  let b = c.indices.map { c[($0 * 5 + 1) % c.count] }
  let d = c.indices.map { c[($0 * 11 + 7) % c.count] }
  let got = try runLanes(fma(), a, b, d)
  for i in a.indices {
    #expect(sameFloat(got[i], fb(bf(d[i]).addingProduct(bf(a[i]), bf(b[i])))), "\(bf(a[i])) * \(bf(b[i])) + \(bf(d[i]))")
  }
  // The classic: (1 + 2^-12)(1 - 2^-12) - 1 is -2^-24 fused, 0 unfused.
  let x = fb(1 + 0x1p-12)
  let y = fb(1 - 0x1p-12)
  #expect(try runLanes(fma(), [x], [y], [fb(-1)]) == [fb(-0x1p-24)])
}

@Test func fmulAliasKeepsSignedZeros() throws {
  // FMUL is FMA with a negative-zero addend, except under round_down (positive zero).
  func mul(_ a: Float, _ b: Float, mode: UInt8 = 0) throws -> UInt32 {
    let addendNeg = mode != 2
    return try runLanes(
      I(.fma, d: 8, r(0), r(1), .zero).with(\.neg, addendNeg ? 4 : 0).with(\.round, mode), [fb(a)], [fb(b)])[0]
  }
  #expect(try mul(0, 1) == fb(0) && mul(-0.0, 1) == fb(-0.0) && mul(0, -1) == fb(-0.0) && mul(-0.0, -1) == fb(0))
  #expect(try mul(0, -1, mode: 2) == fb(-0.0) && mul(-0.0, 1, mode: 2) == fb(-0.0) && mul(0, 1, mode: 2) == fb(0))
  #expect(sameFloat(try mul(0, .infinity), fb(.nan)))
}

@Test func fmaDirectedRoundingMatchesExactReference() throws {
  var g = Lcg(s: 11)
  var a: [UInt32] = []
  var b: [UInt32] = []
  var c: [UInt32] = []
  for _ in 0..<512 {
    func v(_ lo: Int, _ n: Int) -> UInt32 {
      let x = g.next()
      return (x & 0x807F_FFFF) | (UInt32(lo + Int(x >> 9 & UInt32(n))) << 23)
    }
    a.append(v(126, 1))
    b.append(v(126, 1))
    c.append(v(125, 3))
  }
  for mode in [Round.nearestEven, .up, .down, .zero] {
    let got = try runLanes(fma().with(\.round, mode.rawValue), a, b, c)
    for i in a.indices {
      let exact = Double(bf(a[i])) * Double(bf(b[i])) + Double(bf(c[i]))
      if exact != 0 { #expect(got[i] == fb(directed(exact, mode)), "\(mode) \(i)") }
    }
  }
}

@Test func fmaV2f16() throws {
  func pack(_ lo: UInt16, _ hi: UInt16) -> UInt32 { UInt32(lo) | UInt32(hi) << 16 }
  // 2 * 3 + 1 = 7 (0x4700); 0.5 * 0.5 + 0 = 0.25 (0x3400).
  let got = try runLanes(fma(.v2f16), [pack(0x4000, 0x3800)], [pack(0x4200, 0x3800)], [pack(0x3C00, 0)])
  #expect(got == [pack(0x4700, 0x3400)])
}

@Test func fmaNarrowsToHalf() throws {
  let out = try runLanes(fma().w(1), [fb(3)], [fb(0.5)], [fb(0.25)])
  // 3 * 0.5 + 0.25 = 1.75: half 0x3F00.
  #expect(out[0] & 0xFFFF == 0x3F00)
}

@Test func fmaRscale() throws {
  // (3 * 2 + 1) * 2^-1 = 3.5; (e*e)/2 style step.
  let i = I(.fmaRscale, d: 8, r(0), r(1), r(2), r(3))
  #expect(try runLanes(i, [fb(3)], [fb(2)], [fb(1)], [UInt32(bitPattern: -1)]) == [fb(3.5)])
  // `n`: zero times infinity is zero, so the sum is the addend.
  let n = i.with(\.special, 1)
  #expect(try runLanes(n, [fb(0)], [fb(.infinity)], [fb(5)], [0]) == [fb(5)])
  #expect(sameFloat(try runLanes(i, [fb(0)], [fb(.infinity)], [fb(5)], [0])[0], fb(.nan)))
  // A scaled result rounds once, subnormal results included: 1 * 2^-149 * ... = 2^-149.
  #expect(try runLanes(i, [fb(1)], [fb(1)], [fb(0)], [UInt32(bitPattern: -149)]) == [1])
}

@Test func faddLscale() throws {
  // The addend is rescaled into [0.75, 1.5): 8.0 -> 1.0, 12.0 (1.5 * 8) -> 0.75, -0.2 -> -0.8 * ... sign kept.
  let i = I(.faddLscale, d: 8, r(0), r(1))
  let got = try runLanes(i, [0, 0, 0, 0], [fb(8), fb(12), fb(-6), fb(0)]).map(bf)
  #expect(got == [1, 0.75, -0.75, 0])
}

@Test func faddImm() throws {
  let i = I(.faddImm, d: 8, r(0)).with(\.imm, fb(0.5))
  #expect(try runLanes(i, [fb(1)]) == [fb(1.5)])
  let h = I(.faddImm, .v2f16, d: 8, r(0)).with(\.imm, 0x3800_3800)
  #expect(try runLanes(h, [0x3C00_4000]) == [0x3E00_4100])
}

// MARK: Min, max, compare, select

@Test func fminFmaxNaNHandling() throws {
  let nan = fb(.nan)
  let a: [UInt32] = [fb(1), nan, fb(2), nan, fb(-0.0), fb(0)]
  let b: [UInt32] = [fb(2), fb(3), nan, nan, fb(0), fb(-0.0)]
  func go(_ op: Opcode, _ sem: UInt8) throws -> [UInt32] { try runLanes(I(op, d: 8, r(0), r(1)).with(\.sem, sem), a, b) }
  let mn = try go(.fmin, 0)
  #expect(mn[0] == fb(1) && mn[1] == fb(3) && mn[2] == fb(2) && sameFloat(mn[3], nan) && mn[4] == fb(-0.0) && mn[5] == fb(-0.0))
  let mx = try go(.fmax, 0)
  #expect(mx[0] == fb(2) && mx[1] == fb(3) && mx[2] == fb(2) && mx[4] == fb(0) && mx[5] == fb(0))
  let mp = try go(.fmin, 1)
  #expect(sameFloat(mp[1], nan) && sameFloat(mp[2], nan) && mp[0] == fb(1))
  // A clamp cancels a propagated NaN (11a §11a.2.4).
  let cl = try runLanes(I(.fmax, d: 8, r(0), r(1)).with(\.sem, 1).with(\.clamp, 3), [nan], [fb(1)])
  #expect(cl == [0])
}

@Test func fminFmaxV2f16() throws {
  func pack(_ lo: UInt16, _ hi: UInt16) -> UInt32 { UInt32(lo) | UInt32(hi) << 16 }
  let got = try runLanes(I(.fmin, .v2f16, d: 8, r(0), r(1)), [pack(0x4000, 0x3C00)], [pack(0x3C00, 0x4000)])
  #expect(got == [pack(0x3C00, 0x3C00)])
}

@Test func fcmpAllComparisons() throws {
  let nan = fb(.nan)
  let vals: [(Float, Float)] = [(1, 2), (2, 2), (3, 2), (.nan, 1), (0, -0.0), (-.infinity, .infinity)]
  let a = vals.map { fb($0.0) }
  let b = vals.map { fb($0.1) }
  func expect(_ cmp: UInt8, _ f: (Float, Float) -> Bool) throws {
    let got = try runLanes(I(.fcmp, d: 8, r(0), r(1), .zero).with(\.cmp, cmp), a, b)
    for (i, v) in vals.enumerated() { #expect(got[i] == (f(v.0, v.1) ? 1 : 0), "cmp \(cmp) case \(i)") }
  }
  try expect(0) { $0 == $1 }
  try expect(1) { $0 > $1 }
  try expect(2) { $0 >= $1 }
  try expect(3) { $0 != $1 }  // true for NaN
  try expect(4) { $0 < $1 }
  try expect(5) { $0 <= $1 }
  try expect(6) { $0 < $1 || $0 > $1 }
  _ = nan
}

@Test func fcmpTotalOrderAndResultTypes() throws {
  // total: A <= B in the IEEE total order: -NaN < -inf < ... < -0 < +0 < ... < +inf < +NaN.
  let ordered: [UInt32] = [0xFFC0_0000, 0xFF80_0000, 0xBF80_0000, 0x8000_0000, 0, 0x3F80_0000, 0x7F80_0000, 0x7FC0_0000]
  var a: [UInt32] = []
  var b: [UInt32] = []
  for i in ordered.indices {
    for j in ordered.indices {
      a.append(ordered[i])
      b.append(ordered[j])
    }
  }
  let got = try runLanes(I(.fcmp, d: 8, r(0), r(1), .zero).with(\.cmp, 7), a, b)
  for k in a.indices { #expect(got[k] == (k / 8 <= k % 8 ? 1 : 0), "k=\(k)") }
  // Result types: i1, f1, m1; and the combine input (a nonzero C makes OR true).
  let t = fb(1)
  #expect(try runLanes(I(.fcmp, d: 8, r(0), r(1), .zero).with(\.cmp, 1).with(\.resultType, 1), [fb(2)], [t]) == [fb(1)])
  #expect(try runLanes(I(.fcmp, d: 8, r(0), r(1), .zero).with(\.cmp, 1).with(\.resultType, 2), [fb(2)], [t]) == [~0])
  #expect(try runLanes(I(.fcmp, d: 8, r(0), r(1), r(2)).with(\.cmp, 1), [fb(0)], [t], [5]) == [1])
  #expect(try runLanes(I(.fcmp, d: 8, r(0), r(1), r(2)).with(\.cmp, 1).with(\.combine, 1), [fb(2)], [t], [0]) == [0])
}

@Test func fcmpV2f16() throws {
  func pack(_ lo: UInt16, _ hi: UInt16) -> UInt32 { UInt32(lo) | UInt32(hi) << 16 }
  let g = try runLanes(
    I(.fcmp, .v2f16, d: 8, r(0), r(1), .zero).with(\.cmp, 1).with(\.resultType, 2), [pack(0x4000, 0x3C00)],
    [pack(0x3C00, 0x4000)])
  #expect(g == [pack(0xFFFF, 0)])
  let f1 = try runLanes(
    I(.fcmp, .v2f16, d: 8, r(0), r(1), .zero).with(\.cmp, 1).with(\.resultType, 1), [pack(0x4000, 0x3C00)],
    [pack(0x3C00, 0x4000)])
  #expect(f1 == [pack(0x3C00, 0)])
}

@Test func cselTypes() throws {
  let f = I(.csel, .f32, d: 8, r(0), r(1), r(2), r(3)).with(\.cmp, 4)  // a < b ? t : f
  #expect(try runLanes(f, [fb(1), fb(2), fb(.nan)], [fb(2), fb(1), fb(1)], [10], [20]) == [10, 20, 20])
  // Signed and unsigned minimum with tied operands (11b §11b.4.4).
  let smin = I(.csel, .s32, d: 8, r(0), r(1), r(0), r(1)).with(\.cmp, 4)
  let umin = I(.csel, .u32, d: 8, r(0), r(1), r(0), r(1)).with(\.cmp, 4)
  #expect(try runLanes(smin, [0xFFFF_FFFF], [1]) == [0xFFFF_FFFF])
  #expect(try runLanes(umin, [0xFFFF_FFFF], [1]) == [1])
  let v2 = I(.csel, .v2s16, d: 8, r(0), r(1), r(2), r(3)).with(\.cmp, 1)
  #expect(try runLanes(v2, [0x0001_FFFF], [0x0000_0001], [0xAAAA_BBBB], [0x1111_2222]) == [0xAAAA_2222])
}

// MARK: Flush, round, scale

@Test func flushModes() throws {
  let sub = fb(.leastNonzeroMagnitude)
  let nan: UInt32 = 0x7F80_0001  // a signalling NaN
  let i = I(.flush, d: 8, r(0))
  #expect(try runLanes(i.with(\.ftz, true), [sub, 0x8000_0001, fb(1)]) == [0, 0x8000_0000, fb(1)])
  #expect(try runLanes(i.with(\.nanMode, 1), [nan]) == [0])
  #expect(try runLanes(i.with(\.nanMode, 2), [nan]) == [0x7FC0_0001])
  #expect(try runLanes(i, [nan]) == [nan])
  #expect(try runLanes(i.with(\.flushInf, true), [fb(.infinity), fb(-.infinity)]) == [fb(.greatestFiniteMagnitude), fb(-.greatestFiniteMagnitude)])
  // Independent of the shader's flush mode: a subnormal passes without ftz even when the mode flushes.
  #expect(try runLanes(i, [sub], ftz: true) == [sub])
}

@Test func froundAllModes() throws {
  let xs: [Float] = [2.5, 3.5, -2.5, 0.4, -0.25, 1.5, -1.5, .infinity, -.infinity, 8388609]
  for (mode, rule) in [
    (UInt8(0), FloatingPointRoundingRule.toNearestOrEven), (1, .up), (2, .down), (3, .towardZero),
    (4, .toNearestOrAwayFromZero),
  ] {
    let got = try runLanes(I(.fround, d: 8, r(0)).with(\.round, mode), xs.map(fb))
    for (i, x) in xs.enumerated() { #expect(got[i] == fb(x.rounded(rule)), "mode \(mode) x=\(x)") }
  }
  // A subnormal rounds as itself even when the shader flushes (11a §11a.11): its ceiling is 1.
  #expect(try runLanes(I(.fround, d: 8, r(0)).with(\.round, 1), [1], ftz: true) == [fb(1)])
  #expect(sameFloat(try runLanes(I(.fround, d: 8, r(0)), [fb(.nan)])[0], fb(.nan)))
}

@Test func ldexp() throws {
  let i = I(.ldexp, d: 8, r(0), r(1))
  let got = try runLanes(i, [fb(1.5), fb(1), fb(1), fb(-3), fb(1)], [3, UInt32(bitPattern: -149), UInt32(bitPattern: -150), UInt32(bitPattern: -1), 200])
  #expect(got == [fb(12), 1, 0, fb(-1.5), fb(.infinity)])
  // The subnormal result rounds under the mode: 1.5 * 2^-149 rounds up to 2 * 2^-149 (nearest even tie).
  #expect(try runLanes(i.with(\.round, 3), [fb(1.5)], [UInt32(bitPattern: -149)]) == [1])
  #expect(try runLanes(i.with(\.round, 1), [fb(1.5)], [UInt32(bitPattern: -149)]) == [2])
}

// MARK: Conversions

@Test func halfToSingleIsExactForEveryHalf() throws {
  let all = (0..<65536).map { UInt32($0) }
  let got = try runLanes(I(.f16ToF32, d: 8, r(0)), all)
  for h in 0..<65536 {
    let want = halfToFloat(UInt16(h))
    #expect(sameFloat(got[h], fb(want)), "half \(h)")
  }
  // The high lane, and neg and abs.
  #expect(try runLanes(I(.f16ToF32, d: 8, r(0)).with(\.widen0, 1), [0x4000_3C00]) == [fb(2)])
  #expect(try runLanes(I(.f16ToF32, d: 8, r(0)).with(\.neg, 1), [0x3C00]) == [fb(-1)])
}

@Test func singleToHalfNearestEvenMatchesReference() throws {
  // 1 + k 2^-12 for k in 0..4096 covers every tie and neighbour of halves around 1.
  let xs = (0...4096).map { fb(1 + Float($0) * 0x1p-12) }
  let got = try runLanes(fadd().w(1).sources(r(0), .zero).with(\.neg, 2), xs)
  for (k, g) in got.enumerated() {
    let units = Double(k) / 4  // distance from 1 in half ulps (2^-10)
    let n = units.rounded(.toNearestOrEven)
    #expect(g & 0xFFFF == 0x3C00 + UInt32(n), "k=\(k)")
  }
}

@Test func integerToFloatRounding() throws {
  let big: UInt32 = (1 << 24) + 1  // needs 25 bits: a tie between 2^24 and 2^24 + 2
  func cv(_ op: Opcode, _ m: UInt8, _ x: UInt32) throws -> UInt32 { try runLanes(I(op, d: 8, r(0)).with(\.round, m), [x])[0] }
  #expect(try cv(.s32ToF32, 0, big) == fb(16777216) && cv(.s32ToF32, 1, big) == fb(16777218))
  #expect(try cv(.s32ToF32, 2, big) == fb(16777216) && cv(.s32ToF32, 3, big) == fb(16777216) && cv(.s32ToF32, 4, big) == fb(16777218))
  #expect(try cv(.s32ToF32, 0, UInt32(bitPattern: -5)) == fb(-5))
  #expect(try cv(.u32ToF32, 0, 0xFFFF_FFFF) == fb(4294967296))
  // Widened: a byte of the register, signed or not.
  #expect(try runLanes(I(.s32ToF32, d: 8, r(0)).with(\.widen0, 7), [0x80FF_FFFF]) == [fb(-128)])
  #expect(try runLanes(I(.u32ToF32, d: 8, r(0)).with(\.widen0, 3), [0x1234_FFFF]) == [fb(4660)])
}

@Test func floatToIntegerSaturatesAndNaNIsZero() throws {
  let xs: [Float] = [2.5, -2.5, 1e10, -1e10, .nan, .infinity, -.infinity, 3.5, 4294967296, -0.4]
  func cv(_ op: Opcode, _ m: UInt8) throws -> [UInt32] { try runLanes(I(op, d: 8, r(0)).with(\.round, m), xs.map(fb)) }
  let s = try cv(.f32ToS32, 3)
  #expect(s == [2, UInt32(bitPattern: -2), 0x7FFF_FFFF, 0x8000_0000, 0, 0x7FFF_FFFF, 0x8000_0000, 3, 0x7FFF_FFFF, 0])
  let u = try cv(.f32ToU32, 3)
  #expect(u == [2, 0, 0xFFFF_FFFF, 0, 0, 0xFFFF_FFFF, 0, 3, 0xFFFF_FFFF, 0])
  // Rounding modes: 2.5 -> even 2, up 3, down 2, away 3; -2.5 -> -2, -2, -3, -3.
  for (m, want) in [(UInt8(0), (2, -2)), (1, (3, -2)), (2, (2, -3)), (4, (3, -3))] {
    let g = try cv(.f32ToS32, m)
    #expect(g[0] == UInt32(want.0) && g[1] == UInt32(bitPattern: Int32(want.1)), "mode \(m)")
  }
  // The half source (arch 11 and later): widen h1, then neg.
  #expect(try runLanes(I(.f32ToS32, d: 8, r(0)).with(\.widen0, 2).with(\.neg, 1).with(\.round, 3), [0x4500_0000]) == [UInt32(bitPattern: -5)])
}

@Test func integerWidening() throws {
  let x: UInt32 = 0x80F1_7FF0
  func cv(_ op: Opcode, _ lane: UInt8) throws -> UInt32 { try runLanes(I(op, d: 8, r(0)).with(\.widen0, lane), [x])[0] }
  #expect(try cv(.s8ToS32, 3) == 0xFFFF_FF80 && cv(.u8ToU32, 3) == 0x80 && cv(.s8ToS32, 1) == 0x7F)
  #expect(try cv(.s16ToS32, 1) == 0xFFFF_80F1 && cv(.u16ToU32, 1) == 0x80F1 && cv(.s16ToS32, 0) == 0x7FF0)
  // V2S8: lane 0 from byte X, lane 1 from byte Y; the field is X + 4 Y. b30 = 3; b32 = 3 + 4*2 = 11.
  #expect(try cv(.v2s8ToV2s16, 3) == 0xFFF0_FF80 && cv(.v2u8ToV2u16, 3) == 0x00F0_0080)
  #expect(try cv(.v2s8ToV2s16, 11) == 0xFFF1_FF80)
}

// MARK: Special functions

func ulps(_ a: UInt32, _ b: UInt32) -> Int {
  if bf(a).isNaN && bf(b).isNaN { return 0 }
  func key(_ v: UInt32) -> Int { v & 0x8000_0000 != 0 ? -Int(v & 0x7FFF_FFFF) : Int(v) }
  return abs(key(a) - key(b))
}

@Test func reciprocalAndReciprocalSquareRoot() throws {
  let xs = floatCorpus(300, seed: 5)
  let rc = try runLanes(I(.frcp, .f32, d: 8, r(0)), xs)
  let rs = try runLanes(I(.frsq, .f32, d: 8, r(0)), xs)
  for (i, x) in xs.enumerated() {
    let f = bf(x)
    let sub = f != 0 && abs(f) < Float.leastNormalMagnitude
    if sub { #expect(rc[i] == fb(f.sign == .minus ? -.infinity : .infinity)); continue }  // flushed input
    if !f.isNaN {
      let want = Float(1 / Double(f))
      let flushedWant = abs(want) < Float.leastNormalMagnitude && want != 0 ? Float(sign: want.sign, exponent: 0, significand: 0) : want
      #expect(ulps(rc[i], fb(flushedWant)) <= Tolerance.frcpUlps, "rcp \(f)")
      let wantS: Float = f < 0 ? .nan : Float(1 / Double(f).squareRoot())
      #expect(ulps(rs[i], fb(wantS)) <= Tolerance.frsqUlps, "rsq \(f)")
    }
  }
  #expect(try runLanes(I(.frcp, .f32, d: 8, r(0)), [fb(0), fb(-0.0), fb(.infinity), fb(-.infinity)]) == [fb(.infinity), fb(-.infinity), 0, fb(-0.0)])
  #expect(sameFloat(try runLanes(I(.frsq, .f32, d: 8, r(0)), [fb(-4)])[0], fb(.nan)))
  #expect(try runLanes(I(.frsq, .f32, d: 8, r(0)), [fb(4)]) == [fb(0.5)])
}

@Test func halfReciprocalDoesNotFlushAndReplicates() throws {
  // 1 / 0x0400 (2^-14, the smallest normal half) = 2^14; subnormal 0x0001 -> 2^24 = infinity in half.
  let i = I(.frcp, .f16, d: 8, r(0))
  #expect(try runLanes(i, [0x0400]) == [0x7400_7400])
  #expect(try runLanes(i, [0x0001]) == [0x7C00_7C00])
  #expect(try runLanes(i.w(1), [0x4000]) == [0x3800])  // 1/2 in the low half; the high half is r8's old zero
}

@Test func frexpAndLdexpRoundTrip() throws {
  let xs: [Float] = [1, 0.75, 3, -5.5, 1e-3, 123456.0, 0x1p-130, -0x1p-140]
  for mode in [UInt8(0), 1, 2] {
    let m = try runLanes(I(.frexpm, d: 8, r(0)).with(\.special, mode), xs.map(fb)).map(bf)
    let e = try runLanes(I(.frexpe, d: 8, r(0)).with(\.special, mode), xs.map(fb))
    for (i, x) in xs.enumerated() {
      let mag = abs(m[i])
      switch mode {
      case 0: #expect(mag >= 0.5 && mag < 1)
      case 1: #expect(mag >= 0.25 && mag < 1)
      default: #expect(mag >= 0.75 && mag < 1.5)
      }
      let scale = mode == 1 ? 2.0 * Double(Int32(bitPattern: e[i])) : Double(Int32(bitPattern: e[i]))
      #expect(Double(m[i]) * exp2(scale) == Double(x), "mode \(mode) x=\(x)")
      #expect(m[i].sign == x.sign)
    }
  }
  // Exponent of zero, infinity, NaN is 0; the fraction is the source.
  let sp = [fb(0), fb(.infinity), fb(.nan)]
  #expect(try runLanes(I(.frexpe, d: 8, r(0)), sp) == [0, 0, 0])
  #expect(try runLanes(I(.frexpm, d: 8, r(0)), [fb(.infinity)]) == [fb(.infinity)])
  #expect(try runLanes(I(.frexpe, d: 8, r(0)).with(\.negResult, true), [fb(8)]) == [UInt32(bitPattern: -4)])
}

@Test func logarithmAndExponentialPieces() throws {
  // FLOGD(x) = log2(a) / (a - 1) with a the log-mode fraction; exp2 of a fixed-point 8.24 exponent.
  let xs: [Float] = [3, 10, 0.3, 1.2]
  let d = try runLanes(I(.flogd, d: 8, r(0)), xs.map(fb)).map(bf)
  for (i, x) in xs.enumerated() {
    var a = Double(x)
    while a >= 1.5 { a /= 2 }
    while a < 0.75 { a *= 2 }
    let want = Float(log2(a) / (a - 1))
    #expect(ulps(fb(d[i]), fb(want)) <= Tolerance.sequenceUlps, "flogd \(x)")
  }
  let fixed = [Float(2.5), -3.25, 0, 7.99].map { UInt32(bitPattern: Int32(($0 * 16777216).rounded())) }
  let e = try runLanes(I(.fexp, .f32, d: 8, r(0), r(1)), fixed, [fb(1)]).map(bf)
  #expect(e[0] == Float(exp2(2.5)) && e[1] == Float(exp2(-3.25)) && e[2] == 1)
  #expect(sameFloat(try runLanes(I(.fexp, .f32, d: 8, r(0), r(1)), [0], [fb(.nan)])[0], fb(.nan)))
  // f16: log2(8) = 3, 2^3 = 8, pow.
  #expect(try runLanes(I(.flog, .f16, d: 8, r(0)).w(1), [0x4800]) == [0x4200])
  #expect(try runLanes(I(.fexp, .f16, d: 8, nil, r(1)).w(1), [0], [0x4200]) == [0x4800])
  #expect(try runLanes(I(.fpow, .f16, d: 8, r(0), r(1)).w(1), [0x4000], [0x4200]) == [0x4800])
}

@Test func sineCosineTables() throws {
  func idx(_ i: Int) -> UInt32 { (146 << 23) | UInt32(i) }  // exponent 2^19, low bits the index
  let all = (0..<64).map(idx)
  let s = try runLanes(I(.fsinTable, d: 8, r(0)), all).map(bf)
  let c = try runLanes(I(.fcosTable, d: 8, r(0)), all).map(bf)
  for i in 0..<64 {
    let a = Double(i) * Double.pi / 32
    if ![0, 32].contains(i) { #expect(s[i] == Float(sin(a)), "sin \(i)") }
    if ![16, 48].contains(i) { #expect(c[i] == Float(cos(a)), "cos \(i)") }
  }
  // The four signed zeros.
  #expect(s[0].sign == .minus && s[0] == 0 && s[32].sign == .plus && s[32] == 0)
  #expect(c[16].sign == .plus && c[16] == 0 && c[48].sign == .minus && c[48] == 0)
  // Any other exponent, or a negative sign, gives -0; a NaN stays; infinity gives NaN.
  let o = try runLanes(I(.fsinTable, d: 8, r(0)), [fb(1), idx(5) | 0x8000_0000, fb(.nan), fb(.infinity)])
  #expect(o[0] == 0x8000_0000 && o[1] == 0x8000_0000 && bf(o[2]).isNaN && bf(o[3]).isNaN)
}
