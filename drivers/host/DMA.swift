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
/// pinned when a process dies). For a device whose DMA isn't cache
/// coherent (ACPI's _CCA 0, devmgr's `--noncoherent`), `coherent: false`
/// maps it write-combining, Arm's Normal non-cacheable, as Linux's
/// coherent allocations are for such a device: what either side writes
/// is in memory once a barrier (croi_dma_barrier) orders it.
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
  let coherent: Bool
  var regions: [Region] = []

  public init(bti: consuming Handle, coherent: Bool = true) {
    self.bti = bti
    self.coherent = coherent
  }

  public func allocate(bytes: Int) throws(Status) -> (pointer: UnsafeMutableRawPointer, bus: UInt64) {
    let size = (bytes + 4095) & ~4095
    let vmo = try DMA.contiguousVMO(bti: bti, size: size)
    // Before it is mapped or pinned: the kernel cleans its cached lines.
    if !coherent { try VMO.setCachePolicy(vmo, .writeCombining) }
    let mapping = try VMO.map(vmo, length: size)
    let pinned = try DMA.pin(bti, vmo, offset: 0, size: size, options: [.read, .write, .contiguous], count: 1)
    unsafe mapping.address.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    let pointer = unsafe mapping.address
    regions.append(Region(mapping: mapping, pmt: pinned.pmt, vmo: vmo))
    return unsafe (pointer, pinned.addresses[0])
  }
}
