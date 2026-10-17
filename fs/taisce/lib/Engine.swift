// SPDX-License-Identifier: BSD-3-Clause

/// A change to apply to a value without reading it first: gefs's blind
/// deltas (filesystem.md §4), such as "set mtime and size" or "bump the
/// version".
public enum Delta: Equatable, Sendable {
  /// Overwrites bytes at `offset`.
  case put(offset: Int, bytes: [UInt8])
  /// Adds to the little-endian u64 at `offset`, wrapping.
  case add(offset: Int, value: UInt64)
}

/// One step of a transaction.
public enum Message: Equatable, Sendable {
  case insert(tree: UInt64, key: [UInt8], value: [UInt8])
  case delete(tree: UInt64, key: [UInt8])
  case delta(tree: UInt64, key: [UInt8], Delta)

  var tree: UInt64 {
    switch self {
    case .insert(let t, _, _), .delete(let t, _), .delta(let t, _, _): t
    }
  }
  var key: [UInt8] {
    switch self {
    case .insert(_, let k, _), .delete(_, let k), .delta(_, let k, _): k
    }
  }
}

/// Taisce's storage engine: trees by ID, changed by atomic batches of
/// messages, made durable a transaction group at a time through the log.
/// Callers never see nodes or blocks, so S1 can replace the commit layer
/// beneath this API (filesystem.md §2, §4).
public struct Engine<Device: BlockDevice>: ~Copyable {
  public var store: Store<Device>
  /// Every tree's root, by ID, sorted; `changed` marks those to record in
  /// the catalog at the next commit.
  var trees: [(id: UInt64, tree: BTree, changed: Bool)] = []
  var catalog: BTree
  /// The transaction group being built: one past the last committed.
  public private(set) var txg: UInt64
  /// File data was written since the last commit: the commit's barrier
  /// covers it.
  public var dataWritten = false
  /// The operations since the last commit or fsync, for the intent log; and
  /// file blocks allocated for the batch about to be applied.
  var pendingOps: [IntentOp] = []
  var staged: [Extent] = []
  /// Where the next intent record goes (blocks into the region), and its seq.
  var intentAt: UInt64 = 0
  var intentSeq: UInt64 = 0
  public var nextInode: UInt64
  /// A commit failed on the device: what it had written (bitmap blocks
  /// marked written, trees marked unchanged, nodes still fresh) can't be
  /// trusted, so the engine writes nothing more until it's mounted again.
  public private(set) var stopped = false

  /// Stops writes until the next mount: something reached the device, or
  /// failed to, that later commits can't be trusted with.
  mutating func stop() { stopped = true }
  /// Lock-free readers (S1f), once enabled: their epochs, and what waits
  /// for them in limbo (snapshots replaced, blocks retired), oldest first,
  /// with the epoch each was retired in.
  public private(set) var readers: EpochManager?
  var limbo: [(epoch: UInt64, snapshot: Snapshot?, blocks: [Extent])] = []
  /// More than this many in limbo and the writer waits for readers.
  static var limboLimit: Int { 1024 }

  /// A new volume on `device`.
  public static func format(_ device: consuming Device, label: [UInt8], uuid: [UInt8], now: UInt64)
    throws(TaisceError) -> Engine
  {
    let volume = try Volume.format(device, label: label, uuid: uuid, now: now)
    return try mount(volume.device)
  }

  /// Mounts the volume on `device`: its newest valid superblock, then the
  /// intent log's records for it replayed and committed.
  public static func mount(_ device: consuming Device) throws(TaisceError) -> Engine {
    var e = try Engine(Store(try Volume.open(device)))
    try e.replayIntentLog()
    return e
  }

  init(_ store: consuming Store<Device>) throws(TaisceError) {
    self.store = store
    let sb = self.store.volume.superblock
    catalog = BTree(root: sb.catalogRoot)
    nextInode = sb.nextInode
    txg = sb.txg + 1
    for (key, value) in try catalog.scan(from: [], &self.store) {
      guard key.count == 8, value.count == NodePointer.size else { throw .corrupt(.catalog) }
      trees.append((Self.bigEndianID(key), BTree(root: NodePointer.get(value, at: 0)), false))
    }
  }

  static func idKey(_ id: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: id >> (56 - 8 * $0)) } }
  static func bigEndianID(_ key: [UInt8]) -> UInt64 { key.reduce(0) { $0 << 8 | UInt64($1) } }

  func treeIndex(_ id: UInt64) -> (found: Bool, at: Int) {
    var lo = 0, hi = trees.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if trees[mid].id < id { lo = mid + 1 } else { hi = mid }
    }
    return (lo < trees.count && trees[lo].id == id, lo)
  }

  /// Tree `id`'s root, or nil if it has never had entries.
  public func root(_ id: UInt64) -> BTree? {
    let t = treeIndex(id)
    return t.found ? trees[t.at].tree : nil
  }

  /// The IDs of every tree with entries.
  public var treeIDs: [UInt64] { trees.filter { !$0.tree.isEmpty }.map { $0.id } }

  // MARK: Reading

  public mutating func get(_ tree: UInt64, _ key: [UInt8]) throws(TaisceError) -> [UInt8]? {
    let t = treeIndex(tree)
    guard t.found else { return nil }
    return try trees[t.at].tree.get(key, &store)
  }

  /// The last entry of `tree` whose key is at most `key`.
  public mutating func floor(_ tree: UInt64, _ key: [UInt8]) throws(TaisceError) -> (key: [UInt8], value: [UInt8])? {
    let t = treeIndex(tree)
    guard t.found else { return nil }
    return try trees[t.at].tree.floor(key, &store)
  }

  public mutating func scan(_ tree: UInt64, from: [UInt8], to: [UInt8]? = nil, limit: Int = Int.max)
    throws(TaisceError) -> [(key: [UInt8], value: [UInt8])]
  {
    let t = treeIndex(tree)
    guard t.found else { return [] }
    return try trees[t.at].tree.scan(from: from, to: to, limit: limit, &store)
  }

  // MARK: Transactions

  /// Applies `batch` atomically: all of it, or (if one message fails)
  /// none. The messages are sorted by tree and key, keeping their order
  /// within a key. Durable after the next `commitGroup`.
  public mutating func apply(_ batch: [Message]) throws(TaisceError) {
    do {
      try applyOnce(batch)
    } catch .noSpace where hasLimboBlocks {
      // Back-pressure: space readers still hold comes back when they leave.
      waitForReaders()
      try applyOnce(batch)
    }
  }

  mutating func applyOnce(_ batch: [Message]) throws(TaisceError) {
    guard !stopped else { throw .readOnly }
    let ordered = batch.indices.sorted { a, b in
      let x = batch[a], y = batch[b]
      if x.tree != y.tree { return x.tree < y.tree }
      if x.key != y.key { return x.key.lexicographicallyPrecedes(y.key) }
      return a < b
    }.map { batch[$0] }
    // To roll back to if a message fails: the roots and changed nodes as
    // they are (shared, copy-on-write), and the allocator's words as the
    // batch changes them. Re-applying old values instead could itself
    // need space, and fail, half-way.
    let savedTrees = trees, savedDirty = store.dirty
    store.volume.allocator.beginBatch()
    do throws(TaisceError) {
      for m in ordered {
        let before = try get(m.tree, m.key)
        switch m {
        case .insert(let tree, let key, let value):
          try set(tree, key, value)
        case .delete(let tree, let key):
          if before != nil { try remove(tree, key) }
        case .delta(let tree, let key, let delta):
          guard var value = before else { throw .missingKey }
          try Self.apply(delta, to: &value)
          try set(tree, key, value)
        }
      }
    } catch {
      trees = savedTrees
      store.dirty = savedDirty
      store.volume.allocator.rollBack()
      throw error
    }
    store.volume.allocator.endBatch()
    pendingOps.append(IntentOp(messages: batch, allocated: staged, freed: []))
    if readers != nil {
      // Readers will see these blocks: never rewritten in place again.
      for e in staged { store.volume.allocator.pin(e) }
      publish()
    }
    staged = []
  }

  // MARK: Readers (S1f)

  /// Starts publishing snapshots for lock-free readers; returns their
  /// epochs. From here on, file blocks a reader can see aren't rewritten in
  /// place, and freed blocks wait in limbo for readers older than them.
  public mutating func enableReaders() -> EpochManager {
    if let r = readers { return r }
    let r = EpochManager()
    readers = r
    store.volume.allocator.pinFresh()
    publish()
    return r
  }

  /// Publishes the current state for readers.
  mutating func publish() {
    guard let r = readers else { return }
    retire(r.publish(Snapshot(trees: trees, dirty: store.dirty)), [])
  }

  /// Puts what readers may still see in limbo (with no readers, blocks are
  /// released at once), and releases whatever no reader can see any more.
  /// Back-pressure: with too much in limbo, waits for readers to move on.
  mutating func retire(_ snapshot: Snapshot?, _ blocks: [Extent]) {
    guard let r = readers else {
      for e in blocks { store.volume.allocator.release(retired: e) }
      return
    }
    if snapshot != nil || !blocks.isEmpty { limbo.append((r.current, snapshot, blocks)) }
    repeat {
      // Two advances release everything, if no reader holds either back.
      for _ in 0..<2 where limbo.last.map({ $0.epoch + 2 > r.current }) ?? false { r.tryAdvance() }
      let now = r.current
      var done = 0
      while done < limbo.count, limbo[done].epoch + 2 <= now {
        for e in limbo[done].blocks { store.volume.allocator.release(retired: e) }
        done += 1
      }
      if done > 0 { limbo.removeFirst(done) }
    } while limbo.count > Self.limboLimit
  }

  /// How many retirements wait in limbo (the readers' tests watch it).
  public var limboCount: Int { limbo.count }

  /// Freed blocks not yet available again: commits (and readers) give
  /// them back.
  public var reclaimable: UInt64 { store.volume.allocator.waitingCount }

  /// Makes every freed block available: a commit moves this group's frees
  /// to deferred and the last group's to retired, a second retires those,
  /// and the readers then let go of them all. What a writer does when it
  /// runs out of space with `reclaimable` blocks waiting.
  public mutating func reclaim() throws(TaisceError) {
    try commitGroup()
    try commitGroup()
    waitForReaders()
  }

  /// Whether blocks wait in limbo: space that readers will give back.
  public var hasLimboBlocks: Bool { limbo.contains { !$0.blocks.isEmpty } }

  /// Waits (spinning: readers' snapshots are short) until no reader holds
  /// anything in limbo, and releases it all.
  public mutating func waitForReaders() {
    while !limbo.isEmpty { retire(nil, []) }
  }

  // MARK: The intent log (S1e)

  /// File blocks the file system allocated for the batch it's about to apply.
  public mutating func noteAllocated(_ extents: [Extent]) { staged += extents }

  /// The batch failed: those blocks aren't the log's business.
  public mutating func dropStaged() { staged = [] }

  /// File blocks freed after the last batch.
  public mutating func noteFreed(_ extents: [Extent]) {
    guard !extents.isEmpty else { return }
    if pendingOps.isEmpty { pendingOps.append(IntentOp(messages: [], allocated: [], freed: [])) }
    pendingOps[pendingOps.count - 1].freed += extents
  }

  /// Makes everything applied durable without a group commit: the
  /// operations since the last commit or fsync go to the intent log as one
  /// record, then a barrier (which also covers the file data already
  /// written). The blocks they allocated are pinned until the commit. If
  /// the log is full, it commits the group instead.
  public mutating func fsync() throws(TaisceError) {
    guard !stopped else { throw .readOnly }
    guard !pendingOps.isEmpty else {
      if dataWritten { try store.volume.device.flush() }
      return
    }
    let sb = store.volume.superblock
    let record = IntentLog.encode(IntentLog.Record(txg: sb.txg, seq: intentSeq, nextInode: nextInode, ops: pendingOps))
    let blocks = UInt64(record.count / Layout.blockSize)
    guard intentAt + blocks <= sb.layout.intentBlocks else {
      try commitGroup()
      return
    }
    try store.volume.device.write(sb.layout.intentStart + intentAt, record)
    try store.volume.device.flush()
    intentAt += blocks
    intentSeq += 1
    for op in pendingOps { for e in op.allocated { store.volume.allocator.pin(e) } }
    pendingOps = []
  }

  /// Replays the intent records that build on the mounted superblock, in
  /// order, and commits them.
  ///
  /// Every logged allocation is claimed before any batch is replayed:
  /// replay has blocks free that the run didn't (nothing is deferred after
  /// a mount), so an earlier batch's new node could otherwise land on a
  /// block a later batch's file data is in. A block a batch freed and a
  /// later one allocated again stays claimed.
  mutating func replayIntentLog() throws(TaisceError) {
    let sb = store.volume.superblock
    let end = sb.layout.intentStart + sb.layout.intentBlocks
    var at = sb.layout.intentStart
    var seq: UInt64 = 0
    var ops: [IntentOp] = []
    while let (record, blocks) = try IntentLog.read(&store.volume.device, at: at, end: end, txg: sb.txg, seq: seq) {
      ops += record.ops
      nextInode = max(nextInode, record.nextInode)
      at += blocks
      seq += 1
    }
    guard seq > 0 else { return }
    // Each logged block, with the last batch that allocated it; sorted.
    var lastAllocated: [(block: UInt64, op: Int)] = []
    for (i, op) in ops.enumerated() {
      for e in op.allocated {
        store.volume.allocator.claim(e)
        for b in e.start..<e.end { lastAllocated.append((b, i)) }
      }
    }
    lastAllocated.sort { $0.block < $1.block || ($0.block == $1.block && $0.op < $1.op) }
    func allocatedAfter(_ b: UInt64, _ i: Int) -> Bool {
      var lo = 0, hi = lastAllocated.count
      while lo < hi {
        let mid = (lo + hi) / 2
        if lastAllocated[mid].block <= b { lo = mid + 1 } else { hi = mid }
      }
      return lo > 0 && lastAllocated[lo - 1].block == b && lastAllocated[lo - 1].op > i
    }
    for (i, op) in ops.enumerated() {
      try apply(op.messages)
      for e in op.freed {
        for b in e.start..<e.end where !allocatedAfter(b, i) {
          store.volume.allocator.free(Extent(start: b, count: 1))
        }
      }
    }
    // Even if the records changed nothing: only a new txg retires them.
    try commitGroup(always: true)
  }

  static func apply(_ delta: Delta, to value: inout [UInt8]) throws(TaisceError) {
    switch delta {
    case .put(let offset, let bytes):
      guard offset >= 0, offset + bytes.count <= value.count else { throw .badDelta }
      value.put(bytes: bytes, at: offset)
    case .add(let offset, let n):
      guard offset >= 0, offset + 8 <= value.count else { throw .badDelta }
      value.put(value.get(UInt64.self, at: offset) &+ n, at: offset)
    }
  }

  mutating func set(_ id: UInt64, _ key: [UInt8], _ value: [UInt8]) throws(TaisceError) {
    var t = treeIndex(id)
    if !t.found {
      trees.insert((id, BTree(), true), at: t.at)
      t.found = true
    }
    var tree = trees[t.at].tree
    try tree.insert(key, value, &store)
    if tree != trees[t.at].tree { trees[t.at] = (id, tree, true) }
  }

  mutating func remove(_ id: UInt64, _ key: [UInt8]) throws(TaisceError) {
    let t = treeIndex(id)
    guard t.found else { return }
    var tree = trees[t.at].tree
    try tree.delete(key, &store)
    if tree != trees[t.at].tree { trees[t.at] = (id, tree, true) }
  }

  // MARK: Committing

  /// Blocks the next commit will write (an estimate: the catalog may add a few).
  public var pendingBlocks: Int { store.dirtyCount * Layout.nodeBlocks }

  /// Makes every applied transaction durable, by superblock flip. Each
  /// changed tree is written bottom-up to its new blocks (its nodes taking
  /// checksums), its root pointer goes into the catalog, and the catalog is
  /// written last; then the volume writes the bitmap, a barrier, the
  /// superblock naming the catalog's root, and a barrier. File data written
  /// for the group is made durable by that first barrier too.
  public mutating func commitGroup() throws(TaisceError) { try commitGroup(always: false) }

  /// `always`: write a superblock even if nothing changed (after replay,
  /// so the new txg leaves the intent records behind).
  mutating func commitGroup(always: Bool) throws(TaisceError) {
    guard !stopped else { throw .readOnly }
    let written: [(block: UInt64, bytes: [UInt8])]
    do {
      written = try prepareCommit()
    } catch .noSpace where hasLimboBlocks {
      // Back-pressure, as in `apply`: the catalog's copies need space that
      // readers will give back.
      waitForReaders()
      written = try prepareCommit()
    }
    let sb = store.volume.superblock
    // Nothing to commit only if nothing changed and no freed block waits on
    // a commit: moving held and deferred blocks on without a new superblock
    // would let a fallback to the previous one find them reused.
    let a = store.volume.allocator
    guard always || !written.isEmpty || dataWritten || catalog.root != sb.catalogRoot || nextInode != sb.nextInode
      || a.heldCount > 0 || a.deferredCount > 0
    else {
      retire(nil, store.volume.allocator.groupCommitted())
      pendingOps = []
      return
    }
    let root = catalog.root, inode = nextInode
    let retired: [Extent]
    do {
      for (block, bytes) in written { try store.volume.device.write(block, bytes) }
      store.written()
      retired = try store.volume.commit { sb in
        sb.catalogRoot = root
        sb.nextInode = inode
      }
    } catch {
      stopped = true
      throw error
    }
    retire(nil, retired)
    publish()
    dataWritten = false
    txg = store.volume.superblock.txg + 1
    // The new txg leaves every intent record behind.
    pendingOps = []
    intentAt = 0
    intentSeq = 0
  }

  /// A commit's work in memory: each changed tree's nodes take their
  /// checksums and the catalog takes its roots. Returns the nodes to write.
  /// All or nothing, like a batch: on failure the trees, catalog, nodes and
  /// allocator are as they were.
  mutating func prepareCommit() throws(TaisceError) -> [(block: UInt64, bytes: [UInt8])] {
    let savedTrees = trees, savedCatalog = catalog, savedDirty = store.dirty
    store.volume.allocator.beginBatch()
    store.volume.allocator.reserveOpen = true  // the reserve is for this
    defer { store.volume.allocator.reserveOpen = false }
    var written: [(block: UInt64, bytes: [UInt8])] = []
    do throws(TaisceError) {
      for i in trees.indices where trees[i].changed {
        try trees[i].tree.write(&store, txg: txg, &written)
        let key = Self.idKey(trees[i].id)
        if trees[i].tree.isEmpty {
          try catalog.delete(key, &store)
        } else {
          try catalog.insert(key, trees[i].tree.root.encode(), &store)
        }
        trees[i].changed = false
      }
      try catalog.write(&store, txg: txg, &written)
    } catch {
      trees = savedTrees
      catalog = savedCatalog
      store.dirty = savedDirty
      store.volume.allocator.rollBack()
      throw error
    }
    store.volume.allocator.endBatch()
    return written
  }

  /// Every block metadata lives in: each node's four blocks, in every tree
  /// and the catalog (scrub reads them all; the corruption tests flip them).
  public mutating func nodeBlocks() throws(TaisceError) -> [UInt64] {
    var firsts = try catalog.nodeBlocks(&store)
    for t in trees { firsts += try t.tree.nodeBlocks(&store) }
    return firsts.flatMap { b in (0..<UInt64(Layout.nodeBlocks)).map { b + $0 } }
  }

  /// Every tree's invariants, and that the blocks in use are exactly the
  /// reserved ones, the trees' nodes and `dataBlocks` (the file system's
  /// extents): nothing leaked, nothing shared.
  public mutating func check(dataBlocks: UInt64 = 0) throws(TaisceError) -> (entries: Int, nodes: Int) {
    var entries = 0, nodes = try catalog.check(&store).nodes
    for t in trees {
      let s = try t.tree.check(&store)
      entries += s.entries
      nodes += s.nodes
    }
    let a = store.volume.allocator
    let used = a.blockCount - a.freeCount
    guard used == store.volume.superblock.layout.reserved + UInt64(nodes * Layout.nodeBlocks) + dataBlocks else {
      throw .corrupt(.leakedBlocks)
    }
    return (entries, nodes)
  }
}
