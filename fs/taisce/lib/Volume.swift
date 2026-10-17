// SPDX-License-Identifier: BSD-3-Clause

/// A Taisce volume on a device: its superblock and free space (S1).
///
/// A transaction group commits by superblock flip: everything it changed is
/// written to blocks nothing committed points at (copy-on-write), then a
/// barrier, then its superblock, to its ring slot and to the footer, then a
/// barrier. Mount takes the newest valid superblock; there's no log to
/// replay.
public struct Volume<Device: BlockDevice>: ~Copyable {
  public var device: Device
  public private(set) var superblock: Superblock
  public var allocator: Allocator

  /// Makes a new, empty volume on `device`.
  public static func format(_ device: consuming Device, label: [UInt8], uuid: [UInt8], now: UInt64)
    throws(TaisceError) -> Volume
  {
    guard device.blockSize == Layout.blockSize else { throw .outOfRange }
    let layout = try Layout(blockCount: device.blockCount)
    var allocator = Allocator(blockCount: layout.blockCount, reserved: layout.dataStart, reservedTail: Layout.ringSlots)
    // No stale superblock from an earlier volume may survive in either ring.
    let zero = [UInt8](repeating: 0, count: Layout.blockSize)
    for slot in 0..<Layout.ringSlots {
      try device.write(slot, zero)
      try device.write(layout.dataEnd + slot, zero)
    }
    // Both bitmaps, then the first superblock.
    let bitmap = allocator.allBlocks()
    for txg: UInt64 in 0..<2 {
      for (index, bytes) in bitmap { try device.write(layout.bitmapStart(txg: txg) + index, bytes) }
    }
    try device.flush()
    var superblock = Superblock(layout: layout, uuid: uuid, label: label, createdNs: now)
    superblock.bitmapChecksum = allocator.checksum()
    try device.write(layout.headSlot(txg: superblock.txg), superblock.encode())
    try device.write(layout.footerSlot(txg: superblock.txg), superblock.encode())
    try device.flush()
    return Volume(device: device, superblock: superblock, allocator: allocator)
  }

  /// Opens the volume on `device`: the newest valid superblock wins, and its
  /// group's bitmap is the free space.
  public static func open(_ device: consuming Device) throws(TaisceError) -> Volume {
    let superblock = try newestSuperblock(&device)
    let layout = superblock.layout
    let bitmap = try device.read(layout.bitmapStart(txg: superblock.txg), count: Int(layout.bitmapBlocks))
    var allocator = try Allocator(blockCount: layout.blockCount, bitmap: bitmap)
    guard allocator.checksum() == superblock.bitmapChecksum else { throw .corrupt(.bitmapChecksum) }
    // The other region holds the bitmap of the group before this one, so
    // the next commit, which writes it, writes all of it: its own changes
    // alone would leave stale whatever this group changed.
    allocator.markDirty(region: Int((superblock.txg + 1) % 2))
    return Volume(device: device, superblock: superblock, allocator: allocator)
  }

  /// The newest valid superblock among the head ring and the footer ring.
  public static func newestSuperblock(_ device: inout Device) throws(TaisceError) -> Superblock {
    guard device.blockSize == Layout.blockSize, device.blockCount > 2 * Layout.ringSlots else { throw .notAVolume }
    var newest: Superblock?
    func consider(_ block: UInt64) throws(TaisceError) {
      guard let s = try Superblock.decode(device.read(block, count: 1)) else { return }
      if newest.map({ s.txg > $0.txg }) ?? true { newest = s }
    }
    for slot in 0..<Layout.ringSlots {
      try consider(slot)
      try consider(device.blockCount - Layout.ringSlots + slot)
    }
    guard let superblock = newest else { throw .notAVolume }
    guard superblock.layout.blockCount == device.blockCount else { throw .corrupt(.superblockLayout) }
    return superblock
  }

  /// How many of this group's superblock copies (head, footer) are intact.
  public mutating func intactCopies() throws(TaisceError) -> Int {
    let layout = superblock.layout
    var intact = 0
    for block in [layout.headSlot(txg: superblock.txg), layout.footerSlot(txg: superblock.txg)] {
      if let s = try? Superblock.decode(device.read(block, count: 1)), s == superblock { intact += 1 }
    }
    return intact
  }

  init(device: consuming Device, superblock: Superblock, allocator: Allocator) {
    self.device = device
    self.superblock = superblock
    self.allocator = allocator
  }

  /// Commits the next transaction group: its bitmap, a barrier, its
  /// superblock (ring slot and footer), a barrier. Whatever else the group
  /// changed must already be written (to blocks nothing committed points
  /// at); this barrier makes it durable before the superblock names it.
  /// Returns the blocks this retires (see `Allocator.groupCommitted`).
  @discardableResult
  public mutating func commit(_ update: (inout Superblock) -> Void = { _ in }) throws(TaisceError) -> [Extent] {
    var next = superblock
    update(&next)
    next.txg = superblock.txg + 1
    next.bitmapChecksum = allocator.checksum()
    let layout = next.layout
    for (index, bytes) in allocator.dirtyBlocks(region: Int(next.txg % 2)) {
      try device.write(layout.bitmapStart(txg: next.txg) + index, bytes)
    }
    try device.flush()
    let block = next.encode()
    try device.write(layout.headSlot(txg: next.txg), block)
    try device.write(layout.footerSlot(txg: next.txg), block)
    try device.flush()
    superblock = next
    return allocator.groupCommitted()
  }
}
