// SPDX-License-Identifier: BSD-3-Clause

// The SpacemiT P1 PMIC (p1(3)), as bin/p1 reads and writes its registers
// over its I2C bus: six bucks and eleven LDOs (four ALDOs, seven DLDOs),
// each with an enable bit (bit 0 of its control register) and a voltage
// code in the register after it; its real-time clock, binary counts of
// the second to the year; and its power-off bit. Registers, codes and
// ranges are the chip's, as the vendor's spm8821.h and Linux's P1
// regulator driver give them.

public enum P1 {
  public static let version = 0xA1
  /// PWR_CTRL2: bit 2 shuts the board down.
  public static let powerControl = 0x7E
  public static let shutdown: UInt8 = 1 << 2

  public struct Regulator: Equatable, Sendable {
    public var name: String
    public var control: Int
    public var buck: Bool
    /// The register holding its voltage code.
    public var voltage: Int { control + 1 }

    /// The voltage `code` stands for, in µV: a buck's 500 mV to 1.375 V
    /// in 5 mV steps (codes 0 to 0xAA), then to 3.475 V in 25 mV steps;
    /// an LDO's 500 mV up in 25 mV steps from code 0xB.
    public func microvolts(_ code: UInt8) -> UInt32 {
      if buck {
        return code <= 0xAA ? 500_000 + 5_000 * UInt32(code) : 1_375_000 + 25_000 * UInt32(code - 0xAB)
      }
      let c = code & 0x7F
      return c < 0xB ? 500_000 : 500_000 + 25_000 * UInt32(c - 0xB)
    }

    /// The code for `uv`, or nil where none stands for it exactly.
    public func code(_ uv: UInt32) -> UInt8? {
      if buck {
        if uv >= 500_000, uv <= 1_350_000, (uv - 500_000) % 5_000 == 0 { return UInt8((uv - 500_000) / 5_000) }
        if uv >= 1_375_000, uv <= 3_475_000, (uv - 1_375_000) % 25_000 == 0 {
          return UInt8(0xAB + (uv - 1_375_000) / 25_000)
        }
        return nil
      }
      guard uv >= 500_000, uv <= 3_400_000, (uv - 500_000) % 25_000 == 0 else { return nil }
      return UInt8(0xB + (uv - 500_000) / 25_000)
    }
  }

  /// Every regulator, by its name in the tree's `regulators` node.
  public static let regulators: [Regulator] =
    (1...6).map { Regulator(name: "buck\($0)", control: 0x47 + 3 * ($0 - 1), buck: true) }
    + (1...4).map { Regulator(name: "aldo\($0)", control: 0x5B + 3 * ($0 - 1), buck: false) }
    + (1...7).map { Regulator(name: "dldo\($0)", control: 0x67 + 3 * ($0 - 1), buck: false) }

  public static func regulator(_ name: String) -> Regulator? {
    regulators.first { $0.name.utf8.elementsEqual(name.utf8) }
  }

  /// The RTC's counts: second, minute, hour, day, month and year, from
  /// `rtc` up.
  public static let rtc = 0x0D
  /// RTC_CTRL: the crystal on (bit 0), its 32 kHz out (1), the RTC
  /// counting (2), on the internal 32 kHz clock (3).
  public static let rtcControl = 0x1D
  public static let rtcRunning: UInt8 = 1 << 2
  /// What the vendor's driver sets to start it.
  public static let rtcStart: UInt8 = 0x0F

  public struct Date: Equatable, Sendable {
    public var year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int

    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
      (self.year, self.month, self.day, self.hour, self.minute, self.second) = (year, month, day, hour, minute, second)
    }

    /// From the six counts: the day and the month count from 0, the year
    /// from 2000.
    public init?(counts c: [UInt8]) {
      guard c.count >= 6 else { return nil }
      self.init(year: 2000 + Int(c[5] & 0x3F), month: Int(c[4] & 0xF) + 1, day: Int(c[3] & 0x1F) + 1,
                hour: Int(c[2] & 0x1F), minute: Int(c[1] & 0x3F), second: Int(c[0] & 0x3F))
      guard month <= 12, hour < 24, minute < 60, second < 60 else { return nil }
    }

    /// `2026-11-01T18:04:05Z`, the `Z` optional; nil for anything else, or
    /// a date the RTC can't hold (2000 to 2063).
    public init?(text: String) {
      let b = Array(text.utf8.filter { $0 != 0x0A })
      guard b.count == 19 || b.count == 20 && b[19] == UInt8(ascii: "Z") else { return nil }
      func number(_ at: Int, _ n: Int) -> Int? {
        var v = 0
        for c in b[at..<(at + n)] {
          guard c >= 0x30, c <= 0x39 else { return nil }
          v = v * 10 + Int(c - 0x30)
        }
        return v
      }
      let marks: [(Int, UInt8)] = [(4, 0x2D), (7, 0x2D), (10, UInt8(ascii: "T")), (13, 0x3A), (16, 0x3A)]
      guard marks.allSatisfy({ b[$0.0] == $0.1 }), let y = number(0, 4), let mo = number(5, 2), let d = number(8, 2),
        let h = number(11, 2), let mi = number(14, 2), let s = number(17, 2),
        y >= 2000, y <= 2063, mo >= 1, mo <= 12, d >= 1, d <= 31, h < 24, mi < 60, s < 60
      else { return nil }
      self.init(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    }

    /// The six counts it is, from the second.
    public var counts: [UInt8] {
      [UInt8(second), UInt8(minute), UInt8(hour), UInt8(day - 1), UInt8(month - 1), UInt8(year - 2000)]
    }

    /// `2026-11-01T18:04:05Z`.
    public var text: String {
      func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
      return "\(year)-\(two(month))-\(two(day))T\(two(hour)):\(two(minute)):\(two(second))Z"
    }
  }

  /// The voltages the node allows regulator `name`: its
  /// `regulator-min-microvolt` to its `regulator-max-microvolt`; nil
  /// where it gives neither.
  public static func range(node: String, _ name: String) -> ClosedRange<UInt32>? {
    var low: UInt32?, high: UInt32?
    let prefix = Array("regulators/\(name)/".utf8)
    for line in node.utf8.split(separator: 0x0A) where line.starts(with: prefix) {
      let rest = line.dropFirst(prefix.count)
      guard let space = rest.firstIndex(of: 0x20) else { continue }
      let value = rest[rest.index(after: space)...].filter { $0 != UInt8(ascii: "<") && $0 != UInt8(ascii: ">") }
      guard value.starts(with: "0x".utf8), let v = UInt32(String(decoding: value.dropFirst(2), as: UTF8.self), radix: 16)
      else { continue }
      if rest[..<space].elementsEqual("regulator-min-microvolt".utf8) { low = v }
      if rest[..<space].elementsEqual("regulator-max-microvolt".utf8) { high = v }
    }
    guard let low, let high, low <= high else { return nil }
    return low...high
  }

  /// The regulators the node names (`regulators/<name>/...` lines of its
  /// properties), and which say `regulator-always-on`.
  public static func named(node: String) -> [(name: String, alwaysOn: Bool)] {
    var out: [(name: String, alwaysOn: Bool)] = []
    for line in node.utf8.split(separator: 0x0A) where line.starts(with: "regulators/".utf8) {
      let rest = line.dropFirst(11)
      guard let slash = rest.firstIndex(of: UInt8(ascii: "/")) else { continue }
      let name = String(decoding: rest[..<slash], as: UTF8.self)
      guard regulator(name) != nil else { continue }
      let always = rest[slash...].starts(with: "/regulator-always-on".utf8)
      if let i = out.firstIndex(where: { $0.name.utf8.elementsEqual(name.utf8) }) {
        out[i].alwaysOn = out[i].alwaysOn || always
      } else {
        out.append((name, always))
      }
    }
    return out
  }
}
