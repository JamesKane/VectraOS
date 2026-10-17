// SPDX-License-Identifier: BSD-3-Clause

// PCI configuration space (PCI Local Bus 3.0 §6, PCI Express Base 4.0
// §7.2.2): where a function is, and the reads and writes of its registers.
// How the space is reached is a `ConfigSpace`: ECAM's memory window
// (ECAM.swift), or a test's model of devices.

/// A function's place: segment (an ECAM window), bus, device and function.
public struct FunctionAddress: Hashable, Comparable, Sendable {
  public var segment: UInt16
  public var bus: UInt8
  public var device: UInt8
  public var function: UInt8

  public init(segment: UInt16 = 0, bus: UInt8, device: UInt8, function: UInt8) {
    self.segment = segment
    self.bus = bus
    self.device = device
    self.function = function
  }

  public static func < (a: Self, b: Self) -> Bool {
    (a.segment, a.bus, a.device, a.function) < (b.segment, b.bus, b.device, b.function)
  }

  /// `bb:dd.f`, Linux's form, with the segment only if not 0.
  public var description: String {
    (segment == 0 ? "" : hex(UInt32(segment), digits: 4) + ":") + hex(UInt32(bus), digits: 2) + ":"
      + hex(UInt32(device), digits: 2) + "." + hex(UInt32(function), digits: 1)
  }
}

/// Lower-case hexadecimal, `digits` wide (Embedded Swift has no String(radix:)
/// padding).
public func hex(_ value: UInt32, digits: Int) -> String {
  let table = Array("0123456789abcdef".utf8)
  var out: [UInt8] = []
  for i in stride(from: digits - 1, through: 0, by: -1) { out.append(table[Int((value >> UInt32(4 * i)) & 0xF)]) }
  return String(decoding: out, as: UTF8.self)
}

/// A way to a segment's configuration space. Accesses are 1, 2 or 4 bytes
/// at an offset aligned to their width; a function that isn't there reads
/// as all ones.
public protocol ConfigSpace {
  func read(_ f: FunctionAddress, _ offset: Int, width: Int) -> UInt32
  func write(_ f: FunctionAddress, _ offset: Int, width: Int, _ value: UInt32)
}

extension ConfigSpace {
  public func read8(_ f: FunctionAddress, _ offset: Int) -> UInt8 { UInt8(truncatingIfNeeded: read(f, offset, width: 1)) }
  public func read16(_ f: FunctionAddress, _ offset: Int) -> UInt16 {
    UInt16(truncatingIfNeeded: read(f, offset, width: 2))
  }
  public func read32(_ f: FunctionAddress, _ offset: Int) -> UInt32 { read(f, offset, width: 4) }
  public func write16(_ f: FunctionAddress, _ offset: Int, _ value: UInt16) { write(f, offset, width: 2, UInt32(value)) }
  public func write32(_ f: FunctionAddress, _ offset: Int, _ value: UInt32) { write(f, offset, width: 4, value) }
}

/// Registers of the common header (§6.1) and the two header types'.
public enum Register {
  public static let vendor = 0x00
  public static let device = 0x02
  public static let command = 0x04
  public static let status = 0x06
  public static let revision = 0x08
  public static let progIF = 0x09
  public static let subclass = 0x0A
  public static let classCode = 0x0B
  public static let headerType = 0x0E
  public static let bar0 = 0x10
  /// Type 0.
  public static let subsystemVendor = 0x2C
  public static let subsystem = 0x2E
  public static let capabilities = 0x34
  public static let interruptLine = 0x3C
  public static let interruptPin = 0x3D
  /// Type 1 (bridges).
  public static let primaryBus = 0x18
  public static let secondaryBus = 0x19
  public static let subordinateBus = 0x1A
}

/// The command register's bits (§6.2.2).
public enum Command {
  public static let io: UInt16 = 1 << 0
  public static let memory: UInt16 = 1 << 1
  public static let busMaster: UInt16 = 1 << 2
  public static let interruptDisable: UInt16 = 1 << 10
}
