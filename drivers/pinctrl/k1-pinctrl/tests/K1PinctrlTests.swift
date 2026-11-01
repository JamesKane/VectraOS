// SPDX-License-Identifier: BSD-3-Clause

// The K1's pin controller as bin/k1-pinctrl drives it: where each pin's
// register is, the bits a group's settings make, its states read from its
// node, every state of the Orange Pi RV2's tree, and the links a
// consumer turns on through its providers (DriverHost's ProvidedLink).

import DeviceTreeBus
import DriverHost
import Dtc
import Fdt
import Foundation
import K1Pinctrl
import Testing

@Test func eachPinHasItsRegister() {
  #expect(K1Pins.offset(0) == 0x4)
  #expect(K1Pins.offset(85) == 0x158)
  #expect(K1Pins.offset(86) == 0x1EC)
  #expect(K1Pins.offset(98) == 0x174)
  #expect(K1Pins.offset(103) == 0x178)
  #expect(K1Pins.offset(110) == 0x1D0)
  #expect(K1Pins.offset(127) == 0x24C)
  #expect(K1Pins.offset(128) == nil)
  // No two pins share one, and each is in the controller's registers.
  let offsets = (0..<K1Pins.count).compactMap { K1Pins.offset($0) }
  #expect(offsets.count == 128 && Set(offsets).count == 128 && offsets.allSatisfy { $0 < K1Pins.size })
}

@Test func settingsMakeTheRegistersBits() {
  // The Ethernet pins: a weak pull up, 21 mA at 1.8 V (code 2).
  #expect(PinConfig(bias: .up(strong: false), drive: 21).bits(0) == 0xC800)
  #expect(PinConfig(bias: .up(strong: true)).bits(0) == 0xC008)
  #expect(PinConfig(bias: .down, drive: 42).bits(0) == 0xB800)
  #expect(PinConfig(bias: .disable, drive: 50).bits(0) == 0x1800)
  // An SD pin's voltage is its group's: 19 mA at 3.3 V is code 1.
  #expect(PinConfig(drive: 19, power: 3300).bits(76) == 0x400)
  #expect(PinConfig(drive: 19, power: 1800).bits(76) == 0x800)
  #expect(PinConfig(drive: 19).bits(76) == nil)
  #expect(PinConfig(schmitt: 2, slew: 3).bits(0) == 0x0A80)
}

@Test func statesComeFromTheNode() throws {
  let states = PinState.states(node: """
    compatible "spacemit,k1-pinctrl"
    gmac0-cfg/gmac0-pins/pinmux <0x1 0x10001>
    gmac0-cfg/gmac0-pins/bias-pull-up <0x0>
    gmac0-cfg/gmac0-pins/drive-strength <0x15>
    uart0-cfg/uart0-pins/pinmux <0x440001>
    uart0-cfg/uart0-pins/bias-pull-up
    """)
  #expect(states.map(\.name) == ["gmac0-cfg", "uart0-cfg"])
  #expect(states[0].groups == [PinGroup(name: "gmac0-pins", pins: [(0, 1), (1, 1)],
                                        config: PinConfig(bias: .up(strong: false), drive: 21))])
  let writes = try states[0].writes()
  #expect(writes.map(\.offset) == [4, 8] && writes.allSatisfy { $0.value == 0xC801 })
  #expect(states[1].groups[0].config.bias == .up(strong: true))
  #expect(stateCommand("state gmac1-cfg") == "gmac1-cfg")
  #expect(stateCommand("state") == nil && stateCommand("set gmac1-cfg") == nil)
}

@Test func linksNameWhatTurnsThemOn() {
  let links = ProvidedLink.parse("""
    pinctrl default k1-pinctrl-dt-pinctrl@d401e000 /soc/pinctrl@d401e000/gmac1-cfg
    clock - k1-syscon-dt-system-controller@d4282800 38
    reset - k1-syscon-dt-system-controller@d4282800 36
    syscon spacemit,apmu k1-syscon-dt-system-controller@d4282800 1004
    supply vmmc - /soc/i2c@d401d800/pmic@41/regulators/ldo5
    pinctrl uhs k1-pinctrl-dt-pinctrl@d401e000 /soc/pinctrl@d401e000/mmc1-uhs-cfg
    """)
  #expect(links.count == 6)
  #expect(links[0] == ProvidedLink(kind: "pinctrl", name: "default", provider: "k1-pinctrl-dt-pinctrl@d401e000",
                                   node: "/soc/pinctrl@d401e000/gmac1-cfg"))
  #expect(links.map(\.enabling) == ["state gmac1-cfg", "clock 38 on", "reset 36 deassert", nil, "on", nil])
  #expect(links[4].provider == "" && links[4].name == "vmmc")
  #expect(links[3].cells == [1004])
}

@Test(.enabled(if: clang != nil))
func everyStateOfTheRV2Sets() throws {
  let dtb = try compile("riscv/spacemit/k1-orangepi-rv2.dts")
  let all = try #require(dtb.span.bytes.withUnsafeBytes { raw -> [TreeDevice]? in
    guard let t = Fdt(RawSpan(_unsafeBytes: raw)) else { return nil }
    return DeviceTreeBus.devices(t, coherentByDefault: true)
  })
  let pinctrl = try #require(all.first { $0.path == "/soc/pinctrl@d401e000" })
  let states = PinState.states(node: pinctrl.properties)
  #expect(states.count > 10)
  for s in states {
    #expect(throws: Never.self, "\(s.name)") { try s.writes() }
    #expect(s.groups.allSatisfy { !$0.pins.isEmpty }, "\(s.name)")
  }
  // EMAC 1's pins, 29 to 43, function 1, a weak pull up and 21 mA.
  let gmac1 = try #require(states.first { $0.name == "gmac1-cfg" })
  #expect(gmac1.groups[0].pins.map(\.pin) == Array(29...43))
  #expect(try gmac1.writes().allSatisfy { $0.value == 0xC801 })
  // Every state a device links to is one the controller has.
  for d in all {
    for l in d.links where l.kind == "pinctrl" {
      let name = String(l.target.split(separator: "/").last ?? "")
      #expect(states.contains { $0.name == name }, "\(d.path): \(name)")
    }
  }
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
