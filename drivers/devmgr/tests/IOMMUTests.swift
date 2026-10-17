// SPDX-License-Identifier: BSD-3-Clause

// The machine's IOMMUs as devmgr names them to the kernel (D74): from
// QEMU's tables (q35's DMAR and IVRS, arm64 virt's IORT with SMMUv3s) and
// from tables built here for what QEMU's lack (an INCLUDE_PCI_ALL unit
// beside another, reserved memory, a PCIe-based RISC-V IOMMU); and a
// platform device's _CRS as devmgr grants it.

import DevMgr
import Foundation
import PCI
import Sys
import TDACPI
import Testing

func corpusTable(_ machine: String, _ file: String) -> Table? {
  let path = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../.cache/acpi/\(machine)/\(file)")
  guard let bytes = try? Data(contentsOf: path) else { return nil }
  return try? Table(Array(bytes))
}

/// A table with `signature` and `body` after its header, its length and
/// checksum filled in.
func table(_ signature: String, _ body: [UInt8]) -> Table {
  var b = Array(signature.utf8) + [UInt8](repeating: 0, count: 32) + body
  let length = UInt32(b.count)
  for i in 0..<4 { b[4 + i] = UInt8(truncatingIfNeeded: length >> (8 * UInt32(i))) }
  b[9] = 0 &- b.reduce(0, &+)
  return try! Table(b)
}

func le(_ v: UInt64, _ bytes: Int) -> [UInt8] { (0..<bytes).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }

/// A DMAR device scope: an endpoint one hop from `bus`.
func endpoint(bus: UInt8, device: UInt8, function: UInt8) -> [UInt8] { [1, 8, 0, 0, 0, bus, device, function] }

@Test func q35sDMARListsItsEndpoints() throws {
  guard let t = corpusTable("qemu-x86-q35", "DMAR.dmar") else { return }  // no corpus (vx acpi fetch-qemu)
  let units = IOMMUs.units(TableSet([t]), functions: [])
  #expect(units.count == 1 && units[0].type == .intel && units[0].registerBase == 0xFED9_0000)
  #expect(units[0].name == "VT-d fed90000")
  // Not the whole segment: its five endpoints (the IOAPIC's scope is the
  // kernel's own business), one hop each from bus 0, no reserved memory.
  let d = units[0].descriptor
  #expect(Array(d[0..<16]) == le(0xFED9_0000, 8) + [0, 0, 0, 40, 0, 0, 0, 0])
  let scopes = stride(from: 16, to: d.count, by: 8).map { Array(d[$0..<$0 + 8]) }
  #expect(scopes.map { $0[3] } == [0x00, 0x08, 0xF8, 0xFA, 0xFB])
  #expect(scopes.allSatisfy { $0[0] == 0 && $0[1] == 0 && $0[2] == 1 })
}

@Test func anIncludeAllUnitIsTheSegmentLessTheOthers() throws {
  // Unit A lists 00:02.0; unit B (INCLUDE_PCI_ALL) takes the rest. The
  // RMRR names 00:02.0 and 00:03.0: one each.
  let a = le(0, 2) + le(16 + 8, 2) + [0, 0] + le(0, 2) + le(0xFED9_0000, 8) + endpoint(bus: 0, device: 2, function: 0)
  let b = le(0, 2) + le(16, 2) + [1, 0] + le(0, 2) + le(0xFED9_1000, 8)
  let rmrr = le(1, 2) + le(24 + 16, 2) + le(0, 2) + le(0, 2) + le(0x7F00_0000, 8) + le(0x7F00_FFFF, 8)
    + endpoint(bus: 0, device: 2, function: 0) + endpoint(bus: 0, device: 3, function: 0)
  let dmar = table("DMAR", [38, 1] + [UInt8](repeating: 0, count: 10) + a + b + rmrr)
  let units = IOMMUs.units(TableSet([dmar]), functions: [])
  #expect(units.map { $0.registerBase } == [0xFED9_0000, 0xFED9_1000])
  let reservedA = le(0x7F00_0000, 8) + le(0x1_0000, 8) + [8] + [UInt8](repeating: 0, count: 7)
    + [0, 0, 1, 0x10, 0, 0, 0, 0]
  #expect(units[0].descriptor == le(0xFED9_0000, 8) + [0, 0, 0, 8] + le(UInt64(reservedA.count), 2) + [0, 0]
    + [0, 0, 1, 0x10, 0, 0, 0, 0] + reservedA)
  // B: whole segment, A's endpoint its exception, and 00:03.0's memory.
  let reservedB = le(0x7F00_0000, 8) + le(0x1_0000, 8) + [8] + [UInt8](repeating: 0, count: 7)
    + [0, 0, 1, 0x18, 0, 0, 0, 0]
  #expect(units[1].descriptor == le(0xFED9_1000, 8) + [0, 0, 1, 8] + le(UInt64(reservedB.count), 2) + [0, 0]
    + [0, 0, 1, 0x10, 0, 0, 0, 0] + reservedB)
}

@Test func q35sIVRSAndArmsIORT() throws {
  if let t = corpusTable("qemu-x86-q35", "IVRS.ivrs") {
    let units = IOMMUs.units(TableSet([t]), functions: [])
    #expect(units == [IOMMUUnit(type: .amd, registerBase: 0xFED8_0000, descriptor: le(0xFED8_0000, 8) + le(0, 8))])
  }
  if let t = corpusTable("qemu-aarch64-virt", "IORT.smmuv3-dev") {
    let units = IOMMUs.units(TableSet([t]), functions: [])
    #expect(units.map { $0.type } == [.armSMMU, .armSMMU])
    #expect(units.map { $0.descriptor } == [le(0x0C00_0000, 8), le(0x0C02_0000, 8)])
  }
  // Without SMMUs (virt's IORT by default), none.
  if let t = corpusTable("qemu-aarch64-virt", "IORT") { #expect(IOMMUs.units(TableSet([t]), functions: []).isEmpty) }
}

@Test func aPCIeRISCVIOMMUsRegistersAreItsBAR() throws {
  // One IOMMU node: PCIe-based, segment 0, 00:08.0 (QEMU's riscv-iommu-pci).
  let node = [0, 0] + le(40, 2) + le(0, 2) + le(0, 2) + [UInt8](repeating: 0, count: 8) + le(0, 8) + le(1, 4)
    + le(0, 4) + le(0, 2) + le(0x40, 2) + [UInt8](repeating: 0, count: 4)
  let rimt = table("RIMT", le(1, 4) + le(48, 4) + le(0, 4) + node)
  let iommu = Function(address: FunctionAddress(bus: 0, device: 8, function: 0), vendor: 0x1B36, device: 0x0014,
                       classCode: 8, subclass: 6, progIF: 0, revision: 0, headerType: 0, subsystemVendor: 0,
                       subsystem: 0, interruptPin: 0,
                       bars: [BAR(index: 0, space: .memory, address: 0x1_0000_0000, size: 0x1000, is64: true)],
                       capabilities: [], secondaryBus: nil)
  #expect(IOMMUs.units(TableSet([rimt]), functions: [iommu])
    == [IOMMUUnit(type: .riscv, registerBase: 0x1_0000_0000, descriptor: le(0x1_0000_0000, 8))])
  // Its function not found: no unit.
  #expect(IOMMUs.units(TableSet([rimt]), functions: []).isEmpty)
}

@Test func q35sClockHasItsPortsAndInterrupt() throws {
  guard let tables = q35Tables() else { return }
  let host = MachineHost(readMemory: { _, _ in 0 }, writeMemory: { _, _, _ in true }, readPort: { _, _ in 0 },
                         writePort: { _, _, _ in true }, config: RecordingConfig())
  var ns = Namespace(integerBits: 64)
  for t in tables { try ns.load(t, host: host) }
  let rtc = ns.deviceNodes().first { (try? ns.hardwareID($0, host: host)) == Array("PNP0B00".utf8) }
  let node = try #require(rtc)
  let crs = try #require(try ns.currentResources(node, host: host))
  #expect(Device.PlatformResource.of(crs) == [.ioport(base: 0x70, count: 8), .interrupt(8, .edgeHigh)])
}
