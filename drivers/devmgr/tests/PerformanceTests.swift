// SPDX-License-Identifier: BSD-3-Clause

// What devmgr's `cpus` and `thermal` files make of _CPC, _PSD and a
// thermal zone's methods: the Orange Pi 6 Plus's CPU0, as its DSDT has it.

import DevMgr
import TDACPI
import Testing

/// A Generic Register Descriptor and an end tag, as a _CPC buffer holds one.
func register(space: UInt8, width: UInt8, access: UInt8, address: UInt64) -> Datum {
  var b: [UInt8] = [0x82, 0x0C, 0x00, space, width, 0, access]
  for i in 0..<8 { b.append(UInt8(truncatingIfNeeded: address >> (8 * UInt64(i)))) }
  return .buffer(BufferObject(b + [0x79, 0x00]))
}

@Test func theSky1sCPCGivesItsLevelsAndDesiredRegister() {
  let null = register(space: 0, width: 0, access: 0, address: 0)
  let elements: [Datum] = [
    .integer(0x17), .integer(3), .integer(0x2000), .integer(0x2000), .integer(0x9D8), .integer(0x9D8),
    null, register(space: 0, width: 32, access: 3, address: 0x0659_009C), null, null, null, null, .integer(0),
    register(space: 0x7F, width: 64, access: 4, address: 1), register(space: 0x7F, width: 64, access: 4, address: 0),
    null, null, .integer(0), null, null, .integer(0x3E8), .integer(0x320), .integer(0xA28),
  ]
  let cpc = CPC.decode(.package(PackageObject(elements)))
  #expect(cpc == CPC(highest: 8192, nominal: 8192, lowestNonlinear: 2520, lowest: 2520,
                     desired: CPCRegister(space: 0, bitWidth: 32, bitOffset: 0, address: 0x0659_009C),
                     lowestMHz: 800, nominalMHz: 2600))
  let psd = PSD.decode(.package(PackageObject([.package(PackageObject([.integer(5), .integer(0), .integer(4),
                                                                        .integer(0xFD), .integer(2)]))])))
  #expect(psd == PSD(domain: 4, coordination: 0xFD, processors: 2))
  #expect(cpc?.line(uid: 0, path: "\\_SB_.C000.C001.CPU0", domain: psd)
    == "0 \\_SB_.C000.C001.CPU0 perf 2520 2520 8192 8192 mhz 800 2600 desired 0 0x659009c 32 0 domain 4 253 2")
  // Too short a package, or levels upside down: none.
  #expect(CPC.decode(.package(PackageObject([.integer(0x17), .integer(3)]))) == nil)
}

@Test func aZoneReadsInTenthsOfAKelvin() {
  // _TMP's C2DK: 45 °C is 450 + 2732.
  #expect(ZoneReading.kelvin(.integer(0x0AAC + 450)) == 3182)
  #expect(ZoneReading.kelvin(.integer(0xFFFF_FFFF_FFFF_FFFF)) == nil)  // Ones: the sensor failed
  #expect(ZoneReading.kelvin(nil) == nil)
  let z = ZoneReading(path: "\\_SB_.TZVU", temperature: 3182, passive: 0x0DFE, critical: 0x0E80, polling: 50)
  #expect(z.line == "\\_SB_.TZVU 3182 passive 3582 critical 3712 polling 50")
}
