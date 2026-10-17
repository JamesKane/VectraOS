// SPDX-License-Identifier: BSD-3-Clause

// DMA memory for a driver host (M3i).

import Sys

/// Memory a device reaches: zeroed bytes in this process and the address
/// the device uses for them, kept for the provider's life.
public protocol DMAMemory: AnyObject {
  func allocate(bytes: Int) throws(Status) -> (pointer: UnsafeMutableRawPointer, bus: UInt64)
}

/// Memory a device reaches through its BTI (croi K9e): each allocation a
/// contiguous VMO, mapped here and pinned for the device, kept for this
/// provider's life (the pins end with it; croi quarantines what is still
/// pinned when a process dies).
@safe public final class PinnedMemory: DMAMemory {
  final class Region {
    let mapping: Mapping
    let pmt: UInt32
    let vmo: Handle
    init(mapping: consuming Mapping, pmt: UInt32, vmo: consuming Handle) {
      self.mapping = mapping
      self.pmt = pmt
      self.vmo = vmo
    }
    deinit { try? DMA.unpin(pmt: pmt) }
  }

  let bti: Handle
  var regions: [Region] = []

  public init(bti: consuming Handle) { self.bti = bti }

  public func allocate(bytes: Int) throws(Status) -> (pointer: UnsafeMutableRawPointer, bus: UInt64) {
    let size = (bytes + 4095) & ~4095
    let vmo = try DMA.contiguousVMO(bti: bti, size: size)
    let mapping = try VMO.map(vmo, length: size)
    let pinned = try DMA.pin(bti, vmo, offset: 0, size: size, options: [.read, .write, .contiguous], count: 1)
    unsafe mapping.address.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    let pointer = unsafe mapping.address
    regions.append(Region(mapping: mapping, pmt: pinned.pmt, vmo: vmo))
    return unsafe (pointer, pinned.addresses[0])
  }

  /// A handle to the VMO of the region at `pointer`, to share it (the
  /// audio service fills a sound device's periods in place).
  public func share(_ pointer: UnsafeMutableRawPointer, rights: Rights) throws(Status) -> Handle {
    guard let r = regions.first(where: { unsafe $0.mapping.address == pointer }) else { throw .notFound }
    return try r.vmo.duplicate(rights)
  }
}
