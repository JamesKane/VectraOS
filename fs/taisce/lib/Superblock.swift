// SPDX-License-Identifier: BSD-3-Clause

/// Where a volume's regions are, in blocks (S1): a ring of superblock slots
/// at the start, two free-space bitmaps (alternating by transaction group),
/// the intent log, data, and the ring's footer copies at the end.
public struct Layout: Equatable, Sendable {
  public var blockCount: UInt64
  public var bitmapBlocks: UInt64
  /// The intent log (S1e): where `fsync` writes.
  public var intentStart: UInt64
  public var intentBlocks: UInt64
  public var dataStart: UInt64
  /// Where the data ends and the footer ring starts.
  public var dataEnd: UInt64

  public static let blockSize = 4096
  /// B+tree nodes: 16 KiB, four blocks (filesystem.md §3).
  public static let nodeBlocks = 4
  /// Superblock slots in each ring (head and footer).
  public static let ringSlots: UInt64 = 4

  public init(blockCount: UInt64) throws(TaisceError) {
    let bitsPerBlock = UInt64(Self.blockSize * 8)
    let bitmap = (blockCount + bitsPerBlock - 1) / bitsPerBlock
    // The intent log: 1% of the volume, from 1 MiB to 16 MiB.
    self.init(unchecked: blockCount, bitmapBlocks: bitmap, intentBlocks: min(max(blockCount / 100, 256), 4096))
    // Room for at least a few nodes of data.
    guard dataStart + UInt64(Self.nodeBlocks) * 8 <= dataEnd, blockCount > 2 * Self.ringSlots else { throw .tooSmall }
  }

  init(unchecked blockCount: UInt64, bitmapBlocks: UInt64, intentBlocks: UInt64) {
    self.blockCount = blockCount
    self.bitmapBlocks = bitmapBlocks
    intentStart = Self.ringSlots + 2 * bitmapBlocks
    self.intentBlocks = intentBlocks
    dataStart = intentStart + intentBlocks
    dataEnd = blockCount >= Self.ringSlots ? blockCount - Self.ringSlots : 0
  }

  /// The bitmap region a transaction group writes: they alternate.
  public func bitmapStart(txg: UInt64) -> UInt64 { Self.ringSlots + (txg % 2) * bitmapBlocks }
  /// A transaction group's superblock: its head copy and its footer copy.
  public func headSlot(txg: UInt64) -> UInt64 { txg % Self.ringSlots }
  public func footerSlot(txg: UInt64) -> UInt64 { dataEnd + txg % Self.ringSlots }
  /// Blocks never handed out: the ring, the bitmaps, the intent log, the
  /// footer ring.
  public var reserved: UInt64 { dataStart + (blockCount - dataEnd) }
}

/// The volume's root record (S1). Each transaction group writes one, to its
/// slot in the ring and again to the footer; whichever copy is newest and
/// valid wins at mount. That write is the commit.
public struct Superblock: Equatable, Sendable {
  public static let magic: UInt64 = 0x0000_6563_7369_6154  // "Taisce\0\0", little-endian
  public static let version: UInt32 = 4  // S1: superblock flip, data checksums, the intent log

  public var layout: Layout
  /// The transaction group this superblock commits.
  public var txg: UInt64
  public var uuid: [UInt8]  // 16 bytes
  public var label: [UInt8]  // UTF-8, at most 64 bytes
  public var createdNs: UInt64
  /// The catalog's root: the tree of every tree's root pointer.
  public var catalogRoot: NodePointer
  public var nextInode: UInt64
  /// BLAKE3-128 of this group's whole bitmap region, checked at mount.
  public var bitmapChecksum: Checksum = .zero

  public init(layout: Layout, uuid: [UInt8], label: [UInt8], createdNs: UInt64) {
    self.layout = layout
    txg = 1
    self.uuid = uuid
    self.label = Array(label.prefix(64))
    self.createdNs = createdNs
    catalogRoot = .null
    nextInode = 2  // 1 is the root directory
  }

  // The block: fields at fixed offsets, BLAKE3-128 of the rest in its last 16 bytes.
  static let checksumOffset = Layout.blockSize - 16

  public func encode() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: Layout.blockSize)
    b.put(Self.magic, at: 0)
    b.put(Self.version, at: 8)
    b.put(UInt32(Layout.blockSize), at: 12)
    b.put(txg, at: 16)
    b.put(layout.blockCount, at: 24)
    b.put(layout.bitmapBlocks, at: 32)
    b.put(UInt32(Layout.nodeBlocks), at: 40)
    b.put(UInt32(Layout.ringSlots), at: 44)
    b.put(createdNs, at: 48)
    catalogRoot.put(into: &b, at: 56)  // to 88
    b.put(nextInode, at: 88)
    b.put(bytes: uuid, at: 96)
    b.put(UInt8(label.count), at: 112)
    b.put(bytes: label, at: 113)
    b.put(bitmapChecksum.a, at: 184)
    b.put(bitmapChecksum.b, at: 192)
    b.put(layout.intentBlocks, at: 200)
    let c = Checksum(of: Array(b[..<Self.checksumOffset]))
    b.put(c.a, at: Self.checksumOffset)
    b.put(c.b, at: Self.checksumOffset + 8)
    return b
  }

  /// A superblock from a block, or nil if it isn't a valid one.
  public static func decode(_ b: [UInt8]) throws(TaisceError) -> Superblock? {
    guard b.count >= Layout.blockSize, b.get(UInt64.self, at: 0) == magic,
      Checksum(a: b.get(UInt64.self, at: checksumOffset), b: b.get(UInt64.self, at: checksumOffset + 8))
        == Checksum(of: Array(b[..<checksumOffset]))
    else { return nil }
    let version = b.get(UInt32.self, at: 8)
    guard version == Self.version else { throw .unsupportedVersion(version) }
    guard b.get(UInt32.self, at: 12) == UInt32(Layout.blockSize), b.get(UInt32.self, at: 40) == UInt32(Layout.nodeBlocks),
      b.get(UInt32.self, at: 44) == UInt32(Layout.ringSlots)
    else { throw .corrupt(.superblockLayout) }
    let layout = Layout(unchecked: b.get(UInt64.self, at: 24), bitmapBlocks: b.get(UInt64.self, at: 32),
                        intentBlocks: b.get(UInt64.self, at: 200))
    guard layout.dataStart < layout.dataEnd,
      layout.bitmapBlocks * UInt64(Layout.blockSize) * 8 >= layout.blockCount
    else { throw .corrupt(.superblockLayout) }
    let labelCount = min(Int(b[112]), 64)
    var s = Superblock(layout: layout, uuid: b.get(bytes: 16, at: 96), label: b.get(bytes: labelCount, at: 113),
                       createdNs: b.get(UInt64.self, at: 48))
    s.txg = b.get(UInt64.self, at: 16)
    s.catalogRoot = NodePointer.get(b, at: 56)
    s.nextInode = b.get(UInt64.self, at: 88)
    s.bitmapChecksum = Checksum(a: b.get(UInt64.self, at: 184), b: b.get(UInt64.self, at: 192))
    return s
  }
}
