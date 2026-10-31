// SPDX-License-Identifier: BSD-3-Clause

// The K1 EMAC as bin/k1-emac drives it: its descriptors, its MDIO
// commands, a PHY's link from its registers, a Motorcomm PHY's delays, and
// what it reads from the Orange Pi RV2's tree, and what it asks the APMU.

import DeviceTreeBus
import Dtc
import Fdt
import DriverHost
import Foundation
import K1Emac
import Testing

@Test func descriptorsCarryTheirSizesAndMarks() {
  #expect(Descriptor.receive(size: 1536, last: false) == 0x600)
  #expect(Descriptor.receive(size: 1536, last: true) == 0x0400_0600)
  // First and last segment, interrupt on completion, 60 bytes.
  #expect(Descriptor.transmit(length: 60, last: false) == 0xE000_003C)
  #expect(Descriptor.transmit(length: 60, last: true) == 0xE400_003C)
}

@Test func aReceivedFrameIsWholeAndWithoutErrors() {
  let whole: UInt32 = 1 << 30 | 1 << 29
  // 64 bytes with the FCS: 60 without.
  #expect(Descriptor.received(whole | 64, limit: 1514) == 60)
  #expect(Descriptor.received(whole | 1518, limit: 1514) == 1514)
  #expect(Descriptor.received(whole | 1519, limit: 1514) == nil)
  #expect(Descriptor.received(1 << 30 | 64, limit: 1514) == nil)  // spans descriptors
  #expect(Descriptor.received(whole | 1 << 20 | 64, limit: 1514) == nil)  // CRC error
  #expect(Descriptor.received(whole | 17, limit: 1514) == nil)  // shorter than a header
}

@Test func mdioCommandsAndAddresses() {
  // PHY 1, register 2 (its id), read and started.
  #expect(mdioCommand(phy: 1, register: 2, read: true) == 0x8441)
  #expect(mdioCommand(phy: 1, register: 0, read: false) == 0x8001)
  #expect(addressWords([0xC0, 0x74, 0x2B, 0xFC, 0xD4, 0xE6]) == [0x74C0, 0xFC2B, 0xE6D4])
}

@Test func aPHYsRegistersSayTheLink() {
  let up: UInt16 = 0x796D  // linked, negotiated
  // Both ends advertise 1000 full.
  #expect(PHY.link(status: up, advertise: 0x1E1, partner: 0x45E1, control1000: 0x200, status1000: 0x3800)
    == LinkMode(mbps: 1000, fullDuplex: true))
  // A 100 Mb/s partner.
  #expect(PHY.link(status: up, advertise: 0x1E1, partner: 0x41E1, control1000: 0x200, status1000: 0)
    == LinkMode(mbps: 100, fullDuplex: true))
  #expect(PHY.link(status: up, advertise: 0x1E1, partner: 0x4021, control1000: 0x200, status1000: 0)
    == LinkMode(mbps: 10, fullDuplex: false))
  #expect(PHY.link(status: up & ~0x4, advertise: 0x1E1, partner: 0x45E1, control1000: 0x200, status1000: 0x3800) == nil)
  #expect(PHY.link(status: up & ~0x20, advertise: 0x1E1, partner: 0, control1000: 0x200, status1000: 0) == nil)
  // The MAC's global control: speed bits 0-1, full duplex bit 2.
  #expect(LinkMode(mbps: 1000, fullDuplex: true).control(0x1B) == 0x1E)
  #expect(LinkMode(mbps: 10, fullDuplex: false).control(0x7) == 0)
}

@Test func aMotorcommPHYsDelaysFollowTheMode() {
  let id = Motorcomm.setup(.rgmiiID, noSleep: true)
  #expect(id.map(\.register) == [0xA001, 0xA003, 0x27])
  #expect(id[0].mask == 0x100 && id[0].value == 0)
  #expect(id[1].mask == 0x3C0F && id[1].value == 0x340D)
  #expect(id[2].mask == 0x8000 && id[2].value == 0)
  #expect(Motorcomm.setup(.rgmii, noSleep: false).map(\.value) == [0, 0])
  #expect(Motorcomm.setup(.rgmiiTXID, noSleep: false)[1].value == 0xD)
}

@Test func theNodeGivesModeDelaysPHYAndAddress() throws {
  let c = try #require(NodeConfig(node: """
    compatible "spacemit,k1-emac"
    phy-mode "rgmii-id"
    tx-internal-delay-ps <0xfa>
    rx-internal-delay-ps <0x0>
    mac-address [00 00 00 00 00 00]
    local-mac-address [c0 74 2b fc d4 e7]
    mdio-bus/#address-cells <0x1>
    mdio-bus/phy@1/reg <0x1>
    mdio-bus/phy@1/motorcomm,auto-sleep-disabled
    """))
  #expect(c == NodeConfig(mode: .rgmiiID, txDelay: 16, rxDelay: 0, phy: 1, phyNoSleep: true,
                          mac: [0xC0, 0x74, 0x2B, 0xFC, 0xD4, 0xE7]))
  // No mode, a mode the MAC hasn't, a delay past its lines'.
  #expect(NodeConfig(node: "reg <0x0>") == nil)
  #expect(NodeConfig(node: "phy-mode \"sgmii\"") == nil)
  #expect(NodeConfig(node: "phy-mode \"rgmii\"\ntx-internal-delay-ps <0x1000>") == nil)
  // A zero or multicast address is none.
  #expect(NodeConfig(node: "phy-mode \"rmii\"\nmac-address [01 00 5e 00 00 01]")?.mac == nil)
}

@Test func theAPMUSetsTheInterface() {
  let apmu = "k1-syscon-dt-system-controller@d4282800"
  let links = ProvidedLink.parse("""
    clock - \(apmu) 37
    reset - \(apmu) 35
    syscon spacemit,apmu \(apmu) 996
    """)
  let config = NodeConfig(mode: .rgmiiID, txDelay: 16, rxDelay: 0)
  #expect(links.compactMap { $0.enabling ?? emacCommand($0, config) }
    == ["clock 37 on", "reset 35 deassert", "emac 0x3e4 rgmii 16 0"])
  #expect(emacCommand(links[2], NodeConfig(mode: .rmii)) == "emac 0x3e4 rmii 0 0")
  #expect(emacCommand(links[0], config) == nil)
}

@Test(.enabled(if: clang != nil))
func theRV2sEMACsReadTheirNodes() throws {
  let dtb = try compile("riscv/spacemit/k1-orangepi-rv2.dts")
  let all = try #require(dtb.span.bytes.withUnsafeBytes { raw -> [TreeDevice]? in
    guard let t = Fdt(RawSpan(_unsafeBytes: raw)) else { return nil }
    return DeviceTreeBus.devices(t, coherentByDefault: true)
  })
  let eth0 = try #require(all.first { $0.path == "/soc/network-bus/ethernet@cac80000" })
  let eth1 = try #require(all.first { $0.path == "/soc/network-bus/ethernet@cac81000" })
  // Both RGMII with the PHY's delays; EMAC 1's own transmit line 250 ps.
  #expect(NodeConfig(node: eth0.properties) == NodeConfig(mode: .rgmiiID, phy: 1, phyNoSleep: true))
  #expect(NodeConfig(node: eth1.properties) == NodeConfig(mode: .rgmiiID, txDelay: 16, phy: 1, phyNoSleep: true))
  #expect(eth1.links.first { $0.kind == "syscon" }?.cells == [0x3EC])
  // The K1's buses say their DMA isn't coherent.
  #expect(!eth0.coherent)
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
