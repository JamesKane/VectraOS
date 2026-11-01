// SPDX-License-Identifier: BSD-3-Clause

// A fixed regulator as bin/regulator-fixed reads it: its node, the GPIO
// command for on and off by its polarity, and the Orange Pi RV2's PCIe
// slots' supply, linked to the K1's GPIO 116 and to its own supply.

import DeviceTreeBus
import Dtc
import Fdt
import FixedRegulator
import Foundation
import Testing

@Test func itsNodeSaysItsVoltageAndPolarity() {
  let r = FixedRegulator(node: """
    compatible "regulator-fixed"
    enable-active-high
    gpios <0x1f 0x3 0x14 0x0>
    regulator-name "pcie_vcc3v3"
    regulator-min-microvolt <0x325aa0>
    regulator-max-microvolt <0x325aa0>
    startup-delay-us <0x64>
    """)
  #expect(r.name == "pcie_vcc3v3" && r.microvolts == 3_300_000 && r.activeHigh && r.startupDelay == 100)
  #expect(!r.alwaysOn && !r.bootOn)
  #expect(r.gpioCommand([3, 20, 0], on: true) == "gpio 3 20 0 on")
  #expect(r.gpioCommand([3, 20, 0], on: false) == "gpio 3 20 0 off")
  // Without enable-active-high it is on when its GPIO is low, whatever
  // the specifier's flags.
  let low = FixedRegulator(node: "regulator-always-on\nregulator-boot-on\n")
  #expect(low.alwaysOn && low.bootOn && !low.activeHigh)
  #expect(low.gpioCommand([3, 20, 0], on: true) == "gpio 3 20 0 off")
  #expect(low.gpioCommand([3, 20, 1], on: true) == "gpio 3 20 0 off")
  #expect(low.gpioCommand([], on: true) == nil)
}

@Test(.enabled(if: clang != nil))
func theRV2sPCIeSupplyIsGPIO116() throws {
  let dtb = try compile("riscv/spacemit/k1-orangepi-rv2.dts")
  let all = try #require(dtb.span.bytes.withUnsafeBytes { raw -> [TreeDevice]? in
    guard let t = Fdt(RawSpan(_unsafeBytes: raw)) else { return nil }
    return DeviceTreeBus.devices(t, coherentByDefault: true)
  })
  let supply = try #require(all.first { $0.path == "/regulator-pcie-vcc3v3" })
  let r = FixedRegulator(node: supply.properties)
  #expect(r.name == "pcie_vcc3v3" && r.microvolts == 3_300_000 && r.activeHigh)
  let gpio = try #require(supply.links.first { $0.kind == "gpio" })
  #expect(gpio.provider == "/soc/gpio@d4019000" && gpio.cells == [3, 20, 0])
  #expect(r.gpioCommand(gpio.cells, on: true) == "gpio 3 20 0 on")
  #expect(supply.links.contains { $0.kind == "supply" && $0.name == "vin" && $0.provider == "/regulator-vcc-5v0" })
  let input = try #require(all.first { $0.path == "/regulator-vcc-5v0" })
  #expect(FixedRegulator(node: input.properties).alwaysOn)
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
