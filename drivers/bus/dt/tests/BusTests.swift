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

  // What the kernel owns isn't a device, nor is what's disabled, nor what
  // another device's driver reads (the PMIC on an I2C bus, the PHYs on
  // an MDIO bus), nor a bus.
  #expect(device("/soc/interrupt-controller@e0000000") == nil)
  #expect(device("/soc/timer@e4000000") == nil)
  #expect(device("/soc/dma-bus/serial@d4017100") == nil)
  #expect(!all.contains { $0.path.hasPrefix("/soc/i2c@d401d800/") })
  #expect(device("/soc") == nil && device("/soc/network-bus") == nil)
  #expect(!all.contains { $0.path.hasPrefix("/cpus") || $0.path.hasPrefix("/reserved-memory") })

  // Root devices with no registers: the board's regulators and LEDs.
  #expect(device("/regulator-vcc-5v0")?.compatibles == ["regulator-fixed"])
  #expect(device("/regulator-vcc-5v0")?.ranges == [])

  // Every enabled device on a bus has its ranges, and every interrupt
  // the tree gives resolves to the PLIC.
  for d in all where d.path.hasPrefix("/soc/") {
    #expect(!d.ranges.isEmpty, "\(d.path) has no ranges")
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
  // A GPIO block's interrupt is its driver's to give (a provider's).
  #expect(device("/keys")?.interrupts == [TreeDevice.Interrupt(gsi: 41, trigger: .edgeRising)])
  #expect(device("/keys")?.notes == ["interrupt 5 on /gpio@9000000: a provider's"])
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
