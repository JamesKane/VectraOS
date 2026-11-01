// SPDX-License-Identifier: BSD-3-Clause

// The buses PCI host drivers bring up (D154, DriverHost's HostedBus): a
// host serves `pci` once its link is up, and devmgr binds the functions
// it lists as it binds ECAM's. Each function's configuration space is a
// page the host fixed, mapped here uncached as ECAM's buses are; the
// host's memory windows are its root bridge's.

import CroiMMIO
import DriverHost
import PCI
import Sys

/// The listed functions' pages, each mapped the first time it is touched
/// under devmgr's MMIO ranged root (which stays its owner's). A function
/// not listed, or a page that can't be mapped, reads as all ones.
public final class HostedConfig: ConfigSpace, @unchecked Sendable {
  final class Page {
    let address: FunctionAddress
    let mapping: Mapping
    init(_ address: FunctionAddress, _ mapping: consuming Mapping) {
      self.address = address
      self.mapping = mapping
    }
    var base: UInt64 { unsafe UInt64(UInt(bitPattern: mapping.address)) }
  }

  let root: UInt32
  public let bus: HostedBus
  let lock = Lock()
  var pages: [Page] = []
  var refused: [FunctionAddress] = []

  public init(mmioRoot: UInt32, bus: HostedBus) {
    root = mmioRoot
    self.bus = bus
  }

  /// The listed functions' addresses, in the host's segment.
  public var addresses: [FunctionAddress] {
    bus.functions.map { FunctionAddress(segment: bus.segment, bus: $0.bus, device: $0.device, function: $0.function) }
  }

  /// The physical address of `f`'s page.
  public func page(_ f: FunctionAddress) -> UInt64? {
    guard f.segment == bus.segment else { return nil }
    return bus.functions.first { $0.bus == f.bus && $0.device == f.device && $0.function == f.function }?.page
  }

  /// The host's root bridge: its buses and memory windows, at the CPU's
  /// own addresses.
  public var bridge: RootBridge {
    RootBridge(firstBus: 0, lastBus: 255, windows: bus.memory.map {
      RootBridge.Window(minimum: $0.minimum, maximum: $0.maximum, translation: 0)
    })
  }

  func mapped(_ f: FunctionAddress) -> UInt64? {
    guard let physical = page(f) else { return nil }
    return lock.withLock { () -> UInt64? in
      if let p = pages.first(where: { $0.address == f }) { return p.base }
      if refused.contains(f) { return nil }
      do throws(Status) {
        let parent = Handle(raw: root)  // the caller's
        let resource: Handle
        do throws(Status) {
          resource = try Sys.Resource.create(parent: parent, kind: .mmio, base: physical, size: 4096, name: "config")
        } catch {
          _ = parent.release()
          throw error
        }
        _ = parent.release()
        let vmo = try VMO.physical(resource: resource, address: physical, size: 4096)
        try VMO.setCachePolicy(vmo, .uncachedDevice)
        let p = Page(f, try VMO.map(vmo, length: 4096))
        pages.append(p)
        return p.base
      } catch {
        refused.append(f)
        return nil
      }
    }
  }

  public func read(_ f: FunctionAddress, _ offset: Int, width: Int) -> UInt32 {
    guard offset >= 0, offset + width <= 4096, offset % max(width, 1) == 0, let base = mapped(f) else {
      return UInt32.max >> (32 - 8 * min(max(width, 1), 4))
    }
    let at = base + UInt64(offset)
    switch width {
    case 1: return UInt32(croi_mmio_read8(at))
    case 2: return UInt32(croi_mmio_read16(at))
    default: return croi_mmio_read32(at)
    }
  }

  public func write(_ f: FunctionAddress, _ offset: Int, width: Int, _ value: UInt32) {
    guard offset >= 0, offset + width <= 4096, offset % max(width, 1) == 0, let base = mapped(f) else { return }
    let at = base + UInt64(offset)
    switch width {
    case 1: croi_mmio_write8(at, UInt8(truncatingIfNeeded: value))
    case 2: croi_mmio_write16(at, UInt16(truncatingIfNeeded: value))
    default: croi_mmio_write32(at, value)
    }
  }
}
