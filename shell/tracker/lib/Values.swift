// SPDX-License-Identifier: BSD-3-Clause

// Tracker's values (M6j part 3b): a typed attribute as Taisce stores it
// (kinds string 1, int64, uint64, double, time, bool, bytes, ref, type;
// integers little-endian), decoded for showing and sorting, and the
// columns' text as the storyboard shows it (board 01: "14 KiB",
// "3.1 MiB", "2026-10-10", "directory", "—" for what a row lacks).

import Fs
import Node

/// A typed attribute's value.
public enum AttributeValue: Equatable, Sendable {
  case string(String)
  case int(Int64)
  case uint(UInt64)
  case double(Double)
  /// Nanoseconds since the Unix epoch.
  case time(Int64)
  case bool(Bool)
  case bytes([UInt8])
  /// A reference to another node (its bytes).
  case ref([UInt8])
  /// A MIME type.
  case type(String)

  public static let stringKind: UInt8 = 1, int64Kind: UInt8 = 2, uint64Kind: UInt8 = 3, doubleKind: UInt8 = 4,
    timeKind: UInt8 = 5, boolKind: UInt8 = 6, bytesKind: UInt8 = 7, refKind: UInt8 = 8, typeKind: UInt8 = 9

  /// `value` as Taisce encodes a `kind`; nil if it doesn't fit.
  public init?(kind: UInt8, value: [UInt8]) {
    func integer() -> UInt64? {
      guard value.count == 8 else { return nil }
      return value.reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
    switch kind {
    case Self.stringKind: self = .string(String(decoding: value, as: UTF8.self))
    case Self.int64Kind: guard let v = integer() else { return nil }; self = .int(Int64(bitPattern: v))
    case Self.uint64Kind: guard let v = integer() else { return nil }; self = .uint(v)
    case Self.doubleKind: guard let v = integer() else { return nil }; self = .double(Double(bitPattern: v))
    case Self.timeKind: guard let v = integer() else { return nil }; self = .time(Int64(bitPattern: v))
    case Self.boolKind: guard value.count == 1 else { return nil }; self = .bool(value[0] != 0)
    case Self.bytesKind: self = .bytes(value)
    case Self.refKind: self = .ref(value)
    case Self.typeKind: self = .type(String(decoding: value, as: UTF8.self))
    default: return nil
    }
  }

  public init?(_ a: FsIPC.Attribute) { self.init(kind: a.kind, value: a.value) }
  public init?(_ a: NodeIPC.Attribute) { self.init(kind: a.kind, value: a.value) }

  /// Its kind and encoding, as Taisce stores it.
  public var encoded: (kind: UInt8, value: [UInt8]) {
    func le(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
    switch self {
    case .string(let s): return (Self.stringKind, Array(s.utf8))
    case .int(let v): return (Self.int64Kind, le(UInt64(bitPattern: v)))
    case .uint(let v): return (Self.uint64Kind, le(v))
    case .double(let v): return (Self.doubleKind, le(v.bitPattern))
    case .time(let v): return (Self.timeKind, le(UInt64(bitPattern: v)))
    case .bool(let v): return (Self.boolKind, [v ? 1 : 0])
    case .bytes(let b): return (Self.bytesKind, b)
    case .ref(let b): return (Self.refKind, b)
    case .type(let s): return (Self.typeKind, Array(s.utf8))
    }
  }

  /// As a column shows it.
  public var text: String {
    switch self {
    case .string(let s), .type(let s): return s
    case .int(let v): return String(v)
    case .uint(let v): return String(v)
    case .double(let v): return Format.decimal(v)
    case .time(let ns): return Format.date(ns)
    case .bool(let v): return v ? "yes" : "no"
    case .bytes(let b): return Format.size(UInt64(b.count))
    case .ref: return "→"
    }
  }

  /// Ordered within a kind (strings without regard to case); kinds apart
  /// by their number. Numbers of different kinds compare as numbers.
  public static func ascending(_ a: AttributeValue, _ b: AttributeValue) -> Bool {
    switch (a.number, b.number) {
    case (let x?, let y?): return x < y
    default: break
    }
    switch (a, b) {
    case (.string(let x), .string(let y)), (.type(let x), .type(let y)): return Format.caseless(x, y)
    case (.bool(let x), .bool(let y)): return !x && y
    case (.bytes(let x), .bytes(let y)), (.ref(let x), .ref(let y)): return x.lexicographicallyPrecedes(y)
    default: return a.encoded.kind < b.encoded.kind
    }
  }

  var number: Double? {
    switch self {
    case .int(let v): return Double(v)
    case .uint(let v): return Double(v)
    case .double(let v): return v
    case .time(let v): return Double(v)
    default: return nil
    }
  }
}

/// The columns' text.
public enum Format {
  /// A size as the storyboard writes it: bytes below a KiB, then one
  /// decimal below 10 of a unit ("3.1 MiB"), whole above ("14 KiB"),
  /// each to the nearest.
  public static func size(_ bytes: UInt64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let units = ["KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
    var v = Double(bytes) / 1024
    var u = 0
    while v >= 1024 && u < units.count - 1 {
      v /= 1024
      u += 1
    }
    if v < 10 {
      let tenths = Int((v * 10).rounded())
      if tenths < 100 { return "\(tenths / 10).\(tenths % 10) \(units[u])" }
    }
    let whole = Int(v.rounded())
    // 1023.6 KiB is 1.0 MiB, not 1024 KiB.
    if whole >= 1024 && u < units.count - 1 { return "1.0 \(units[u + 1])" }
    return "\(whole) \(units[u])"
  }

  /// The day, in UTC, as ISO 8601 writes it ("2026-10-10").
  public static func date(_ ns: Int64) -> String {
    let days = Int64((Double(ns) / 86_400e9).rounded(.down))
    let (y, m, d) = civil(days)
    func two(_ v: Int64) -> String { v < 10 ? "0\(v)" : "\(v)" }
    return "\(y)-\(two(m))-\(two(d))"
  }

  /// Days since 1970-01-01 as a year, month and day (Howard Hinnant's
  /// days-to-civil, the proleptic Gregorian calendar).
  static func civil(_ days: Int64) -> (Int64, Int64, Int64) {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
  }

  /// A number with at most three decimals, trailing zeros dropped.
  public static func decimal(_ v: Double) -> String {
    guard v.isFinite else { return v.isNaN ? "nan" : v < 0 ? "-inf" : "inf" }
    let thousandths = Int64((abs(v) * 1000).rounded())
    var s = (v < 0 && thousandths != 0 ? "-" : "") + String(thousandths / 1000)
    var frac = thousandths % 1000
    if frac != 0 {
      var digits = String(frac + 1000).dropFirst()
      while digits.hasSuffix("0") { digits.removeLast() }
      s += "." + digits
      frac = 0
    }
    return s
  }

  /// Names in order without regard to case, then as written.
  public static func caseless(_ a: String, _ b: String) -> Bool {
    let la = a.lowercased(), lb = b.lowercased()
    return la != lb ? la < lb : a < b
  }
}
