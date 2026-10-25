// SPDX-License-Identifier: BSD-3-Clause

// A device's registers, mapped uncached (DeviceResources.map), read and
// written through the runtime's accessors (croi/mmio.h, D74).

import CroiMMIO
import Sys

/// A device's registers, mapped: loads and stores are volatile, each made
/// once and in order, at offsets from the window's start.
@safe public struct Registers: ~Copyable {
  let mapping: Mapping
  let offset: Int
  public let size: Int

  init(_ mapping: consuming Mapping, offset: Int, size: Int) {
    self.mapping = mapping
    self.offset = offset
    self.size = size
  }

  func at<T>(_ o: Int, _: T.Type) -> UInt64 {
    precondition(o >= 0 && o + MemoryLayout<T>.size <= size && o % MemoryLayout<T>.size == 0)
    return unsafe UInt64(UInt(bitPattern: mapping.address)) + UInt64(offset + o)
  }

  /// The window an MMIO resource covers, mapped uncached: a device's BAR,
  /// or registers a service was granted (power(8)'s CPPC registers).
  public static func map(_ resource: borrowing Handle) throws(Status) -> Registers {
    let info = try Resource.info(resource)
    guard info.kind == ResourceKind.mmio.rawValue else { throw .wrongType }
    let base = info.base & ~4095
    let size = Int((info.base - base + info.size + 4095) & ~4095)
    let vmo = try VMO.physical(resource: resource, address: base, size: size)
    return Registers(try VMO.map(vmo, length: size), offset: Int(info.base - base), size: Int(info.size))
  }

  public func load64(_ o: Int) -> UInt64 { croi_mmio_read64(at(o, UInt64.self)) }
  public func load32(_ o: Int) -> UInt32 { croi_mmio_read32(at(o, UInt32.self)) }
  public func load16(_ o: Int) -> UInt16 { croi_mmio_read16(at(o, UInt16.self)) }
  public func load8(_ o: Int) -> UInt8 { croi_mmio_read8(at(o, UInt8.self)) }
  public func store64(_ o: Int, _ v: UInt64) { croi_mmio_write64(at(o, UInt64.self), v) }
  public func store32(_ o: Int, _ v: UInt32) { croi_mmio_write32(at(o, UInt32.self), v) }
  public func store16(_ o: Int, _ v: UInt16) { croi_mmio_write16(at(o, UInt16.self), v) }
  public func store8(_ o: Int, _ v: UInt8) { croi_mmio_write8(at(o, UInt8.self), v) }
}
