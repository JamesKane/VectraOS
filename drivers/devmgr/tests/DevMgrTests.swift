// SPDX-License-Identifier: BSD-3-Clause

// devmgr's match records (M4h), and the manifest directives that give it
// hardware and programs (M3g).

import DevMgr
import Foundation
import Launch
import PCI
import Testing

func function(_ vendor: UInt16, _ device: UInt16, at d: UInt8, class c: UInt8 = 0, subclass: UInt8 = 0, progIF: UInt8 = 0)
  -> Function
{
  Function(address: FunctionAddress(bus: 0, device: d, function: 0), vendor: vendor, device: device, classCode: c,
           subclass: subclass, progIF: progIF, revision: 0, headerType: 0, subsystemVendor: 0, subsystem: 0,
           interruptPin: 0, bars: [], capabilities: [], secondaryBus: nil)
}

func acpi(_ hid: String?, _ cids: [String] = []) -> Device {
  Device(acpi: Device.ACPIDevice(path: "\\_SB_.DEV0", hid: hid, cids: cids, status: 0xF))
}

func index(_ text: String) throws -> DriverIndex { try DriverIndex(text: text, file: "t") }

func bound(_ i: DriverIndex, _ d: Device) -> String {
  switch i.match(d) {
  case .driver(let n): i.drivers[n].name
  case .none: "-"
  case .ambiguous(let names): "ambiguous " + names.joined(separator: " ")
  }
}

@Test func matchRecordsParseWithTheirLines() throws {
  let i = try index("""
    # a comment
    driver hda
    class audio
    match pci 8086:2668   # QEMU's
    match pci-class 04.03
    driver edu
    match pci 1234:11e8
    dma-bits 28
    driver generic
    match acpi-compatible PNP0C50
    match acpi PNP0B00
    match pci-class 01.08.02
    fallback
    """)
  #expect(i.drivers.map { $0.name } == ["hda", "edu", "generic"])
  #expect(i.drivers[0].rules == [.pci(vendor: 0x8086, device: 0x2668), .pciClass(4, 3, progIF: nil)])
  #expect(i.drivers[0].deviceClass == "audio" && i.drivers[0].origin == "t:2")
  #expect(i.drivers[1].addressBits == 28 && !i.drivers[1].fallback)
  #expect(i.drivers[2].fallback && i.drivers[2].rules.last == .pciClass(1, 8, progIF: 2))
  func error(_ text: String) -> String {
    do throws(IndexError) {
      _ = try DriverIndex(text: text, file: "t")
      return "parsed"
    } catch {
      return error.description
    }
  }
  #expect(error("class audio\n") == "t:1: 'driver' must come first")
  #expect(error("driver a\nmatch pci 8086\n") == "t:2: bad match 'pci 8086'")
  #expect(error("driver a\nmatch usb 1:2\n") == "t:2: bad match 'usb 1:2'")
  #expect(error("driver a\nbind x\n") == "t:2: unknown directive 'bind'")
  #expect(error("driver a\ndma-bits 8\nmatch pci 1234:5678\n") == "t:2: 'dma-bits' takes 12 to 64")
  #expect(error("driver a\nclass audio\n") == "t:1: driver 'a' matches nothing")
}

@Test func exactIdsBeatCompatibleIdsBeatClassesBeatFallbacks() throws {
  let i = try index("""
    driver by-id
    match pci 8086:2668
    driver by-class
    match pci-class 04.03
    driver by-progif
    match pci-class 01.06.01
    driver by-subclass
    match pci-class 01.06
    driver touchpad
    match acpi-compatible PNP0C50
    driver elan
    match acpi ELAN0000
    driver hid-generic
    match acpi-compatible PNP0C51
    driver any-hda
    match pci-class 04.03
    fallback
    """)
  #expect(bound(i, Device(pci: function(0x8086, 0x2668, at: 1, class: 4, subclass: 3))) == "by-id")
  #expect(bound(i, Device(pci: function(0x10DE, 0x0001, at: 2, class: 4, subclass: 3))) == "by-class")
  #expect(bound(i, Device(pci: function(0x1B21, 0x0612, at: 3, class: 1, subclass: 6, progIF: 1))) == "by-progif")
  #expect(bound(i, Device(pci: function(0x1B21, 0x0612, at: 3, class: 1, subclass: 6, progIF: 0))) == "by-subclass")
  #expect(bound(i, Device(pci: function(0x1AF4, 0x1044, at: 4))) == "-")
  #expect(bound(i, acpi("ELAN0000", ["PNP0C50"])) == "elan")
  // Compatible ids in the device's order.
  #expect(bound(i, acpi("XYZ0001", ["PNP0C51", "PNP0C50"])) == "hid-generic")
  #expect(bound(i, acpi("XYZ0001", ["PNP0C50", "PNP0C51"])) == "touchpad")
  #expect(bound(i, acpi(nil)) == "-")
  // Two at the deciding level: neither.
  let tie = try index("driver a\nmatch pci-class 04.03\ndriver b\nmatch pci-class 04.03\n")
  #expect(bound(tie, Device(pci: function(1, 2, at: 1, class: 4, subclass: 3))) == "ambiguous a b")
  #expect(tie.conflicts == ["t:1 and t:3: 'a' and 'b' both match pci-class 04.03"])
  #expect(i.conflicts == [])
}

/// Every drivers/**/driver.manifest, sorted (td's order).
func driverManifests() -> [String] {
  let all = (try? FileManager.default.subpathsOfDirectory(atPath: "drivers")) ?? []
  return all.filter { $0.hasSuffix("/driver.manifest") }.sorted().map { "drivers/" + $0 }
}

@Test func theTreesDriversFormAConsistentIndex() throws {
  // Every drivers/**/driver.manifest, as td collects them.
  let text = try driverManifests().map { try String(contentsOfFile: $0, encoding: .utf8) }.joined(separator: "\n")
  let i = try index(text)
  #expect(i.conflicts == [])
  #expect(bound(i, Device(pci: function(0x1234, 0x11E8, at: 4))) == "edu")
  #expect(i.drivers.first { $0.name == "edu" }?.addressBits == 28)
  #expect(bound(i, Device(pci: function(0x8086, 0x29C0, at: 0, class: 6))) == "-")  // q35's host bridge
}

@Test func resourceAndProgramsDirectives() throws {
  let m = try Manifest(file: "devmgr.manifest", text: """
    service devmgr
    program devmgr
    resource mmio
    resource ioport
    programs
    export
    """)
  #expect(m.resources.map { $0.kind } == [.mmio, .ioport])
  #expect(m.resources.map { $0.line } == [3, 4])
  #expect(m.programsLine == 5)
  for (text, message) in [
    ("resource dma", "devmgr.manifest:3: 'resource' takes mmio, irq, ioport, smc or system"),
    ("resource mmio\nresource mmio", "devmgr.manifest:4: a second 'resource mmio'"),
    ("programs bin", "devmgr.manifest:3: 'programs' takes 0 arguments"),
  ] {
    #expect(throws: LaunchError(message)) { try Manifest(file: "devmgr.manifest", text: "service devmgr\nprogram devmgr\n\(text)") }
  }
}
