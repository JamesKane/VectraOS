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

/// The Orange Pi RV2's CPU `hart` as devmgr gives it (D161): its
/// cluster's core clock, 2 or 6, and BUCK1.
func rv2CPU(_ hart: Int) -> String {
  "\(hart) /cpus/cpu@\(hart) opp clock k1-syscon-dt-system-controller@d4282800 \(hart < 4 ? 2 : 6) supply "
    + "p1-dt-pmic@41 buck1 points 614400000/950000 819200000/950000 1228800000/950000 1600000000/1050000"
}
let rv2CPU4 = rv2CPU(4)

@Test func aTreeCPUsLineGivesItsClockSupplyAndPoints() throws {
  let c = try #require(TreeCPUControl.parse(rv2CPU4))
  #expect(c.hart == 4 && c.clockService == "k1-syscon-dt-system-controller@d4282800" && c.clockID == 6)
  #expect(c.supply == TreeCPUControl.Supply(service: "p1-dt-pmic@41", regulator: "buck1"))
  #expect(c.points.map { $0.hz } == [614_400_000, 819_200_000, 1_228_800_000, 1_600_000_000])
  #expect(c.points.map { $0.microvolts } == [950_000, 950_000, 950_000, 1_050_000])
  #expect(TreeCPUControl.isTree(rv2CPU4) && !TreeCPUControl.isTree("0 \\_SB_.CPU0 no _CPC"))
  // No clock driver, or a supply whose driver doesn't run, or no points:
  // nothing to set. No supply at all: clocks alone.
  #expect(TreeCPUControl.parse("0 /cpus/cpu@0 opp clock - - supply - - points") == nil)
  #expect(TreeCPUControl.parse("0 /cpus/cpu@0 opp clock k 2 supply - buck1 points 1/1") == nil)
  #expect(TreeCPUControl.parse("0 /cpus/cpu@0 opp clock k 2 supply - - points") == nil)
  #expect(TreeCPUControl.parse("0 /cpus/cpu@0 opp clock k 2 supply - - points 1000/0")?.supply == nil)
  // Its supply's voltage, from p1's status.
  #expect(c.supply?.microvolts(status: "version 0x2\nbuck1 on 1050000 uV always-on\nbuck2 on 1000000 uV\n") == 1_050_000)
  #expect(c.supply?.microvolts(status: "buck1 unread\n") == nil)
}

@Test func aClocksCPUsMoveTogetherThroughItsPoints() throws {
  let cpus = (0..<8).compactMap { TreeCPUControl.parse(rv2CPU($0)) }
  #expect(cpus.count == 8)
  let domains = ClockDomain.group(cpus)
  #expect(domains.map { $0.harts } == [[0, 1, 2, 3], [4, 5, 6, 7]])
  #expect(domains.map { $0.cpu.clockID } == [2, 6])
  // A step's rate is as far from 614.4 MHz toward 1.6 GHz as the step is
  // toward 8, and the point the fastest at or below it.
  #expect((0...8).map { domains[0].point($0, of: Policy.steps).hz / 100_000 }
    == [6144, 6144, 8192, 8192, 8192, 12288, 12288, 12288, 16000])
}

@Test func aMoveRaisesTheVoltageFirstAndLowersItLast() throws {
  let cpus = [
    try #require(TreeCPUControl.parse(rv2CPU(0))),
    try #require(TreeCPUControl.parse(rv2CPU4)),
  ]
  let domains = ClockDomain.group(cpus)
  let k1 = "k1-syscon-dt-system-controller@d4282800", p1 = "p1-dt-pmic@41"
  // Down from 1.6 GHz: both clocks slowed, then BUCK1 to 0.95 V.
  #expect(ClockDomain.plan(domains, from: 8, to: 7, steps: 8) == [
    DriverWrite(k1, "clock 2 rate 1228800000"), DriverWrite(k1, "clock 6 rate 1228800000"),
    DriverWrite(p1, "voltage buck1 950000"),
  ])
  // Up to it: BUCK1 to 1.05 V first.
  #expect(ClockDomain.plan(domains, from: 7, to: 8, steps: 8) == [
    DriverWrite(p1, "voltage buck1 1050000"),
    DriverWrite(k1, "clock 2 rate 1600000000"), DriverWrite(k1, "clock 6 rate 1600000000"),
  ])
  // Between points at one voltage, clocks alone; a step that keeps the
  // point, nothing.
  #expect(ClockDomain.plan(domains, from: 7, to: 4, steps: 8) == [
    DriverWrite(k1, "clock 2 rate 819200000"), DriverWrite(k1, "clock 6 rate 819200000"),
  ])
  #expect(ClockDomain.plan(domains, from: 7, to: 6, steps: 8).isEmpty)
  // From firmware's, unknown: the most any point needs first, then the
  // clocks, then the step's; not lowered first where it reads higher.
  #expect(ClockDomain.plan(domains, from: nil, to: 3, steps: 8) == [
    DriverWrite(p1, "voltage buck1 1050000"),
    DriverWrite(k1, "clock 2 rate 819200000"), DriverWrite(k1, "clock 6 rate 819200000"),
    DriverWrite(p1, "voltage buck1 950000"),
  ])
  #expect(ClockDomain.plan(domains, from: nil, to: 8, steps: 8, present: { _ in 1_100_000 }) == [
    DriverWrite(k1, "clock 2 rate 1600000000"), DriverWrite(k1, "clock 6 rate 1600000000"),
    DriverWrite(p1, "voltage buck1 1050000"),
  ])
}
