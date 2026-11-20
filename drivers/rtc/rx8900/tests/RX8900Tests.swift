// SPDX-License-Identifier: BSD-3-Clause

// The Epson RX8900 as bin/rx8900 reads it: BCD, the time registers and the
// date they are, the weekday, the flag register, and which dates it holds.

import RX8900
import Testing

@Test func aKnownDateRoundTripsThroughRegisters() {
  // 2026-11-20 (a Friday) 13:45:59.
  let d = RX8900.Date(year: 2026, month: 11, day: 20, hour: 13, minute: 45, second: 59)!
  #expect(d.registers == [0x59, 0x45, 0x13, 0x20, 0x20, 0x11, 0x26])
  #expect(RX8900.Date(registers: d.registers) == d)
  #expect(RX8900.Date(text: d.text) == d && d.text == "2026-11-20T13:45:59Z")
  #expect(RX8900.Date(text: "2026-11-20T13:45:59\n") == d)
}

@Test func theWeekdayIsOneHotFromSunday() {
  #expect(RX8900.weekday(year: 2000, month: 1, day: 1) == 6)  // Saturday
  #expect(RX8900.weekday(year: 2026, month: 11, day: 20) == 5)  // Friday
  #expect(RX8900.weekday(year: 2024, month: 2, day: 29) == 4)  // Thursday
  #expect(RX8900.weekday(year: 2099, month: 12, day: 31) == 4)  // Thursday
  #expect(RX8900.weekday(year: 2023, month: 1, day: 1) == 0)  // Sunday
  #expect(RX8900.Date(year: 2023, month: 1, day: 1, hour: 0, minute: 0, second: 0)!.registers[3] == 0x01)
  #expect(RX8900.Date(year: 2026, month: 11, day: 20, hour: 0, minute: 0, second: 0)!.registers[3] == 0x20)
}

@Test func bcdOutOfRangeIsRefused() {
  #expect(RX8900.bcd(59) == 0x59 && RX8900.bcd(100) == nil && RX8900.bcd(-1) == nil)
  #expect(RX8900.unbcd(0x59) == 59 && RX8900.unbcd(0x5A) == nil && RX8900.unbcd(0xA0) == nil)
  #expect(RX8900.Date(registers: [0x6A, 0x00, 0x00, 0x01, 0x01, 0x01, 0x00]) == nil)
  #expect(RX8900.Date(registers: [0x00, 0x00, 0x24, 0x01, 0x01, 0x01, 0x00]) == nil)
  #expect(RX8900.Date(registers: [0x00, 0x00, 0x00, 0x01, 0x01, 0x13, 0x00]) == nil)
  #expect(RX8900.Date(registers: [0x00, 0x00]) == nil)
}

@Test func theFlagRegisterIsDecoded() {
  #expect(RX8900.Flags(0x02).timeLost && !RX8900.Flags(0x01).timeLost && RX8900.Flags(0x01).voltageDrop)
  #expect(RX8900.Flags(0x00).text == "0x00 -")
  #expect(RX8900.Flags(0x3B).text == "0x3b VDET VLF AF TF UF")
}

@Test func timeLostMakesItNoDate() {
  let r: [UInt8] = [0x00, 0x00, 0x00, 0x40, 0x01, 0x01, 0x00]
  #expect(RX8900.Date(registers: r, flags: RX8900.Flags(0)) != nil)
  #expect(RX8900.Date(registers: r, flags: RX8900.Flags(RX8900.vlf)) == nil)
  #expect(RX8900.why(registers: r, flags: RX8900.Flags(RX8900.vlf)) == "time lost (VLF)")
  #expect(RX8900.why(registers: r, flags: RX8900.Flags(0)) == nil)
}

@Test func leapYearsAndTheChipsYears() {
  #expect(RX8900.Date(year: 2000, month: 2, day: 29, hour: 0, minute: 0, second: 0) != nil)
  #expect(RX8900.Date(year: 2024, month: 2, day: 29, hour: 0, minute: 0, second: 0) != nil)
  #expect(RX8900.Date(year: 2023, month: 2, day: 29, hour: 0, minute: 0, second: 0) == nil)
  #expect(RX8900.Date(year: 2100, month: 1, day: 1, hour: 0, minute: 0, second: 0) == nil)
  #expect(RX8900.Date(year: 1999, month: 12, day: 31, hour: 0, minute: 0, second: 0) == nil)
  #expect(RX8900.Date(year: 2026, month: 4, day: 31, hour: 0, minute: 0, second: 0) == nil)
  for bad in ["2023-02-29T00:00:00Z", "2100-01-01T00:00:00Z", "2026-13-01T00:00:00Z", "2026-11-01 18:04:05Z", ""] {
    #expect(RX8900.Date(text: bad) == nil, "\(bad)")
  }
}
