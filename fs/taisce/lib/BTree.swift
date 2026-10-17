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
    guard !root.isNull else { return nil }
    var p = root
    while true {
      let n = try store.node(p)
      if n.isLeaf {
        let i = n.lowerBound(key)
        return i < n.keys.count && n.keys[i] == key ? n.values[i] : nil
      }
      p = n.children[n.childIndex(key)]
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
      return i >= 0 ? (n.keys[i], n.values[i]) : nil
    }
    var c = n.childIndex(key)
    while c >= 0 {
      if let found = try floor(n.children[c], key, &store) { return found }
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
    guard !root.isNull, limit > 0 else { return out }
    try collect(root, from, to, limit, &out, &store)
    return out
  }

  /// Visits the subtree in order, from the child covering `from`.
  func collect<S: NodeSource & ~Copyable>(_ p: NodePointer, _ from: [UInt8], _ to: [UInt8]?, _ limit: Int,
                                          _ out: inout [(key: [UInt8], value: [UInt8])], _ store: inout S)
    throws(TaisceError)
  {
    let n = try store.node(p)
    if n.isLeaf {
      var i = n.lowerBound(from)
      while i < n.keys.count, out.count < limit {
        if let to, !n.keys[i].lexicographicallyPrecedes(to) { return }
        out.append((n.keys[i], n.values[i]))
        i += 1
      }
      return
    }
    var c = n.childIndex(from)
    while c < n.children.count, out.count < limit {
      // A child whose lower bound is at or past `to` holds nothing wanted.
      if c > 0, let to, !n.keys[c - 1].lexicographicallyPrecedes(to) { return }
      try collect(n.children[c], from, to, limit, &out, &store)
      c += 1
    }
  }

  // MARK: Inserting

  /// Sets `key` to `value`, replacing what was there.
  public mutating func insert<D>(_ key: [UInt8], _ value: [UInt8], _ store: inout Store<D>) throws(TaisceError) {
    guard key.count <= Self.maxKey, value.count <= Self.maxValue else { throw .tooLarge }
    guard !root.isNull else {
      var leaf = Node(level: 0)
      leaf.keys = [key]
      leaf.values = [value]
      let block = try store.allocateNode(near: store.volume.superblock.layout.dataStart)
      store.put(block, leaf)
      root = .fresh(block)
      return
    }
    let (updated, split) = try insert(root, key, value, &store)
    root = updated
    if let (separator, right) = split {
      let old = try store.node(root)
      var top = Node(level: old.level + 1)
      top.keys = [separator]
      top.children = [root, right]
      let block = try store.allocateNode(near: root.block)
      store.put(block, top)
      root = .fresh(block)
    }
  }

  /// Inserts into the subtree `p` points at: its new pointer, and if it
  /// split, the separator and the new right node.
  func insert<D>(_ p: NodePointer, _ key: [UInt8], _ value: [UInt8], _ store: inout Store<D>)
    throws(TaisceError) -> (NodePointer, (separator: [UInt8], right: NodePointer)?)
  {
    var n = try store.node(p)
    if n.isLeaf {
      let i = n.lowerBound(key)
      if i < n.keys.count && n.keys[i] == key {
        n.values[i] = value
      } else {
        n.keys.insert(key, at: i)
        n.values.insert(value, at: i)
      }
    } else {
      let c = n.childIndex(key)
      let (child, split) = try insert(n.children[c], key, value, &store)
      n.children[c] = child
      if let (separator, right) = split {
        n.keys.insert(separator, at: c)
        n.children.insert(right, at: c + 1)
      }
    }
    guard n.size > Node.bytes else { return (.fresh(try store.update(p.block, n)), nil) }
    let (left, separator, right) = split(n)
    let leftBlock = try store.update(p.block, left)
    let rightBlock = try store.allocateNode(near: leftBlock)
    store.put(rightBlock, right)
    return (.fresh(leftBlock), (separator, .fresh(rightBlock)))
  }

  /// Splits an overfull node near the middle of its bytes.
  func split(_ n: Node) -> (Node, [UInt8], Node) {
    var left = Node(level: n.level), right = Node(level: n.level)
    let half = (n.size - Node.headerSize) / 2
    var used = 0, at = 0
    // A leaf's right half needs a key; an internal one's needs a key after
    // the one that moves up.
    let last = n.isLeaf ? n.keys.count - 1 : n.keys.count - 2
    while at < last {
      let cell = n.isLeaf ? Node.leafCell(n.keys[at], n.values[at]) : Node.internalCell(n.keys[at])
      if used + cell > half && at > 0 { break }
      used += cell
      at += 1
    }
    if n.isLeaf {
      left.keys = Array(n.keys[..<at])
      left.values = Array(n.values[..<at])
      right.keys = Array(n.keys[at...])
      right.values = Array(n.values[at...])
      return (left, right.keys[0], right)
    }
    // The middle key moves up; the children split around it.
    left.keys = Array(n.keys[..<at])
    left.children = Array(n.children[...at])
    right.keys = Array(n.keys[(at + 1)...])
    right.children = Array(n.children[(at + 1)...])
    return (left, n.keys[at], right)
  }

  // MARK: Deleting

  /// Removes `key`; false if it wasn't there.
  @discardableResult
  public mutating func delete<D>(_ key: [UInt8], _ store: inout Store<D>) throws(TaisceError) -> Bool {
    guard !root.isNull else { return false }
    let (found, updated) = try delete(root, key, &store)
    guard found else { return false }
    root = updated
    // Shrink from the top: an empty leaf root empties the tree, and an
    // internal root with one child hands over to it.
    let r = try store.node(root)
    if r.keys.isEmpty {
      store.freeNode(root.block)
      root = r.isLeaf ? .null : r.children[0]
    }
    return true
  }

  /// Deletes from the subtree `p` points at, rebalancing children that fall
  /// under a quarter full. Whether the key was there, and the subtree's
  /// pointer (unchanged if it wasn't).
  func delete<D>(_ p: NodePointer, _ key: [UInt8], _ store: inout Store<D>) throws(TaisceError) -> (Bool, NodePointer) {
    var n = try store.node(p)
    if n.isLeaf {
      let i = n.lowerBound(key)
      guard i < n.keys.count, n.keys[i] == key else { return (false, p) }
      n.keys.remove(at: i)
      n.values.remove(at: i)
      return (true, .fresh(try store.update(p.block, n)))
    }
    let c = n.childIndex(key)
    let (found, child) = try delete(n.children[c], key, &store)
    guard found else { return (false, p) }
    n.children[c] = child
    if try store.node(child).size < Self.minFill && n.children.count > 1 {
      try rebalance(&n, c, &store)
    }
    return (true, .fresh(try store.update(p.block, n)))
  }

  /// Merges child `c` with a sibling, or shares entries with it.
  func rebalance<D>(_ parent: inout Node, _ c: Int, _ store: inout Store<D>) throws(TaisceError) {
    let l = c + 1 < parent.children.count ? c : c - 1  // the pair (l, l + 1)
    let leftPointer = parent.children[l], rightPointer = parent.children[l + 1]
    let left = try store.node(leftPointer), right = try store.node(rightPointer)
    // Everything in one node, in order (an internal pair pulls the separator down).
    var all = Node(level: left.level)
    all.keys = left.keys
    all.values = left.values
    all.children = left.children
    if !left.isLeaf { all.keys.append(parent.keys[l]) }
    all.keys += right.keys
    all.values += right.values
    all.children += right.children
    if all.size <= Node.bytes {
      parent.children[l] = .fresh(try store.update(leftPointer.block, all))
      store.freeNode(rightPointer.block)
      parent.keys.remove(at: l)
      parent.children.remove(at: l + 1)
    } else {
      let (newLeft, separator, newRight) = split(all)
      parent.children[l] = .fresh(try store.update(leftPointer.block, newLeft))
      parent.children[l + 1] = .fresh(try store.update(rightPointer.block, newRight))
      parent.keys[l] = separator
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
      for i in n.children.indices { n.children[i] = try write(n.children[i], txg, &store, &out) }
      store.put(p.block, n)
    }
    let bytes = n.encode()
    out.append((p.block, bytes))
    return NodePointer(block: p.block, checksum: Checksum(of: bytes), birth: txg)
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
    if !store.volume.allocator.isFresh(p.block), Checksum(of: n.encode()) != p.checksum {
      throw .corrupt(.checksum(p.block))
    }
    stats.nodes += 1
    guard n.size <= Node.bytes else { throw .corrupt(.tree(.overfull)) }
    if !isRoot && n.size < Self.minFill && n.keys.count > 1 {
      // A node with one big entry can't be fuller; otherwise it must be.
      throw .corrupt(.tree(.underfull))
    }
    for i in n.keys.indices {
      if i > 0, !n.keys[i - 1].lexicographicallyPrecedes(n.keys[i]) { throw .corrupt(.tree(.keysOutOfOrder)) }
      if let lower, n.keys[i].lexicographicallyPrecedes(lower) { throw .corrupt(.tree(.keyOutsideItsBounds)) }
      if let upper, !n.keys[i].lexicographicallyPrecedes(upper) { throw .corrupt(.tree(.keyOutsideItsBounds)) }
    }
    if n.isLeaf {
      if let d = leafDepth, d != depth { throw .corrupt(.tree(.uneven)) }
      leafDepth = depth
      stats.entries += n.keys.count
      return
    }
    guard n.children.count == n.keys.count + 1, !n.keys.isEmpty else { throw .corrupt(.tree(.childCount)) }
    for c in n.children.indices {
      try check(n.children[c], lower: c == 0 ? lower : n.keys[c - 1], upper: c == n.keys.count ? upper : n.keys[c],
                depth: depth + 1, isRoot: false, &leafDepth, &stats, &store)
    }
  }
}
