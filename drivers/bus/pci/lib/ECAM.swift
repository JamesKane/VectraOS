// SPDX-License-Identifier: BSD-3-Clause

// ECAM, the enhanced configuration access mechanism (PCI Express Base 4.0
// §7.2.2; PCI Firmware 3.2 §4.1.2, the MCFG table): each function's 4 KiB
// of configuration space at a fixed place in one memory window,
// base + (bus - startBus) << 20 | device << 15 | function << 12.
// Registers are read and written as the device's: volatile, each access
// once and in order, through the runtime's accessors (croi/mmio.h, D74).

import CroiMMIO

@safe public struct ECAM: ConfigSpace {
  /// Where the window is mapped in this process, for buses
  /// `startBus...endBus` of `segment`.
  let base: UInt64
  public let segment: UInt16
  public let startBus: UInt8
  public let endBus: UInt8

  /// The window's bytes for buses `startBus...endBus`, mapped uncached
  /// (natively a physical VMO over the MCFG's range); they must stay mapped
  /// while the ECAM is used.
  public init(unsafe base: UnsafeMutableRawPointer, segment: UInt16 = 0, startBus: UInt8 = 0, endBus: UInt8) {
    self.base = UInt64(UInt(bitPattern: base))
    self.segment = segment
    self.startBus = startBus
    self.endBus = endBus
  }

  /// The window's size for `buses` buses: 1 MiB each.
  public static func size(buses: Int) -> Int { buses << 20 }

  /// A function's 4 KiB from the window's start.
  public static func offset(bus: Int, device: UInt8, function: UInt8) -> Int {
    bus << 20 | Int(device & 0x1F) << 15 | Int(function & 0x7) << 12
  }

  func place(_ f: FunctionAddress, _ offset: Int, _ width: Int) -> UInt64? {
    guard f.segment == segment, f.bus >= startBus, f.bus <= endBus, f.device < 32, f.function < 8,
      offset >= 0, offset + width <= 4096, offset % width == 0
    else { return nil }
    return base + UInt64(Self.offset(bus: Int(f.bus - startBus), device: f.device, function: f.function) + offset)
  }

  public func read(_ f: FunctionAddress, _ offset: Int, width: Int) -> UInt32 {
    guard let at = place(f, offset, width) else { return UInt32.max >> (32 - 8 * min(max(width, 1), 4)) }
    switch width {
    case 1: return UInt32(croi_mmio_read8(at))
    case 2: return UInt32(croi_mmio_read16(at))
    default: return croi_mmio_read32(at)
    }
  }

  public func write(_ f: FunctionAddress, _ offset: Int, width: Int, _ value: UInt32) {
    guard let at = place(f, offset, width) else { return }
    switch width {
    case 1: croi_mmio_write8(at, UInt8(truncatingIfNeeded: value))
    case 2: croi_mmio_write16(at, UInt16(truncatingIfNeeded: value))
    default: croi_mmio_write32(at, value)
    }
  }
}
