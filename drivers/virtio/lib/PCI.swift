// SPDX-License-Identifier: BSD-3-Clause

// A virtio device as a driver host has it (M3i, M3k): its configuration
// space and BARs from devmgr's grants (DeviceResources), the vendor
// capabilities found in the former, and windows into the latter for the
// common and device configurations. Only the BARs the capabilities name
// are mapped; the PCI configuration access capability is used through
// configuration space, never mapped.

import CroiMMIO
import DriverHost
import Sys

/// A mapped BAR, shared by the windows into it.
public final class MappedBAR {
  public let index: Int
  let regs: Registers
  init(index: Int, regs: consuming Registers) {
    self.index = index
    self.regs = regs
  }
}

/// A capability's range in its BAR, as a `Window`.
public final class BARWindow: Window {
  let bar: MappedBAR
  let base: Int
  init(_ bar: MappedBAR, base: Int) {
    self.bar = bar
    self.base = base
  }
  public func read(_ offset: Int, width: Int) -> UInt64 {
    let o = base + offset
    switch width {
    case 1: return UInt64(bar.regs.load8(o))
    case 2: return UInt64(bar.regs.load16(o))
    case 4: return UInt64(bar.regs.load32(o))
    default: return UInt64(bar.regs.load32(o)) | UInt64(bar.regs.load32(o + 4)) << 32
    }
  }
  public func write(_ offset: Int, width: Int, _ value: UInt64) {
    let o = base + offset
    switch width {
    case 1: bar.regs.store8(o, UInt8(truncatingIfNeeded: value))
    case 2: bar.regs.store16(o, UInt16(truncatingIfNeeded: value))
    case 4: bar.regs.store32(o, UInt32(truncatingIfNeeded: value))
    default:
      bar.regs.store32(o, UInt32(truncatingIfNeeded: value))
      bar.regs.store32(o + 4, UInt32(truncatingIfNeeded: value >> 32))
    }
  }
}

extension PCIInterrupt {
  /// The vector a virtio queue should use (Device.enable).
  public var vector: UInt16 { msix ? 0 : Device<BARWindow>.noVector }
}

/// The device a driver host was given, opened.
public final class PCIDevice {
  public let capabilities: [Capability]
  /// The function's configuration space, kept mapped.
  let config: MappedBAR
  public let bars: [MappedBAR]
  public let device: Device<BARWindow>
  /// Where queues are notified (§4.1.4.4): queue_notify_off times
  /// `notifyMultiplier` into this window.
  public let notify: BARWindow?
  public let notifyMultiplier: UInt32
  /// ISR status (§4.1.4.5): reading it clears the device's INTx line.
  public let isr: BARWindow?
  /// Its shared memory regions (§4.1.4.7), unmapped: a driver maps what it
  /// needs of them.
  public let sharedMemory: [SharedMemoryRegion]

  public init(_ resources: borrowing DeviceResources) throws(Status) {
    let config = try resources.mapConfig()
    let list = pciCapabilities(config)
    let caps = Capability.find(at: list) { config.load8($0) }
    sharedMemory = SharedMemoryRegion.find(at: list) { config.load8($0) }
    var bars: [MappedBAR] = []
    for c in caps where c.kind != .pci && !bars.contains(where: { $0.index == c.bar }) {
      bars.append(MappedBAR(index: c.bar, regs: try resources.map(bar: c.bar)))
    }
    func window(_ kind: Capability.Kind) -> BARWindow? {
      guard let c = caps.first(where: { $0.kind == kind }), let b = bars.first(where: { $0.index == c.bar }) else {
        return nil
      }
      return BARWindow(b, base: Int(c.offset))
    }
    guard let common = window(.common) else { throw .notSupported }
    // Bus mastering on (command bit 2): the queues are DMA. Firmware turns
    // it on only for the devices it used, and a warm boot's devmgr turned
    // it off for every one (D101).
    config.store16(4, config.load16(4) | 0x4)
    // A device with no configuration of its own gets an empty window.
    let device = window(.device) ?? common
    notify = window(.notify)
    isr = window(.isr)
    notifyMultiplier = caps.first { $0.kind == .notify }?.multiplier ?? 0
    capabilities = caps
    self.bars = bars
    self.config = MappedBAR(index: -1, regs: config)
    self.device = Device(common: common, device: device)
  }

  /// The device's interrupt (DriverHost's PCIInterrupt: MSI-X vector 0 if
  /// it can, else INTx), the configuration change interrupt off on MSI-X.
  /// Call before enabling queues, so they can take vector 0.
  public func interrupt(_ resources: borrowing DeviceResources) throws(Status) -> PCIInterrupt {
    let irq = try PCIInterrupt(resources, config: config.regs)
    if irq.msix { device.setConfigVector(Device<BARWindow>.noVector) }
    return irq
  }

  /// Tells the device a queue has new buffers: a write of the queue's
  /// index at its notification offset (`enable`'s, times the multiplier,
  /// §4.1.4.4), after a barrier, so the device sees the ring as written.
  public func notify(queue index: Int, offset: Int) {
    croi_dma_barrier()
    notify?.write(offset * Int(notifyMultiplier), width: 2, UInt64(index))
  }

  /// `kind@barN` for each capability, for a status line.
  public var summary: String { capabilities.map { "\($0.kind.rawValue)@bar\($0.bar)" }.joined(separator: " ") }
}

extension Device {
  /// The size to give `queues`: a power of two, at most `most` and what
  /// each of them allows.
  public func queueSize(most: Int, _ queues: [Int]) -> Int {
    var size = queues.reduce(most) { min($0, queueSize($1)) }
    while size & (size - 1) != 0 { size &= size - 1 }
    return size
  }

  /// Queue `index` of `size` entries, its rings in `memory` and enabled
  /// with `vector`: the queue and its notification offset (`enable`'s).
  public func makeQueue(_ index: Int, size: Int, memory: DMAMemory, vector: UInt16 = noVector)
    throws(Status) -> (queue: SplitQueue, notify: Int)
  {
    let layout = QueueLayout(size: size)
    let rings = try unsafe memory.allocate(bytes: layout.bytes)
    let queue = unsafe SplitQueue(layout: layout, unsafe: rings.pointer, busAddress: rings.bus)
    do throws(VirtioError) {
      return (queue, try enable(queue: index, size: size, descriptors: queue.descriptorsAddress,
                                driver: queue.availableAddress, device: queue.usedAddress, vector: vector))
    } catch {
      throw .notSupported
    }
  }
}
