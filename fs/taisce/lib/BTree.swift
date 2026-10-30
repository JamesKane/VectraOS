// SPDX-License-Identifier: BSD-3-Clause

/// A copy-on-write B+tree over byte-string keys in byte order, with
/// byte-string values (filesystem.md §3–4). Its nodes live in a Store; the
/// tree itself is a pointer to its root. The file system tree, the index
/// forest and the change journal are each one, with keys encoded so byte
/// order is their order.
///
/// Nodes split and merge by encoded size: a node holds what fits in 16 KiB,
/// and one under a quarter full borrows from or merges with a sibling.
///
/// Copy-on-write (S1): changing a node gives it a new block unless this
/// group already did, so every change returns its node's pointer, and the
/// parent takes it, up to the root. `write` then writes the group's nodes
/// bottom-up, each parent recording its children's checksums.
public struct BTree: Equatable, Sendable {
  /// The root, or `.null` for an empty tree.
  public var root: NodePointer

  public init(root: NodePointer = .null) { self.root = root }

  public var isEmpty: Bool { root.isNull }

  public static let maxKey = 1024
  public static let maxValue = 3072
  static let minFill = Node.bytes / 4

  // MARK: Reading

  public func get<S: NodeSource & ~Copyable>(_ key: [UInt8], _ store: inout S) throws(TaisceError) -> [UInt8]? {
    try withValue(key, &store) { v in Self.bytes(v) }
  }

  /// `body` on `key`'s value, as a span of its node's page; nil if absent.
  public func withValue<S: NodeSource & ~Copyable, R>(_ key: [UInt8], _ store: inout S,
                                                      _ body: (Span<UInt8>) throws(TaisceError) -> R) throws(TaisceError) -> R?
  {
    guard !root.isNull else { return nil }
    var p = root
    while true {
      let n = try store.node(p)
      if n.isLeaf {
        let i = n.lowerBound(key)
        guard i < n.count, n.compare(i, key) == 0 else { return nil }
        return try n.withEntry(i) { _, v throws(TaisceError) in try body(v) }
      }
      p = n.child(n.childIndex(key))
    }
  }

  /// The values of `keys`, which are in order, each nil if absent: one
  /// pass, each node on the way read once, where `get` would descend from
  /// the root for every key (a listing's stats: ~35% of fs's time walking
  /// a tree, D127).
  public func get<S: NodeSource & ~Copyable>(sorted keys: [[UInt8]], _ store: inout S) throws(TaisceError)
    -> [[UInt8]?]
  {
    var out = [[UInt8]?](repeating: nil, count: keys.count)
    try get(sorted: keys, &store) { (k: Int, v: Span<UInt8>) throws(TaisceError) in out[k] = Self.bytes(v) }
    return out
  }

  /// `body` on each of `keys` found (in order), with its index in `keys`
  /// and its value as a span of its node's page: `get(sorted:)` without
  /// copying the values out.
  public func get<S: NodeSource & ~Copyable>(sorted keys: [[UInt8]], _ store: inout S,
                                             _ body: (Int, Span<UInt8>) throws(TaisceError) -> Void) throws(TaisceError)
  {
    guard !root.isNull, !keys.isEmpty else { return }
    try get(root, keys, 0..<keys.count, &store, body)
  }

  func get<S: NodeSource & ~Copyable>(_ p: NodePointer, _ keys: [[UInt8]], _ range: Range<Int>, _ store: inout S,
                                      _ body: (Int, Span<UInt8>) throws(TaisceError) -> Void) throws(TaisceError)
  {
    let n = try store.node(p)
    if n.isLeaf {
      var i = n.lowerBound(keys[range.lowerBound])
      for k in range {
        while i < n.count {
          let c = n.compare(i, keys[k])
          if c < 0 {
            i += 1
            continue
          }
          if c == 0 { try n.withEntry(i) { _, v throws(TaisceError) in try body(k, v) } }
          break
        }
      }
      return
    }
    var k = range.lowerBound
    while k < range.upperBound {
      let c = n.childIndex(keys[k])
      // The keys after it below the child's upper bound go there too.
      var end = k + 1
      if c < n.count {
        while end < range.upperBound && n.compare(c, keys[end]) > 0 { end += 1 }
      } else {
        end = range.upperBound
      }
      try get(n.child(c), keys, k..<end, &store, body)
      k = end
    }
  }

  /// The last entry whose key is at most `key`.
  public func floor<S: NodeSource & ~Copyable>(_ key: [UInt8], _ store: inout S) throws(TaisceError)
    -> (key: [UInt8], value: [UInt8])?
  {
    guard !root.isNull else { return nil }
    return try floor(root, key, &store)
  }

  func floor<S: NodeSource & ~Copyable>(_ p: NodePointer, _ key: [UInt8], _ store: inout S) throws(TaisceError)
    -> (key: [UInt8], value: [UInt8])?
  {
    let n = try store.node(p)
    if n.isLeaf {
      let i = n.childIndex(key) - 1  // the number of keys ≤ key, less one
      return i >= 0 ? (n.key(i), n.value(i)) : nil
    }
    var c = n.childIndex(key)
    while c >= 0 {
      if let found = try floor(n.child(c), key, &store) { return found }
      c -= 1  // everything in the earlier child is below `key`
    }
    return nil
  }

  /// The entries with `from ≤ key < to` (to the end if `to` is nil), in
  /// order, at most `limit`.
  public func scan<S: NodeSource & ~Copyable>(from: [UInt8], to: [UInt8]? = nil, limit: Int = Int.max, _ store: inout S)
    throws(TaisceError) -> [(key: [UInt8], value: [UInt8])]
  {
    var out: [(key: [UInt8], value: [UInt8])] = []
    try scan(from: from, to: to, limit: limit, &store) { (k: Span<UInt8>, v: Span<UInt8>) throws(TaisceError) in
      out.append((Self.bytes(k), Self.bytes(v)))
    }
    return out
  }

  /// `body` on each entry `scan` would give, key and value as spans of
  /// their node's page.
  public func scan<S: NodeSource & ~Copyable>(from: [UInt8], to: [UInt8]? = nil, limit: Int = Int.max, _ store: inout S,
                                              _ body: (Span<UInt8>, Span<UInt8>) throws(TaisceError) -> Void)
    throws(TaisceError)
  {
    guard !root.isNull, limit > 0 else { return }
    var left = limit
    try collect(root, from, to, &left, &store, body)
  }

  /// Visits the subtree in order, from the child covering `from`.
  func collect<S: NodeSource & ~Copyable>(_ p: NodePointer, _ from: [UInt8], _ to: [UInt8]?, _ left: inout Int,
                                          _ store: inout S,
                                          _ body: (Span<UInt8>, Span<UInt8>) throws(TaisceError) -> Void)
    throws(TaisceError)
  {
    let n = try store.node(p)
    if n.isLeaf {
      var i = n.lowerBound(from)
      while i < n.count, left > 0 {
        if let to, n.compare(i, to) >= 0 { return }
        try n.withEntry(i, body)
        left -= 1
        i += 1
      }
      return
    }
    var c = n.childIndex(from)
    while c <= n.count, left > 0 {
      // A child whose lower bound is at or past `to` holds nothing wanted.
      if c > 0, let to, n.compare(c - 1, to) >= 0 { return }
      try collect(n.child(c), from, to, &left, &store, body)
      c += 1
    }
  }

  /// A span's bytes as an array.
  static func bytes(_ s: Span<UInt8>) -> [UInt8] {
    unsafe s.withUnsafeBufferPointer { unsafe Array($0) }
  }

  // MARK: Inserting

  /// Sets `key` to `value`, replacing what was there.
  public mutating func insert<D>(_ key: [UInt8], _ value: [UInt8], _ store: inout Store<D>) throws(TaisceError) {
    guard key.count <= Self.maxKey, value.count <= Self.maxValue else { throw .tooLarge }
    guard !root.isNull else {
      var leaf = Node(level: 0)
      _ = leaf.insert(at: 0, key, value)
      let block = try store.allocateNode(near: store.volume.superblock.layout.dataStart)
      store.put(block, leaf)
      root = .fresh(block)
      return
    }
    let (updated, split) = try insert(root, key, value, &store)
    try grow(updated, split, &store)
  }

  /// Takes `updated` as the root, and if it split, a new root above it.
  mutating func grow<D>(_ updated: NodePointer, _ split: (separator: [UInt8], right: NodePointer)?,
                        _ store: inout Store<D>) throws(TaisceError) {
    root = updated
    guard let (separator, right) = split else { return }
    var top = Node(level: try store.node(root).level + 1)
    top.setChild(0, root)
    _ = top.insert(at: 0, separator, right: right)
    let block = try store.allocateNode(near: root.block)
    store.put(block, top)
    root = .fresh(block)
  }

  /// Inserts into the subtree `p` points at: its new pointer, and if it
  /// split, the separator and the new right node.
  func insert<D>(_ p: NodePointer, _ key: [UInt8], _ value: [UInt8], _ store: inout Store<D>)
    throws(TaisceError) -> (NodePointer, (separator: [UInt8], right: NodePointer)?)
  {
    var n = try store.node(p)
    if n.isLeaf {
      let i = n.lowerBound(key)
      if i < n.count && n.compare(i, key) == 0 {
        Self.change(&n) { $0.replaceValue(i, value) }
      } else {
        Self.change(&n) { $0.insert(at: i, key, value) }
      }
    } else {
      let c = n.childIndex(key)
      let (child, split) = try insert(n.child(c), key, value, &store)
      n.setChild(c, child)
      if let (separator, right) = split {
        Self.change(&n) { $0.insert(at: c, separator, right: right) }
      } else if try store.node(child).used < Self.minFill {
        // A value replaced by a shorter one shrinks its leaf as a delete does.
        try rebalance(&n, c, &store)
      }
    }
    return try place(n, p, &store)
  }

  /// Makes a change to `n`, in a page twice the size if it doesn't fit
  /// (every change fits there: an entry is at most a quarter of a node).
  static func change(_ n: inout Node, _ edit: (inout Node) -> Bool) {
    if edit(&n) { return }
    n = n.copy(capacity: 2 * Node.bytes)
    let fitted = edit(&n)
    precondition(fitted)
  }

  /// Gives a changed node its block for this group: one node if it fits
  /// one, else split in two near the middle of its bytes.
  func place<D>(_ n: Node, _ p: NodePointer, _ store: inout Store<D>) throws(TaisceError)
    -> (NodePointer, (separator: [UInt8], right: NodePointer)?)
  {
    if n.used <= Node.bytes {
      let node = n.page.count == Node.bytes ? n : n.copy(capacity: Node.bytes)
      return (.fresh(try store.update(p, node)), nil)
    }
    let (left, separator, right) = split(n)
    let leftBlock = try store.update(p, left)
    let rightBlock = try store.allocateNode(near: leftBlock)
    store.put(rightBlock, right)
    return (.fresh(leftBlock), (separator, .fresh(rightBlock)))
  }

  /// Splits an overfull node near the middle of its bytes.
  func split(_ n: Node) -> (Node, [UInt8], Node) {
    var left = Node(level: n.level), right = Node(level: n.level)
    let half = (n.used - Node.headerSize) / 2
    var used = 0, at = 0
    // A leaf's right half needs a key; an internal one's needs a key after
    // the one that moves up.
    let last = n.isLeaf ? n.count - 1 : n.count - 2
    while at < last {
      let cell = n.cellSize(at) + 2
      if used + cell > half && at > 0 { break }
      used += cell
      at += 1
    }
    if n.isLeaf {
      for i in 0..<at { left.append(n, i) }
      for i in at..<n.count { right.append(n, i) }
      return (left, right.key(0), right)
    }
    // The middle key moves up; the children split around it.
    left.setChild(0, n.child(0))
    for i in 0..<at { left.append(n, i) }
    right.setChild(0, n.child(at + 1))
    for i in (at + 1)..<n.count { right.append(n, i) }
    return (left, n.key(at), right)
  }

  // MARK: Deleting

  /// Removes `key`; false if it wasn't there.
  @discardableResult
  public mutating func delete<D>(_ key: [UInt8], _ store: inout Store<D>) throws(TaisceError) -> Bool {
    guard !root.isNull else { return false }
    let (found, updated, split) = try delete(root, key, &store)
    guard found else { return false }
    try grow(updated, split, &store)
    // Shrink from the top: an empty leaf root empties the tree, and an
    // internal root with one child hands over to it.
    let r = try store.node(root)
    if r.count == 0 {
      store.freeNode(root)
      root = r.isLeaf ? .null : r.child(0)
    }
    return true
  }

  /// Deletes from the subtree `p` points at, rebalancing children that fall
  /// under a quarter full. Whether the key was there, the subtree's
  /// pointer (unchanged if it wasn't), and a split if a longer separator
  /// overfilled it.
  func delete<D>(_ p: NodePointer, _ key: [UInt8], _ store: inout Store<D>) throws(TaisceError)
    -> (Bool, NodePointer, (separator: [UInt8], right: NodePointer)?)
  {
    var n = try store.node(p)
    if n.isLeaf {
      let i = n.lowerBound(key)
      guard i < n.count, n.compare(i, key) == 0 else { return (false, p, nil) }
      n.remove(i)
      return (true, .fresh(try store.update(p, n)), nil)
    }
    let c = n.childIndex(key)
    let (found, child, split) = try delete(n.child(c), key, &store)
    guard found else { return (false, p, nil) }
    n.setChild(c, child)
    if let (separator, right) = split {
      Self.change(&n) { $0.insert(at: c, separator, right: right) }
    } else if try store.node(child).used < Self.minFill && n.count > 0 {
      try rebalance(&n, c, &store)
    }
    let (updated, up) = try place(n, p, &store)
    return (true, updated, up)
  }

  /// Merges child `c` with a sibling, or shares entries with it.
  func rebalance<D>(_ parent: inout Node, _ c: Int, _ store: inout Store<D>) throws(TaisceError) {
    let l = c + 1 <= parent.count ? c : c - 1  // the pair (l, l + 1)
    let leftPointer = parent.child(l), rightPointer = parent.child(l + 1)
    let left = try store.node(leftPointer), right = try store.node(rightPointer)
    // Everything in one node, in order (an internal pair pulls the separator down).
    var all = Node(level: left.level, capacity: 2 * Node.bytes + BTree.maxKey + 64)
    if !left.isLeaf { all.setChild(0, left.child(0)) }
    for i in 0..<left.count { all.append(left, i) }
    if !left.isLeaf { _ = all.insert(at: all.count, parent.key(l), right: right.child(0)) }
    for i in 0..<right.count { all.append(right, i) }
    if all.used <= Node.bytes {
      parent.setChild(l, .fresh(try store.update(leftPointer, all.copy(capacity: Node.bytes))))
      store.freeNode(rightPointer)
      parent.remove(l)
    } else {
      let (newLeft, separator, newRight) = split(all)
      parent.setChild(l, .fresh(try store.update(leftPointer, newLeft)))
      parent.setChild(l + 1, .fresh(try store.update(rightPointer, newRight)))
      Self.change(&parent) { $0.replaceKey(l, separator) }
    }
  }

  // MARK: Writing

  /// Writes this group's nodes bottom-up, appending (block, bytes) to
  /// `out`: each parent takes its children's new checksums, and the root
  /// pointer gets its own. Untouched subtrees aren't visited: a node needs
  /// writing exactly when its block was allocated in this group.
  public mutating func write<D>(_ store: inout Store<D>, txg: UInt64, _ out: inout [(block: UInt64, bytes: [UInt8])])
    throws(TaisceError)
  {
    root = try write(root, txg, &store, &out)
  }

  func write<D>(_ p: NodePointer, _ txg: UInt64, _ store: inout Store<D>,
                _ out: inout [(block: UInt64, bytes: [UInt8])]) throws(TaisceError) -> NodePointer {
    guard !p.isNull, store.volume.allocator.isFresh(p.block) else { return p }
    var n = try store.node(p)
    if !n.isLeaf {
      for i in 0...n.count { n.setChild(i, try write(n.child(i), txg, &store, &out)) }
      store.put(p.block, n)
    }
    out.append((p.block, n.page))
    return NodePointer(block: p.block, checksum: Checksum(of: n.page, key: store.volume.device.checksumKey), birth: txg)
  }

  /// The pointers to every leaf, in key order, reading only the nodes
  /// above them (S2: two trees' leaves alike are alike).
  public func leaves<S: NodeSource & ~Copyable>(_ store: inout S) throws(TaisceError) -> [NodePointer] {
    guard !root.isNull else { return [] }
    if try store.node(root).isLeaf { return [root] }
    var out: [NodePointer] = []
    var stack = [root]
    while let p = stack.popLast() {
      let n = try store.node(p)
      if n.level == 1 { out += n.children } else { stack += n.children.reversed() }
    }
    return out
  }

  /// Every node's first block, root first.
  public func nodeBlocks<D>(_ store: inout Store<D>) throws(TaisceError) -> [UInt64] {
    var out: [UInt64] = []
    var stack = root.isNull ? [] : [root]
    while let p = stack.popLast() {
      out.append(p.block)
      let n = try store.node(p)
      stack += n.children
    }
    return out
  }

  // MARK: Checking

  public struct Stats: Equatable, Sendable {
    public var entries = 0
    public var nodes = 0
    public var depth = 0
  }

  /// Checks every invariant: order, bounds, even depth, fill, that every
  /// node's blocks are allocated, and that every written node has the
  /// checksum its parent records. For tests and fsck.
  public func check<D>(_ store: inout Store<D>) throws(TaisceError) -> Stats {
    var stats = Stats()
    guard !root.isNull else { return stats }
    var leafDepth: Int? = nil
    try check(root, lower: nil, upper: nil, depth: 1, isRoot: true, &leafDepth, &stats, &store)
    stats.depth = leafDepth ?? 0
    return stats
  }

  func check<D>(_ p: NodePointer, lower: [UInt8]?, upper: [UInt8]?, depth: Int, isRoot: Bool, _ leafDepth: inout Int?,
                _ stats: inout Stats, _ store: inout Store<D>) throws(TaisceError) {
    for b in p.block..<(p.block + UInt64(Layout.nodeBlocks)) where !store.volume.allocator.isUsed(b) {
      throw .corrupt(.tree(.blockNotAllocated))
    }
    let n = try store.node(p)
    // A written node (not changed in this group) must match its pointer.
    if !store.volume.allocator.isFresh(p.block), Checksum(of: n.page, key: store.volume.device.checksumKey) != p.checksum {
      throw .corrupt(.checksum(p.block))
    }
    stats.nodes += 1
    guard n.page.count == Node.bytes, n.used <= Node.bytes else { throw .corrupt(.tree(.overfull)) }
    if !isRoot && n.used < Self.minFill && n.count > 1 {
      // A node with one big entry can't be fuller; otherwise it must be.
      throw .corrupt(.tree(.underfull))
    }
    var previous: [UInt8]? = nil
    for i in 0..<n.count {
      let key = n.key(i)
      if let previous, !previous.lexicographicallyPrecedes(key) { throw .corrupt(.tree(.keysOutOfOrder)) }
      if let lower, key.lexicographicallyPrecedes(lower) { throw .corrupt(.tree(.keyOutsideItsBounds)) }
      if let upper, !key.lexicographicallyPrecedes(upper) { throw .corrupt(.tree(.keyOutsideItsBounds)) }
      previous = key
    }
    if n.isLeaf {
      if let d = leafDepth, d != depth { throw .corrupt(.tree(.uneven)) }
      leafDepth = depth
      stats.entries += n.count
      return
    }
    guard n.count > 0 else { throw .corrupt(.tree(.childCount)) }
    for c in 0...n.count {
      try check(n.child(c), lower: c == 0 ? lower : n.key(c - 1), upper: c == n.count ? upper : n.key(c),
                depth: depth + 1, isRoot: false, &leafDepth, &stats, &store)
    }
  }
}
