// SPDX-License-Identifier: BSD-3-Clause

// printf's formatting (M6c) against the host's glibc: the same format and
// arguments through our formatter and glibc's vsnprintf, compared byte for
// byte, on seeded random conversions (flags, widths, precisions, lengths)
// and values (integers at every size, strings, doubles from edge cases and
// random bit patterns, subnormals and the extremes among them).

import Foundation
import Glibc
@testable import LibC
import Testing

/// One printf argument, for both formatters.
enum Value {
  case int(Int64), double(Double), longDouble(Float80), binary128(UInt128), string(String?), pointer(UInt)
}

/// Our formatter's arguments, from an array.
struct ArrayArguments: FormatArguments {
  var values: [Value]
  var strings: [UnsafeMutablePointer<UInt8>?]
  var next = 0

  init(_ values: [Value]) {
    self.values = values
    strings = values.map {
      if case .string(let s?) = $0 {
        let bytes = Array(s.utf8) + [0]
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
        p.initialize(from: bytes, count: bytes.count)
        return p
      }
      return nil
    }
  }

  func free() { for p in strings { p?.deallocate() } }

  mutating func take() -> Int {
    defer { next += 1 }
    return next
  }
  mutating func integer(_ size: Int) -> UInt64 {
    let i = take()
    if case .int(let v) = values[i] { return UInt64(bitPattern: v) }
    return 0
  }
  mutating func double() -> Double {
    let i = take()
    if case .double(let v) = values[i] { return v }
    return 0
  }
  mutating func longDouble() -> FloatValue {
    let i = take()
    if case .longDouble(let v) = values[i] { return x87Value(v) }
    if case .binary128(let v) = values[i] { return FloatValue(binary128: v) }
    return FloatValue(0)
  }
  mutating func pointer() -> UInt {
    let i = take()
    if case .pointer(let v) = values[i] { return v }
    return 0
  }
  mutating func string() -> UnsafePointer<UInt8>? { UnsafePointer(strings[take()]) }
}

/// A Float80 as ours decodes it, from its bytes: the significand's 64
/// bits, then the sign and exponent's 16.
func x87Value(_ v: Float80) -> FloatValue {
  withUnsafeBytes(of: v) { FloatValue(x87: $0.load(as: UInt64.self), $0.load(fromByteOffset: 8, as: UInt16.self)) }
}

struct BufferSink: FormatSink {
  var bytes: [UInt8] = []
  mutating func put(_ byte: UInt8) { bytes.append(byte) }
}

/// Ours: the output and the count.
func ours(_ format: String, _ values: [Value]) -> (String, Int) {
  var args = ArrayArguments(values)
  defer { args.free() }
  var sink = BufferSink()
  let n = Array(format.utf8CString).withUnsafeBufferPointer { f in
    f.withMemoryRebound(to: UInt8.self) { LibC.format($0.baseAddress!, &args, &sink) }
  }
  return (String(decoding: sink.bytes, as: UTF8.self), n)
}

/// glibc's, through vsnprintf.
func glibcs(_ format: String, _ values: [Value]) -> (String, Int) {
  var keep: [UnsafeMutablePointer<CChar>?] = []
  defer { for p in keep { p.map { Glibc.free($0) } } }
  let cargs: [any CVarArg] = values.map {
    switch $0 {
    case .int(let v): return v
    case .double(let v): return v
    case .longDouble(let v): return v
    case .binary128: fatalError("binary128 doesn't travel through vsnprintf")
    case .pointer(let v): return Int(bitPattern: v)  // a pointer travels as a word
    case .string(let s):
      let p = s.map { Glibc.strdup($0) } ?? nil
      keep.append(p)
      return Int(bitPattern: p)
    }
  }
  var buffer = [CChar](repeating: 0, count: 16_384)
  let n = withVaList(cargs) { va in vsnprintf(&buffer, buffer.count, format, va) }
  return (String(cString: buffer), Int(n))
}

/// TODHCHAI_FORMAT_CASES=N runs more.
let formatCases = Int(ProcessInfo.processInfo.environment["TODHCHAI_FORMAT_CASES"] ?? "") ?? 40_000

/// A double worth printing: an edge value or random bits.
func interestingDouble(_ r: inout Random) -> Double {
  let edges: [Double] = [0, -0.0, 1, -1, 0.5, 0.1, 0.125, 1.5, 2.5, 9.5, 99.5, 0.05, 0.005, 1e-5, 1e-4, 123456.789,
                         1e15, 1e16, 1e21, 1e22, 1e23, 1e100, 1e300, 1.7976931348623157e308, 2.2250738585072014e-308,
                         4.9e-324, 5e-324, 1e-320, 0.3, 2.0 / 3.0, 1.0 / 3.0, 9.999999, 0.9999995, 999999.5,
                         .infinity, -.infinity, .nan, 3.14159265358979, 6.02214076e23, 1.602176634e-19]
  switch r.below(4) {
  case 0: return edges[r.below(edges.count)]
  case 1: return Double(bitPattern: UInt64(r.below(Int(Int32.max))) << 32 | UInt64(r.below(Int(Int32.max))))
  case 2: return Double(r.below(2_000_000)) / Double([1, 10, 100, 1000, 8, 16, 1024][r.below(7)]) * (r.below(2) == 0 ? 1 : -1)
  default:
    // Values near a rounding boundary: n + 0.5 at some decimal place.
    let place = Double([1, 0.1, 0.01, 0.001, 1e-6][r.below(5)])
    return (Double(r.below(100_000)) + 0.5) * place
  }
}

/// A conversion with random flags, width, precision and length, and its
/// argument (and `*` arguments).
func randomConversion(_ r: inout Random) -> (String, [Value]) {
  var s = "%"
  var values: [Value] = []
  for flag in ["-", "+", " ", "#", "0"] where r.below(5) == 0 { s += flag }
  if r.below(3) == 0 {
    if r.below(5) == 0 {
      s += "*"
      values.append(.int(Int64(r.below(30)) - 5))
    } else {
      s += String(r.below(25))
    }
  }
  if r.below(2) == 0 {
    if r.below(6) == 0 {
      s += ".*"
      values.append(.int(Int64(r.below(25)) - 3))
    } else {
      s += "." + String(r.below(r.below(4) == 0 ? 60 : 18))
    }
  }
  switch r.below(4) {
  case 0:
    let lengths = ["hh", "h", "", "l", "ll", "z", "j"]
    let length = lengths[r.below(lengths.count)]
    let conversion = ["d", "i", "u", "o", "x", "X"][r.below(6)]
    s += length + conversion
    let v: Int64
    switch r.below(4) {
    case 0: v = Int64(r.below(200)) - 100
    case 1: v = [Int64.max, Int64.min, Int64(Int32.max), Int64(Int32.min), 0, -1, 255, 256, 65535][r.below(9)]
    default: v = Int64(bitPattern: UInt64(r.below(Int(Int32.max))) << 33 ^ UInt64(r.below(Int(Int32.max))))
    }
    // An int-sized conversion is passed as an int, a long one as a long.
    values.append(.int(length == "" || length == "h" || length == "hh" ? Int64(Int32(truncatingIfNeeded: v)) : v))
  case 1:
    s += ["s", "c", "p"][r.below(3)]
    if s.hasSuffix("s") {
      values.append(.string(r.below(8) == 0 ? nil : ["", "a", "hello", "todhchai on croi", "x y z"][r.below(5)]))
    } else if s.hasSuffix("c") {
      values.append(.int(Int64(32 + r.below(90))))
    } else {
      values.append(.pointer(r.below(4) == 0 ? 0 : UInt(r.below(Int(Int32.max)))))
    }
  default:
    s += ["f", "F", "e", "E", "g", "G", "a", "A"][r.below(8)]
    values.append(.double(interestingDouble(&r)))
  }
  return (s, values)
}

/// glibc's %#g where rounding carries into the next power of ten (999999.5
/// to 6 digits): C23 §7.23.6.1 has style E's exponent after rounding (6, so
/// style e with precision P - 1: "1.00000e+06"); glibc takes the precision
/// from the exponent before it ("1.e+06"). Ours is the standard's.
func glibcsAlternateGRounding(_ format: String, ours: String, glibc: String) -> Bool {
  guard format.contains("#") && (format.contains("g") || format.contains("G")) else { return false }
  return glibc.contains(".e+") || glibc.contains(".E+") || glibc.contains(".e-") || glibc.contains(".E-")
}

@Test func formatMatchesGlibc() {
  var r = Random(state: 61)
  var failures = 0
  for i in 0..<formatCases {
    var format = r.below(3) == 0 ? "<" : ""
    var values: [Value] = []
    for _ in 0..<(1 + r.below(2)) {
      let (f, v) = randomConversion(&r)
      format += f + (r.below(4) == 0 ? "|" : "")
      values += v
    }
    // %c with 0 or - and a precision is fine; glibc and C agree.
    let (o, on) = ours(format, values), (g, gn) = glibcs(format, values)
    if o != g || on != gn, !glibcsAlternateGRounding(format, ours: o, glibc: g) {
      failures += 1
      if failures <= 25 { Issue.record("case \(i): \(format) \(values): glibc \"\(g)\" (\(gn)), ours \"\(o)\" (\(on))") }
    }
  }
  #expect(failures == 0, "\(failures) of \(formatCases) differ")
}

@Test func formatHandlesTheEdgesC23Names() {
  // A few fixed cases, readable when they fail.
  let fixed: [(String, [Value])] = [
    ("%d %i %u", [.int(-42), .int(7), .int(42)]), ("%5.3d|%-6x|%#o|%#x", [.int(7), .int(255), .int(8), .int(0)]),
    ("%.0f %.0f %.0f %.0f", [.double(0.5), .double(1.5), .double(2.5), .double(-0.5)]),
    ("%e %E %.0e %#.0e", [.double(123.456), .double(0), .double(9.5), .double(1)]),
    ("%g %g %g %g %#g", [.double(100000), .double(1000000), .double(0.0001), .double(0.00001), .double(1)]),
    ("%a %A %.2a %a", [.double(1), .double(-0.1), .double(1.999), .double(4.9e-324)]),
    ("%f %F %e", [.double(.infinity), .double(-.infinity), .double(.nan)]),
    ("%.20f", [.double(0.1)]), ("%.60e", [.double(4.9e-324)]), ("%f", [.double(1.7976931348623157e308)]),
    ("%s|%.2s|%10s|%-10s|", [.string("hello"), .string("hello"), .string("hi"), .string("hi")]),
    ("%p %p", [.pointer(0), .pointer(0x1234)]), ("%%|%c", [.int(65)]),
  ]
  for (f, v) in fixed {
    let (o, on) = ours(f, v), (g, gn) = glibcs(f, v)
    #expect(o == g && on == gn, "\(f): glibc \"\(g)\", ours \"\(o)\"")
  }
}
