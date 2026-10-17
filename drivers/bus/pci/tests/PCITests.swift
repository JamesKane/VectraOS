// SPDX-License-Identifier: BSD-3-Clause

// PCI enumeration over a model of configuration space that behaves as
// hardware does: BARs answer all ones with their size mask, read-only
// registers ignore writes. And ECAM's addressing over a buffer, and the
// MCFG table from QEMU's q35.

import Foundation
import PCI
import TDACPI
import Testing

/// Functions' configuration spaces, with each BAR's size so that writes
/// of all ones read back as its mask.
final class Model: ConfigSpace {
  var spaces: [FunctionAddress: [UInt8]] = [:]
  /// (function, BAR offset) → the bits a write may set.
  var barMasks: [FunctionAddress: [Int: UInt32]] = [:]
  var writes = 0

  func add(_ at: FunctionAddress, vendor: UInt16, device: UInt16, classCode: UInt8, subclass: UInt8,
           header: UInt8 = 0, command: UInt16 = 0x0007)
  {
    var s = [UInt8](repeating: 0, count: 4096)
    put(&s, Register.vendor, 2, UInt32(vendor))
    put(&s, Register.device, 2, UInt32(device))
    put(&s, Register.command, 2, UInt32(command))
    s[Register.classCode] = classCode
    s[Register.subclass] = subclass
    s[Register.headerType] = header
    spaces[at] = s
  }

  /// A BAR at register `index` of `size` bytes: `low` its type bits.
  func bar(_ at: FunctionAddress, _ index: Int, address: UInt64, size: UInt64, low: UInt32, is64: Bool = false) {
    let offset = Register.bar0 + 4 * index
    let mask = ~(size - 1)
    put(&spaces[at]!, offset, 4, UInt32(truncatingIfNeeded: address) | low)
    barMasks[at, default: [:]][offset] = UInt32(truncatingIfNeeded: mask) & ~(low & 1 == 1 ? 0x3 : 0xF)
    if is64 {
      put(&spaces[at]!, offset + 4, 4, UInt32(truncatingIfNeeded: address >> 32))
      barMasks[at, default: [:]][offset + 4] = UInt32(truncatingIfNeeded: mask >> 32)
    }
  }

  func capabilities(_ at: FunctionAddress, _ list: [(id: UInt8, offset: Int, next: Int)]) {
    var s = spaces[at]!
    put(&s, Register.status, 2, 0x10)
    s[Register.capabilities] = UInt8(list[0].offset)
    for c in list {
      s[c.offset] = c.id
      s[c.offset + 1] = UInt8(c.next)
    }
    spaces[at] = s
  }

  func put(_ s: inout [UInt8], _ offset: Int, _ width: Int, _ value: UInt32) {
    for i in 0..<width { s[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(i))) }
  }

  func read(_ f: FunctionAddress, _ offset: Int, width: Int) -> UInt32 {
    guard let s = spaces[f] else { return UInt32.max >> (32 - 8 * width) }
    var v: UInt32 = 0
    for i in 0..<width { v |= UInt32(s[offset + i]) << (8 * UInt32(i)) }
    return v
  }

  func write(_ f: FunctionAddress, _ offset: Int, width: Int, _ value: UInt32) {
    guard spaces[f] != nil else { return }
    writes += 1
    if let mask = barMasks[f]?[offset] {
      precondition(width == 4)
      let fixed = read(f, offset, width: 4) & ~mask
      put(&spaces[f]!, offset, 4, (value & mask) | fixed)
    } else if offset == Register.command {
      put(&spaces[f]!, offset, width, value)
    } else if offset >= Register.bar0 && offset < Register.bar0 + 24 {
      // An unimplemented BAR: reads as zero.
    } else {
      put(&spaces[f]!, offset, width, value)
    }
  }
}

func at(_ bus: UInt8, _ device: UInt8, _ function: UInt8 = 0) -> FunctionAddress {
  FunctionAddress(bus: bus, device: device, function: function)
}

/// A host bridge, a multi-function device with every kind of BAR, and a
/// bridge to bus 1 holding a device with capabilities.
func machine() -> Model {
  let m = Model()
  m.add(at(0, 0), vendor: 0x8086, device: 0x29C0, classCode: 0x06, subclass: 0x00)
  m.add(at(0, 2), vendor: 0x1AF4, device: 0x1042, classCode: 0x01, subclass: 0x00, header: 0x80)
  m.bar(at(0, 2), 0, address: 0xFEBF_0000, size: 0x1000, low: 0)
  m.bar(at(0, 2), 1, address: 0xC000, size: 0x20, low: 1)
  m.bar(at(0, 2), 4, address: 0x8_0000_0000, size: 0x4000, low: 0x4 | 0x8, is64: true)
  m.add(at(0, 2, 1), vendor: 0x1AF4, device: 0x1043, classCode: 0x07, subclass: 0x80)
  m.add(at(0, 0x1E), vendor: 0x8086, device: 0x244E, classCode: 0x06, subclass: 0x04, header: 1)
  m.spaces[at(0, 0x1E)]![Register.secondaryBus] = 1
  m.add(at(1, 0), vendor: 0x1234, device: 0x11E8, classCode: 0x00, subclass: 0xFF)
  m.bar(at(1, 0), 0, address: 0xFE00_0000, size: 0x10_0000, low: 0)
  m.capabilities(at(1, 0), [(0x05, 0x40, 0x50), (0x11, 0x50, 0)])
  return m
}

@Test func enumeratesEveryFunction() {
  let found = enumerate(machine())
  #expect(found.map { $0.address.description } == ["00:00.0", "00:02.0", "00:02.1", "00:1e.0", "01:00.0"])
  #expect(found[1].description == "00:02.0 1af4:1042 class 01.00.00")
  #expect(found[3].secondaryBus == 1 && found[3].headerType == 1)
}

@Test func sizesBARs() {
  let m = machine()
  let f = enumerate(m).first { $0.address == at(0, 2) }!
  #expect(f.bars == [
    BAR(index: 0, space: .memory, address: 0xFEBF_0000, size: 0x1000),
    BAR(index: 1, space: .io, address: 0xC000, size: 0x20),
    BAR(index: 4, space: .memory, address: 0x8_0000_0000, size: 0x4000, is64: true, prefetchable: true),
  ])
  // Every BAR and the command register are as they were.
  #expect(m.read32(at(0, 2), Register.bar0) == 0xFEBF_0000)
  #expect(m.read32(at(0, 2), Register.bar0 + 4) == 0xC001)
  #expect(m.read32(at(0, 2), Register.bar0 + 20) == 0x8)
  #expect(m.read16(at(0, 2), Register.command) == 0x0007)
}

@Test func walksCapabilities() {
  let f = enumerate(machine()).first { $0.address == at(1, 0) }!
  #expect(f.capabilities == [Capability(id: 0x05, offset: 0x40), Capability(id: 0x11, offset: 0x50)])
  #expect(f.capability(0x11)?.offset == 0x50)
  #expect(f.bars == [BAR(index: 0, space: .memory, address: 0xFE00_0000, size: 0x10_0000)])
}

@Test func loopsEnd() {
  let m = machine()
  // A capability list pointing at itself, and a bridge back to bus 0.
  m.capabilities(at(1, 0), [(0x05, 0x40, 0x40)])
  m.add(at(1, 1), vendor: 0x8086, device: 0x244E, classCode: 0x06, subclass: 0x04, header: 1)
  m.spaces[at(1, 1)]![Register.secondaryBus] = 0
  let found = enumerate(m)
  #expect(found.count == 6)
  #expect(found.first { $0.address == at(1, 0) }!.capabilities.count == 48)
}

@Test func ecamAddressing() {
  // Two buses' windows: each function at bus << 20 | device << 15 | function << 12.
  let buffer = UnsafeMutableRawPointer.allocate(byteCount: ECAM.size(buses: 2), alignment: 4096)
  defer { buffer.deallocate() }
  buffer.initializeMemory(as: UInt8.self, repeating: 0xFF, count: ECAM.size(buses: 2))
  let ecam = ECAM(unsafe: buffer, startBus: 4, endBus: 5)
  buffer.storeBytes(of: UInt32(0x11E8_1234), toByteOffset: 1 << 20 | 3 << 15 | 2 << 12, as: UInt32.self)
  #expect(ecam.read32(FunctionAddress(bus: 5, device: 3, function: 2), 0) == 0x11E8_1234)
  #expect(ecam.read16(FunctionAddress(bus: 5, device: 3, function: 2), 2) == 0x11E8)
  #expect(ecam.read16(FunctionAddress(bus: 6, device: 0, function: 0), 0) == 0xFFFF)  // outside the window
  ecam.write16(FunctionAddress(bus: 4, device: 0, function: 0), Register.command, 0x0406)
  #expect(buffer.load(fromByteOffset: 4, as: UInt16.self) == 0x0406)
}

@Test func q35MCFG() throws {
  let path = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../.cache/acpi/qemu-x86-q35/MCFG")
  guard let bytes = try? Data(contentsOf: path) else { return }  // the corpus is absent (vx acpi fetch-qemu)
  let mcfg = try MCFG(Table(Array(bytes)))
  #expect(mcfg.windows == [MCFG.Window(base: 0xB000_0000, segment: 0, startBus: 0, endBus: 255)])
}
