// SPDX-License-Identifier: BSD-3-Clause

// The power service's policy: devmgr's lines as it reads them, the levels
// and clocks of the Orange Pi 6 Plus's CPU0, and the thermal steps, the
// critical power-off among them.

import PowerPolicy
import Testing

@Test func aCPUsLineGivesItsLevelsAndRegister() {
  let c = CPUControl.parse("0 \\_SB_.C000.C001.CPU0 perf 2520 2520 8192 8192 mhz 800 2600 desired 0 0x659009c 32 0 domain 4 253 2")
  #expect(c?.address == 0x0659_009C && c?.bitWidth == 32 && c?.domain == 4)
  #expect(c?.level(0, of: 8) == 2520 && c?.level(8, of: 8) == 8192 && c?.level(4, of: 8) == 5356)
  #expect(c?.megahertz(8192) == 2600 && c?.megahertz(2520) == 800)
  // A register in another space (PCC, FFixedHW) isn't written.
  #expect(CPUControl.parse("1 \\_SB_.CPU1 perf 10 10 100 100 mhz 0 0 desired 10 0x4 32 0")?.address == nil)
  #expect(CPUControl.parse("2 \\_SB_.CPU2 no _CPC") == nil)
}

func zone(_ celsius: Int?, passive: UInt32? = 3582, critical: UInt32? = 3712) -> Zone {
  Zone(path: "\\_SB_.TZVU", temperature: celsius.map { UInt32($0 * 10 + 2732) }, passive: passive, critical: critical,
       polling: 50)
}

@Test func theStepFollowsThePassiveTrip() {
  #expect(Zone.parse("\\_SB_.TZVU 3182 passive 3582 critical 3712 polling 50") == zone(45))
  #expect(Zone.parse("\\_SB_.TZVU - passive - critical - polling 0")?.temperature == nil)
  var p = Policy()
  #expect(p.next([zone(45)]) == .stay && p.step == Policy.steps)
  // At 85 C, its passive trip: a step down each reading while it stays.
  #expect(p.next([zone(45), zone(85)]) == .step(7))
  #expect(p.next([zone(86)]) == .step(6))
  // Below the trip but within 5 C of it: held.
  #expect(p.next([zone(82)]) == .stay)
  // Clear of it: a step back up each reading.
  #expect(p.next([zone(79)]) == .step(7))
  #expect(p.next([zone(70)]) == .step(8))
  #expect(p.next([zone(70)]) == .stay)
  // Never below lowest.
  for _ in 0..<12 { _ = p.next([zone(90)]) }
  #expect(p.step == 0)
  #expect(Policy.period([zone(45)]) == 10)
}

@Test func theCriticalTripPowersOffAndNoReadingIsLowest() {
  var p = Policy()
  #expect(p.next([zone(45), zone(98)]) == .powerOff("\\_SB_.TZVU"))
  #expect(p.reason == "\\_SB_.TZVU at 98.0 C, its critical trip 98.0 C")
  // Zones that can't be read: lowest, until one can.
  var q = Policy()
  #expect(q.next([zone(nil), zone(nil)]) == .step(0))
  #expect(q.next([zone(60)]) == .step(1))
  // No zones at all (QEMU, a PC whose firmware cools it): highest.
  var r = Policy()
  #expect(r.next([]) == .stay && r.step == Policy.steps)
}
