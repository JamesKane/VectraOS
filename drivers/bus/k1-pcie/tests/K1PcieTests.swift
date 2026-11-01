// SPDX-License-Identifier: BSD-3-Clause

// The K1's PCIe hosts as bin/k1-pcie drives them, without the hardware:
// the iATU's writes, BARs sized and placed in the host's window, the
// root port's bridge window, the host's node read from the Orange Pi
// RV2's tree, and the bus it gives devmgr (DriverHost's HostedBus).

import DeviceTreeBus
import DriverHost
import Dtc
import Fdt
import Foundation
import K1Pcie
import Testing

@Test func anOutboundRegionIsProgrammedThenEnabled() {
  // PCIe 1's config window on bus 1's device 0, on a 5.20a core.
  let w = ATU.outbound(index: 0, .config0, cpu: 0x9F00_0000, size: 4096,
                       target: ATU.target(bus: 1, device: 0, function: 0), version: 0x3532_302A)
  #expect(w.map(\.offset) == [0x08, 0x0C, 0x10, 0x20, 0x14, 0x18, 0x00, 0x04])
  #expect(w.map(\.value) == [0x9F00_0000, 0, 0x9F00_0FFF, 0, 0x0100_0000, 0, 4, 0x8800_0000])
  // Region 1, memory, on a core before 4.60a: no upper limit, no DMA
  // bypass, and the digest bit.
  let m = ATU.outbound(index: 1, .memory, cpu: 0x9000_0000, size: 0x0F00_0000, target: 0x9000_0000, version: 0x3433_302A)
  #expect(m.first?.offset == 0x208 && m.count == 7)
  #expect(m.last! == (0x204, 0x8000_0000) && m[m.count - 2] == (0x200, 0x100))
  #expect(ATU.target(bus: 2, device: 3, function: 1) == 0x0219_0000)
}

@Test func barsAreSizedAndPlacedLargestFirst() throws {
  // An NVMe drive's: a 64-bit 16 KiB BAR 0 and a 32-bit 8 KiB BAR 4.
  let b0 = try #require(SizedBAR(index: 0, original: 0x4, mask: 0xFFFF_C004, upperMask: 0xFFFF_FFFF))
  #expect(b0 == SizedBAR(index: 0, size: 0x4000, wide: true))
  let b4 = try #require(SizedBAR(index: 4, original: 0, mask: 0xFFFF_E000))
  #expect(b4.size == 0x2000 && !b4.wide)
  #expect(SizedBAR(index: 1, original: 0, mask: 0) == nil)  // not there
  #expect(SizedBAR(index: 2, original: 1, mask: 0xFFFF_FF01) == nil)  // I/O
  let placed = try #require(Placement.place([b4, b0], in: (0x9000_0000, 0x9EFF_FFFF)))
  #expect(placed.map(\.index) == [0, 4] && placed.map(\.address) == [0x9000_0000, 0x9000_4000])
  // Each aligned to its size.
  let big = SizedBAR(index: 2, size: 0x10_0000, wide: false)
  let p = try #require(Placement.place([b4, big], in: (0x9000_1000, 0x9EFF_FFFF)))
  #expect(p.map(\.address) == [0x9010_0000, 0x9020_0000])
  #expect(Placement.place([big], in: (0x9000_0000, 0x9000_FFFF)) == nil)
}

@Test func theRootPortForwardsWhatWasPlaced() {
  #expect(Placement.bridgeWindow((0x9000_0000, 0x900F_FFFF)) == 0x9000_9000)
  #expect(Placement.bridgeWindow((0x9000_0000, 0x902F_FFFF)) == 0x9020_9000)
  #expect(Placement.bridgeWindow(nil) == 0x0000_FFF0)
  #expect(linkText(0x0022) == "5 GT/s x2" && linkText(0x0011) == "2.5 GT/s x1")
}

@Test func theBusRoundTripsAsDevmgrReadsIt() {
  var bus = HostedBus()
  bus.segment = 1
  bus.memory = [(0x9000_0000, 0x9EFF_FFFF)]
  bus.dmaBits = 31
  bus.msi = HostedBus.MSIBlock(registers: 0xCA40_0820, target: 0x7FF0_0000, gsi: 142)
  bus.functions = [HostedBus.Function(bus: 1, device: 0, function: 0, page: 0x9F00_0000)]
  #expect(bus.text == """
    segment 1
    memory 0x90000000 0x9effffff
    dma-bits 31
    msi dwc 0xca400820 0x7ff00000 142
    function 01:00.0 0x9f000000

    """)
  #expect(HostedBus(text: bus.text) == bus)
  // A line it can't read is left out.
  let partial = HostedBus(text: "function 01:20.0 0x9f000000\nfunction 01:00.0 0x9f000800\nmsi gic 1 2 3\nsegment 1\n")
  #expect(partial.functions.isEmpty && partial.msi == nil && partial.segment == 1)
  #expect(HostedBus(text: "").functions.isEmpty)
}

@Test(.enabled(if: clang != nil))
func theRV2sHostsReadTheirWindowsAndDomains() throws {
  let dtb = try compile("riscv/spacemit/k1-orangepi-rv2.dts")
  let all = try #require(dtb.span.bytes.withUnsafeBytes { raw -> [TreeDevice]? in
    guard let t = Fdt(RawSpan(_unsafeBytes: raw)) else { return nil }
    return DeviceTreeBus.devices(t, coherentByDefault: true)
  })
  let one = try #require(all.first { $0.path == "/soc/pcie-bus/pcie@ca400000" })
  let n1 = HostNode(node: one.properties)
  #expect(n1.domain == 1)
  #expect(n1.memory?.cpu == 0x9000_0000 && n1.memory?.pci == 0x9000_0000 && n1.memory?.size == 0x0F00_0000)
  // PCIe 2's has a prefetchable window first, which isn't taken.
  let two = try #require(all.first { $0.path == "/soc/pcie-bus/pcie@ca800000" })
  let n2 = HostNode(node: two.properties)
  #expect(n2.domain == 2 && n2.memory?.cpu == 0xB000_0000 && n2.memory?.size == 0x0700_0000)
  // Its registers in its reg's order: DBI, iATU, config window, link.
  #expect(one.ranges.map(\.base) == [0xCA40_0000, 0xCA70_0000, 0x9F00_0000, 0xC0C2_0000])
  #expect(one.ranges[0].size >= UInt64(DBI.size))
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
