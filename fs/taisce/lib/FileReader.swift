// SPDX-License-Identifier: BSD-3-Clause

/// A lock-free reader of a file system (S1f), one per thread. Inside
/// `withSnapshot` it sees one published state, whole, without taking a
/// lock or waiting for the writer. Every cache keeps each node and block
/// with the checksum it was verified against, and a hit must match the
/// checksum the snapshot expects, so none needs invalidating when a block
/// is reused.
///
/// Verified bytes (file blocks, nodes as stored) are in caches all the
/// file system's readers share (`ReaderCaches`), so a block one reader
/// read is a hit for the next. Each reader keeps its own small cache of
/// decoded nodes: a decoded node's arrays shared between threads would
/// have their reference counts bounce between cores on every read. Its
/// cache is two-way set-associative: two hot nodes that map to one set (a
/// tree's root and an inner node, say) don't evict each other on every
/// read, as they did direct-mapped.
public struct FileReader<Device: ConcurrentReadable>: ~Copyable, FileReading, Sendable {
  let epochs: EpochManager
  let device: Device
  let slot: Int
  var snapshot: Snapshot?
  var nodes: VerifiedCache<Node>
  let shared: ReaderCaches

  /// A reader of what the writer publishes to `epochs`, on `device` (a copy
  /// of the writer's); nil if every reader slot is taken.
  init?(epochs: EpochManager, device: Device, shared: ReaderCaches, cacheNodes: Int) {
    guard let slot = epochs.register() else { return nil }
    self.epochs = epochs
    self.device = device
    self.slot = slot
    self.shared = shared
    nodes = VerifiedCache(count: cacheNodes)
  }

  deinit { epochs.unregister(slot) }

  /// Runs `body` on the latest published state. Keep it short: the writer
  /// can't reuse what this snapshot sees until it's done.
  public mutating func withSnapshot<T, E: Error>(_ body: (inout FileReader) throws(E) -> T) throws(E) -> T {
    epochs.enter(slot)
    snapshot = epochs.snapshot()
    defer {
      snapshot = nil
      epochs.exit(slot)
    }
    return try body(&self)
  }

  public func root(_ id: UInt64) -> BTree? { snapshot!.root(id) }

  public mutating func node(_ pointer: NodePointer) throws(TaisceError) -> Node {
    if let n = snapshot!.dirty.node(pointer.block) { return n }
    let set = pointer.block / UInt64(Layout.nodeBlocks)
    if let n = nodes.get(pointer.block, pointer.checksum, set: set) { return n }
    var bytes: [UInt8] = []
    if !shared.nodes.get(pointer.block, pointer.checksum, set: set, into: &bytes) {
      bytes = try device.readConcurrently(pointer.block, count: Layout.nodeBlocks)
      guard Checksum(of: bytes) == pointer.checksum else { throw .corrupt(.checksum(pointer.block)) }
      shared.nodes.put(pointer.block, pointer.checksum, set: set, bytes)
    }
    let node = try Node.decode(bytes)
    nodes.put(pointer.block, pointer.checksum, node, set: set)
    return node
  }

  public mutating func dataBlocks(_ physical: UInt64, _ checksums: ArraySlice<Checksum>) throws(TaisceError)
    -> [UInt8]
  {
    let bs = Layout.blockSize
    var out: [UInt8] = []
    out.reserveCapacity(checksums.count * bs)
    for (k, sum) in checksums.enumerated() {
      let b = physical + UInt64(k)
      guard shared.blocks.get(b, sum, set: b, into: &out) else { break }
    }
    if out.count == checksums.count * bs { return out }
    let bytes = try device.readConcurrently(physical, count: checksums.count)
    for (k, sum) in checksums.enumerated() {
      let b = physical + UInt64(k)
      guard Checksum(of: Array(bytes[(k * bs)..<((k + 1) * bs)])) == sum else { throw .corrupt(.checksum(b)) }
      shared.blocks.put(b, sum, set: b, bytes, from: k * bs)
    }
    return bytes
  }
}

extension FileSystem where Device: ConcurrentReadable {
  /// A lock-free reader for another thread (S1f), keeping up to
  /// `cacheNodes` decoded nodes of its own; nil if all
  /// `EpochManager.readers` slots are taken. The first starts the writer
  /// publishing snapshots, and makes the caches every reader shares, of
  /// `sharedNodes` nodes and `sharedBlocks` file blocks (later readers'
  /// shared sizes are ignored).
  public mutating func reader(cacheNodes: Int = 256, sharedNodes: Int = 512, sharedBlocks: Int = 4096)
    -> FileReader<Device>?
  {
    let epochs = engine.enableReaders()
    let shared = readerCaches ?? ReaderCaches(blocks: sharedBlocks, nodes: sharedNodes)
    readerCaches = shared
    return FileReader(epochs: epochs, device: engine.store.volume.device, shared: shared, cacheNodes: cacheNodes)
  }
}

/// What a reader verified, by block and the checksum it matched: `count`
/// entries in sets of two ways, the least recently used way replaced.
struct VerifiedCache<Value: Sendable>: Sendable {
  var blocks: [UInt64]  // block + 1; 0 is empty
  var checksums: [Checksum]
  var values: [Value?]
  /// Per set, the way used last.
  var recent: [UInt8]

  init(count: Int) {
    let n = max(2, count + count % 2)
    blocks = [UInt64](repeating: 0, count: n)
    checksums = [Checksum](repeating: .zero, count: n)
    values = [Value?](repeating: nil, count: n)
    recent = [UInt8](repeating: 0, count: n / 2)
  }

  /// The value for `block` verified against `checksum`; `set` picks its set.
  mutating func get(_ block: UInt64, _ checksum: Checksum, set: UInt64) -> Value? {
    let s = Int(set % UInt64(recent.count))
    for way in 0..<2 where blocks[2 * s + way] == block + 1 && checksums[2 * s + way] == checksum {
      recent[s] = UInt8(way)
      return values[2 * s + way]
    }
    return nil
  }

  mutating func put(_ block: UInt64, _ checksum: Checksum, _ value: Value, set: UInt64) {
    let s = Int(set % UInt64(recent.count))
    // The way this block already has, else the one not used last.
    let way = blocks[2 * s] == block + 1 ? 0 : blocks[2 * s + 1] == block + 1 ? 1 : 1 - Int(recent[s])
    blocks[2 * s + way] = block + 1
    checksums[2 * s + way] = checksum
    values[2 * s + way] = value
    recent[s] = UInt8(way)
  }
}
