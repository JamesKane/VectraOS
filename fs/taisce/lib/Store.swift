// SPDX-License-Identifier: BSD-3-Clause

/// Where a tree's reads get nodes: the writer's Store, or a reader's
/// snapshot (S1f).
public protocol NodeSource: ~Copyable {
  mutating func node(_ pointer: NodePointer) throws(TaisceError) -> Node
}

/// The volume, and the B+tree nodes in memory: a cache of clean nodes
/// (each checked against its pointer's checksum when read) up to a budget
/// of bytes, and the nodes changed in this transaction group, until the
/// commit writes them. Every tree on the volume shares one store.
///
/// Copy-on-write (S1): a committed node is never changed where it is.
/// `update` gives it a new block (unless it was allocated in this group,
/// which nothing committed points at) and holds the old one until the
/// commit.
public struct Store<Device: BlockDevice>: ~Copyable, NodeSource {
  public var volume: Volume<Device>
  var cache: NodeCache
  /// Changed nodes, by block: buckets, each sorted. A reader's snapshot
  /// (S1f) shares them, so a change after it copies one bucket and the
  /// outer array, not every node. No hashed collections in tier 0.
  var dirty = DirtyNodes()
  public var dirtyCount: Int { dirty.count }
  /// The newest snapshot's txg, 0 for none (S2): a block born at or
  /// before it is one that snapshot still sees.
  public internal(set) var newestSnapshot: UInt64 = 0
  /// Blocks let go that a snapshot still sees, until the commit puts
  /// them on the deadlist (Engine.prepareCommit): they stay in use.
  var dead: [Freed] = []

  /// The default budget: 512 full nodes, 8 MiB as stored.
  public static var defaultCacheBytes: Int { 512 * Node.bytes }

  public init(_ volume: consuming Volume<Device>, cacheBytes: Int = Self.defaultCacheBytes) {
    self.volume = volume
    cache = NodeCache(bytes: cacheBytes)
  }

  /// The node `pointer` points at. Read from the device, its bytes must
  /// have the pointer's checksum (`.corrupt(.checksum)` otherwise).
  public mutating func node(_ pointer: NodePointer) throws(TaisceError) -> Node {
    let block = pointer.block
    if let n = dirty.node(block) { return n }
    if let n = cache.node(block) { return n }
    let bytes = try volume.device.read(block, count: Layout.nodeBlocks)
    guard Checksum(of: bytes, key: volume.device.checksumKey) == pointer.checksum else { throw .corrupt(.checksum(block)) }
    let node = try Node(page: bytes)
    cache.put(block, node)
    return node
  }

  /// Gives the node `p` points at its new contents for this group: its
  /// block itself if it was allocated in this group, else a new one (the
  /// old is let go as `release` says). Returns the block it's now at.
  public mutating func update(_ p: NodePointer, _ node: Node) throws(TaisceError) -> UInt64 {
    if volume.allocator.isFresh(p.block) {
      put(p.block, node)
      return p.block
    }
    let moved = try allocateNode(near: p.block)
    put(moved, node)
    freeNode(p)
    return moved
  }

  /// Replaces the node at `block`, in memory until `writeDirty`.
  public mutating func put(_ block: UInt64, _ node: Node) {
    dirty.put(block, node)
    cache.remove(block)
  }

  /// Blocks for a new node, near `hint`.
  public mutating func allocateNode(near hint: UInt64 = 0) throws(TaisceError) -> UInt64 {
    try volume.allocator.allocateContiguous(UInt64(Layout.nodeBlocks), near: hint).start
  }

  /// Lets go of the node `p` points at, and forgets it.
  public mutating func freeNode(_ p: NodePointer) {
    dirty.remove(p.block)
    cache.remove(p.block)
    release(Extent(start: p.block, count: UInt64(Layout.nodeBlocks)), birth: p.birth)
  }

  /// Lets go of blocks the live volume no longer uses, written in group
  /// `birth`: freed, unless the newest snapshot sees them (born at or
  /// before it, and not allocated in this group, whose pointers have no
  /// birth yet), when they wait for the deadlist.
  public mutating func release(_ e: Extent, birth: UInt64) {
    if newestSnapshot == 0 || birth > newestSnapshot || volume.allocator.isFresh(e.start) {
      volume.allocator.free(e)
    } else {
      dead.append(Freed(e, birth: birth))
    }
  }

  /// After a commit wrote the changed nodes: keeps them as clean.
  public mutating func written() {
    for bucket in dirty.buckets { for d in bucket { cache.put(d.block, d.node) } }
    dirty = DirtyNodes()
  }
}

struct CachedNode: Sendable {
  var block: UInt64
  var node: Node
}

/// Clean nodes, by block, up to about `budget` bytes: each costed at its
/// page. Eviction is CLOCK
/// (an approximation of least recently used, as FreeBSD's and Linux's
/// page lists are): a hand sweeps the slots, sparing once a node read
/// since it last passed. The index is open addressing over the slots,
/// with backward-shift removal; no hashed collections in tier 0.
struct NodeCache: Sendable {
  struct Slot: Sendable {
    var block: UInt64
    var node: Node?
    var cost: Int
    var referenced: Bool
  }

  let budget: Int
  private(set) var bytes = 0
  private(set) var count = 0
  var slots: [Slot] = []
  /// Slots whose node was taken out, to reuse.
  var vacant: [Int] = []
  /// A slot's number, or -1: a power of two, at most half full.
  var index = [Int32](repeating: -1, count: 64)
  var hand = 0

  init(bytes budget: Int) { self.budget = Swift.max(budget, Node.bytes) }

  /// What a node holds in memory: its page, and the page's header.
  static func cost(_ node: Node) -> Int { node.page.count + 32 }

  static func hash(_ block: UInt64) -> Int { Int(truncatingIfNeeded: (block &* 0x9E37_79B9_7F4A_7C15) >> 32) }

  /// Where `block` is in the index, or where it would go.
  func find(_ block: UInt64) -> (at: Int, slot: Int?) {
    let mask = index.count - 1
    var i = Self.hash(block) & mask
    while true {
      let s = index[i]
      if s < 0 { return (i, nil) }
      if slots[Int(s)].block == block { return (i, Int(s)) }
      i = (i + 1) & mask
    }
  }

  mutating func node(_ block: UInt64) -> Node? {
    guard count > 0, let s = find(block).slot else { return nil }
    slots[s].referenced = true
    return slots[s].node
  }

  /// Keeps `node` as `block`'s, evicting until it fits.
  mutating func put(_ block: UInt64, _ node: Node) {
    remove(block)
    let cost = Self.cost(node)
    while bytes + cost > budget && count > 0 { evict() }
    let entry = Slot(block: block, node: node, cost: cost, referenced: false)
    let s: Int
    if let v = vacant.popLast() {
      s = v
      slots[s] = entry
    } else {
      s = slots.count
      slots.append(entry)
    }
    bytes += cost
    count += 1
    if count * 2 > index.count {
      grow()
    } else {
      index[find(block).at] = Int32(s)
    }
  }

  mutating func remove(_ block: UInt64) {
    guard count > 0 else { return }
    let (at, slot) = find(block)
    guard let s = slot else { return }
    unindex(at)
    vacate(s)
  }

  /// The hand's next node not read since it last passed.
  private mutating func evict() {
    while true {
      if hand >= slots.count { hand = 0 }
      let s = hand
      hand += 1
      guard slots[s].node != nil else { continue }
      if slots[s].referenced {
        slots[s].referenced = false
        continue
      }
      unindex(find(slots[s].block).at)
      vacate(s)
      return
    }
  }

  private mutating func vacate(_ s: Int) {
    bytes -= slots[s].cost
    slots[s].node = nil
    slots[s].cost = 0
    slots[s].referenced = false
    vacant.append(s)
    count -= 1
  }

  /// Empties `at`, moving back each later entry of its run whose home
  /// is at or before the hole, so no lookup stops short.
  private mutating func unindex(_ at: Int) {
    let mask = index.count - 1
    var hole = at
    var i = (at + 1) & mask
    while index[i] >= 0 {
      let home = Self.hash(slots[Int(index[i])].block) & mask
      if (i - home) & mask >= (i - hole) & mask {
        index[hole] = index[i]
        hole = i
      }
      i = (i + 1) & mask
    }
    index[hole] = -1
  }

  private mutating func grow() {
    index = [Int32](repeating: -1, count: index.count * 2)
    let mask = index.count - 1
    for s in slots.indices where slots[s].node != nil {
      var i = Self.hash(slots[s].block) & mask
      while index[i] >= 0 { i = (i + 1) & mask }
      index[i] = Int32(s)
    }
  }
}

/// Nodes changed in this group, by block.
struct DirtyNodes: Sendable {
  static let bucketCount = 64
  var buckets = [[CachedNode]](repeating: [], count: bucketCount)
  private(set) var count = 0

  static func bucket(_ block: UInt64) -> Int { Int((block / UInt64(Layout.nodeBlocks)) % UInt64(bucketCount)) }

  func index(_ block: UInt64, in b: Int) -> (found: Bool, at: Int) {
    let list = buckets[b]
    var lo = 0, hi = list.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if list[mid].block < block { lo = mid + 1 } else { hi = mid }
    }
    return (lo < list.count && list[lo].block == block, lo)
  }

  func node(_ block: UInt64) -> Node? {
    guard count > 0 else { return nil }
    let b = Self.bucket(block)
    let i = index(block, in: b)
    return i.found ? buckets[b][i.at].node : nil
  }

  mutating func put(_ block: UInt64, _ node: Node) {
    let b = Self.bucket(block)
    let i = index(block, in: b)
    if i.found {
      buckets[b][i.at].node = node
    } else {
      buckets[b].insert(CachedNode(block: block, node: node), at: i.at)
      count += 1
    }
  }

  mutating func remove(_ block: UInt64) {
    let b = Self.bucket(block)
    let i = index(block, in: b)
    if i.found {
      buckets[b].remove(at: i.at)
      count -= 1
    }
  }
}
