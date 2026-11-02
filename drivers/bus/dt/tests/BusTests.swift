// SPDX-License-Identifier: BSD-3-Clause

// The devicetree as a bus (D154): the Orange Pi RV2's own tree, as
// devmgr's devices, and the rules of a tree's buses and interrupts on
// small trees.

import DeviceTreeBus
import Dtc
import Fdt
import Foundation
import Testing

func devices(_ dtb: [UInt8], coherentByDefault: Bool = true) -> [TreeDevice]? {
  dtb.span.bytes.withUnsafeBytes { raw in
    guard let t = Fdt(RawSpan(_unsafeBytes: raw)) else { return nil }
    return DeviceTreeBus.devices(t, coherentByDefault: coherentByDefault)
  }
}

func dtb(_ source: String) throws -> [UInt8] {
  try DtsParser.parse("/dts-v1/;\n" + source, file: "test.dts").flatten()
}

/// A board's tree from firmware/dts, through the bundled clang's
/// preprocessor, as CMake builds it.
enum Boards {
  static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  static let clang: String? = {
    var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    dirs.append("\(NSHomeDirectory())/.local/share/swiftly/toolchains/6.4.0/usr/bin")
    return dirs.map { "\($0)/clang" }.first { FileManager.default.isExecutableFile(atPath: $0) }
  }()

  static func compile(_ tree: String) throws -> [UInt8] {
    let dts = root.appendingPathComponent("firmware/dts").appendingPathComponent(tree)
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("dt-\(UUID().uuidString).i")
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
}

@Test(.enabled(if: Boards.clang != nil))
func theRV2sDevicesAreItsTreesEnabledNodes() throws {
  let all = try #require(devices(try Boards.compile("riscv/spacemit/k1-orangepi-rv2.dts")))
  func device(_ path: String) -> TreeDevice? { all.first { $0.path == path } }

  // Its two EMACs: their registers, their PLIC sources, and the K1's DMA,
  // which its soc node says isn't coherent.
  let eth0 = try #require(device("/soc/network-bus/ethernet@cac80000"))
  #expect(eth0.name == "ethernet@cac80000")
  #expect(eth0.compatibles == ["spacemit,k1-emac"])
  #expect(eth0.ranges == [TreeDevice.Range(base: 0xcac8_0000, size: 0x420)])
  #expect(eth0.interrupts == [TreeDevice.Interrupt(gsi: 131, trigger: .levelHigh)])
  #expect(!eth0.coherent)
  // Its bus maps its first 2 GiB unchanged, and the rest elsewhere.
  #expect(eth0.dmaBits == 31)
  #expect(eth0.notes.isEmpty)
  #expect(device("/soc/network-bus/ethernet@cac81000")?.interrupts.map(\.gsi) == [133])

  // The SD card's and the eMMC's SDHCIs, the card's enabled by the board.
  let sd = try #require(device("/soc/storage-bus/mmc@d4280000"))
  #expect(sd.compatibles == ["spacemit,k1-sdhci"])
  #expect(sd.ranges == [TreeDevice.Range(base: 0xd428_0000, size: 0x200)])
  #expect(sd.interrupts == [TreeDevice.Interrupt(gsi: 99, trigger: .levelHigh)])
  #expect(device("/soc/storage-bus/mmc@d4281000")?.interrupts.map(\.gsi) == [101])

  // The console's UART, through its alias's bus.
  #expect(device("/soc/dma-bus/serial@d4017000")?.ranges == [TreeDevice.Range(base: 0xd401_7000, size: 0x100)])

  // A device on a PCIe host is its driver's; the hosts are devices.
  let pcie = try #require(device("/soc/pcie-bus/pcie@ca400000"))
  #expect(pcie.ranges.count == 4)
  #expect(pcie.interrupts.map(\.gsi) == [142])
  #expect(device("/soc/pcie-bus/pcie@ca400000/pcie@0") == nil)
  // Its root port's PHY and slot supply are its links, and its PHY's
  // calibration is the combo PHY's.
  #expect(pcie.links.contains(DeviceLink(kind: "phy", provider: "/soc/phy@c0c10000")))
  #expect(pcie.links.contains(DeviceLink(kind: "supply", name: "vpcie3v3", provider: "/regulator-pcie-vcc3v3")))
  #expect(pcie.links.contains { $0.kind == "syscon" && $0.provider == "/soc/system-controller@d4282800" && $0.cells == [0x3D4] })
  let phy = try #require(device("/soc/phy@c0c10000"))
  #expect(phy.links.contains(DeviceLink(kind: "phy", name: "calibration", provider: "/soc/phy@c0b10000")))
  #expect(phy.links.contains { $0.kind == "reset" && $0.name == "phy" && $0.cells == [30] })

  // What the kernel owns isn't a device, nor is what's disabled, nor what
  // another device's driver reads (the PHYs on an MDIO bus), nor a bus.
  #expect(device("/soc/interrupt-controller@e0000000") == nil)
  #expect(device("/soc/timer@e4000000") == nil)
  #expect(device("/soc/dma-bus/serial@d4017100") == nil)
  // The PMIC on i2c8 is a device (D158); an MDIO bus's PHYs aren't.
  #expect(all.filter { $0.path.hasPrefix("/soc/i2c@d401d800/") }.map(\.path) == ["/soc/i2c@d401d800/pmic@41"])
  #expect(!all.contains { $0.path.contains("/mdio") })
  #expect(device("/soc") == nil && device("/soc/network-bus") == nil)
  #expect(!all.contains { $0.path.hasPrefix("/cpus") || $0.path.hasPrefix("/reserved-memory") })

  // Root devices with no registers: the board's regulators and LEDs.
  #expect(device("/regulator-vcc-5v0")?.compatibles == ["regulator-fixed"])
  #expect(device("/regulator-vcc-5v0")?.ranges == [])

  // Every enabled device on a bus but an I2C one has its ranges, and
  // every interrupt the tree gives resolves to the PLIC.
  for d in all where d.path.hasPrefix("/soc/") {
    #expect(!d.ranges.isEmpty || d.links.contains { $0.kind == "i2c" }, "\(d.path) has no ranges")
    #expect(d.notes.isEmpty, "\(d.path): \(d.notes)")
  }
  #expect(Set(all.map(\.name)).count == all.count)
}

@Test func rangesAreTranslatedThroughEachBus() throws {
  let all = try #require(devices(try dtb("""
    / {
      #address-cells = <2>; #size-cells = <2>;
      bus@f0000000 {
        compatible = "simple-bus"; #address-cells = <1>; #size-cells = <1>;
        ranges = <0x0 0x0 0xf0000000 0x100000>, <0x200000 0x1 0x0 0x1000>;
        a@100 { compatible = "a"; reg = <0x100 0x10>, <0x200010 0x8>; };
        inner@1000 {
          compatible = "simple-bus"; #address-cells = <1>; #size-cells = <1>;
          ranges = <0x0 0x1000 0x100>;
          b@20 { compatible = "b"; reg = <0x20 0x4>, <0x200 0x4>; };
        };
        notbus { #address-cells = <1>; #size-cells = <0>; c@1 { compatible = "c"; reg = <1>; }; };
      };
      flat { compatible = "simple-bus"; #address-cells = <2>; #size-cells = <2>; ranges;
        d@40000000 { compatible = "d"; reg = <0 0x40000000 0 0x1000>; dma-coherent; };
      };
    };
    """)))
  #expect(all.map(\.path) == ["/bus@f0000000/a@100", "/bus@f0000000/inner@1000/b@20", "/flat/d@40000000"])
  #expect(all[0].ranges == [TreeDevice.Range(base: 0xf000_0100, size: 0x10), TreeDevice.Range(base: 0x1_0000_0010, size: 8)])
  // b's second range is past its bus's window: noted, not granted.
  #expect(all[1].ranges == [TreeDevice.Range(base: 0xf000_1020, size: 4)])
  #expect(all[1].notes == ["reg 1 not translated"])
  #expect(all[2].ranges == [TreeDevice.Range(base: 0x4000_0000, size: 0x1000)])
}

@Test func aBussDMARangesNarrowItsDevicesDMA() throws {
  let all = try #require(devices(try dtb("""
    / {
      #address-cells = <2>; #size-cells = <2>;
      outer { compatible = "simple-bus"; #address-cells = <2>; #size-cells = <2>; ranges;
        dma-ranges = <0 0x80000000 0 0 0 0x1000>, <0 0 0 0 0 0xc0000000>;
        a@1000 { compatible = "a"; reg = <0 0x1000 0 0x10>; };
        inner { compatible = "simple-bus"; #address-cells = <1>; #size-cells = <1>; ranges = <0 0 0 0x10000000>;
          dma-ranges = <0 0 0 0x10000000>;
          b@20 { compatible = "b"; reg = <0x20 0x4>; };
        };
      };
      shifted { compatible = "simple-bus"; #address-cells = <1>; #size-cells = <1>; ranges = <0 0 0 0x1000>;
        dma-ranges = <0 0 1 0 0x40000000>;
        c@10 { compatible = "c"; reg = <0x10 0x4>; };
      };
      d@2000 { compatible = "d"; reg = <0 0x2000 0 0x10>; };
    };
    """)))
  // 3 GiB from 0 at 0 (a second range elsewhere aside) rounds to 31 bits;
  // a bus inside it narrows it again; one that moves its addresses, and
  // a device on no bus, aren't narrowed.
  #expect(all.map(\.path) == ["/outer/a@1000", "/outer/inner/b@20", "/shifted/c@10", "/d@2000"])
  #expect(all.map(\.dmaBits) == [31, 28, 64, 64])
}

@Test func interruptsResolveToTheKernelsController() throws {
  let source = """
    / {
      #address-cells = <2>; #size-cells = <2>; interrupt-parent = <&gic>;
      gic: interrupt-controller@8000000 {
        compatible = "arm,gic-v3"; interrupt-controller; #interrupt-cells = <3>; #address-cells = <2>;
        reg = <0 0x8000000 0 0x10000>;
      };
      gpio: gpio@9000000 {
        compatible = "vendor,gpio"; reg = <0 0x9000000 0 0x1000>; interrupt-controller; #interrupt-cells = <2>;
        interrupts = <0 7 4>;
      };
      uart@9010000 { compatible = "arm,pl011"; reg = <0 0x9010000 0 0x1000>; interrupts = <0 1 4>; };
      timer-user@0 { compatible = "x,timer"; interrupts = <1 13 8>; };
      keys { compatible = "gpio-keys"; interrupts-extended = <&gpio 5 2>, <&gic 0 9 1>; };
      pcie@10000000 {
        compatible = "pci-host-ecam-generic"; reg = <0 0x10000000 0 0x10000000>;
        #address-cells = <3>; #size-cells = <2>; #interrupt-cells = <1>;
        interrupt-map-mask = <0x1800 0 0 7>;
        interrupt-map = <0x0000 0 0 1 &gic 0 0 0 3 4>, <0x0800 0 0 1 &gic 0 0 0 4 4>;
      };
      nexus-user { compatible = "x,behind"; reg = <0 0x100 0 0x10>; interrupt-parent = <&nexus>; interrupts = <1>; };
      nexus: nexus {
        #address-cells = <1>; #interrupt-cells = <1>; interrupt-map-mask = <0 7>;
        interrupt-map = <0 1 &gic 0 0 0 20 1>;
      };
    };
    """
  let all = try #require(devices(try dtb(source), coherentByDefault: false))
  func device(_ path: String) -> TreeDevice? { all.first { $0.path == path } }
  #expect(device("/interrupt-controller@8000000") == nil)
  #expect(device("/gpio@9000000")?.interrupts == [TreeDevice.Interrupt(gsi: 39, trigger: .levelHigh)])
  #expect(device("/uart@9010000")?.interrupts == [TreeDevice.Interrupt(gsi: 33, trigger: .levelHigh)])
  #expect(device("/uart@9010000")?.coherent == false)
  #expect(device("/timer-user@0")?.interrupts == [TreeDevice.Interrupt(gsi: 29, trigger: .levelLow)])
  // A GPIO block's interrupt is its driver's to give: a link to it.
  #expect(device("/keys")?.interrupts == [TreeDevice.Interrupt(gsi: 41, trigger: .edgeRising)])
  #expect(device("/keys")?.links == [DeviceLink(kind: "interrupt", provider: "/gpio@9000000", cells: [5, 2])])
  #expect(device("/keys")?.notes == [])
  #expect(device("/nexus-user")?.interrupts == [TreeDevice.Interrupt(gsi: 52, trigger: .edgeRising)])
  #expect(device("/pcie@10000000")?.interrupts == [])
}

@Test func iommusAndNamesAndStatus() throws {
  let all = try #require(devices(try dtb("""
    / {
      #address-cells = <1>; #size-cells = <1>;
      smmu: iommu@1000 { compatible = "arm,smmu-v3"; reg = <0x1000 0x100>; #iommu-cells = <1>; };
      a { compatible = "simple-bus"; ranges; #address-cells = <1>; #size-cells = <1>;
        dev@2000 { compatible = "x,dev", "x,generic"; reg = <0x2000 0x10>; iommus = <&smmu 0x42>; };
      };
      b { compatible = "simple-bus"; ranges; #address-cells = <1>; #size-cells = <1>;
        dev@2000 { compatible = "x,other"; reg = <0x2000 0x10>; };
        off@3000 { compatible = "x,off"; reg = <0x3000 0x10>; status = "disabled"; };
      };
      gone { compatible = "simple-bus"; status = "disabled"; ranges; x@0 { compatible = "x"; }; };
    };
    """)))
  #expect(all.map(\.path) == ["/iommu@1000", "/a/dev@2000", "/b/dev@2000"])
  #expect(all.map(\.name) == ["iommu@1000", "a.dev@2000", "b.dev@2000"])
  #expect(all[1].compatibles == ["x,dev", "x,generic"])
  #expect(all[1].iommus == [TreeDevice.IOMMU(unit: "/iommu@1000", id: [0x42])])
}

@Test(.enabled(if: Boards.clang != nil))
func theRV2sLinksNameItsSysconsCells() throws {
  let all = try #require(devices(try Boards.compile("riscv/spacemit/k1-orangepi-rv2.dts")))
  func device(_ path: String) -> TreeDevice? { all.first { $0.path == path } }
  let apmu = "/soc/system-controller@d4282800"
  #expect(device(apmu)?.compatibles == ["spacemit,k1-syscon-apmu"])

  // EMAC 0's bus clock and reset are the APMU's 37 and 35
  // (dt-bindings/clock/spacemit,k1-syscon.h), unnamed; its pins are
  // the pin controller's, by the state its node names.
  let eth0 = try #require(device("/soc/network-bus/ethernet@cac80000"))
  #expect(eth0.links.filter { $0.kind == "clock" } == [DeviceLink(kind: "clock", provider: apmu, cells: [37])])
  #expect(eth0.links.filter { $0.kind == "reset" } == [DeviceLink(kind: "reset", provider: apmu, cells: [35])])
  let pins = try #require(eth0.links.first { $0.kind == "pinctrl" })
  #expect(pins.name == "default" && pins.provider == "/soc/pinctrl@d401e000")
  #expect(pins.target.hasPrefix("/soc/pinctrl@d401e000/"))
  // Its control registers in the APMU, by their offset.
  #expect(eth0.links.filter { $0.kind == "syscon" }
    == [DeviceLink(kind: "syscon", name: "spacemit,apmu", provider: apmu, cells: [0x3E4])])
  // Its properties for its driver, its PHY's under its MDIO bus.
  let properties = eth0.properties.split(separator: "\n").map(String.init)
  for line in ["compatible \"spacemit,k1-emac\"", "reg <0x0 0xcac80000 0x0 0x420>", "phy-mode \"rgmii-id\"",
               "mac-address [00 00 00 00 00 00]", "tx-internal-delay-ps <0x0>", "mdio-bus/phy@1/reg <0x1>",
               "mdio-bus/phy@1/motorcomm,auto-sleep-disabled"] {
    #expect(properties.contains(line), "\(line)")
  }
  // Its MDIO bus's reset line is its own link: GPIO 110 (bank 3, pin 14,
  // active low) for EMAC 0, 115 (pin 19) for EMAC 1, their delays in its
  // properties.
  #expect(eth0.links.filter { $0.kind == "gpio" }
    == [DeviceLink(kind: "gpio", name: "mdio-reset", provider: "/soc/gpio@d4019000", cells: [3, 14, 1])])
  #expect(properties.contains("mdio-bus/reset-delay-us <0x2710>"))
  #expect(properties.contains("mdio-bus/reset-post-delay-us <0x186a0>"))
  let eth1 = try #require(device("/soc/network-bus/ethernet@cac81000"))
  #expect(eth1.links.filter { $0.kind == "gpio" }
    == [DeviceLink(kind: "gpio", name: "mdio-reset", provider: "/soc/gpio@d4019000", cells: [3, 19, 1])])

  // The SD card's clocks and resets by their names, its supplies by
  // their properties', its card detect a GPIO with its cells.
  let sd = try #require(device("/soc/storage-bus/mmc@d4280000"))
  #expect(sd.links.filter { $0.kind == "clock" } == [DeviceLink(kind: "clock", name: "core", provider: apmu, cells: [10]),
                                                     DeviceLink(kind: "clock", name: "io", provider: apmu, cells: [11])])
  #expect(sd.links.filter { $0.kind == "reset" }.map(\.name) == ["axi", "sdh"])
  #expect(sd.links.filter { $0.kind == "pinctrl" }.map(\.name) == ["default", "uhs"])
  #expect(sd.links.filter { $0.kind == "supply" }.map(\.name) == ["vmmc", "vqmmc"])
  // (GPIO 80: bank 2, pin 16, active low.)
  let cd = try #require(sd.links.first { $0.kind == "gpio" })
  #expect(cd.name == "cd" && cd.provider == "/soc/gpio@d4019000" && cd.cells == [2, 16, 1])
  // The pin controller names the APBC, whose keys unlock its pads' power
  // domains: a syscon link with no cells.
  let pinctrl = try #require(device("/soc/pinctrl@d401e000"))
  #expect(pinctrl.links.filter { $0.kind == "syscon" }
    == [DeviceLink(kind: "syscon", name: "spacemit,apbc", provider: "/soc/system-controller@d4015000")])

  // Every link the RV2's devices have names a node a device holds (a
  // supply on its PMIC, the I2C controller it sits on), but for its
  // oscillators, fixed clocks outside any bus, which no driver serves.
  for d in all {
    #expect(d.notes.isEmpty, "\(d.path): \(d.notes)")
    for l in d.links where l.provider.isEmpty && !l.target.hasPrefix("/clocks/") { Issue.record("\(d.path): \(l.kind) \(l.target) has no device") }
  }
}

@Test func linksNameTheirProvidersAndCells() throws {
  let all = try #require(devices(try dtb("""
    / {
      #address-cells = <1>; #size-cells = <1>;
      osc: osc { compatible = "fixed-clock"; #clock-cells = <0>; };
      cru: clock-controller@1000 { compatible = "x,cru"; reg = <0x1000 0x100>; #clock-cells = <1>; #reset-cells = <2>; };
      pd: power@2000 { compatible = "x,pmu"; reg = <0x2000 0x100>; #power-domain-cells = <1>; };
      pinctrl@3000 { compatible = "x,pinctrl"; reg = <0x3000 0x100>;
        uart_pins: uart { pins { pinmux = <1>; }; };
      };
      vdd: regulator { compatible = "regulator-fixed"; };
      gpio: gpio@4000 { compatible = "x,gpio"; reg = <0x4000 0x100>; #gpio-cells = <2>; };
      uart@5000 {
        compatible = "x,uart"; reg = <0x5000 0x100>;
        clocks = <&osc>, <&cru 7>; clock-names = "ref", "bus";
        resets = <&cru 3 1>;
        power-domains = <&pd 4>;
        pinctrl-names = "default"; pinctrl-0 = <&uart_pins>;
        vcc-supply = <&vdd>;
        enable-gpios = <&gpio 9 0>;
        bad-supply = <0x99>;
      };
      ethernet@6000 {
        compatible = "x,mac"; reg = <0x6000 0x100>;
        mdio {
          reset-gpios = <&gpio 10 1>;
          phy@1 { reg = <1>; reset-gpios = <&gpio 11 1>; };
          phy@2 { reg = <2>; reset-gpios = <&gpio 12 1>; status = "disabled"; };
        };
        leds { reset-gpios = <&gpio 13 1>; };
      };
    };
    """)))
  // An MDIO bus's reset line and its enabled PHYs' are the MAC's; another
  // child's isn't.
  let mac = try #require(all.first { $0.path == "/ethernet@6000" })
  #expect(mac.links == [
    DeviceLink(kind: "gpio", name: "mdio-reset", provider: "/gpio@4000", cells: [10, 1]),
    DeviceLink(kind: "gpio", name: "phy-reset", provider: "/gpio@4000", cells: [11, 1]),
  ])
  let uart = try #require(all.first { $0.path == "/uart@5000" })
  #expect(uart.links == [
    DeviceLink(kind: "clock", name: "ref", provider: "/osc"),
    DeviceLink(kind: "clock", name: "bus", provider: "/clock-controller@1000", cells: [7]),
    DeviceLink(kind: "reset", provider: "/clock-controller@1000", cells: [3, 1]),
    DeviceLink(kind: "power-domain", provider: "/power@2000", cells: [4]),
    DeviceLink(kind: "pinctrl", name: "default", provider: "/pinctrl@3000", target: "/pinctrl@3000/uart"),
    DeviceLink(kind: "supply", name: "vcc", provider: "/regulator"),
    DeviceLink(kind: "gpio", name: "enable", provider: "/gpio@4000", cells: [9, 0]),
  ])
  #expect(uart.notes == ["bad-supply names no node"])
}

// The RV2's tree as it boots (D157): upstream's, and the vendor's EHCI
// controllers and their PHYs, which upstream doesn't describe.
@Test(.enabled(if: Boards.clang != nil))
func theRV2sBoardFileAddsTheVendorsEHCIs() throws {
  let all = try #require(devices(try Boards.compile("vectraos/spacemit/k1-orangepi-rv2.dts")))
  func device(_ path: String) -> TreeDevice? { all.first { $0.path == path } }
  // Upstream's devices are all still there.
  #expect(device("/soc/storage-bus/usb@c0a00000")?.compatibles == ["spacemit,k1-dwc3"])
  let ehci = try #require(device("/soc/storage-bus/ehci@c0900100"))
  #expect(ehci.compatibles == ["ky,mv-ehci"])
  #expect(ehci.ranges == [TreeDevice.Range(base: 0xc090_0100, size: 0x4000), TreeDevice.Range(base: 0xd428_287c, size: 4)])
  #expect(ehci.interrupts.map(\.gsi) == [105, 106])
  #expect(ehci.dmaBits == 31 && !ehci.coherent)
  #expect(ehci.links.contains(DeviceLink(kind: "phy", name: "usb-phy", provider: "/soc/storage-bus/usbphy@c0940000")))
  #expect(ehci.links.contains(DeviceLink(kind: "supply", name: "vbus", provider: "/regulator-vbus-usb0")))
  #expect(ehci.links.contains { $0.kind == "clock" && $0.cells == [15] })
  #expect(ehci.links.contains { $0.kind == "reset" && $0.cells == [7] })
  #expect(ehci.notes.isEmpty)
  let ehci1 = try #require(device("/soc/storage-bus/ehci1@c0980100"))
  #expect(ehci1.links.contains(DeviceLink(kind: "phy", name: "usb-phy", provider: "/soc/storage-bus/usbphy1@c09c0000")))
  #expect(ehci1.links.contains(DeviceLink(kind: "supply", name: "vbus", provider: "/regulator-vcc5v0-usb30")))
  #expect(device("/soc/storage-bus/usbphy1@c09c0000")?.compatibles == ["ky,usb2-phy"])
}

// D158: an I2C controller's children are devices, linked to it by their
// address; the RV2's PMIC on i2c8, and the SD card's supplies its.
@Test(.enabled(if: Boards.clang != nil))
func anI2CControllersChildrenAreDevices() throws {
  let all = try #require(devices(try Boards.compile("vectraos/spacemit/k1-orangepi-rv2.dts")))
  func device(_ path: String) -> TreeDevice? { all.first { $0.path == path } }
  let i2c8 = "/soc/i2c@d401d800"
  #expect(device(i2c8)?.compatibles == ["spacemit,k1-i2c"])
  let pmic = try #require(device(i2c8 + "/pmic@41"))
  #expect(pmic.compatibles == ["spacemit,p1"])
  #expect(pmic.ranges.isEmpty)
  #expect(pmic.interrupts.map(\.gsi) == [64])
  #expect(pmic.links.first == DeviceLink(kind: "i2c", provider: i2c8, cells: [0x41]))
  #expect(pmic.notes.isEmpty)
  // A supply under it is the PMIC's to provide.
  let sd = try #require(device("/soc/storage-bus/mmc@d4280000"))
  #expect(sd.links.contains(DeviceLink(kind: "supply", name: "vqmmc", provider: i2c8 + "/pmic@41",
                                       target: i2c8 + "/pmic@41/regulators/aldo1")))
  #expect(DeviceTreeBus.isI2C("i2c@d401d800") && DeviceTreeBus.isI2C("i2c") && !DeviceTreeBus.isI2C("i2cx@1"))
}
