// SPDX-License-Identifier: BSD-3-Clause

// <math.h> (M6c) against the host's glibc. The exact functions (one right
// answer) bit for bit: rounding to integers, fmod and remainder, fma, and
// the small ones, on random bit patterns and edge values (halves, values
// near 2^52, subnormals, infinities); fma also on near-total cancellation
// (z ≈ -x·y) and subnormal results.

import Foundation
import Glibc
@testable import LibC
import Testing

let mathCases = Int(ProcessInfo.processInfo.environment["TODHCHAI_MATH_CASES"] ?? "") ?? 100_000

func randomDouble(_ r: inout Random) -> Double {
  switch r.below(5) {
  case 0:
    let edges: [Double] = [0, -0.0, 0.5, -0.5, 1.5, 2.5, -2.5, 0.49999999999999994, 4503599627370495.5,
                           4503599627370496, 9007199254740991, 1e300, -1e-300, 4.9e-324, 2.2250738585072014e-308,
                           .infinity, -.infinity, .nan, 1, -1, 3, 0.1]
    return edges[r.below(edges.count)]
  case 1: return Double(r.below(2_000_001) - 1_000_000) / Double([1, 2, 4, 8, 10, 1024][r.below(6)])
  default:
    return Double(bitPattern: UInt64(r.below(Int(Int32.max))) << 33 ^ UInt64(r.below(Int(Int32.max))) ^
                  (r.below(2) == 0 ? 0 : 1 << 63))
  }
}

func same(_ a: Double, _ b: Double) -> Bool { (a.isNaN && b.isNaN) || a.bitPattern == b.bitPattern }
func same(_ a: Float, _ b: Float) -> Bool { (a.isNaN && b.isNaN) || a.bitPattern == b.bitPattern }

@Test func roundingToIntegersMatchesGlibc() {
  var r = Random(state: 101)
  var failures: [String] = []
  for _ in 0..<mathCases {
    let x = randomDouble(&r), f = Float(x)
    let pairs: [(String, Double, Double)] = [
      ("floor", Glibc.floor(x), LibC.floor(x)), ("ceil", Glibc.ceil(x), LibC.ceil(x)),
      ("trunc", Glibc.trunc(x), LibC.trunc(x)), ("round", Glibc.round(x), LibC.round(x)),
      ("rint", Glibc.rint(x), LibC.rint(x)), ("nearbyint", Glibc.nearbyint(x), LibC.nearbyint(x)),
      ("fabs", Glibc.fabs(x), LibC.fabs(x)), ("sqrt", Glibc.sqrt(x), LibC.sqrt(x)),
    ]
    for (name, g, o) in pairs where !same(g, o) { failures.append("\(name)(\(x)): glibc \(g), ours \(o)") }
    let fpairs: [(String, Float, Float)] = [
      ("floorf", Glibc.floorf(f), LibC.floorf(f)), ("ceilf", Glibc.ceilf(f), LibC.ceilf(f)),
      ("truncf", Glibc.truncf(f), LibC.truncf(f)), ("roundf", Glibc.roundf(f), LibC.roundf(f)),
      ("rintf", Glibc.rintf(f), LibC.rintf(f)),
    ]
    for (name, g, o) in fpairs where !same(g, o) { failures.append("\(name)(\(f)): glibc \(g), ours \(o)") }
    var ge: Int32 = 0, oe: Int32 = 0
    let gm = Glibc.frexp(x, &ge), om = LibC.frexp(x, &oe)
    if !same(gm, om) || (x.isFinite && ge != oe) { failures.append("frexp(\(x)): glibc \(gm) \(ge), ours \(om) \(oe)") }
    let n = Int32(r.below(4200)) - 2100
    if !same(Glibc.ldexp(x, n), LibC.ldexp(x, n)) {
      failures.append("ldexp(\(x), \(n)): glibc \(Glibc.ldexp(x, n)), ours \(LibC.ldexp(x, n))")
    }
    var gi = 0.0, oi = 0.0
    let gf = Glibc.modf(x, &gi), of = LibC.modf(x, &oi)
    if !same(gf, of) || !same(gi, oi) { failures.append("modf(\(x)): glibc \(gf) \(gi), ours \(of) \(oi)") }
    if failures.count > 20 { break }
  }
  #expect(failures.isEmpty, "\(failures.prefix(20).joined(separator: "\n"))")
}

@Test func fmodAndRemainderMatchGlibc() {
  var r = Random(state: 102)
  var failures: [String] = []
  for _ in 0..<mathCases {
    let x = randomDouble(&r)
    var y = randomDouble(&r)
    if r.below(3) == 0 { y = x / Double(1 + r.below(9)) * (r.below(2) == 0 ? 1 : -1) }  // near multiples
    if !same(Glibc.fmod(x, y), LibC.fmod(x, y)) {
      failures.append("fmod(\(x), \(y)): glibc \(Glibc.fmod(x, y)), ours \(LibC.fmod(x, y))")
    }
    if !same(Glibc.remainder(x, y), LibC.remainder(x, y)) {
      failures.append("remainder(\(x), \(y)): glibc \(Glibc.remainder(x, y)), ours \(LibC.remainder(x, y))")
    }
    let fx = Float(x), fy = Float(y)
    if !same(Glibc.fmodf(fx, fy), LibC.fmodf(fx, fy)) { failures.append("fmodf(\(fx), \(fy))") }
    if !same(Glibc.remainderf(fx, fy), LibC.remainderf(fx, fy)) { failures.append("remainderf(\(fx), \(fy))") }
    if failures.count > 20 { break }
  }
  #expect(failures.isEmpty, "\(failures.prefix(20).joined(separator: "\n"))")
}

@Test func fmaMatchesGlibc() {
  var r = Random(state: 103)
  var failures: [String] = []
  for _ in 0..<mathCases {
    let x = randomDouble(&r), y = randomDouble(&r)
    var z = randomDouble(&r)
    switch r.below(4) {
    case 0: z = -(x * y)  // near-total cancellation
    case 1: z = -(x * y) * (1 + Double(r.below(100)) * 0x1p-52)
    default: break
    }
    if !same(Glibc.fma(x, y, z), LibC.fma(x, y, z)) {
      failures.append("fma(\(x), \(y), \(z)): glibc \(Glibc.fma(x, y, z)), ours \(LibC.fma(x, y, z))")
    }
    let fx = Float(x), fy = Float(y), fz = r.below(3) == 0 ? -(Float(x) * Float(y)) : Float(z)
    if !same(Glibc.fmaf(fx, fy, fz), LibC.fmaf(fx, fy, fz)) {
      failures.append("fmaf(\(fx), \(fy), \(fz)): glibc \(Glibc.fmaf(fx, fy, fz)), ours \(LibC.fmaf(fx, fy, fz))")
    }
    if failures.count > 20 { break }
  }
  #expect(failures.isEmpty, "\(failures.prefix(20).joined(separator: "\n"))")
}

/// How many units in the last place `ours` is from `theirs` (both finite).
func ulps(_ ours: Double, _ theirs: Double) -> Double {
  if ours == theirs || (ours.isNaN && theirs.isNaN) { return 0 }
  if !ours.isFinite || !theirs.isFinite { return .infinity }
  return abs(ours - theirs) / theirs.ulp
}

/// Arguments for a function: random bits in its domain, and edges.
/// kind 0 exp, 1 log, 2 trig and atan, 3 asin and acos (within ±1).
func transcendentalArgument(_ r: inout Random, _ kind: Int) -> Double {
  if kind == 3 {
    let sign: Double = r.below(2) == 0 ? 1 : -1
    let u = Double(r.next() >> 11) * 0x1p-53
    switch r.below(3) {
    case 0: return sign * u
    case 1: return sign * (1 - u * [1e-3, 1e-8, 1e-15][r.below(3)])  // near ±1
    default: return sign * u * [1e-3, 1e-8, 1e-20][r.below(3)]
    }
  }
  switch r.below(4) {
  case 0: return randomDouble(&r)
  case 1:
    // Ordinary magnitudes, where most calls are.
    return (Double(r.below(2_000_000)) / 1_000_000 - 1) * [1.0, 10, 100, 700, 0.001, 1e-8][r.below(6)]
  case 2:
    // Near the reduction's boundaries: multiples of ln 2 or π/2, and 1 for logs.
    let base = kind == 0 ? 0.6931471805599453 : kind == 1 ? 1.0 : 1.5707963267948966
    return base * Double(r.below(40) - 20) + Double(r.below(2000) - 1000) * 1e-12
  default:
    return Double(bitPattern: UInt64(r.below(Int(Int32.max))) << 33 ^ UInt64(r.below(Int(Int32.max))))
  }
}

/// Ours (and glibc's) against the truth: glibc's 80-bit functions, accurate
/// to about 2^-11 of a double's ulp. glibc's double functions aren't all
/// correctly rounded (log10 is up to 2 ulps off), so they're the comparison,
/// not the reference.
@Test func transcendentalsAreWithinAnUlp() {
  var r = Random(state: 104)
  // name, ours, glibc's, the truth, the argument's kind
  let functions: [(String, (Double) -> Double, (Double) -> Double, (Float80) -> Float80, Int)] = [
    ("exp", LibC.exp, Glibc.exp, expl, 0), ("exp2", LibC.exp2, Glibc.exp2, exp2l, 0),
    ("log", LibC.log, Glibc.log, logl, 1), ("log2", LibC.log2, Glibc.log2, log2l, 1),
    ("log10", LibC.log10, Glibc.log10, log10l, 1), ("sin", LibC.sin, Glibc.sin, sinl, 2),
    ("cos", LibC.cos, Glibc.cos, cosl, 2), ("tan", LibC.tan, Glibc.tan, tanl, 2),
    ("atan", LibC.atan, Glibc.atan, atanl, 2), ("asin", LibC.asin, Glibc.asin, asinl, 3),
    ("acos", LibC.acos, Glibc.acos, acosl, 3),
  ]
  var report: [String] = []
  var failed = false
  for (name, ours, theirs, truth, kind) in functions {
    var worst = 0.0, worstAt = 0.0, glibcWorst = 0.0
    for _ in 0..<mathCases {
      let x = transcendentalArgument(&r, kind)
      let t = truth(Float80(x))
      let rounded = Double(t)
      guard rounded.isFinite, rounded != 0, abs(rounded) >= 2.2250738585072014e-308 else { continue }
      // Large arguments of sin, cos and tan: the 80-bit reduction is exact, as ours is.
      let ulp = Float80(rounded.ulp)
      let o = Double(abs(Float80(ours(x)) - t) / ulp), g = Double(abs(Float80(theirs(x)) - t) / ulp)
      if o > worst {
        worst = o
        worstAt = x
      }
      glibcWorst = max(glibcWorst, g)
    }
    report.append("\(name): worst \(worst) ulp at \(worstAt) (glibc's worst \(glibcWorst))")
    if worst >= 1 { failed = true }
  }
  print(report.joined(separator: "\n"))
  #expect(!failed, "\(report.joined(separator: "\n"))")
}

/// The float versions: ours rounded from the double. Where they differ
/// from glibc's, ours must be the nearer to the truth (glibc's 80-bit
/// functions): glibc's sinf and cosf aren't always correctly rounded.
@Test func floatTranscendentalsAreNoWorseThanGlibcs() {
  var r = Random(state: 105)
  let functions: [(String, (Float) -> Float, (Float) -> Float, (Float80) -> Float80, Int)] = [
    ("expf", LibC.expf, Glibc.expf, expl, 0), ("exp2f", LibC.exp2f, Glibc.exp2f, exp2l, 0),
    ("logf", LibC.logf, Glibc.logf, logl, 1), ("log2f", LibC.log2f, Glibc.log2f, log2l, 1),
    ("log10f", LibC.log10f, Glibc.log10f, log10l, 1), ("sinf", LibC.sinf, Glibc.sinf, sinl, 2),
    ("cosf", LibC.cosf, Glibc.cosf, cosl, 2), ("tanf", LibC.tanf, Glibc.tanf, tanl, 2),
    ("atanf", LibC.atanf, Glibc.atanf, atanl, 2), ("asinf", LibC.asinf, Glibc.asinf, asinl, 3),
    ("acosf", LibC.acosf, Glibc.acosf, acosl, 3),
  ]
  var failures: [String] = []
  for (name, ours, theirs, truth, kind) in functions {
    var oursNearer = 0
    for _ in 0..<mathCases {
      let x = Float(transcendentalArgument(&r, kind))
      let o = ours(x), g = theirs(x)
      if o == g || (o.isNaN && g.isNaN) { continue }
      let t = truth(Float80(x))
      let oe = abs(Float80(o) - t), ge = abs(Float80(g) - t)
      if oe <= ge { oursNearer += 1 } else { failures.append("\(name)(\(x)) = \(t): glibc \(g), ours \(o)") }
    }
    print("\(name): differs from glibc \(oursNearer) times, ours the nearer each time")
  }
  #expect(failures.isEmpty, "\(failures.prefix(20).joined(separator: "\n"))")
}

/// atan2's and pow's arguments: (y, x) for atan2, (x, y) for pow. pow's
/// keep y·ln x within exp's range most of the time, and take negative
/// bases with integer powers and bases near 1 with large ones.
func twoArguments(_ r: inout Random, pow: Bool) -> (Double, Double) {
  func unit(_ r: inout Random) -> Double { Double(r.next() >> 11) * 0x1p-53 }
  if !pow {
    var y = transcendentalArgument(&r, 2), x = transcendentalArgument(&r, 2)
    if r.below(4) == 0 { x = y * (1 + Double(r.below(100) - 50) * 1e-3) * (r.below(2) == 0 ? 1 : -1) }
    if r.below(8) == 0 {  // both tiny or both huge: the quotient's scaling
      y = abs(randomDouble(&r)) * 0x1p-900
      x = -abs(randomDouble(&r)) * 0x1p-1000
    }
    return (y, x)
  }
  func range(_ x: Double) -> Double { 700 / max(abs(Glibc.log(abs(x))), 1e-300) }
  switch r.below(5) {
  case 0:
    let x = Double(bitPattern: UInt64(r.below(Int(Int32.max))) << 33 ^ UInt64(r.below(Int(Int32.max))))
    return (x, (unit(&r) * 2 - 1) * range(x))
  case 1: return (unit(&r) * [2.0, 10, 1000, 1e-5][r.below(4)], (unit(&r) * 2 - 1) * [1.0, 10, 100, 0.01][r.below(4)])
  case 2:
    let x = 1 + (unit(&r) * 2 - 1) * [1e-3, 1e-10, 1e-15][r.below(3)]
    return (x, (unit(&r) * 2 - 1) * range(x))
  case 3: return (-(unit(&r) * 20), Double(r.below(60) - 30))
  default: return (unit(&r) * 4, Double(r.below(200) - 100) * 0.5)
  }
}

/// atan2 and pow against the truth (glibc's 80-bit functions), within an
/// ulp, and their float versions no worse than glibc's.
@Test func atan2AndPowAreWithinAnUlp() {
  var r = Random(state: 106)
  let functions: [(String, (Double, Double) -> Double, (Double, Double) -> Double, (Float80, Float80) -> Float80,
                   (Float, Float) -> Float, (Float, Float) -> Float, Bool)] = [
    ("atan2", LibC.atan2, Glibc.atan2, atan2l, LibC.atan2f, Glibc.atan2f, false),
    ("pow", LibC.pow, Glibc.pow, powl, LibC.powf, Glibc.powf, true),
  ]
  var report: [String] = []
  var failures: [String] = []
  for (name, ours, theirs, truth, oursF, theirsF, isPow) in functions {
    var worst = 0.0, worstAt = (0.0, 0.0), glibcWorst = 0.0
    for _ in 0..<mathCases {
      let (a, b) = twoArguments(&r, pow: isPow)
      let fa = Float(a), fb = Float(b)
      let fo = oursF(fa, fb), fg = theirsF(fa, fb)
      if !same(fo, fg) {
        let ft = truth(Float80(fa), Float80(fb))
        if !(abs(Float80(fo) - ft) <= abs(Float80(fg) - ft)) {
          failures.append("\(name)f(\(fa), \(fb)) = \(ft): glibc \(fg), ours \(fo)")
        }
      }
      let t = truth(Float80(a), Float80(b))
      let rounded = Double(t)
      guard rounded.isFinite, rounded != 0, abs(rounded) >= 2.2250738585072014e-308 else { continue }
      let ulp = Float80(rounded.ulp)
      let o = Double(abs(Float80(ours(a, b)) - t) / ulp), g = Double(abs(Float80(theirs(a, b)) - t) / ulp)
      if !(o <= worst) {
        worst = o
        worstAt = (a, b)
      }
      glibcWorst = max(glibcWorst, g)
    }
    report.append("\(name): worst \(worst) ulp at \(worstAt) (glibc's worst \(glibcWorst))")
    if !(worst < 1) { failures.append("\(name): worst \(worst) ulp at \(worstAt)") }
  }
  print(report.joined(separator: "\n"))
  #expect(failures.isEmpty, "\(failures.prefix(20).joined(separator: "\n"))")
}

/// C23 Annex F's special cases (F.10.1, F.10.4.4) on a grid of zeros,
/// infinities, NaN, ±1, odd and even integers and the extremes: where
/// either answer is a zero, an infinity or a NaN, ours is glibc's bit for
/// bit; elsewhere within an ulp of it.
@Test func specialCasesFollowAnnexF() {
  let values: [Double] = [0, -0.0, 1, -1, 0.5, -0.5, 2, -2, 3, -3, 1.5, -1.5, .infinity, -.infinity, .nan,
                          9007199254740991, -9007199254740991, 9007199254740992, -9007199254740992, 1e308, -1e308,
                          4.9e-324, -4.9e-324, 2.2250738585072014e-308, 0.9999999999999999, 1.0000000000000002,
                          -0.9999999999999999, 1e-300, 1024, -1075, 0.1, 7, -7]
  func agrees(_ o: Double, _ g: Double) -> Bool {
    if same(o, g) { return true }
    if !o.isFinite || !g.isFinite || o == 0 || g == 0 || o.sign != g.sign { return false }
    return abs(o - g) <= g.ulp
  }
  func agrees(_ o: Float, _ g: Float) -> Bool {
    if same(o, g) { return true }
    if !o.isFinite || !g.isFinite || o == 0 || g == 0 || o.sign != g.sign { return false }
    return abs(o - g) <= g.ulp
  }
  var failures: [String] = []
  for x in values {
    let one: [(String, Double, Double)] = [
      ("tan", LibC.tan(x), Glibc.tan(x)), ("atan", LibC.atan(x), Glibc.atan(x)),
      ("asin", LibC.asin(x), Glibc.asin(x)), ("acos", LibC.acos(x), Glibc.acos(x)),
    ]
    for (name, o, g) in one where !agrees(o, g) { failures.append("\(name)(\(x)): glibc \(g), ours \(o)") }
    for y in values {
      let a = LibC.atan2(y, x), ag = Glibc.atan2(y, x)
      if !agrees(a, ag) { failures.append("atan2(\(y), \(x)): glibc \(ag), ours \(a)") }
      let p = LibC.pow(x, y), pg = Glibc.pow(x, y)
      if !agrees(p, pg) { failures.append("pow(\(x), \(y)): glibc \(pg), ours \(p)") }
      let fx = Float(x), fy = Float(y)
      let af = LibC.atan2f(fy, fx), afg = Glibc.atan2f(fy, fx)
      if !agrees(af, afg) { failures.append("atan2f(\(fy), \(fx)): glibc \(afg), ours \(af)") }
      let pf = LibC.powf(fx, fy), pfg = Glibc.powf(fx, fy)
      if !agrees(pf, pfg) { failures.append("powf(\(fx), \(fy)): glibc \(pfg), ours \(pf)") }
    }
  }
  #expect(failures.isEmpty, "\(failures.prefix(20).joined(separator: "\n"))")
}
