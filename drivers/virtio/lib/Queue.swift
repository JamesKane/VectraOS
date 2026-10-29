// SPDX-License-Identifier: BSD-3-Clause

// A split virtqueue (Virtual I/O Device 1.2 §2.7): a descriptor table, the
// driver's available ring and the device's used ring, in memory both the
// driver and the device reach. The driver chains descriptors for a
// request, publishes its head in the available ring, and finds it again in
// the used ring when the device is done. The rings' memory and its bus
// addresses come from the caller: natively a pinned VMO (croi's BTI, K9e),
// in tests an allocation the model reads directly. The device sees each
// slot before the index that publishes it, and the driver reads a used
// entry only after the index that covers it: croi_dma_barrier (croi/mmio.h)
// between them.

import CroiMMIO

/// Where a queue's rings are, and their size in bytes for `size` entries:
/// descriptors (16 bytes each, 16-aligned), the available ring (4 + 2
/// each, 2-aligned; no used_event), the used ring (4 + 8 each, 4-aligned).
public struct QueueLayout: Equatable, Sendable {
  public let size: Int
  public let descriptors = 0
  public let available: Int
  public let used: Int
  public let bytes: Int

  public init(size: Int) {
    precondition(size > 0 && size & (size - 1) == 0 && size <= 32768)
    self.size = size
    available = 16 * size
    used = (available + 4 + 2 * size + 3) & ~3
    bytes = used + 4 + 8 * size
  }
}

/// A buffer of a request: its bus address and length, and whether the
/// device writes it.
public struct Buffer: Equatable, Sendable {
  public var address: UInt64
  public var length: UInt32
  public var deviceWrites: Bool

  public init(address: UInt64, length: UInt32, deviceWrites: Bool) {
    self.address = address
    self.length = length
    self.deviceWrites = deviceWrites
  }
}

@safe public final class SplitQueue: @unchecked Sendable {
  public let layout: QueueLayout
  /// The rings in this process, and their bus address.
  let base: UInt
  public let busAddress: UInt64
  var free: [UInt16]
  var availableIndex: UInt16 = 0
  var usedSeen: UInt16 = 0

  /// The rings at `memory` (zeroed, `layout.bytes` long, kept by the
  /// caller), which the device reaches at `busAddress`.
  public init(layout: QueueLayout, unsafe memory: UnsafeMutableRawPointer, busAddress: UInt64) {
    self.layout = layout
    base = unsafe UInt(bitPattern: memory)
    self.busAddress = busAddress
    free = (0..<layout.size).reversed().map { UInt16($0) }
  }

  public var descriptorsAddress: UInt64 { busAddress + UInt64(layout.descriptors) }
  public var availableAddress: UInt64 { busAddress + UInt64(layout.available) }
  public var usedAddress: UInt64 { busAddress + UInt64(layout.used) }
  public var freeDescriptors: Int { free.count }

  func store<T: FixedWidthInteger>(_ v: T, _ offset: Int) {
    unsafe UnsafeMutableRawPointer(bitPattern: base + UInt(offset))!.storeBytes(of: v.littleEndian, as: T.self)
  }
  func load<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
    T(littleEndian: unsafe UnsafeRawPointer(bitPattern: base + UInt(offset))!.load(as: T.self))
  }

  /// Chains `buffers` (those the device reads first, as §2.7.4 requires)
  /// and makes them available; the head's id, or nil if too few
  /// descriptors are free. The device learns of it at the next notify.
  public func submit(_ buffers: [Buffer]) -> UInt16? {
    guard !buffers.isEmpty, buffers.count <= free.count else { return nil }
    var ids: [UInt16] = []
    for _ in buffers { ids.append(free.removeLast()) }
    for (i, b) in buffers.enumerated() {
      let at = layout.descriptors + 16 * Int(ids[i])
      let last = i == buffers.count - 1
      store(b.address, at)
      store(b.length, at + 8)
      store(UInt16(last ? 0 : 1) | (b.deviceWrites ? 2 : 0), at + 12)  // NEXT, WRITE
      store(last ? UInt16(0) : ids[i + 1], at + 14)
    }
    store(ids[0], layout.available + 4 + 2 * (Int(availableIndex) % layout.size))
    availableIndex &+= 1
    // The ring's entry before its index (§2.7.13: a write barrier between).
    croi_dma_barrier()
    store(availableIndex, layout.available + 2)
    return ids[0]
  }

  /// Whether the device wants a notify for what `submit` made available:
  /// it sets NO_NOTIFY in the used ring's flags while it is working through
  /// the queue anyway (§2.7.10, without EVENT_IDX). Read past a full
  /// barrier after the index's store, so a device that clears the flag and
  /// then looks at the index sees the new entries either way. A notify is
  /// an exit under a hypervisor, and QEMU's virtio-net sets the flag while
  /// it sends what it was given.
  public var needsNotify: Bool {
    croi_dma_barrier()
    return load(layout.used, UInt16.self) & 1 == 0
  }

  /// Requests the device has finished since the last call: each head's id,
  /// the bytes it wrote, and its first buffer's bus address (which names
  /// the request's buffer without a table of ids: a driver posting buffers
  /// again would otherwise have to read every completion's id before
  /// posting, since the ids are free again and may be reused at once).
  public func completed() -> [(id: UInt16, written: UInt32, address: UInt64)] {
    var out: [(id: UInt16, written: UInt32, address: UInt64)] = []
    let deviceIndex: UInt16 = load(layout.used + 2, UInt16.self)
    croi_dma_barrier()  // the entries after the index that covers them
    while usedSeen != deviceIndex {
      let at = layout.used + 4 + 8 * (Int(usedSeen) % layout.size)
      let id = UInt16(truncatingIfNeeded: load(at, UInt32.self))
      out.append((id, load(at + 4, UInt32.self), load(layout.descriptors + 16 * Int(id), UInt64.self)))
      var d = id
      while true {
        free.append(d)
        let flags: UInt16 = load(layout.descriptors + 16 * Int(d) + 12, UInt16.self)
        guard flags & 1 != 0 else { break }
        d = load(layout.descriptors + 16 * Int(d) + 14, UInt16.self)
      }
      usedSeen &+= 1
    }
    return out
  }
}
