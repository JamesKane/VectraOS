// SPDX-License-Identifier: BSD-3-Clause

/// Reading files (S1f): what the writer's FileSystem and a lock-free
/// FileReader share. Each gives trees' roots, their nodes, and verified
/// file blocks; the rest (stat, lookup, directories, data, attributes) is
/// the same code for both.
public protocol FileReading: NodeSource, ~Copyable {
  /// Tree `id`'s root, or nil if it has never had entries.
  func root(_ id: UInt64) -> BTree?
  /// `checksums.count` file blocks from `physical`, each checked against its
  /// checksum (`.corrupt(.checksum)` otherwise).
  mutating func dataBlocks(_ physical: UInt64, _ checksums: ArraySlice<Checksum>) throws(TaisceError) -> [UInt8]
  /// The same blocks, each checked as `dataBlocks` checks it, given to
  /// `body` in order with its index: where it is cached, the cache's own
  /// bytes, so a caller copies them once.
  mutating func withDataBlocks(_ physical: UInt64, _ checksums: ArraySlice<Checksum>,
                               _ body: (Int, UnsafeRawBufferPointer) -> Void) throws(TaisceError)
}

extension FileReading where Self: ~Copyable {
  public mutating func withDataBlocks(_ physical: UInt64, _ checksums: ArraySlice<Checksum>,
                                      _ body: (Int, UnsafeRawBufferPointer) -> Void) throws(TaisceError)
  {
    let bytes = try dataBlocks(physical, checksums)
    let bs = Layout.blockSize
    bytes.withUnsafeBytes { b in
      for k in 0..<checksums.count { unsafe body(k, UnsafeRawBufferPointer(rebasing: b[(k * bs)..<((k + 1) * bs)])) }
    }
  }

  // MARK: Trees

  mutating func get(_ tree: UInt64, _ key: [UInt8]) throws(TaisceError) -> [UInt8]? {
    guard let t = root(tree) else { return nil }
    return try t.get(key, &self)
  }

  mutating func floor(_ tree: UInt64, _ key: [UInt8]) throws(TaisceError) -> (key: [UInt8], value: [UInt8])? {
    guard let t = root(tree) else { return nil }
    return try t.floor(key, &self)
  }

  mutating func scan(_ tree: UInt64, from: [UInt8], to: [UInt8]? = nil, limit: Int = Int.max)
    throws(TaisceError) -> [(key: [UInt8], value: [UInt8])]
  {
    guard let t = root(tree) else { return [] }
    return try t.scan(from: from, to: to, limit: limit, &self)
  }

  // MARK: Nodes

  public mutating func stat(_ ino: UInt64) throws(TaisceError) -> Inode {
    guard let v = try get(FSKey.tree, FSKey.make(ino, FSKey.inode)) else { throw .notFound }
    return try Inode.decode(v)
  }

  /// The node `name` names in `dir`.
  public mutating func lookup(_ dir: UInt64, _ name: [UInt8]) throws(TaisceError) -> UInt64 {
    guard let v = try get(FSKey.tree, FSKey.make(dir, FSKey.dirent, FSKey.u64(Bucket.hash(name)))),
      let e = try Bucket.decode(v).first(where: { $0.name == name })
    else { throw .notFound }
    return e.ino
  }

  public mutating func readlink(_ ino: UInt64) throws(TaisceError) -> [UInt8] {
    guard let t = try get(FSKey.tree, FSKey.make(ino, FSKey.symlink)) else { throw .invalid }
    return t
  }

  /// A node's names: (directory, name) for each, from its own records.
  public mutating func names(_ ino: UInt64) throws(TaisceError) -> [(dir: UInt64, name: [UInt8])] {
    try scan(FSKey.tree, from: FSKey.make(ino, FSKey.name), to: FSKey.make(ino, FSKey.name + 1)).map {
      (FSKey.readU64($0.key, at: 9), Array($0.key[17...]))
    }
  }

  /// A node's first name, as `names` would list it first (nil: an
  /// orphan): one entry read, not all of them.
  public mutating func firstName(_ ino: UInt64) throws(TaisceError) -> (dir: UInt64, name: [UInt8])? {
    try scan(FSKey.tree, from: FSKey.make(ino, FSKey.name), to: FSKey.make(ino, FSKey.name + 1), limit: 1).first.map {
      (FSKey.readU64($0.key, at: 9), Array($0.key[17...]))
    }
  }

  /// A path to the node from the root ("/" for the root; its first name at
  /// each level), or nil for one with no name (an orphan).
  public mutating func path(_ ino: UInt64) throws(TaisceError) -> [UInt8]? {
    if ino == FSKey.rootDirectory { return [0x2F] }
    var parts: [[UInt8]] = []
    var at = ino
    while at != FSKey.rootDirectory {
      guard let first = try firstName(at), parts.count < 4096 else { return nil }
      parts.append(first.name)
      at = first.dir
    }
    var out: [UInt8] = []
    for p in parts.reversed() { out += [0x2F] + p }
    return out
  }

  // MARK: Directories

  /// A directory's entries after `cookie` (nil: from the start), at most
  /// about `limit`, each with the cookie to continue after it. Order is by
  /// name hash; entries sharing a hash come together.
  public mutating func list(_ dir: UInt64, after cookie: UInt64? = nil, limit: Int = Int.max) throws(TaisceError)
    -> [(entry: DirectoryEntry, cookie: UInt64)]
  {
    guard try stat(dir).type == .directory else { throw .notDirectory }
    if cookie == UInt64.max { return [] }
    let from = FSKey.make(dir, FSKey.dirent, FSKey.u64(cookie.map { $0 + 1 } ?? 0))
    var out: [(entry: DirectoryEntry, cookie: UInt64)] = []
    for (key, value) in try scan(FSKey.tree, from: from, to: FSKey.make(dir, FSKey.dirent + 1), limit: limit) {
      let hash = FSKey.readU64(key, at: 9)
      for e in try Bucket.decode(value) { out.append((e, hash)) }
    }
    return out
  }

  // MARK: Data

  /// Up to `count` bytes from `offset`; fewer at the end of the file.
  public mutating func read(_ ino: UInt64, offset: UInt64, count: Int) throws(TaisceError) -> [UInt8] {
    let node = try stat(ino)
    guard node.type == .file else { throw node.type == .directory ? .isDirectory : .invalid }
    guard offset < node.size, count > 0 else { return [] }
    let end = min(node.size, offset + UInt64(count))
    let bs = UInt64(Layout.blockSize)
    let first = offset / bs, last = (end - 1) / bs
    let n = Int(last - first + 1)
    let blocks = try readBlocks(try storedExtents(ino, first, first + UInt64(n)), first, n)
    let start = Int(offset - first * bs)
    return Array(blocks[start..<(start + Int(end - offset))])
  }

  /// What `read` gives, into `buffer` (up to its size): each block's bytes
  /// copied there once from where they are kept, holes as zeros. A ring's
  /// 128 KiB read went through four arrays that size, each a mapping of
  /// its own. Returns how many bytes; fewer at the end of the file.
  public mutating func read(_ ino: UInt64, offset: UInt64, into buffer: UnsafeMutableRawBufferPointer)
    throws(TaisceError) -> Int
  {
    let node = try stat(ino)
    guard node.type == .file else { throw node.type == .directory ? .isDirectory : .invalid }
    guard offset < node.size, buffer.count > 0 else { return 0 }
    let end = min(node.size, offset + UInt64(buffer.count))
    let bs = UInt64(Layout.blockSize)
    let first = offset / bs, last = (end - 1) / bs
    // File bytes lo..<hi, as much as the read covers, from `bytes` (which
    // start at lo), or zeros.
    func place(_ lo: UInt64, _ hi: UInt64, _ bytes: UnsafeRawBufferPointer?) {
      let a = max(lo, offset), b = min(hi, end)
      guard a < b else { return }
      let to = unsafe UnsafeMutableRawBufferPointer(rebasing: buffer[Int(a - offset)..<Int(b - offset)])
      if let bytes = unsafe bytes {
        unsafe to.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[Int(a - lo)..<Int(b - lo)]))
      } else {
        unsafe to.initializeMemory(as: UInt8.self, repeating: 0)
      }
    }
    var placed = first  // the blocks before it are in place
    for e in try storedExtents(ino, first, last + 1) {
      let lo = max(e.start, first), hi = min(e.start + e.count, last + 1)
      guard lo < hi else { continue }
      if placed < lo { place(placed * bs, lo * bs, nil) }  // a hole
      let from = Int(lo - e.start)
      try unsafe withDataBlocks(e.physical + UInt64(from), e.checksums[from..<(from + Int(hi - lo))]) { k, bytes in
        unsafe place((lo + UInt64(k)) * bs, (lo + UInt64(k) + 1) * bs, bytes)
      }
      placed = hi
    }
    if placed <= last { place(placed * bs, (last + 1) * bs, nil) }
    return Int(end - offset)
  }

  /// The extents overlapping file blocks `first..<end` that the trees hold,
  /// in order.
  mutating func storedExtents(_ ino: UInt64, _ first: UInt64, _ end: UInt64) throws(TaisceError) -> [FileExtent] {
    var found: [FileExtent] = []
    func add(_ key: [UInt8], _ value: [UInt8]) throws(TaisceError) {
      guard key.count == 17, FSKey.readU64(key, at: 0) == ino, key[8] == FSKey.extent else { return }
      found.append(try FileExtent.decode(start: FSKey.readU64(key, at: 9), value))
    }
    if let (key, value) = try floor(FSKey.tree, FSKey.make(ino, FSKey.extent, FSKey.u64(first))) {
      try add(key, value)
    }
    if end > first + 1 {
      let from = FSKey.make(ino, FSKey.extent, FSKey.u64(first + 1))
      for (key, value) in try scan(FSKey.tree, from: from, to: FSKey.make(ino, FSKey.extent, FSKey.u64(end))) {
        try add(key, value)
      }
    }
    return found
  }

  /// `count` file blocks from `first`, as `extents` map them, holes as zeros.
  mutating func readBlocks(_ extents: [FileExtent], _ first: UInt64, _ count: Int) throws(TaisceError) -> [UInt8] {
    let bs = Layout.blockSize
    // One extent covering them all (most reads): its blocks as they come.
    if extents.count == 1, let e = extents.first, e.start <= first, first + UInt64(count) <= e.start + e.count {
      let from = Int(first - e.start)
      return try dataBlocks(e.physical + UInt64(from), e.checksums[from..<(from + count)])
    }
    var data = [UInt8](repeating: 0, count: count * bs)
    for e in extents {
      let lo = max(e.start, first), hi = min(e.start + e.count, first + UInt64(count))
      guard lo < hi else { continue }
      let from = Int(lo - e.start), n = Int(hi - lo)
      let bytes = try dataBlocks(e.physical + UInt64(from), e.checksums[from..<(from + n)])
      data.replaceSubrange(Int(lo - first) * bs..<Int(hi - first) * bs, with: bytes)
    }
    return data
  }

  // MARK: Attributes

  /// An attribute's value, or nil if the node hasn't one by that name.
  public mutating func attribute(_ ino: UInt64, _ name: [UInt8]) throws(TaisceError) -> AttributeValue? {
    let name = try FSKey.attributeName(name)
    guard let v = try get(FSKey.tree, FSKey.make(ino, FSKey.attribute, name)), !v.isEmpty else { return nil }
    guard let kind = AttributeKind(rawValue: v[0] & ~FSKey.overflowFlag) else { throw .corrupt(.attribute) }
    if v[0] & FSKey.overflowFlag == 0 { return try AttributeValue.decode(kind, Array(v[1...])) }
    guard v.count == 9 else { throw .corrupt(.attribute) }
    let length = Int(v.get(UInt64.self, at: 1))
    var payload: [UInt8] = []
    payload.reserveCapacity(length)
    let from = FSKey.chunkKey(ino, name, 0), to = FSKey.chunkKey(ino, name, UInt32.max)
    for (_, part) in try scan(FSKey.tree, from: from, to: to) { payload += part }
    guard payload.count == length else { throw .corrupt(.attribute) }
    return try AttributeValue.decode(kind, payload)
  }

  /// A node's attribute names and kinds, in name order.
  public mutating func attributes(_ ino: UInt64) throws(TaisceError) -> [(name: [UInt8], kind: AttributeKind)] {
    _ = try stat(ino)
    var out: [(name: [UInt8], kind: AttributeKind)] = []
    let from = FSKey.make(ino, FSKey.attribute), to = FSKey.make(ino, FSKey.attribute + 1)
    for (key, value) in try scan(FSKey.tree, from: from, to: to) {
      guard !value.isEmpty, let kind = AttributeKind(rawValue: value[0] & ~FSKey.overflowFlag) else {
        throw .corrupt(.attribute)
      }
      out.append((Array(key[9...]), kind))
    }
    return out
  }
}
