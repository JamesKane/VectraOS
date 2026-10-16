// SPDX-License-Identifier: BSD-3-Clause

// The RTC's registers read as UTC (M6g), against glibc's timegm: random
// dates from 1900 to 2099 in each of the clock's encodings (BCD or binary,
// 12- or 24-hour, with and without the century register), and readings no
// date fits.

import Glibc
import RTC
import Testing

func bcd(_ v: Int) -> UInt8 { UInt8((v / 10) << 4 | v % 10) }

/// `t` as the clock would keep it.
func reading(_ t: tm, binary: Bool, twentyFour: Bool, century: Bool) -> RTCReading {
  let enc: (Int) -> UInt8 = { binary ? UInt8($0) : bcd($0) }
  var hours = enc(Int(t.tm_hour))
  if !twentyFour {
    let h12 = Int(t.tm_hour) % 12 == 0 ? 12 : Int(t.tm_hour) % 12
    hours = enc(h12) | (t.tm_hour >= 12 ? 0x80 : 0)
  }
  let year = Int(t.tm_year) + 1900
  return RTCReading(seconds: enc(Int(t.tm_sec)), minutes: enc(Int(t.tm_min)), hours: hours, day: enc(Int(t.tm_mday)),
                    month: enc(Int(t.tm_mon) + 1), year: enc(year % 100), century: century ? enc(year / 100) : nil,
                    statusB: (binary ? 0x04 : 0) | (twentyFour ? 0x02 : 0))
}

@Test func readingsMatchTimegm() {
  var state: UInt64 = 0x7274_63
  func next() -> UInt64 {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return state >> 11
  }
  for i in 0..<20_000 {
    // A second from 1900 to 2099, or one in 2000-2099 without the century.
    let century = i % 4 != 0
    let low: Int64 = century ? -2_208_988_800 : 946_684_800, high: Int64 = 4_102_444_800
    var seconds = time_t(low + Int64(next() % UInt64(high - low)))
    var t = tm()
    gmtime_r(&seconds, &t)
    let r = reading(t, binary: i % 2 == 0, twentyFour: i % 3 != 0, century: century)
    #expect(r.unixNanoseconds == Int64(timegm(&t)) * 1_000_000_000, "case \(i): \(r)")
  }
}

@Test func twelveHourEdges() {
  // 12 AM is hour 0, 12 PM hour 12.
  let midnight = RTCReading(seconds: 0, minutes: 0, hours: 0x12, day: 1, month: 1, year: 0x26, century: 0x20, statusB: 0)
  let noon = RTCReading(seconds: 0, minutes: 0, hours: 0x92, day: 1, month: 1, year: 0x26, century: 0x20, statusB: 0)
  #expect(midnight.date?.hour == 0)
  #expect(noon.date?.hour == 12)
}

@Test func nonsenseIsNoDate() {
  let ok = RTCReading(seconds: 0x30, minutes: 0x15, hours: 0x09, day: 0x12, month: 0x10, year: 0x26, century: 0x20, statusB: 0x02)
  #expect(ok.unixNanoseconds == Int64(1_791_796_530_000_000_000))  // 2026-10-12T09:15:30Z
  var bad = ok
  bad.seconds = 0x1A  // not BCD
  #expect(bad.unixNanoseconds == nil)
  bad = ok
  bad.month = 0x02
  bad.day = 0x30  // February 30th
  #expect(bad.unixNanoseconds == nil)
  bad = ok
  bad.hours = 0x24
  #expect(bad.unixNanoseconds == nil)
  bad = ok
  bad.statusB = 0  // 12-hour: hour 0 isn't one
  bad.hours = 0x00
  #expect(bad.unixNanoseconds == nil)
}
