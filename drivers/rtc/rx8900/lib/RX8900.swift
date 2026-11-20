// SPDX-License-Identifier: BSD-3-Clause

// The Epson RX8900 (rx8900(3)) as bin/rx8900 reads and writes it over its
// I2C bus: a real-time clock whose time registers are BCD, the second to
// the year (2000 to 2099) with the weekday one-hot between, a flag
// register whose VLF bit says the time was lost, and a control register
// whose RESET bit holds the counters while they are written. Registers
// are the chip's application manual's.

public enum RX8900 {
  /// SEC, then MIN, HOUR, WEEK, DAY, MONTH and YEAR: the seven time
  /// registers, read and written in one transfer.
  public static let time = 0x00
  public static let flag = 0x0E
  public static let control = 0x0F

  /// Flag register bits.
  public static let vdet: UInt8 = 1 << 0
  public static let vlf: UInt8 = 1 << 1
  public static let alarm: UInt8 = 1 << 3
  public static let timer: UInt8 = 1 << 4
  public static let update: UInt8 = 1 << 5
  /// Control register: RESET holds the divider and the counters.
  public static let reset: UInt8 = 1 << 0

  /// The BCD byte for `v` (0 to 99), nil past it.
  public static func bcd(_ v: Int) -> UInt8? {
    guard v >= 0, v <= 99 else { return nil }
    return UInt8(((v / 10) << 4) | (v % 10))
  }

  /// The value of BCD byte `b`, nil if a nibble is past 9.
  public static func unbcd(_ b: UInt8) -> Int? {
    guard b >> 4 <= 9, b & 0xF <= 9 else { return nil }
    return Int(b >> 4) * 10 + Int(b & 0xF)
  }

  public static func isLeap(_ year: Int) -> Bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  }

  public static func daysIn(month: Int, year: Int) -> Int {
    switch month {
    case 2: isLeap(year) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  /// 0 for Sunday to 6 for Saturday.
  public static func weekday(year: Int, month: Int, day: Int) -> Int {
    let t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
    let y = month < 3 ? year - 1 : year
    return (y + y / 4 - y / 100 + y / 400 + t[month - 1] + day) % 7
  }

  /// The flag register, decoded.
  public struct Flags: Equatable, Sendable {
    public var raw: UInt8
    public init(_ raw: UInt8) { self.raw = raw }
    /// The time was lost: the supply fell below what the clock keeps it at.
    public var timeLost: Bool { raw & RX8900.vlf != 0 }
    public var voltageDrop: Bool { raw & RX8900.vdet != 0 }

    /// `0x02 VLF`, or `0x00 -`: the register and the bits set.
    public var text: String {
      var names: [String] = []
      if raw & RX8900.vdet != 0 { names.append("VDET") }
      if raw & RX8900.vlf != 0 { names.append("VLF") }
      if raw & RX8900.alarm != 0 { names.append("AF") }
      if raw & RX8900.timer != 0 { names.append("TF") }
      if raw & RX8900.update != 0 { names.append("UF") }
      let hex = String(raw, radix: 16)
      return "0x" + (hex.utf8.count < 2 ? "0" : "") + hex + " " + (names.isEmpty ? "-" : names.joined(separator: " "))
    }
  }

  public struct Date: Equatable, Sendable {
    public var year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int

    /// nil for a date the chip can't hold or isn't one: 2000 to 2099,
    /// the month, the day of it (leap years included), the time of day.
    public init?(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
      guard year >= 2000, year <= 2099, month >= 1, month <= 12, day >= 1, day <= RX8900.daysIn(month: month, year: year),
        hour >= 0, hour < 24, minute >= 0, minute < 60, second >= 0, second < 60
      else { return nil }
      (self.year, self.month, self.day, self.hour, self.minute, self.second) = (year, month, day, hour, minute, second)
    }

    /// From the seven time registers, nil if any isn't BCD or the date
    /// isn't one. A set VLF in `flags` gives no date: the registers hold
    /// what the chip started counting from.
    public init?(registers r: [UInt8], flags: Flags = Flags(0)) {
      guard r.count >= 7, !flags.timeLost,
        let s = RX8900.unbcd(r[0] & 0x7F), let mi = RX8900.unbcd(r[1] & 0x7F), let h = RX8900.unbcd(r[2] & 0x3F),
        let d = RX8900.unbcd(r[4] & 0x3F), let mo = RX8900.unbcd(r[5] & 0x1F), let y = RX8900.unbcd(r[6])
      else { return nil }
      self.init(year: 2000 + y, month: mo, day: d, hour: h, minute: mi, second: s)
    }

    /// The seven time registers it is, the weekday computed.
    public var registers: [UInt8] {
      [RX8900.bcd(second)!, RX8900.bcd(minute)!, RX8900.bcd(hour)!,
       UInt8(1 << RX8900.weekday(year: year, month: month, day: day)),
       RX8900.bcd(day)!, RX8900.bcd(month)!, RX8900.bcd(year - 2000)!]
    }

    /// `2026-11-01T18:04:05Z`, the `Z` optional and trailing newlines
    /// allowed; nil for anything else or a date the chip can't hold.
    public init?(text: String) {
      var b = Array(text.utf8)
      while let l = b.last, l == 0x0A { b.removeLast() }
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
        let h = number(11, 2), let mi = number(14, 2), let s = number(17, 2)
      else { return nil }
      self.init(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    }

    /// `2026-11-01T18:04:05Z`.
    public var text: String {
      func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
      return "\(year)-\(two(month))-\(two(day))T\(two(hour)):\(two(minute)):\(two(second))Z"
    }
  }

  /// Why the registers give no date, or nil where they do.
  public static func why(registers r: [UInt8], flags: Flags) -> String? {
    if flags.timeLost { return "time lost (VLF)" }
    return Date(registers: r, flags: flags) == nil ? "registers are not a date" : nil
  }
}
