// SPDX-License-Identifier: BSD-3-Clause

// The SpacemiT P1 PMIC as bin/p1 reads it: its regulators' registers and
// voltage codes, its RTC's date, and the regulators its node names.

import P1
import Testing

@Test func regulatorsHaveTheirRegistersAndCodes() {
  #expect(P1.regulators.count == 17)
  let buck4 = P1.regulator("buck4")!, aldo1 = P1.regulator("aldo1")!, dldo7 = P1.regulator("dldo7")!
  #expect(buck4.control == 0x50 && buck4.voltage == 0x51)
  #expect(aldo1.control == 0x5B && aldo1.voltage == 0x5C && dldo7.control == 0x79)
  #expect(buck4.microvolts(0) == 500_000 && buck4.microvolts(0xAA) == 1_350_000)
  #expect(buck4.microvolts(0xAB) == 1_375_000 && buck4.microvolts(0xFF) == 3_475_000)
  #expect(buck4.code(3_300_000) == 0xAB + 77 && buck4.code(1_800_000) == 0xAB + 17 && buck4.code(1_351_000) == nil)
  #expect(aldo1.microvolts(0x0B) == 500_000 && aldo1.microvolts(0x7F) == 3_400_000)
  #expect(aldo1.code(1_800_000) == 0x0B + 52 && aldo1.code(3_300_000) == 0x0B + 112)
  #expect(aldo1.microvolts(aldo1.code(3_300_000)!) == 3_300_000)
  #expect(P1.regulator("buck7") == nil)
}

@Test func theRTCsCountsAreADate() {
  // 2026-11-01 18:04:05: the day and month from 0, the year from 2000.
  let d = P1.Date(counts: [5, 4, 18, 0, 10, 26])
  #expect(d == P1.Date(year: 2026, month: 11, day: 1, hour: 18, minute: 4, second: 5))
  #expect(d?.text == "2026-11-01T18:04:05Z")
  #expect(P1.Date(counts: [0, 0, 25, 0, 0, 0]) == nil && P1.Date(counts: [1, 2]) == nil)
}

@Test func theNodeNamesItsRegulators() {
  let named = P1.named(node: """
    compatible "spacemit,p1"
    reg <0x41>
    regulators/buck1/regulator-always-on
    regulators/buck4/regulator-name "buck4"
    regulators/buck4/regulator-always-on
    regulators/aldo1/regulator-boot-on
    regulators/foo/bar
    """)
  #expect(named.map(\.name) == ["buck1", "buck4", "aldo1"])
  #expect(named.map(\.alwaysOn) == [true, true, false])
}

@Test func aDateIsReadFromTextAndWrittenAsCounts() {
  let d = P1.Date(text: "2026-11-01T18:04:05Z")
  #expect(d == P1.Date(year: 2026, month: 11, day: 1, hour: 18, minute: 4, second: 5))
  #expect(d?.counts == [5, 4, 18, 0, 10, 26])
  #expect(P1.Date(counts: d!.counts) == d && P1.Date(text: "2026-11-01T18:04:05\n") == d)
  for bad in ["2026-13-01T00:00:00Z", "1999-01-01T00:00:00Z", "2064-01-01T00:00:00Z", "2026-11-01 18:04:05Z",
              "2026-11-1T18:04:05Z", ""] {
    #expect(P1.Date(text: bad) == nil, "\(bad)")
  }
}

@Test func theNodeGivesEachRegulatorsVoltageRange() {
  let node = """
    regulators/aldo1/regulator-min-microvolt <0x7a120>
    regulators/aldo1/regulator-max-microvolt <0x33e140>
    regulators/aldo1/regulator-boot-on
    regulators/aldo10/regulator-min-microvolt <0x1>
    regulators/buck1/regulator-max-microvolt <0x100590>
    """
  #expect(P1.range(node: node, "aldo1") == 500_000...3_400_000)
  #expect(P1.range(node: node, "buck1") == nil && P1.range(node: node, "dldo1") == nil)
  #expect(P1.range(node: node, "aldo1")!.contains(1_800_000))
}
