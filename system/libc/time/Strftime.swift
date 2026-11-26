// SPDX-License-Identifier: BSD-3-Clause

// strftime in the C locale (C23 §7.29.3.5): every conversion, with the C
// locale's names and formats (%c "%a %b %e %H:%M:%S %Y", %x "%m/%d/%y",
// %X "%H:%M:%S", %p AM/PM); E and O modifiers are accepted and change
// nothing, as the C locale has no alternatives; ISO 8601 weeks for %g %G
// %V. A field out of its range prints "?" for a name and its number
// otherwise. An unknown conversion is copied as written. Runtime-free.

/// A broken-down time's fields (struct tm's), and its zone.
@safe struct BrokenDownTime {
  var second = 0, minute = 0, hour = 0, day = 1, month = 0, year = 0, weekday = 0, yearDay = 0
  /// Seconds east of UTC, and the zone's name (nil: "UTC").
  var offset = 0
  var zone: UnsafePointer<UInt8>? = nil
}

/// strftime's output: at most `max` bytes, its NUL included.
@safe struct TimeSink {
  let buffer: UnsafeMutablePointer<UInt8>
  let max: Int
  var n = 0
  var overflow = false
  mutating func put(_ b: UInt8) {
    if n + 1 < max {
      unsafe buffer[n] = b
      n += 1
    } else {
      overflow = true
    }
  }
  mutating func put(_ s: StaticString) { for k in 0..<s.utf8CodeUnitCount { put(unsafe s.utf8Start[k]) } }
  /// `v` in decimal, at least `width` digits, padded with `pad`.
  mutating func number(_ v: Int, _ width: Int, _ pad: UInt8 = 0x30) {
    var digits = InlineArray<24, UInt8>(repeating: 0)
    var m = v < 0 ? UInt(0) &- UInt(bitPattern: v) : UInt(v)
    var k = 0
    repeat {
      digits[k] = UInt8(truncatingIfNeeded: m % 10) + 0x30
      m /= 10
      k += 1
    } while m > 0
    if v < 0 { put(0x2D) }
    var w = k
    while w < width {
      put(pad)
      w += 1
    }
    while k > 0 {
      k -= 1
      put(digits[k])
    }
  }
}

/// The C locale's names (switches, not arrays: nothing here allocates).
func weekdayName(_ k: Int) -> StaticString? {
  switch k {
  case 0: "Sunday"
  case 1: "Monday"
  case 2: "Tuesday"
  case 3: "Wednesday"
  case 4: "Thursday"
  case 5: "Friday"
  case 6: "Saturday"
  default: nil
  }
}

func monthName(_ k: Int) -> StaticString? {
  switch k {
  case 0: "January"
  case 1: "February"
  case 2: "March"
  case 3: "April"
  case 4: "May"
  case 5: "June"
  case 6: "July"
  case 7: "August"
  case 8: "September"
  case 9: "October"
  case 10: "November"
  case 11: "December"
  default: nil
  }
}

/// `x` divided by `d`, rounded down (d > 0).
@inline(__always) func floorDiv(_ x: Int, _ d: Int) -> Int { x >= 0 ? x / d : -((-x + d - 1) / d) }
@inline(__always) func floorMod(_ x: Int, _ d: Int) -> Int { x - floorDiv(x, d) * d }

/// The number of ISO 8601 weeks in `year` (52 or 53): 53 when it starts on
/// a Thursday, or on a Wednesday in a leap year.
func isoWeeks(_ year: Int) -> Int {
  func p(_ y: Int) -> Int { floorMod(y + floorDiv(y, 4) - floorDiv(y, 100) + floorDiv(y, 400), 7) }
  return p(year) == 4 || p(year - 1) == 3 ? 53 : 52
}

/// The ISO 8601 week-based year and week of `t`.
func isoWeek(_ t: BrokenDownTime) -> (year: Int, week: Int) {
  let isoDay = floorMod(t.weekday + 6, 7) + 1  // Monday 1 ... Sunday 7
  let week = (t.yearDay + 1 - isoDay + 10) / 7
  if week < 1 { return (t.year - 1, isoWeeks(t.year - 1)) }
  if week > isoWeeks(t.year) { return (t.year + 1, 1) }
  return (t.year, week)
}

/// strftime: the bytes written before the NUL, or 0 if they didn't fit in
/// `max` (the buffer's contents then indeterminate).
func strftime(_ s: UnsafeMutablePointer<UInt8>, _ max: Int, _ format: UnsafePointer<UInt8>, _ t: BrokenDownTime) -> Int {
  guard max > 0 else { return 0 }
  var sink = unsafe TimeSink(buffer: s, max: max)
  unsafe expand(format, t, &sink)
  if sink.overflow { return 0 }
  unsafe s[sink.n] = 0
  return sink.n
}

func expand(_ format: UnsafePointer<UInt8>, _ t: BrokenDownTime, _ sink: inout TimeSink) {
  var i = 0
  func name(_ n: StaticString?, _ short: Bool, _ sink: inout TimeSink) {
    guard let n else { return sink.put(0x3F) }
    for j in 0..<(short ? 3 : n.utf8CodeUnitCount) { sink.put(unsafe n.utf8Start[j]) }
  }
  while unsafe format[i] != 0 {
    let c = unsafe format[i]
    i += 1
    if c != 0x25 {
      sink.put(c)
      continue
    }
    let start = i - 1
    if unsafe format[i] == 0x45 || format[i] == 0x4F { i += 1 }  // E, O
    let conversion = unsafe format[i]
    if conversion == 0 {
      for k in start..<i { sink.put(unsafe format[k]) }
      break
    }
    i += 1
    let hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12
    switch conversion {
    case 0x61: name(weekdayName(t.weekday), true, &sink)  // a
    case 0x41: name(weekdayName(t.weekday), false, &sink)  // A
    case 0x62, 0x68: name(monthName(t.month), true, &sink)  // b h
    case 0x42: name(monthName(t.month), false, &sink)  // B
    case 0x63: expandLiteral("%a %b %e %H:%M:%S %Y", t, &sink)  // c
    case 0x43: sink.number(floorDiv(t.year, 100), 2)  // C
    case 0x64: sink.number(t.day, 2)  // d
    case 0x44: expandLiteral("%m/%d/%y", t, &sink)  // D
    case 0x65: sink.number(t.day, 2, 0x20)  // e
    case 0x46: expandLiteral("%Y-%m-%d", t, &sink)  // F
    case 0x67: sink.number(floorMod(isoWeek(t).year, 100), 2)  // g
    case 0x47: sink.number(isoWeek(t).year, 1)  // G
    case 0x48: sink.number(t.hour, 2)  // H
    case 0x49: sink.number(hour12, 2)  // I
    case 0x6A: sink.number(t.yearDay + 1, 3)  // j
    case 0x6D: sink.number(t.month + 1, 2)  // m
    case 0x4D: sink.number(t.minute, 2)  // M
    case 0x6E: sink.put(0x0A)  // n
    case 0x70: sink.put(t.hour < 12 ? "AM" : "PM")  // p
    case 0x72: expandLiteral("%I:%M:%S %p", t, &sink)  // r
    case 0x52: expandLiteral("%H:%M", t, &sink)  // R
    case 0x53: sink.number(t.second, 2)  // S
    case 0x74: sink.put(0x09)  // t
    case 0x54: expandLiteral("%H:%M:%S", t, &sink)  // T
    case 0x75: sink.number(floorMod(t.weekday + 6, 7) + 1, 1)  // u
    case 0x55: sink.number((t.yearDay + 7 - t.weekday) / 7, 2)  // U
    case 0x56: sink.number(isoWeek(t).week, 2)  // V
    case 0x77: sink.number(t.weekday, 1)  // w
    case 0x57: sink.number((t.yearDay + 7 - floorMod(t.weekday + 6, 7)) / 7, 2)  // W
    case 0x78: expandLiteral("%m/%d/%y", t, &sink)  // x
    case 0x58: expandLiteral("%H:%M:%S", t, &sink)  // X
    case 0x79: sink.number(floorMod(t.year, 100), 2)  // y
    case 0x59: sink.number(t.year, 1)  // Y
    case 0x7A:  // z: +hhmm
      let m = abs(t.offset) / 60
      sink.put(t.offset < 0 ? 0x2D : 0x2B)
      sink.number(m / 60 * 100 + m % 60, 4)
    case 0x5A:  // Z
      if let zone = unsafe t.zone {
        var k = 0
        while unsafe zone[k] != 0 {
          sink.put(unsafe zone[k])
          k += 1
        }
      } else {
        sink.put("UTC")
      }
    case 0x25: sink.put(0x25)
    default:
      for k in start..<i { sink.put(unsafe format[k]) }
    }
  }
}

/// expand over a literal.
func expandLiteral(_ format: StaticString, _ t: BrokenDownTime, _ sink: inout TimeSink) {
  unsafe expand(format.utf8Start, t, &sink)
}
