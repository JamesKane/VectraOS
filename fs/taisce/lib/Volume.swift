// SPDX-License-Identifier: BSD-3-Clause

/// A Taisce volume on a device: its superblock and free space (S1).
///
/// A transaction group commits by superblock flip: everything it changed is
/// written to blocks nothing committed points at (copy-on-write), then a
/// barrier, then its superblock, to its ring slot and to the footer, then a
/// barrier. Mount takes the newest valid superblock; there's no log to
/// replay.
///
/// An encrypted volume's device is a SealedDevice with its volume key's
/// sealing (S2, D153 §3): its superblocks carry the keybag and are
/// authenticated by the key, and every other checksum is keyed by it.
public struct Volume<Device: BlockDevice>: ~Copyable {
  public var device: Device
  public private(set) var superblock: Superblock
  public var allocator: Allocator

  /// Makes a new, empty volume on `device`: an encrypted one if `keybag`
  /// is given, which must hold the key `device` is sealed with.
  public static func format(_ device: consuming Device, label: [UInt8], uuid: [UInt8], now: UInt64,
                            keybag: Keybag? = nil) throws(TaisceError) -> Volume
  {
    guard device.blockSize == Layout.blockSize, (keybag == nil) == (device.checksumKey == nil) else {
      throw .outOfRange
    }
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
    superblock.keybag = keybag
    superblock.bitmapChecksum = allocator.checksum(key: device.checksumKey)
    try device.write(layout.headSlot(txg: superblock.txg), superblock.encode(key: device.checksumKey))
    try device.write(layout.footerSlot(txg: superblock.txg), superblock.encode(key: device.checksumKey))
    try device.flush()
    return Volume(device: device, superblock: superblock, allocator: allocator)
  }

  /// Opens the volume on `device`: the newest valid superblock wins, and its
  /// group's bitmap is the free space. An encrypted volume needs its key's
  /// sealing on the device (`.locked` without one); a plain one, none.
  public static func open(_ device: consuming Device) throws(TaisceError) -> Volume {
    let superblock = try newestSuperblock(&device)
    guard superblock.keybag == nil || device.checksumKey != nil else { throw .locked }
    guard superblock.keybag != nil || device.checksumKey == nil else { throw .invalid }
    let layout = superblock.layout
    let bitmap = try device.read(layout.bitmapStart(txg: superblock.txg), count: Int(layout.bitmapBlocks))
    var allocator = try Allocator(blockCount: layout.blockCount, bitmap: bitmap)
    guard allocator.checksum(key: device.checksumKey) == superblock.bitmapChecksum else {
      throw .corrupt(.bitmapChecksum)
    }
    // The other region holds the bitmap of the group before this one, so
    // the next commit, which writes it, writes all of it: its own changes
    // alone would leave stale whatever this group changed.
    allocator.markDirty(region: Int((superblock.txg + 1) % 2))
    return Volume(device: device, superblock: superblock, allocator: allocator)
  }

  /// The newest valid superblock among the head ring and the footer ring;
  /// on a sealed device, the newest its key authenticates. Unsealed, an
  /// encrypted volume's newest copy is read for its keybag.
  public static func newestSuperblock(_ device: inout Device) throws(TaisceError) -> Superblock {
    guard device.blockSize == Layout.blockSize, device.blockCount > 2 * Layout.ringSlots else { throw .notAVolume }
    var newest: Superblock?
    let key = device.checksumKey
    func consider(_ block: UInt64) throws(TaisceError) {
      let bytes = try device.read(block, count: 1)
      guard let s = try Superblock.decode(bytes) else { return }
      if let key, s.keybag != nil, !Superblock.authentic(bytes, key: key) { return }
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

  /// A new keybag for the next commit's superblock.
  mutating func setKeybag(_ keybag: Keybag) { superblock.keybag = keybag }

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
    next.bitmapChecksum = allocator.checksum(key: device.checksumKey)
    let layout = next.layout
    for (index, bytes) in allocator.dirtyBlocks(region: Int(next.txg % 2)) {
      try device.write(layout.bitmapStart(txg: next.txg) + index, bytes)
    }
    try device.flush()
    let block = next.encode(key: device.checksumKey)
    try device.write(layout.headSlot(txg: next.txg), block)
    try device.write(layout.footerSlot(txg: next.txg), block)
    try device.flush()
    superblock = next
    return allocator.groupCommitted()
  }
}
