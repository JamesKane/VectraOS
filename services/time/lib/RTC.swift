// SPDX-License-Identifier: BSD-3-Clause

// The PC's real-time clock (M6g): the MC146818's registers as the CMOS
// presents them through ports 0x70 (index) and 0x71 (data), and their date
// as UTC. Status register B says how they're kept: bit 2 binary (else BCD),
// bit 1 a 24-hour clock (else 12, the hour's bit 7 meaning PM). Register
// 0x32 holds the century where firmware keeps it (QEMU does; ACPI's FADT
// names it), else the year is taken as 20YY. The machine's clock is UTC
// (QEMU's default, `-rtc base=utc`), as Linux assumes unless told.

/// The registers the time service reads.
public enum RTCRegister {
  public static let seconds: UInt8 = 0x00
  public static let minutes: UInt8 = 0x02
  public static let hours: UInt8 = 0x04
  public static let day: UInt8 = 0x07
  public static let month: UInt8 = 0x08
  public static let year: UInt8 = 0x09
  /// Bit 7: an update is in progress (the others may be mid-change).
  public static let statusA: UInt8 = 0x0A
  public static let statusB: UInt8 = 0x0B
  public static let century: UInt8 = 0x32
}

/// One reading of the clock's registers, as they hold them.
public struct RTCReading: Equatable, Sendable {
  public var seconds: UInt8
  public var minutes: UInt8
  public var hours: UInt8
  public var day: UInt8
  public var month: UInt8
  public var year: UInt8
  /// Register 0x32, or nil where there's none.
  public var century: UInt8?
  public var statusB: UInt8

  public init(seconds: UInt8, minutes: UInt8, hours: UInt8, day: UInt8, month: UInt8, year: UInt8, century: UInt8?,
              statusB: UInt8)
  {
    self.seconds = seconds
    self.minutes = minutes
    self.hours = hours
    self.day = day
    self.month = month
    self.year = year
    self.century = century
    self.statusB = statusB
  }

  var binary: Bool { statusB & 0x04 != 0 }
  var twentyFourHour: Bool { statusB & 0x02 != 0 }

  func value(_ v: UInt8) -> Int? {
    if binary { return Int(v) }
    let hi = Int(v >> 4), lo = Int(v & 0x0F)
    guard hi < 10, lo < 10 else { return nil }
    return hi * 10 + lo
  }

  /// The date it says, or nil if a register holds nonsense.
  public var date: (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int)? {
    guard let s = value(seconds), let m = value(minutes), let d = value(day), let mo = value(month),
      let y = value(year)
    else { return nil }
    let pm = !twentyFourHour && hours & 0x80 != 0
    guard var h = value(hours & 0x7F) else { return nil }
    if !twentyFourHour {
      guard (1...12).contains(h) else { return nil }
      h = h % 12 + (pm ? 12 : 0)
    }
    let c = century.flatMap { value($0) } ?? 20
    guard (0...59).contains(s), (0...59).contains(m), (0...23).contains(h), (1...12).contains(mo), (1...31).contains(d),
      (0...99).contains(y), (19...99).contains(c)
    else { return nil }
    return (c * 100 + y, mo, d, h, m, s)
  }

  /// The reading as nanoseconds since the Unix epoch, UTC.
  public var unixNanoseconds: Int64? {
    guard let t = date, t.day <= RTC.daysIn(month: t.month, year: t.year) else { return nil }
    let days = RTC.daysFromCivil(year: t.year, month: t.month, day: t.day)
    let seconds = days * 86_400 + Int64(t.hour * 3600 + t.minute * 60 + t.second)
    return seconds * 1_000_000_000
  }
}

public enum RTC {
  /// Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's
  /// days_from_civil).
  public static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
    let y = Int64(month <= 2 ? year - 1 : year)
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = Int64((month + 9) % 12)
    let doy = (153 * mp + 2) / 5 + Int64(day) - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
  }

  public static func daysIn(month: Int, year: Int) -> Int {
    switch month {
    case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
  }
}

extension RTC {
  /// `2026-11-01T18:04:05Z` (the `Z` optional, a newline after it
  /// ignored) as nanoseconds since the Unix epoch, UTC: how a
  /// devicetree machine's clock driver gives its date (`rtc`, time(8)).
  public static func unixNanoseconds(text: String) -> Int64? {
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
      y >= 1970, mo >= 1, mo <= 12, d >= 1, d <= daysIn(month: mo, year: y), h < 24, mi < 60, s < 60
    else { return nil }
    return (daysFromCivil(year: y, month: mo, day: d) * 86_400 + Int64(h * 3600 + mi * 60 + s)) * 1_000_000_000
  }
}
