// SPDX-License-Identifier: BSD-3-Clause

// strtod and strtof (M6c) against the host's glibc, which rounds correctly:
// the same strings through both, results compared bit for bit, with where
// the subject sequence ended and errno (M6d). The hard cases are halfway points between
// adjacent doubles, written out exactly (glibc's %.800e) and nudged above
// and below in their last digits; the rest are random digit strings,
// exponents at the extremes, subnormals, hex floats, inf and nan, junk.

import Foundation
import Glibc
@testable import LibC
import Testing

let strtodCases = Int(ProcessInfo.processInfo.environment["TODHCHAI_STRTOD_CASES"] ?? "") ?? 20_000

/// A string worth converting.
func floatingLike(_ r: inout Random) -> String {
  switch r.below(8) {
  case 0, 1:
    // A halfway point between two adjacent doubles, exactly, maybe nudged
    // in its last digits.
    let a = Double(bitPattern: UInt64(r.below(Int(Int32.max))) << 32 | UInt64(r.below(Int(Int32.max))))
    guard a.isFinite, a > 0, a.nextUp.isFinite else { return "0.5" }
    let midpoint = exactMidpoint(a)
    switch r.below(3) {
    case 0: return midpoint
    case 1: return midpoint + "0000001"  // just above
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
    for _ in 0..<(1 + r.below(30)) { s += String(r.below(10)) }
    if r.below(2) == 0 { s += "." + (0..<r.below(30)).map { _ in String(r.below(10)) }.joined() }
    if r.below(2) == 0 { s += "e" + (r.below(2) == 0 ? "-" : "") + String(r.below(400)) }
    return s
  case 3:
    let edges = ["1e308", "1.7976931348623157e308", "1.7976931348623158e308", "1.797693134862315807e308",
            "1.7976931348623159e308", "2e308", "4.9e-324", "2.4703282292062327e-324", "2.4703282292062328e-324",
            "2.2250738585072011e-308", "2.2250738585072014e-308", "1e-400", "0.000", "-0", "+.5", ".", "e5", "1e",
            "1e+", "0x1p-1074", "0x1.fffffffffffffp1023", "0x1p1024", "0X.8P1", "0x", "0x.p1", "inf", "-INFINITY",
            "infinit", "nan", "NAN(abc_1)", "nan(", "  \t 12.5xyz", "3.4028235e38", "3.4028236e38", "1.17549435e-38",
            "1.4e-45", "7e-46", "0.1", "9007199254740993", "9007199254740992.5"]
    return edges[r.below(edges.count)]
  case 4:
    // Many digits: past 768 significant ones.
    var s = String(r.below(9) + 1)
    for _ in 0..<(700 + r.below(200)) { s += String(r.below(10)) }
    return s + "e" + String(Int(r.below(700)) - 1000)
  case 5:
    var s = "0x" + String(r.below(1 << 30), radix: 16)
    if r.below(2) == 0 { s += "." + String(r.below(1 << 30), radix: 16) }
    return s + "p" + String(Int(r.below(2200)) - 1100)
  default:
    let d = Double(bitPattern: UInt64(r.below(Int(Int32.max))) << 32 | UInt64(r.below(Int(Int32.max))))
    return String(format: ["%.17g", "%.25e", "%.3e", "%g"][r.below(4)], d)
  }
}

/// The exact decimal midpoint of `a` and the next double up: with a = m ×
/// 2^e it is (2m + 1) × 2^(e-1), whose 54 bits a long double holds exactly,
/// and glibc prints a long double exactly (%.1100Le).
func exactMidpoint(_ a: Double) -> String {
  let m = a.significandBitPattern | (a.isNormal ? 1 << 52 : 0)
  let e = a.isNormal ? Int(a.exponent) - 52 : -1074
  let v = Float80(2 * m + 1) * Float80(sign: .plus, exponent: e - 1, significand: 1)
  return String(format: "%.1100Le", v)
}

@Test func strtodMatchesGlibc() {
  var r = Random(state: 91)
  var failures = 0
  for i in 0..<strtodCases {
    let s = floatingLike(&r)
    Array(s.utf8CString).withUnsafeBufferPointer { p in
      let start = p.baseAddress!
      var hostEnd: UnsafeMutablePointer<CChar>?, ourEnd: UnsafeMutablePointer<CChar>?
      errno = 0
      let h = Glibc.strtod(start, &hostEnd)
      let hostErrno = errno
      errno = 0
      let o = LibC.strtod(start, &ourEnd)
      if hostErrno != errno {
        failures += 1
        if failures <= 20 { Issue.record("case \(i): strtod(\"\(s.prefix(120))\"): errno glibc \(hostErrno), ours \(errno)") }
      }
      // NaNs compare by being NaNs (glibc's payload from NAN(chars) is its own).
      let same = (h.isNaN && o.isNaN && h.sign == o.sign) || h.bitPattern == o.bitPattern
      if !same || hostEnd != ourEnd {
        failures += 1
        if failures <= 20 {
          Issue.record("case \(i): strtod(\"\(s.prefix(120))\"): glibc \(h) (\(String(h.bitPattern, radix: 16))) +\(hostEnd! - UnsafeMutablePointer(mutating: start)), ours \(o) (\(String(o.bitPattern, radix: 16))) +\(ourEnd! - UnsafeMutablePointer(mutating: start))")
        }
      }
      errno = 0
      let hf = Glibc.strtof(start, &hostEnd)
      let hostErrnoF = errno
      errno = 0
      let of = LibC.strtof(start, &ourEnd)
      if hostErrnoF != errno {
        failures += 1
        if failures <= 20 { Issue.record("case \(i): strtof(\"\(s.prefix(120))\"): errno glibc \(hostErrnoF), ours \(errno)") }
      }
      let sameF = (hf.isNaN && of.isNaN && hf.sign == of.sign) || hf.bitPattern == of.bitPattern
      if !sameF || hostEnd != ourEnd {
        failures += 1
        if failures <= 20 { Issue.record("case \(i): strtof(\"\(s.prefix(120))\"): glibc \(hf), ours \(of)") }
      }
    }
  }
  #expect(failures == 0, "\(failures) of \(2 * strtodCases) differ")
}
