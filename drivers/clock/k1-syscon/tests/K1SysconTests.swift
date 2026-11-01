// SPDX-License-Identifier: BSD-3-Clause

// The K1's clock and reset units as bin/k1-syscon drives them: its ctl's
// commands, the writes they make, and its tables against the Orange Pi
// RV2's tree, whose devices name their clocks and resets by these ids.

import DeviceTreeBus
import Dtc
import Fdt
import Foundation
import K1Syscon
import Testing

@Test func ctlLinesBecomeCommands() {
  #expect(Command("clock 37 on") == .clock(id: 37, on: true))
  #expect(Command("clock 0x25 off") == .clock(id: 37, on: false))
  #expect(Command("reset 35 assert") == .reset(id: 35, asserted: true))
  #expect(Command("reset 35 deassert") == .reset(id: 35, asserted: false))
  #expect(Command("reset 35 on") == nil)
  #expect(Command("clock x on") == nil)
  #expect(Command("clock 37") == nil)
  #expect(Command("reset 35 deassert")?.description == "reset 35 deassert")
}

@Test func commandsWriteTheirBits() throws {
  // EMAC 0 (APMU_EMAC0_CLK_RES_CTRL, 0x3e4): its bus clock bit 0, its
  // reset released by bit 1.
  #expect(try SysconUnit.apmu.updates(.clock(id: 37, on: true)) == [Update(register: 0x3E4, mask: 1, value: 1)])
  #expect(try SysconUnit.apmu.updates(.clock(id: 37, on: false)) == [Update(register: 0x3E4, mask: 1, value: 0)])
  #expect(try SysconUnit.apmu.updates(.reset(id: 35, asserted: true)) == [Update(register: 0x3E4, mask: 2, value: 0)])
  #expect(try SysconUnit.apmu.updates(.reset(id: 35, asserted: false)) == [Update(register: 0x3E4, mask: 2, value: 2)])
  // UART 0 (APBC_UART1_CLK_RST, 0): its function clock bit 1, bus clock
  // bit 0, and a reset bit, 2.
  #expect(try SysconUnit.apbc.updates(.clock(id: 0, on: true)) == [Update(register: 0, mask: 2, value: 2)])
  #expect(try SysconUnit.apbc.updates(.reset(id: 0, asserted: true)) == [Update(register: 0, mask: 4, value: 4)])
  // The APMU's AXI clock has no gate: on writes nothing, off is refused.
  #expect(try SysconUnit.apmu.updates(.clock(id: 27, on: true)).isEmpty)
  #expect(throws: SysconError.ungated) { try SysconUnit.apmu.updates(.clock(id: 27, on: false)) }
  #expect(throws: SysconError.noSuch) { try SysconUnit.apmu.updates(.clock(id: 999, on: true)) }
}

@Test func anEMACsInterfaceAndDelaysAreItsControlRegisters() throws {
  // The Orange Pi RV2's EMAC 1: RGMII, 250 ps more on its transmit clock
  // (16 steps of 15.6 ps).
  let c = try #require(Command("emac 0x3ec rgmii 16 0"))
  #expect(c == .emac(offset: 0x3EC, rgmii: true, tx: 16, rx: 0))
  #expect(c.description == "emac 0x3ec rgmii 16 0")
  #expect(try SysconUnit.apmu.updates(c) == [Update(register: 0x3EC, mask: 0x210C, value: 0x2004),
                                             Update(register: 0x3F0, mask: 0xFF31_FF31, value: 0x1001_0001)])
  #expect(try SysconUnit.apmu.updates(.emac(offset: 0x3E4, rgmii: false, tx: 0, rx: 0))
    == [Update(register: 0x3E4, mask: 0x210C, value: 0x2000), Update(register: 0x3E8, mask: 0xFF31_FF31, value: 0)])
  // Only a MAC's register, and only on the APMU; a code is a byte.
  #expect(throws: SysconError.noSuch) { try SysconUnit.apmu.updates(.emac(offset: 0x3E8, rgmii: true, tx: 0, rx: 0)) }
  #expect(throws: SysconError.noSuch) { try SysconUnit.apbc.updates(.emac(offset: 0x3E4, rgmii: true, tx: 0, rx: 0)) }
  #expect(Command("emac 0x3e4 rgmii 256 0") == nil)
  #expect(Command("emac 0x3e4 sgmii 0 0") == nil)
  let lines = SysconUnit.apmu.states { $0 == 0x3E4 ? 0x2007 : $0 == 0x3E8 ? 0x0A01_0501 : 0 }
  #expect(lines.contains("emac 0x3e4 rgmii tx 10 rx 5"))
  #expect(lines.contains("emac 0x3ec rmii tx 0 rx 0"))
}

@Test func aPCIeControllersBitsAreItsControlRegisters() throws {
  // PCIe 1's: PERST# asserted, then its soft reset in the register after.
  let c = try #require(Command("pcie 0x3d4 perst on"))
  #expect(c == .pcie(offset: 0x3D4, field: .perst, on: true))
  #expect(c.description == "pcie 0x3d4 perst on")
  #expect(try SysconUnit.apmu.updates(c) == [Update(register: 0x3D4, mask: 0x1000, value: 0x1000)])
  #expect(try SysconUnit.apmu.updates(.pcie(offset: 0x3DC, field: .softReset, on: false))
    == [Update(register: 0x3E0, mask: 1, value: 0)])
  #expect(try SysconUnit.apmu.updates(#require(Command("pcie 0x3cc rc on")))
    == [Update(register: 0x3CC, mask: 0x8000_0000, value: 0x8000_0000)])
  #expect(throws: SysconError.noSuch) { try SysconUnit.apmu.updates(.pcie(offset: 0x3D0, field: .ltssm, on: true)) }
  #expect(throws: SysconError.noSuch) { try SysconUnit.apbc.updates(.pcie(offset: 0x3D4, field: .ltssm, on: true)) }
  #expect(Command("pcie 0x3d4 link on") == nil)
  #expect(Command("pcie 0x3d4 ltssm") == nil)
  // The combo PHY to PCIe clears USB 3's bit.
  #expect(try SysconUnit.apmu.updates(#require(Command("combo pcie"))) == [Update(register: 0x110, mask: 8, value: 0)])
  #expect(try SysconUnit.apmu.updates(.combo(pcie: false)) == [Update(register: 0x110, mask: 8, value: 8)])
  #expect(throws: SysconError.noSuch) { try SysconUnit.apbc.updates(.combo(pcie: true)) }
  let lines = SysconUnit.apmu.states { $0 == 0x3D4 ? 0xC000_1000 : $0 == 0x3D8 ? 1 : $0 == 0x110 ? 8 : 0 }
  #expect(lines.contains("pcie 0x3d4 perst hold-phy rc soft-reset"))
  #expect(lines.contains("pcie 0x3cc -"))
  #expect(lines.contains("combo usb"))
}

@Test func anSDHCIsClockTakesAnExactRateFromPLL1() throws {
  #expect(Command("clock 11 rate 204800000") == .rate(id: 11, hz: 204_800_000))
  #expect(Command("clock 11 rate 204800000")?.description == "clock 11 rate 204800000")
  #expect(Command("clock 11 rate") == nil)
  // 409.6 MHz (PLL1 / 6, mux 0) halved: the divider's field 1; set with
  // the frequency-change bit, waited for.
  #expect(try SysconUnit.apmu.updates(.rate(id: 11, hz: 204_800_000))
    == [Update(register: 0x54, mask: 0xFE0, value: 0x900, settles: 0x800)])
  // 614.4 MHz is the second parent, undivided; 102.4 MHz is 409.6 / 4.
  #expect(try SysconUnit.apmu.updates(.rate(id: 12, hz: 614_400_000))
    == [Update(register: 0x58, mask: 0xFE0, value: 0x820, settles: 0x800)])
  #expect(try SysconUnit.apmu.updates(.rate(id: 13, hz: 102_400_000))
    == [Update(register: 0xE0, mask: 0xFE0, value: 0xB00, settles: 0x800)])
  #expect(throws: SysconError.noRate) { try SysconUnit.apmu.updates(.rate(id: 11, hz: 200_000_000)) }
  #expect(throws: SysconError.noSuch) { try SysconUnit.apmu.updates(.rate(id: 37, hz: 204_800_000)) }
  #expect(throws: SysconError.noSuch) { try SysconUnit.apbc.updates(.rate(id: 11, hz: 204_800_000)) }
  // What a register holds: mux 0, divider 2; a parent from PLL2 (mux 2)
  // is unknown.
  let lines = SysconUnit.apmu.states { $0 == 0x54 ? 0x110 : $0 == 0x58 ? 0x40 : 0 }
  #expect(lines.contains("rate 11 sdh0 204800000"))
  #expect(lines.contains("rate 12 sdh1 unknown"))
  #expect(lines.contains("rate 13 sdh2 409600000"))
}

@Test func statesAreReadFromTheRegisters() {
  // SDH0's register (0x54) with the AXI clock and its reset released.
  let lines = SysconUnit.apmu.states { $0 == 0x54 ? 0b1001 : 0 }
  #expect(lines.contains("clock 10 sdh_axi_aclk on"))
  #expect(lines.contains("clock 11 sdh0 off"))
  #expect(lines.contains("clock 27 pmua_aclk ungated"))
  #expect(lines.contains("reset 2 sdh_axi deasserted"))
  #expect(lines.contains("reset 3 sdh0 asserted"))
  #expect(SysconUnit(compatibles: [Array("spacemit,k1-syscon-apmu".utf8)]) == .apmu)
  #expect(SysconUnit(compatibles: [Array("x".utf8)]) == nil)
}

@Test func eachUnitsIdsAreItsOwnAndInItsRegisters() {
  for unit in [SysconUnit.apbc, .apmu] {
    let clocks = unit.clocks.map(\.id), resets = unit.resets.map(\.id)
    #expect(Set(clocks).count == clocks.count)
    #expect(Set(resets).count == resets.count)
    #expect(unit.clocks.allSatisfy { $0.register + 4 <= unit.size && $0.register % 4 == 0 })
    #expect(unit.resets.allSatisfy { $0.register + 4 <= unit.size && $0.assert | $0.deassert != 0 })
  }
}

@Test(.enabled(if: clang != nil))
func everyClockAndResetTheRV2NamesIsInTheTables() throws {
  let dtb = try compile("riscv/spacemit/k1-orangepi-rv2.dts")
  let all = try #require(dtb.span.bytes.withUnsafeBytes { raw -> [TreeDevice]? in
    guard let t = Fdt(RawSpan(_unsafeBytes: raw)) else { return nil }
    return DeviceTreeBus.devices(t, coherentByDefault: true)
  })
  let units = [("/soc/system-controller@d4015000", SysconUnit.apbc), ("/soc/system-controller@d4282800", .apmu)]
  var named = 0
  for d in all {
    for l in d.links {
      guard let unit = units.first(where: { $0.0 == l.provider })?.1, l.cells.count == 1 else { continue }
      named += 1
      if l.kind == "clock" {
        #expect(unit.clocks.contains { $0.id == l.cells[0] }, Comment(rawValue: "\(d.path): \(unit.name) clock \(l.cells[0])"))
      } else if l.kind == "reset" {
        #expect(unit.resets.contains { $0.id == l.cells[0] }, Comment(rawValue: "\(d.path): \(unit.name) reset \(l.cells[0])"))
      }
    }
  }
  #expect(named > 20)
}

// The RV2's tree, through the bundled clang's preprocessor, as CMake
// builds it.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

let clang: String? = {
  var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
  dirs.append("\(NSHomeDirectory())/.local/share/swiftly/toolchains/6.4.0/usr/bin")
  return dirs.map { "\($0)/clang" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}()

func compile(_ tree: String) throws -> [UInt8] {
  let dts = root.appendingPathComponent("firmware/dts").appendingPathComponent(tree)
  let out = FileManager.default.temporaryDirectory.appendingPathComponent("k1-\(UUID().uuidString).i")
  defer { try? FileManager.default.removeItem(at: out) }
  let p = Process()
  p.executableURL = URL(fileURLWithPath: clang!)
  p.arguments = ["-E", "-nostdinc", "-undef", "-D__DTS__", "-x", "assembler-with-cpp",
                 "-I", dts.deletingLastPathComponent().path, "-I", root.appendingPathComponent("firmware/dts/include").path,
                 dts.path, "-o", out.path]
  try p.run()
  p.waitUntilExit()
  try #require(p.terminationStatus == 0)
  return try DtsParser.parse(String(contentsOf: out, encoding: .utf8), file: tree).flatten()
}
