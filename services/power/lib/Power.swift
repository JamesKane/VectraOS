// SPDX-License-Identifier: BSD-3-Clause

// The power service's policy (power(8), D130): every CPU at its highest
// performance level, stepped down while a thermal zone is at or above its
// passive trip point and back up once every zone is clear of it, and the
// machine powered off when one reaches its critical trip. What devmgr's
// `cpus` and `thermal` files say, read as they say it.

/// `line`'s words: bytes split at spaces, never Characters (whose rules
/// would bring in the Unicode tables).
func words(_ line: String) -> [String] {
  line.utf8.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
}

/// Whether `a` is the text `b`, compared as bytes.
func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

/// A text's lines, split at newlines as bytes.
public func lines(_ text: String) -> [String] {
  text.utf8.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) }
}

/// A CPU's performance controls, from a `cpus` line.
public struct CPUControl: Equatable, Sendable {
  public var uid: UInt64
  public var lowest: UInt32
  public var highest: UInt32
  public var lowestMHz: UInt32
  public var nominal: UInt32
  public var nominalMHz: UInt32
  /// The desired-performance register: SystemMemory's address, its bits
  /// and their offset; nil where it is none, or in another space.
  public var address: UInt64?
  public var bitWidth: UInt8
  public var bitOffset: UInt8
  public var domain: UInt32?

  /// `<uid> <path> perf <lowest> <nonlinear> <nominal> <highest> mhz
  /// <low> <nominal> desired <space> <address> <width> <offset> [domain
  /// <d> <coordination> <n>]`; nil for any other line (`no _CPC`).
  public static func parse(_ line: String) -> CPUControl? {
    let w = words(line)
    guard w.count >= 11, same(w[2], "perf"), same(w[7], "mhz"), same(w[10], "desired"), let uid = UInt64(w[0]),
      let lowest = UInt32(w[3]), let nominal = UInt32(w[5]), let highest = UInt32(w[6]), let low = UInt32(w[8]),
      let nom = UInt32(w[9]), lowest <= highest
    else { return nil }
    var c = CPUControl(uid: uid, lowest: lowest, highest: highest, lowestMHz: low, nominal: nominal, nominalMHz: nom,
                       address: nil, bitWidth: 0, bitOffset: 0, domain: nil)
    var at = 11
    if w.count >= 15, same(w[11], "0"), w[12].utf8.starts(with: [0x30, 0x78]),
      let a = UInt64(String(decoding: w[12].utf8.dropFirst(2), as: UTF8.self), radix: 16),
      let width = UInt8(w[13]), let offset = UInt8(w[14]), [8, 16, 32, 64].contains(width), offset == 0
    {
      c.address = a
      c.bitWidth = width
      c.bitOffset = offset
      at = 15
    }
    while at < w.count, !same(w[at], "domain") { at += 1 }
    if at + 1 < w.count { c.domain = UInt32(w[at + 1]) }
    return c
  }

  /// The level for `step` of `steps`: lowest at 0, highest at `steps`.
  public func level(_ step: Int, of steps: Int) -> UInt32 {
    guard steps > 0 else { return highest }
    let s = UInt64(max(0, min(step, steps)))
    return lowest + UInt32((UInt64(highest - lowest) * s) / UInt64(steps))
  }

  /// A level's clock, in MHz, on the line through lowest and nominal's
  /// (0 if _CPC gives no frequencies).
  public func megahertz(_ level: UInt32) -> UInt32 {
    guard nominal > lowest, nominalMHz > lowestMHz else { return 0 }
    let above = UInt64(level >= lowest ? level - lowest : 0)
    return lowestMHz + UInt32(above * UInt64(nominalMHz - lowestMHz) / UInt64(nominal - lowest))
  }
}

/// A thermal zone, from a `thermal` line: tenths of a kelvin, nil where
/// it has none (or its sensor failed); polling in tenths of a second.
public struct Zone: Equatable, Sendable {
  public var path: String
  public var temperature: UInt32?
  public var passive: UInt32?
  public var critical: UInt32?
  public var polling: UInt32

  public init(path: String, temperature: UInt32?, passive: UInt32?, critical: UInt32?, polling: UInt32) {
    self.path = path
    self.temperature = temperature
    self.passive = passive
    self.critical = critical
    self.polling = polling
  }

  /// `<path> <dK|-> passive <dK|-> critical <dK|-> polling <ds>`.
  public static func parse(_ line: String) -> Zone? {
    let w = words(line)
    guard w.count == 8, same(w[2], "passive"), same(w[4], "critical"), same(w[6], "polling"), let polling = UInt32(w[7])
    else {
      return nil
    }
    return Zone(path: w[0], temperature: UInt32(w[1]), passive: UInt32(w[3]), critical: UInt32(w[5]), polling: polling)
  }

  /// Tenths of a kelvin as degrees Celsius, to a tenth: `45.3`.
  public static func celsius(_ dK: UInt32) -> String {
    let t = Int(dK) - 2732
    return "\(t < 0 ? "-" : "")\(abs(t) / 10).\(abs(t) % 10)"
  }
}

/// What the policy does after a reading.
public enum Action: Equatable, Sendable {
  case stay
  /// Every CPU to this step.
  case step(Int)
  /// The zone at its critical trip: the machine goes off.
  case powerOff(String)
}

/// Where performance stands, and how a reading moves it.
public struct Policy: Equatable, Sendable {
  /// The steps between lowest (0) and highest.
  public static let steps = 8
  /// How far below its passive trip every zone must be before a step up:
  /// 5 K, in tenths.
  public static let clearance: UInt32 = 50
  /// How often zones are read, at most: a second, in tenths.
  public static let longestPoll: UInt32 = 10

  public private(set) var step = Policy.steps
  /// Why the last move was made.
  public private(set) var reason = "highest: no reading yet"

  public init() {}

  /// The step after `zones` are read.
  public mutating func next(_ zones: [Zone]) -> Action {
    guard !zones.isEmpty else {
      reason = "highest: no thermal zones"
      return set(Self.steps)
    }
    for z in zones {
      if let t = z.temperature, let c = z.critical, t >= c {
        reason = "\(z.path) at \(Zone.celsius(t)) C, its critical trip \(Zone.celsius(c)) C"
        return .powerOff(z.path)
      }
    }
    let read = zones.filter { $0.temperature != nil }
    guard !read.isEmpty else {
      reason = "lowest: no zone reads its temperature"
      return set(0)
    }
    if let hot = read.first(where: { $0.passive != nil && $0.temperature! >= $0.passive! }) {
      reason = "\(hot.path) at \(Zone.celsius(hot.temperature!)) C, its passive trip \(Zone.celsius(hot.passive!)) C"
      return set(step - 1)
    }
    if read.allSatisfy({ $0.passive == nil || $0.temperature! + Self.clearance <= $0.passive! }) {
      reason = step < Self.steps ? "every zone 5 C below its passive trip" : "highest: every zone clear"
      return set(step + 1)
    }
    return .stay
  }

  mutating func set(_ s: Int) -> Action {
    let to = max(0, min(s, Self.steps))
    guard to != step else { return .stay }
    step = to
    return .step(to)
  }

  /// The polling period in tenths of a second: the zones' shortest _TZP,
  /// at most a second.
  public static func period(_ zones: [Zone]) -> UInt32 {
    let asked = zones.map { $0.polling }.filter { $0 > 0 }.min() ?? longestPoll
    return min(asked, longestPoll)
  }
}
