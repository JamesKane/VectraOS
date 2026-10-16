// SPDX-License-Identifier: BSD-3-Clause

// Long double (M6d) against the host's glibc, in both of its formats: x87's
// 80-bit extended format (amd64's long double; glibc's strtold and
// printf's %L on Float80) and IEEE's binary128 (arm64's and rv64's; glibc's
// strtof128 and strfromf128, through TDFloat128). strtold's results are
// compared bit for bit with where the subject sequence ended and errno, on halfway
// points between adjacent values written out exactly and nudged, random
// digit strings, more than 11600 digits, extremes, hex and inf and nan.
// printf's %Le %Lf %Lg %La are compared byte for byte (but for glibc's
// %#g carried into the next power of ten, FormatTests.swift).

import Foundation
import Glibc
@testable import LibC
import TDFloat128
import Testing

/// TODHCHAI_STRTOLD_CASES=N runs more (each format, each test).
let longDoubleCases = Int(ProcessInfo.processInfo.environment["TODHCHAI_STRTOLD_CASES"] ?? "") ?? 3_000

/// A long double format under test: its shape, and glibc's conversions.
struct LongDoubleFormat {
  let name: String
  let format: BinaryFormat

  static let x87 = LongDoubleFormat(name: "x87", format: LibC.x87Format)
  static let binary128 = LongDoubleFormat(name: "binary128", format: LibC.binary128Format)

  var p: Int { format.mantissaBits }
  var minExponent: Int { format.minExponent }

  /// glibc's conversion of `s`: the bits and the end's offset.
  func glibcParse(_ s: UnsafePointer<CChar>) -> (UInt128, Int) {
    var end: UnsafeMutablePointer<CChar>?
    if format.explicitLeadingBit {
      let v = Glibc.strtold(s, &end)
      return (x87Bits(v), end! - UnsafeMutablePointer(mutating: s))
    }
    var bytes = [UInt8](repeating: 0, count: 16)
    td_strtof128(s, &end, &bytes)
    return (bytesToBits(bytes), end! - UnsafeMutablePointer(mutating: s))
  }

  /// The value m × 2^e (m below 2^p, e at least the smallest subnormal's)
  /// in this format's encoding, exactly (no rounding: the tests' own).
  func encode(_ m: UInt128, _ e: Int) -> UInt128 {
    let lsbMin = minExponent - (p - 1)
    var m = m, e = e
    while m != 0 && m >> UInt128(p - 1) == 0 && e > lsbMin {
      m <<= 1
      e -= 1
    }
    if m >> UInt128(p - 1) == 0 { return m }  // subnormal
    let field = UInt128(e + p - 1 + format.maxExponent)
    return field << UInt128(format.exponentShift) | (format.explicitLeadingBit ? m : m & ((UInt128(1) << UInt128(p - 1)) - 1))
  }

  /// The exact decimal of m × 2^e (representable in binary128, which holds
  /// every x87 value), as d.ddd…e±x, from glibc.
  func exactDecimal(_ m: UInt128, _ e: Int) -> String {
    let bits = LongDoubleFormat.binary128.encode(m, e)
    var buffer = [CChar](repeating: 0, count: 12_200)
    let bytes = bitsToBytes(bits)
    _ = td_strfromf128(&buffer, buffer.count, "%.12000e", bytes)
    return String(cString: buffer)
  }

  func isNaN(_ bits: UInt128) -> Bool {
    let field = Int(bits >> UInt128(format.exponentShift)) & 0x7FFF
    let low = bits & ((UInt128(1) << UInt128(format.exponentShift)) - 1)
    return field == 0x7FFF && (format.explicitLeadingBit ? low << 65 != 0 : low != 0)
  }
  func signOf(_ bits: UInt128) -> Bool { bits & format.signBit != 0 }
}

func x87Bits(_ v: Float80) -> UInt128 {
  withUnsafeBytes(of: v) { UInt128($0.load(as: UInt64.self)) | UInt128($0.load(fromByteOffset: 8, as: UInt16.self)) << 64 }
}
func bytesToBits(_ b: [UInt8]) -> UInt128 { b.reversed().reduce(UInt128(0)) { $0 << 8 | UInt128($1) } }
func bitsToBytes(_ v: UInt128) -> [UInt8] { (0..<16).map { UInt8(truncatingIfNeeded: v >> UInt128(8 * $0)) } }

/// An exact decimal (d.ddd…e±x) as its digits and the exponent of its last.
func decimalParts(_ s: String) -> ([UInt8], Int) {
  let parts = s.split(separator: "e")
  var digits = parts[0].compactMap { $0.wholeNumberValue.map(UInt8.init) }
  let exponent = Int(parts[1])! - (digits.count - 1)
  while digits.count > 1 && digits.first == 0 { digits.removeFirst() }
  return (digits, exponent)
}

/// a + b, both exact decimals, as an exact decimal.
func addDecimal(_ a: String, _ b: String) -> String {
  var (x, ex) = decimalParts(a), (y, ey) = decimalParts(b)
  let low = min(ex, ey)
  x += [UInt8](repeating: 0, count: ex - low)
  y += [UInt8](repeating: 0, count: ey - low)
  let n = max(x.count, y.count) + 1
  x = [UInt8](repeating: 0, count: n - x.count) + x
  y = [UInt8](repeating: 0, count: n - y.count) + y
  var sum = [UInt8](repeating: 0, count: n), carry: UInt8 = 0
  for i in stride(from: n - 1, through: 0, by: -1) {
    let d = x[i] + y[i] + carry
    sum[i] = d % 10
    carry = d / 10
  }
  while sum.count > 1 && sum.first == 0 { sum.removeFirst() }
  let exponent = low + sum.count - 1
  return "\(sum[0])." + sum.dropFirst().map(String.init).joined() + "e\(exponent)"
}

/// half of an exact decimal.
func halveDecimal(_ a: String) -> String {
  var (x, e) = decimalParts(a)
  x.append(0)
  e -= 1
  var out: [UInt8] = [], rem: UInt8 = 0
  for d in x {
    let v = rem * 10 + d
    out.append(v / 2)
    rem = v % 2
  }
  while out.count > 1 && out.first == 0 { out.removeFirst() }
  return "\(out[0])." + out.dropFirst().map(String.init).joined() + "e\(e + out.count - 1)"
}

/// A string worth converting to a long double of `f`'s format.
func longDoubleLike(_ r: inout Random, _ f: LongDoubleFormat) -> String {
  let p = f.p
  switch r.below(8) {
  case 0, 1:
    // A halfway point between two adjacent values, exactly (a and half an
    // ulp, added), maybe nudged in its last digits.
    let subnormal = r.below(6) == 0
    var m = (UInt128(r.next()) << 64 | UInt128(r.next())) & ((UInt128(1) << UInt128(p)) - 1)
    m = subnormal ? m >> 1 : m | UInt128(1) << UInt128(p - 1)
    let lsbMin = f.minExponent - (p - 1)
    let e = subnormal ? lsbMin : lsbMin + r.below(2 * f.format.maxExponent - 1)
    let midpoint = addDecimal(f.exactDecimal(m, e), halveDecimal(f.exactDecimal(1, e)))
    switch r.below(3) {
    case 0: return midpoint
    case 1:
      let ePos = midpoint.firstIndex(of: "e")!
      return String(midpoint[..<ePos]) + "0000001" + String(midpoint[ePos...])  // just above
    default:
      // Just below: the last nonzero digit lowered by one.
      var digits = Array(midpoint)
      let ePos = digits.firstIndex(of: "e")!
      var k = ePos - 1
      while k > 0 && digits[k] == "0" { k -= 1 }
      if let d = digits[k].wholeNumberValue, d > 0 { digits[k] = Character(String(d - 1)) }
      return String(digits[..<ePos]) + "9999" + String(digits[ePos...])
    }
  case 2:
    var s = r.below(2) == 0 ? "-" : ""
    for _ in 0..<(1 + r.below(45)) { s += String(r.below(10)) }
    if r.below(2) == 0 { s += "." + (0..<r.below(45)).map { _ in String(r.below(10)) }.joined() }
    if r.below(2) == 0 { s += "e" + (r.below(2) == 0 ? "-" : "") + String(r.below(5000)) }
    return s
  case 3:
    let edges = ["1.18973149535723176502e4932", "1.18973149535723176505e4932", "1.1897314953572317650857593266280070e4932",
                 "1.18973149535723176508575932662800702e4932", "1.18973149535723176508575932662800703e4932", "1e4932",
                 "2e4932", "1e4933", "3.64519953188247460253e-4951", "1.82259976594123730126e-4951",
                 "1.82259976594123730127e-4951", "6.4751751194380251109244389582276465525e-4966",
                 "3.2375875597190125554622194791138232762e-4966", "3.2375875597190125554622194791138232763e-4966",
                 "3.36210314311209350626e-4932", "3.3621031431120935062626778173217526e-4932", "1e-4960", "1e-4970",
                 "0x1p-16445", "0x1p-16446", "0x1p-16494", "0x1p-16495", "0x1.ffffffffffffffffffffffffffffp16383",
                 "0xf.fffffffffffffffp16380", "0xf.fffffffffffffff8p16380", "0x1p16384", "0.1", "1e-10", "3.14159",
                 "-0", "inf", "-INFINITY", "nan", "NAN(x)", "1e", "0x", "  42.5e+3x", "9223372036854775807.5",
                 "18446744073709551615.5", "10384593717069655257060992658440191.5"]
    return edges[r.below(edges.count)]
  case 4:
    // Many digits: past 11600 significant ones, sometimes.
    let n = 11_000 + r.below(1500)
    var s = String(r.below(9) + 1)
    for _ in 1..<n { s += String(r.below(10)) }
    return s + "e" + String(-n + r.below(9000) - 4900)
  case 5:
    var s = "0x" + String(r.next(), radix: 16)
    if r.below(2) == 0 { s += "." + String(r.next() >> UInt64(r.below(64)), radix: 16) }
    return s + "p" + String(Int(r.below(33_000)) - 16_550)
  default:
    // A random value printed to 21 to 40 digits.
    let v = Float80(sign: .plus, exponent: r.below(32_000) - 16_000,
                    significand: 1 + Float80(r.next() >> 11) / Float80(1 << 53))
    return String(format: "%.\(20 + r.below(20))Le", v)
  }
}

func checkStrtold(_ f: LongDoubleFormat, seed: UInt64) {
  var r = Random(state: seed)
  var failures = 0
  for i in 0..<longDoubleCases {
    let s = longDoubleLike(&r, f)
    Array(s.utf8CString).withUnsafeBufferPointer { p in
      let start = p.baseAddress!
      errno = 0
      let (h, hostEnd) = f.glibcParse(start)
      let hostErrno = errno
      var ourEnd: UnsafeMutablePointer<CChar>?
      errno = 0
      let o = LibC.strtoldBits(start, &ourEnd, f.format)
      if hostErrno != errno {
        failures += 1
        if failures <= 20 { Issue.record("\(f.name) case \(i): strtold(\"\(s.prefix(100))\"): errno glibc \(hostErrno), ours \(errno)") }
      }
      let same = (f.isNaN(h) && f.isNaN(o) && f.signOf(h) == f.signOf(o)) || h == o
      if !same || hostEnd != ourEnd! - UnsafeMutablePointer(mutating: start) {
        failures += 1
        if failures <= 20 {
          Issue.record("\(f.name) case \(i): strtold(\"\(s.prefix(100))\"): glibc \(String(h, radix: 16)) +\(hostEnd), ours \(String(o, radix: 16)) +\(ourEnd! - UnsafeMutablePointer(mutating: start))")
        }
      }
    }
  }
  #expect(failures == 0, "\(f.name): \(failures) of \(longDoubleCases) differ")
}

@Test func strtoldX87MatchesGlibc() { checkStrtold(.x87, seed: 211) }
@Test func strtoldBinary128MatchesGlibc() { checkStrtold(.binary128, seed: 212) }

/// A long double worth printing, as Float80: an edge or random bits (a
/// valid encoding: the leading bit set exactly when the exponent isn't 0).
func interestingFloat80(_ r: inout Random) -> Float80 {
  let edges: [Float80] = [0, -0.0, 1, -1, 0.5, 0.1, 2.5, 9.5, 999999.5, 1e20, 1e4000, .greatestFiniteMagnitude,
                          .leastNormalMagnitude, .leastNonzeroMagnitude, .leastNormalMagnitude.nextDown,
                          .infinity, -.infinity, .nan, 3.14159265358979323846, 1.0 / 3.0, 0xf.8p0, 0xf.fp0]
  switch r.below(4) {
  case 0: return edges[r.below(edges.count)]
  case 1, 2:
    let field = UInt16(r.below(0x7FFF))
    let low = field == 0 ? r.next() >> 1 : r.next() | 1 << 63
    let high = field | (r.below(2) == 0 ? 0x8000 : 0)
    var v: Float80 = 0
    withUnsafeMutableBytes(of: &v) {
      $0.storeBytes(of: low, as: UInt64.self)
      $0.storeBytes(of: high, toByteOffset: 8, as: UInt16.self)
    }
    return v
  default:
    // Near a rounding boundary: n + 0.5 at some decimal place.
    return (Float80(r.below(100_000)) + 0.5) * [1, 0.1, 0.01, 1e-6][r.below(4)]
  }
}

@Test func longDoubleFormatMatchesGlibc() {
  var r = Random(state: 213)
  var failures = 0
  for i in 0..<(4 * longDoubleCases) {
    var f = "%"
    for flag in ["-", "+", " ", "#", "0"] where r.below(5) == 0 { f += flag }
    if r.below(3) == 0 { f += String(r.below(40)) }
    if r.below(2) == 0 { f += "." + String(r.below(45)) }
    f += "L" + ["e", "E", "f", "F", "g", "G", "a", "A"][r.below(8)]
    let v = interestingFloat80(&r)
    let (o, on) = ours(f, [.longDouble(v)]), (g, gn) = glibcs(f, [.longDouble(v)])
    if o != g || on != gn, !glibcsAlternateGRounding(f, ours: o, glibc: g) {
      failures += 1
      if failures <= 20 { Issue.record("case \(i): \(f) of \(v): glibc \"\(g)\", ours \"\(o)\"") }
    }
  }
  #expect(failures == 0, "\(failures) of \(4 * longDoubleCases) differ")
}

@Test func binary128FormatMatchesGlibc() {
  var r = Random(state: 214)
  var failures = 0
  let f128 = LongDoubleFormat.binary128
  for i in 0..<(4 * longDoubleCases) {
    var f = "%"
    if r.below(4) != 0 { f += "." + String(r.below(45)) }
    f += ["e", "E", "f", "F", "g", "G", "a", "A"][r.below(8)]
    var bits: UInt128
    switch r.below(5) {
    case 0:
      let edges: [UInt128] = [0, f128.format.signBit, f128.encode(1, 0), f128.encode(1, -16494),
                              f128.encode((UInt128(1) << 113) - 1, 16383 - 112), f128.encode(1, -16382),
                              f128.format.infinity, f128.format.quietNaN, f128.encode(5, -1), f128.encode(1, -1),
                              f128.encode(0x1F, -1)]
      bits = edges[r.below(edges.count)]
    case 1:
      bits = (UInt128(r.next()) << 64 | UInt128(r.next())) & ((UInt128(1) << 112) - 1)  // subnormal
    default:
      bits = UInt128(r.next()) << 64 | UInt128(r.next())
      if Int(bits >> 112) & 0x7FFF == 0x7FFF { bits &= ~(UInt128(1) << 112) }
    }
    var buffer = [CChar](repeating: 0, count: 6000)
    let gn = Int(td_strfromf128(&buffer, buffer.count, f, bitsToBytes(bits)))
    let g = String(cString: buffer)
    var printf = f
    printf.insert("L", at: printf.index(before: printf.endIndex))
    let (o, on) = ours(printf, [.binary128(bits)])
    if o != g || on != gn {
      failures += 1
      if failures <= 20 { Issue.record("case \(i): \(f) of \(String(bits, radix: 16)): glibc \"\(g)\", ours \"\(o)\"") }
    }
  }
  #expect(failures == 0, "\(failures) of \(4 * longDoubleCases) differ")
}
