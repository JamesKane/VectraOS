// SPDX-License-Identifier: BSD-3-Clause

import TDUnicode

// Attributes, indices and the change journal (filesystem.md §3, §6), on
// FileSystem. An attribute is its own key, (ino, ATTR, name): its kind and
// value inline up to 2 KiB, or its kind and length with the value in 3 KiB
// overflow chunks, (ino, ATTR_CHUNK, name, 0, index). Every change updates
// the indices on that name and the journal in the same batch.

extension FileSystem {
  static var maxInline: Int { 2048 }
  static var chunk: Int { 3072 }
  /// The largest attribute value.
  public static var maxAttribute: Int { 16 << 20 }

  // MARK: Attributes

  /// Sets an attribute, replacing what was there. Strings are stored in NFC.
  public mutating func setAttribute(_ ino: UInt64, _ name: [UInt8], _ value: AttributeValue, now: UInt64)
    throws(TaisceError)
  {
    try reclaiming { (fs: inout Self) throws(TaisceError) in try fs.putAttribute(ino, name, value, now: now) }
  }

  mutating func putAttribute(_ ino: UInt64, _ name: [UInt8], _ value: AttributeValue, now: UInt64)
    throws(TaisceError)
  {
    let name = try FSKey.attributeName(name)
    var value = value
    switch value {
    case .string(let s):
      guard let n = Text.normalized(s) else { throw .invalid }
      value = .string(n)
    case .type(let s):
      guard let n = Text.normalized(s) else { throw .invalid }
      value = .type(n)
    default: break
    }
    let payload = value.payload()
    guard payload.count <= Self.maxAttribute else { throw .tooLarge }
    var c = Changes()
    var node = try inode(ino, &c)
    let old = try attribute(ino, name)
    try deleteOverflow(ino, name, &c)
    let key = FSKey.make(ino, FSKey.attribute, name)
    if payload.count <= Self.maxInline {
      c.set(key, [value.kind.rawValue] + payload)
    } else {
      var head = [UInt8](repeating: 0, count: 9)
      head[0] = value.kind.rawValue | FSKey.overflowFlag
      head.put(UInt64(payload.count), at: 1)
      c.set(key, head)
      var i = 0
      while i * Self.chunk < payload.count {
        let part = Array(payload[(i * Self.chunk)..<min(payload.count, (i + 1) * Self.chunk)])
        c.set(FSKey.chunkKey(ino, name, UInt32(i)), part)
        i += 1
      }
    }
    indexChange(ino, name, old: old, new: value, &c)
    node.ctime = now
    node.version += 1
    try putInode(ino, node, &c)
    journal(&c, ino, parent: node.parent, .attribute, name: name)
    try applyChanges(c)
  }

  /// Removes an attribute; false if there was none.
  @discardableResult
  public mutating func removeAttribute(_ ino: UInt64, _ name: [UInt8], now: UInt64) throws(TaisceError) -> Bool {
    try reclaiming { (fs: inout Self) throws(TaisceError) in try fs.deleteAttribute(ino, name, now: now) }
  }

  mutating func deleteAttribute(_ ino: UInt64, _ name: [UInt8], now: UInt64) throws(TaisceError) -> Bool {
    let name = try FSKey.attributeName(name)
    var c = Changes()
    var node = try inode(ino, &c)
    guard let old = try attribute(ino, name) else { return false }
    c.delete(FSKey.make(ino, FSKey.attribute, name))
    try deleteOverflow(ino, name, &c)
    indexChange(ino, name, old: old, new: nil, &c)
    node.ctime = now
    node.version += 1
    try putInode(ino, node, &c)
    journal(&c, ino, parent: node.parent, .attribute, name: name)
    try applyChanges(c)
    return true
  }


  mutating func deleteOverflow(_ ino: UInt64, _ name: [UInt8], _ c: inout Changes) throws(TaisceError) {
    let from = FSKey.chunkKey(ino, name, 0), to = FSKey.chunkKey(ino, name, UInt32.max)
    for (key, _) in try engine.scan(FSKey.tree, from: from, to: to) { c.delete(key) }
  }

  /// Moves the indices on `name` from `old` to `new` for `ino`.
  func indexChange(_ ino: UInt64, _ name: [UInt8], old: AttributeValue?, new: AttributeValue?, _ c: inout Changes) {
    for index in indices where index.name == name {
      if let old, index.accepts(old) {
        c.other.append(.delete(tree: index.tree, key: index.key(old) + FSKey.u64(ino)))
      }
      if let new, index.accepts(new) {
        c.other.append(.insert(tree: index.tree, key: index.key(new) + FSKey.u64(ino), value: []))
      }
    }
  }

  // MARK: Indices

  /// Declares an index on an attribute (filesystem.md §6). It's kept up to
  /// date from now on, and `backfill` fills in what was there before.
  public mutating func declareIndex(_ name: [UInt8], _ kind: AttributeKind, collation: Collation = .exact)
    throws(TaisceError)
  {
    let name = try FSKey.attributeName(name)
    guard !indices.contains(where: { $0.name == name }) else { throw .exists }
    let tree = max(Self.firstDeclaredIndex, (indices.map { $0.tree }.max() ?? 0) + 1)
    let info = IndexInfo(name: name, kind: kind, collation: collation, building: true, tree: tree, cursor: 0)
    try reclaiming { (fs: inout Self) throws(TaisceError) in
      try fs.engine.apply([.insert(tree: Self.registry, key: name, value: info.encode())])
    }
    indices.append(info)
  }

  /// Fills in declared indices from existing attributes, visiting at most
  /// `budget` nodes. Call it when idle; it returns true when no index is
  /// building any more.
  @discardableResult
  public mutating func backfill(budget: Int) throws(TaisceError) -> Bool {
    try reclaiming { (fs: inout Self) throws(TaisceError) in try fs.backfillStep(budget: budget) }
  }

  mutating func backfillStep(budget: Int) throws(TaisceError) -> Bool {
    guard let i = indices.firstIndex(where: { $0.building }) else { return true }
    var index = indices[i]
    var c = Changes()
    var visited = 0
    var next = index.cursor
    let from = FSKey.make(index.cursor, FSKey.inode)
    for (key, _) in try engine.scan(FSKey.tree, from: from, limit: Int.max) {
      guard key[8] == FSKey.inode else { continue }
      let ino = FSKey.readU64(key, at: 0)
      if visited == budget {
        next = ino
        break
      }
      visited += 1
      next = ino + 1
      if let v = try attribute(ino, index.name), index.accepts(v) {
        c.other.append(.insert(tree: index.tree, key: index.key(v) + FSKey.u64(ino), value: []))
      }
    }
    // Done when the scan ran out before the budget did.
    if visited < budget { index.building = false }
    index.cursor = next
    c.other.append(.insert(tree: Self.registry, key: index.name, value: index.encode()))
    try applyChanges(c)
    indices[i] = index
    return !indices.contains(where: { $0.building })
  }

  /// The nodes whose `name` attribute (or node field: "name", "size",
  /// "mtime") equals `value`, through its index. The index must be ready.
  public mutating func indexLookup(_ name: [UInt8], equal value: AttributeValue) throws(TaisceError) -> [UInt64] {
    guard let index = indices.first(where: { $0.name == name }), !index.building else { throw .notFound }
    let prefix = index.key(value)
    var out: [UInt64] = []
    for (key, _) in try engine.scan(index.tree, from: prefix) {
      guard key.count >= prefix.count + 8, Array(key[..<prefix.count]) == prefix else { break }
      let ino = FSKey.readU64(key, at: prefix.count)
      if out.last != ino { out.append(ino) }
    }
    return out
  }

  // MARK: The journal

  /// Journal records after `seq`, at most `limit`.
  public mutating func journal(after seq: UInt64, limit: Int = Int.max) throws(TaisceError) -> [JournalEntry] {
    var out: [JournalEntry] = []
    for (key, value) in try engine.scan(Self.journal, from: FSKey.u64(seq &+ 1), limit: limit) {
      out.append(try JournalEntry.decode(FSKey.readU64(key, at: 0), value))
    }
    return out
  }

  /// Drops journal records up to and including `seq`, once every consumer
  /// has seen them.
  public mutating func trimJournal(through seq: UInt64) throws(TaisceError) {
    try reclaiming { (fs: inout Self) throws(TaisceError) in
      let old = try fs.engine.scan(Self.journal, from: [], to: FSKey.u64(seq &+ 1))
      try fs.engine.apply(old.map { .delete(tree: Self.journal, key: $0.key) })
    }
  }
}
