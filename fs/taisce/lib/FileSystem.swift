// SPDX-License-Identifier: BSD-3-Clause

/// Files and directories on the engine (filesystem.md §3): inodes,
/// directory entries bucketed by name hash, extents, symlinks, and an
/// orphan list. Every operation is one atomic batch.
///
/// File data is copy-on-write per write in S0: a write puts its blocks in
/// newly allocated space (unless they were allocated in this group, which
/// nothing committed points at), reaches the disk before the group's log
/// commit, and the blocks it replaces stay held until that commit. So data
/// changes atomically with its group, and a crash shows a file exactly as
/// some group left it.
public struct FileSystem<Device: BlockDevice>: ~Copyable, FileReading {
  public var engine: Engine<Device>
  /// Nodes open now, with how often: one unlinked while open becomes an
  /// orphan, freed at its last close or at the next mount.
  var openCounts: [(ino: UInt64, count: Int)] = []
  /// File blocks in memory: each verified against its checksum when read,
  /// or written here, so a cached read doesn't hash again (the page cache's
  /// job). Direct-mapped by physical block; every data write updates it.
  /// The scrub (`check`) still reads the device.
  var dataCache = [CachedBlock?](repeating: nil, count: 4096)  // 16 MiB

  struct CachedBlock {
    var block: UInt64
    var bytes: [UInt8]
  }
  /// The caches its reader threads share, once there are readers (S1f).
  var readerCaches: ReaderCaches?
  /// Every declared index, from the registry.
  public internal(set) var indices: [IndexInfo] = []
  /// The next change-journal sequence number.
  public internal(set) var nextSeq: UInt64 = 1

  public static var root: UInt64 { FSKey.rootDirectory }
  public static var maxName: Int { 255 }
  static var orphans: UInt64 { 2 }
  static var registry: UInt64 { 3 }
  static var journal: UInt64 { 4 }
  // The default indices: three on node fields, one on an attribute.
  static var nameIndex: UInt64 { 16 }
  static var sizeIndex: UInt64 { 17 }
  static var mtimeIndex: UInt64 { 18 }
  static var typeIndex: UInt64 { 19 }
  static var firstDeclaredIndex: UInt64 { 32 }
  static var blockSize: Int { Layout.blockSize }

  // MARK: Volumes

  /// A new file system on `device`, with an empty root directory.
  public static func format(_ device: consuming Device, label: [UInt8], uuid: [UInt8], now: UInt64)
    throws(TaisceError) -> FileSystem
  {
    var fs = FileSystem(engine: try Engine.format(device, label: label, uuid: uuid, now: now))
    var c = Changes()
    for (name, kind, tree) in [(Array("name".utf8), AttributeKind.string, nameIndex), (Array("size".utf8), .uint64, sizeIndex),
                               (Array("mtime".utf8), .time, mtimeIndex), (Array("sys:type".utf8), .string, typeIndex)] {
      let info = IndexInfo(name: name, kind: kind, collation: .exact, building: false, tree: tree, cursor: 0)
      c.other.append(.insert(tree: registry, key: name, value: info.encode()))
      fs.indices.append(info)
    }
    try fs.putInode(Self.root, Inode(type: .directory, mode: 0o755, parent: Self.root, now: now), &c)
    try fs.applyChanges(c)
    try fs.engine.commitGroup()
    return fs
  }

  /// Mounts the file system on `device`: replays the log, then frees what
  /// orphans a crash left.
  public static func mount(_ device: consuming Device) throws(TaisceError) -> FileSystem {
    var fs = FileSystem(engine: try Engine.mount(device))
    for (key, value) in try fs.engine.scan(registry, from: []) { fs.indices.append(try IndexInfo.decode(key, value)) }
    if let (last, _) = try fs.engine.floor(journal, [UInt8](repeating: 0xFF, count: 8)) {
      fs.nextSeq = FSKey.readU64(last, at: 0) + 1
    }
    for (key, _) in try fs.engine.scan(orphans, from: []) {
      try fs.destroy(FSKey.readU64(key, at: 0))
    }
    try fs.engine.commitGroup()
    return fs
  }

  init(engine: consuming Engine<Device>) { self.engine = engine }

  /// Runs an operation. If it runs out of space while freed blocks wait to
  /// be reusable (held for the group, deferred, or in the readers' limbo),
  /// makes them reusable and runs it again. An operation that fails
  /// changes nothing (its batch rolls back, its new blocks are let go and
  /// blocks it rewrote in place get their contents back), so it's safe to
  /// commit between the two tries.
  mutating func reclaiming<T>(_ operation: (inout Self) throws(TaisceError) -> T) throws(TaisceError) -> T {
    guard !engine.stopped else { throw .readOnly }  // before any file data is written
    do {
      return try operation(&self)
    } catch .noSpace where engine.reclaimable > 0 {
      try engine.reclaim()
      return try operation(&self)
    }
  }

  /// Makes everything so far durable, by committing the group.
  public mutating func sync() throws(TaisceError) { try engine.commitGroup() }

  /// Makes everything so far durable, quickly: through the intent log,
  /// without a group commit (S1e). It covers every operation so far, not
  /// just one file's.
  public mutating func fsync() throws(TaisceError) { try engine.fsync() }

  // MARK: Nodes

  /// Changes a node's permissions, owners or times; nil leaves one as is.
  public mutating func setAttributes(_ ino: UInt64, mode: UInt32? = nil, uid: UInt32? = nil, gid: UInt32? = nil,
                                     atime: UInt64? = nil, mtime: UInt64? = nil, now: UInt64) throws(TaisceError) {
    try reclaiming { (fs: inout Self) throws(TaisceError) in
      try fs.changeAttributes(ino, mode: mode, uid: uid, gid: gid, atime: atime, mtime: mtime, now: now)
    }
  }

  mutating func changeAttributes(_ ino: UInt64, mode: UInt32?, uid: UInt32?, gid: UInt32?, atime: UInt64?,
                                 mtime: UInt64?, now: UInt64) throws(TaisceError) {
    var c = Changes()
    var n = try inode(ino, &c)
    if let mode { n.mode = mode & 0o7777 }
    if let uid { n.uid = uid }
    if let gid { n.gid = gid }
    if let atime { n.atime = atime }
    if let mtime { n.mtime = mtime }
    n.ctime = now
    n.version += 1
    try putInode(ino, n, &c)
    journal(&c, ino, parent: n.parent, .metadata)
    try applyChanges(c)
  }

  /// Marks a node open (FUSE open, or a native handle).
  public mutating func opened(_ ino: UInt64) {
    if let i = openCounts.firstIndex(where: { $0.ino == ino }) {
      openCounts[i].count += 1
    } else {
      openCounts.append((ino, 1))
    }
  }

  /// Marks a node closed; an orphan's last close frees it.
  public mutating func closed(_ ino: UInt64) throws(TaisceError) {
    guard let i = openCounts.firstIndex(where: { $0.ino == ino }) else { return }
    openCounts[i].count -= 1
    guard openCounts[i].count == 0 else { return }
    openCounts.remove(at: i)
    if try engine.get(Self.orphans, FSKey.u64(ino)) != nil { try destroy(ino) }
  }

  func isOpen(_ ino: UInt64) -> Bool { openCounts.contains { $0.ino == ino } }

  // MARK: Directories

  /// A new, empty file or directory named `name` in `dir`.
  public mutating func create(_ dir: UInt64, _ name: [UInt8], _ type: NodeType, mode: UInt32, uid: UInt32 = 0,
                               gid: UInt32 = 0, now: UInt64) throws(TaisceError) -> UInt64
  {
    guard type != .symlink else { throw .invalid }
    return try reclaiming { (fs: inout Self) throws(TaisceError) in
      try fs.make(dir, name, type, mode: mode, uid: uid, gid: gid, target: nil, now: now)
    }
  }

  /// A symbolic link to `target`.
  public mutating func symlink(_ dir: UInt64, _ name: [UInt8], target: [UInt8], uid: UInt32 = 0, gid: UInt32 = 0,
                                now: UInt64) throws(TaisceError) -> UInt64
  {
    guard !target.isEmpty, target.count <= BTree.maxValue else { throw .invalid }
    return try reclaiming { (fs: inout Self) throws(TaisceError) in
      try fs.make(dir, name, .symlink, mode: 0o777, uid: uid, gid: gid, target: target, now: now)
    }
  }

  mutating func make(_ dir: UInt64, _ name: [UInt8], _ type: NodeType, mode: UInt32, uid: UInt32, gid: UInt32,
                     target: [UInt8]?, now: UInt64) throws(TaisceError) -> UInt64
  {
    try Self.checkName(name)
    var c = Changes()
    var parent = try inode(dir, &c)
    guard parent.type == .directory else { throw .notDirectory }
    guard try entry(dir, name, &c) == nil else { throw .exists }
    let ino = engine.nextInode
    var node = Inode(type: type, mode: mode, parent: dir, now: now)
    node.uid = uid
    node.gid = gid
    if let target {
      node.size = UInt64(target.count)
      c.set(FSKey.make(ino, FSKey.symlink), target)
    }
    try putInode(ino, node, &c)
    try addEntry(dir, DirectoryEntry(name: name, ino: ino, type: type), &c)
    if type == .directory { parent.links += 1 }
    touch(&parent, now)
    try putInode(dir, parent, &c)
    journal(&c, ino, parent: dir, .created, name: name)
    journal(&c, dir, parent: parent.parent, .metadata)
    try applyChanges(c)
    engine.nextInode += 1
    return ino
  }

  /// Another name for a file.
  public mutating func link(_ ino: UInt64, _ dir: UInt64, _ name: [UInt8], now: UInt64) throws(TaisceError) {
    try reclaiming { (fs: inout Self) throws(TaisceError) in try fs.addLink(ino, dir, name, now: now) }
  }

  mutating func addLink(_ ino: UInt64, _ dir: UInt64, _ name: [UInt8], now: UInt64) throws(TaisceError) {
    try Self.checkName(name)
    var c = Changes()
    var node = try inode(ino, &c)
    guard node.type != .directory else { throw .isDirectory }
    var parent = try inode(dir, &c)
    guard parent.type == .directory else { throw .notDirectory }
    guard try entry(dir, name, &c) == nil else { throw .exists }
    try addEntry(dir, DirectoryEntry(name: name, ino: ino, type: node.type), &c)
    node.links += 1
    node.ctime = now
    node.version += 1
    try putInode(ino, node, &c)
    touch(&parent, now)
    try putInode(dir, parent, &c)
    journal(&c, ino, parent: dir, .linked, name: name)
    journal(&c, dir, parent: parent.parent, .metadata)
    try applyChanges(c)
  }

  /// Removes a file's or symlink's name; its last name frees it, or makes
  /// it an orphan while it's open.
  public mutating func unlink(_ dir: UInt64, _ name: [UInt8], now: UInt64) throws(TaisceError) {
    let freeing = try reclaiming { (fs: inout Self) throws(TaisceError) in try fs.removeName(dir, name, now: now) }
    if let freeing { try destroy(freeing) }
  }

  /// Unlink's first batch; returns the node to free, if any.
  mutating func removeName(_ dir: UInt64, _ name: [UInt8], now: UInt64) throws(TaisceError) -> UInt64? {
    var c = Changes()
    guard let e = try entry(dir, name, &c) else { throw .notFound }
    guard e.type != .directory else { throw .isDirectory }
    try removeEntry(dir, name, &c)
    var parent = try inode(dir, &c)
    touch(&parent, now)
    try putInode(dir, parent, &c)
    let freeing = try dropLink(e.ino, now, &c)
    journal(&c, e.ino, parent: dir, .unlinked, name: name)
    journal(&c, dir, parent: parent.parent, .metadata)
    try applyChanges(c)
    return freeing ? e.ino : nil
  }

  /// Removes an empty directory.
  public mutating func rmdir(_ dir: UInt64, _ name: [UInt8], now: UInt64) throws(TaisceError) {
    let freeing = try reclaiming { (fs: inout Self) throws(TaisceError) in try fs.removeDirectory(dir, name, now: now) }
    if let freeing { try destroy(freeing) }
  }

  /// Rmdir's first batch; returns the node to free, if any.
  mutating func removeDirectory(_ dir: UInt64, _ name: [UInt8], now: UInt64) throws(TaisceError) -> UInt64? {
    var c = Changes()
    guard let e = try entry(dir, name, &c) else { throw .notFound }
    guard e.type == .directory else { throw .notDirectory }
    guard try isEmpty(e.ino) else { throw .notEmpty }
    try removeEntry(dir, name, &c)
    var parent = try inode(dir, &c)
    parent.links -= 1
    touch(&parent, now)
    try putInode(dir, parent, &c)
    let freeing = try dropLink(e.ino, now, &c)
    journal(&c, e.ino, parent: dir, .unlinked, name: name)
    journal(&c, dir, parent: parent.parent, .metadata)
    try applyChanges(c)
    return freeing ? e.ino : nil
  }

  /// Moves `fromName` in `fromDir` to `toName` in `toDir`, replacing what's
  /// there as POSIX rename does.
  public mutating func rename(_ fromDir: UInt64, _ fromName: [UInt8], _ toDir: UInt64, _ toName: [UInt8], now: UInt64)
    throws(TaisceError)
  {
    let freeing = try reclaiming { (fs: inout Self) throws(TaisceError) in
      try fs.move(fromDir, fromName, toDir, toName, now: now)
    }
    if let freeing { try destroy(freeing) }
  }

  /// Rename's first batch; returns the node it replaced, to free, if any.
  mutating func move(_ fromDir: UInt64, _ fromName: [UInt8], _ toDir: UInt64, _ toName: [UInt8], now: UInt64)
    throws(TaisceError) -> UInt64?
  {
    try Self.checkName(toName)
    var c = Changes()
    guard let source = try entry(fromDir, fromName, &c) else { throw .notFound }
    guard try inode(toDir, &c).type == .directory else { throw .notDirectory }
    if fromDir == toDir && fromName == toName { return nil }
    if source.type == .directory {
      // Not into itself or below it.
      var d = toDir
      while true {
        if d == source.ino { throw .invalid }
        let p = try inode(d, &c).parent
        if p == d { break }
        d = p
      }
    }
    var freeing: UInt64? = nil
    if let target = try entry(toDir, toName, &c) {
      if target.ino == source.ino { return nil }  // two names for one file: nothing to do
      if source.type == .directory {
        guard target.type == .directory else { throw .notDirectory }
        guard try isEmpty(target.ino) else { throw .notEmpty }
      } else if target.type == .directory {
        throw .isDirectory
      }
      try removeEntry(toDir, toName, &c)
      if target.type == .directory {
        var to = try inode(toDir, &c)
        to.links -= 1
        try putInode(toDir, to, &c)
      }
      if try dropLink(target.ino, now, &c) { freeing = target.ino }
      journal(&c, target.ino, parent: toDir, .unlinked, name: toName)
    }
    try removeEntry(fromDir, fromName, &c)
    try addEntry(toDir, DirectoryEntry(name: toName, ino: source.ino, type: source.type), &c)
    var node = try inode(source.ino, &c)
    node.ctime = now
    node.version += 1
    node.parent = toDir  // a file's most recent directory, for the journal
    if source.type == .directory && fromDir != toDir {
      var from = try inode(fromDir, &c), to = try inode(toDir, &c)
      from.links -= 1
      try putInode(fromDir, from, &c)
      to.links += 1
      try putInode(toDir, to, &c)
    }
    try putInode(source.ino, node, &c)
    for d in fromDir == toDir ? [fromDir] : [fromDir, toDir] {
      var p = try inode(d, &c)
      touch(&p, now)
      try putInode(d, p, &c)
      journal(&c, d, parent: p.parent, .metadata)
    }
    journal(&c, source.ino, parent: toDir, .renamed, name: toName)
    try applyChanges(c)
    return freeing
  }

  // MARK: Data

  /// Writes `bytes` at `offset`, growing the file as needed.
  public mutating func write(_ ino: UInt64, offset: UInt64, _ bytes: [UInt8], now: UInt64) throws(TaisceError) {
    try reclaiming { (fs: inout Self) throws(TaisceError) in try fs.writeData(ino, offset: offset, bytes, now: now) }
  }

  mutating func writeData(_ ino: UInt64, offset: UInt64, _ bytes: [UInt8], now: UInt64) throws(TaisceError) {
    var c = Changes()
    var node = try inode(ino, &c)
    guard node.type == .file else { throw node.type == .directory ? .isDirectory : .invalid }
    guard !bytes.isEmpty else { return }
    let bs = UInt64(Self.blockSize)
    let end = offset + UInt64(bytes.count)
    let first = offset / bs, last = (end - 1) / bs
    var data = try readBlocks(ino, first, Int(last - first + 1), &c)
    data.replaceSubrange(Int(offset - first * bs)..<Int(end - first * bs), with: bytes)
    do {
      let freed = try replaceBlocks(ino, first, data, &c)
      node.size = max(node.size, end)
      touchData(&node, now)
      try putInode(ino, node, &c)
      journalData(&c, ino, node.parent)
      try commitData(c, freed)
    } catch {
      abandon(c)
      throw error
    }
  }

  /// Sets a file's size: shrinking frees the blocks past it, growing reads
  /// as zeros.
  public mutating func truncate(_ ino: UInt64, size: UInt64, now: UInt64) throws(TaisceError) {
    try reclaiming { (fs: inout Self) throws(TaisceError) in try fs.resize(ino, size: size, now: now) }
  }

  mutating func resize(_ ino: UInt64, size: UInt64, now: UInt64) throws(TaisceError) {
    var c = Changes()
    var node = try inode(ino, &c)
    guard node.type == .file else { throw node.type == .directory ? .isDirectory : .invalid }
    var freed: [Extent] = []
    do {
      if size < node.size {
        let bs = UInt64(Self.blockSize)
        let keep = (size + bs - 1) / bs  // blocks that still hold data
        // Bytes past the end of the last block stay zero, so growing later
        // reads zeros there.
        if size % bs != 0, try mapping(ino, size / bs, &c) != nil {
          var tail = try readBlocks(ino, size / bs, 1, &c)
          for i in Int(size % bs)..<Self.blockSize { tail[i] = 0 }
          freed += try replaceBlocks(ino, size / bs, tail, &c)
        }
        freed += try unmap(ino, from: keep, &c)
      }
      node.size = size
      touchData(&node, now)
      try putInode(ino, node, &c)
      journalData(&c, ino, node.parent)
      try commitData(c, freed)
    } catch {
      abandon(c)
      throw error
    }
  }

  /// Applies a data change's metadata, then lets go of the blocks it
  /// replaced (held until the group commits). If it fails, the caller
  /// abandons the change.
  mutating func commitData(_ c: Changes, _ freed: [Extent]) throws(TaisceError) {
    try applyChanges(c)
    for e in freed { engine.store.volume.allocator.free(e) }
    engine.noteFreed(freed)
  }

  /// Undoes what a data change that failed had done, wherever it failed:
  /// its new blocks are let go (fresh: available again at once), the
  /// intent log forgets them, and blocks it rewrote in place get their
  /// old contents back. If the device won't take those back, the engine
  /// stops: the group's extents name checksums those blocks no longer
  /// match.
  mutating func abandon(_ c: Changes) {
    for e in c.allocated { engine.store.volume.allocator.free(e) }
    engine.dropStaged()
    for (block, bytes) in c.overwritten.reversed() {
      cache(block, bytes)
      do {
        try engine.store.volume.device.write(block, bytes)
      } catch {
        engine.stop()
      }
    }
  }

  // MARK: Extents

  /// The extent covering file block `block`: (its first file block,
  /// physical start, count), as `c` leaves it.
  mutating func mapping(_ ino: UInt64, _ block: UInt64, _ c: inout Changes) throws(TaisceError)
    -> (UInt64, UInt64, UInt64)?
  {
    try extents(ino, block, block + 1, &c).first.map { ($0.start, $0.physical, $0.count) }
  }

  /// The extents overlapping file blocks `first..<end`, in order, as the
  /// engine has them with `c`'s pending changes on top.
  mutating func extents(_ ino: UInt64, _ first: UInt64, _ end: UInt64, _ c: inout Changes) throws(TaisceError)
    -> [FileExtent]
  {
    var found = try storedExtents(ino, first, end)
    func add(_ key: [UInt8], _ value: [UInt8]) throws(TaisceError) {
      found.append(try FileExtent.decode(start: FSKey.readU64(key, at: 9), value))
    }
    // Pending changes win: the last for each key.
    for (i, e) in c.entries.enumerated() where e.key.count == 17 && e.key[8] == FSKey.extent
      && FSKey.readU64(e.key, at: 0) == ino && !c.entries[(i + 1)...].contains(where: { $0.key == e.key })
    {
      let start = FSKey.readU64(e.key, at: 9)
      found.removeAll { $0.start == start }
      if let v = e.value { try add(e.key, v) }
    }
    return found.filter { $0.start < end && $0.start + $0.count > first }.sorted { $0.start < $1.start }
  }

  /// `count` file blocks from `first`, holes as zeros, with `c`'s pending
  /// changes on top.
  mutating func readBlocks(_ ino: UInt64, _ first: UInt64, _ count: Int, _ c: inout Changes) throws(TaisceError)
    -> [UInt8]
  {
    try readBlocks(try extents(ino, first, first + UInt64(count), &c), first, count)
  }

  /// Gives file blocks `first...` the contents `data` (whole blocks): blocks
  /// allocated in this group are rewritten in place, the rest go to new
  /// space. Returns the blocks this replaces, to free once it's applied.
  mutating func replaceBlocks(_ ino: UInt64, _ first: UInt64, _ data: [UInt8], _ c: inout Changes)
    throws(TaisceError) -> [Extent]
  {
    let count = UInt64(data.count / Self.blockSize)
    let old = try extents(ino, first, first + count, &c)
    // Where each block goes: in place if fresh, else new space.
    var target = [UInt64](repeating: 0, count: Int(count))
    var needed: UInt64 = 0
    for i in 0..<count {
      let b = first + i
      if let e = old.first(where: { b >= $0.start && b < $0.start + $0.count }),
        engine.store.volume.allocator.isRewritable(e.physical + (b - e.start))
      {
        target[Int(i)] = e.physical + (b - e.start)
      } else {
        needed += 1
      }
    }
    var hint = old.last.map { $0.physical + $0.count } ?? 0
    if first > 0, let prior = try mapping(ino, first - 1, &c) { hint = prior.1 + prior.2 }
    let fresh = try engine.store.volume.allocator.allocate(needed, near: hint)
    c.allocated += fresh
    engine.noteAllocated(fresh)
    // Blocks rewritten in place: what they hold now, to put back if the
    // batch fails (nothing committed or logged names them, but the
    // group's own extents do, with these contents' checksums).
    for i in target.indices where target[i] != 0 {
      let block = target[i]
      if let bytes = cached(block) {
        c.overwritten.append((block, bytes))
      } else {
        c.overwritten.append((block, try engine.store.volume.device.read(block, count: 1)))
      }
    }
    var spare = fresh.flatMap { e in (e.start..<e.end).map { $0 } }[...]
    for i in target.indices where target[i] == 0 { target[i] = spare.removeFirst() }
    // The data, in runs of consecutive physical blocks.
    var i = 0
    while i < target.count {
      var j = i + 1
      while j < target.count, target[j] == target[j - 1] + 1 { j += 1 }
      try engine.store.volume.device.write(target[i], Array(data[(i * Self.blockSize)..<(j * Self.blockSize)]))
      for k in i..<j { cache(target[k], Array(data[(k * Self.blockSize)..<((k + 1) * Self.blockSize)])) }
      i = j
    }
    engine.dataWritten = true
    // The mapping: what's kept of old extents outside the range (with their
    // checksums), then the new runs, each block's checksum from its data.
    var freed: [Extent] = []
    for e in old {
      c.delete(FSKey.make(ino, FSKey.extent, FSKey.u64(e.start)))
      if e.start < first {
        c.setExtent(ino, e.start, e.physical, Array(e.checksums[..<Int(first - e.start)]))
      }
      let end = first + count, eEnd = e.start + e.count
      if eEnd > end {
        c.setExtent(ino, end, e.physical + (end - e.start), Array(e.checksums[Int(end - e.start)...]))
      }
      // Its blocks inside the range that weren't kept in place.
      let lo = max(e.start, first), hi = min(eEnd, end)
      var b = lo
      while b < hi {
        let p = e.physical + (b - e.start)
        if target[Int(b - first)] != p { freed.append(Extent(start: p, count: 1)) }
        b += 1
      }
    }
    let sums = (0..<target.count).map { Checksum(of: Array(data[($0 * Self.blockSize)..<(($0 + 1) * Self.blockSize)])) }
    i = 0
    while i < target.count {
      var j = i + 1
      while j < target.count, j - i < FileExtent.maxBlocks, target[j] == target[j - 1] + 1 { j += 1 }
      c.setExtent(ino, first + UInt64(i), target[i], Array(sums[i..<j]))
      i = j
    }
    return freed
  }

  /// Removes the mapping of file blocks from `first` on; returns the
  /// blocks to free.
  mutating func unmap(_ ino: UInt64, from first: UInt64, _ c: inout Changes) throws(TaisceError) -> [Extent] {
    var freed: [Extent] = []
    for e in try extents(ino, first, UInt64.max, &c) {
      c.delete(FSKey.make(ino, FSKey.extent, FSKey.u64(e.start)))
      if e.start < first {
        c.setExtent(ino, e.start, e.physical, Array(e.checksums[..<Int(first - e.start)]))
        freed.append(Extent(start: e.physical + (first - e.start), count: e.count - (first - e.start)))
      } else {
        freed.append(Extent(start: e.physical, count: e.count))
      }
    }
    return freed
  }

  func cached(_ block: UInt64) -> [UInt8]? {
    guard let c = dataCache[Int(block % UInt64(dataCache.count))], c.block == block else { return nil }
    return c.bytes
  }

  mutating func cache(_ block: UInt64, _ bytes: [UInt8]) {
    dataCache[Int(block % UInt64(dataCache.count))] = CachedBlock(block: block, bytes: bytes)
  }

  // MARK: Reading (FileReading)

  public func root(_ id: UInt64) -> BTree? { engine.root(id) }

  public mutating func node(_ pointer: NodePointer) throws(TaisceError) -> Node { try engine.store.node(pointer) }

  public mutating func dataBlocks(_ physical: UInt64, _ checksums: ArraySlice<Checksum>) throws(TaisceError)
    -> [UInt8]
  {
    let n = checksums.count
    if (0..<n).allSatisfy({ cached(physical + UInt64($0)) != nil }) {
      var out: [UInt8] = []
      out.reserveCapacity(n * Self.blockSize)
      for k in 0..<n { out += cached(physical + UInt64(k))! }
      return out
    }
    let bytes = try engine.store.volume.device.read(physical, count: n)
    // Every block must have the checksum its extent records (S1).
    for (k, sum) in checksums.enumerated() {
      let block = Array(bytes[(k * Self.blockSize)..<((k + 1) * Self.blockSize)])
      guard Checksum(of: block) == sum else { throw .corrupt(.checksum(physical + UInt64(k))) }
      cache(physical + UInt64(k), block)
    }
    return bytes
  }

  // MARK: Checking

  /// Every invariant, the engine's and the file system's: what fsck checks.
  /// Returns how many nodes the volume holds.
  @discardableResult
  public mutating func check() throws(TaisceError) -> Int {
    // Every inode, and every name for it, from the keys themselves.
    var inodes: [(ino: UInt64, node: Inode, names: UInt32, subdirs: UInt32)] = []
    var entries: [(dir: UInt64, entry: DirectoryEntry)] = []
    var extents: [(ino: UInt64, start: UInt64, physical: UInt64, count: UInt64)] = []
    var backlinks: [[UInt8]] = []
    var extentSums: [FileExtent] = []
    for (key, value) in try engine.scan(FSKey.tree, from: []) {
      let ino = FSKey.readU64(key, at: 0)
      switch key[8] {
      case FSKey.inode: inodes.append((ino, try Inode.decode(value), 0, 0))
      case FSKey.dirent: for e in try Bucket.decode(value) { entries.append((ino, e)) }
      case FSKey.extent:
        let e = try FileExtent.decode(start: FSKey.readU64(key, at: 9), value)
        extents.append((ino, e.start, e.physical, e.count))
        extentSums.append(e)
      case FSKey.name:
        backlinks.append(key)
      default: break
      }
    }
    func index(_ ino: UInt64) -> Int? {
      var lo = 0, hi = inodes.count  // sorted: they came from the tree in key order
      while lo < hi {
        let mid = (lo + hi) / 2
        if inodes[mid].ino < ino { lo = mid + 1 } else { hi = mid }
      }
      return lo < inodes.count && inodes[lo].ino == ino ? lo : nil
    }
    for (dir, e) in entries {
      guard let i = index(e.ino), let d = index(dir) else { throw .corrupt(.fileSystem(.danglingEntry)) }
      guard inodes[i].node.type == e.type, inodes[d].node.type == .directory else {
        throw .corrupt(.fileSystem(.wrongType))
      }
      inodes[i].names += 1
      if e.type == .directory {
        inodes[d].subdirs += 1
        guard inodes[i].node.parent == dir else { throw .corrupt(.fileSystem(.parent)) }
      }
    }
    // Each name, from the node's side: exactly the directory entries.
    let names = entries.map { FSKey.make($0.entry.ino, FSKey.name, FSKey.u64($0.dir) + $0.entry.name) }
    guard backlinks == names.sorted(by: { $0.lexicographicallyPrecedes($1) }) else {
      throw .corrupt(.fileSystem(.backlink))
    }
    for n in inodes {
      let orphan = try engine.get(Self.orphans, FSKey.u64(n.ino)) != nil
      if n.ino == Self.root {
        guard n.node.links == 2 + n.subdirs, n.node.parent == Self.root else { throw .corrupt(.fileSystem(.linkCount)) }
      } else if orphan {
        guard n.node.links == 0, n.names == 0 else { throw .corrupt(.fileSystem(.linkCount)) }
      } else if n.names == 0 {
        throw .corrupt(.fileSystem(.unreachable))
      } else if n.node.type == .directory {
        guard n.names == 1, n.node.links == 2 + n.subdirs else { throw .corrupt(.fileSystem(.linkCount)) }
      } else {
        guard n.node.links == n.names else { throw .corrupt(.fileSystem(.linkCount)) }
      }
    }
    // Extents: inside their file, and no block in two of them. (The engine's
    // count then catches a data block that's also a node.)
    let bs = UInt64(Self.blockSize)
    var data: UInt64 = 0
    var blocks = extents.map { Extent(start: $0.physical, count: $0.count) }
    blocks.sort { $0.start < $1.start }
    for i in blocks.indices.dropFirst() where blocks[i].start < blocks[i - 1].end {
      throw .corrupt(.fileSystem(.sharedBlock))
    }
    for e in extents {
      guard let i = index(e.ino), (e.start + e.count) * bs < inodes[i].node.size + bs else {
        throw .corrupt(.fileSystem(.extentPastEnd))
      }
      for b in e.physical..<(e.physical + e.count) where !engine.store.volume.allocator.isUsed(b) {
        throw .corrupt(.fileSystem(.sharedBlock))
      }
      data += e.count
    }
    // The scrub: every data block read and checked against its extent.
    for e in extentSums {
      let bytes = try engine.store.volume.device.read(e.physical, count: Int(e.count))
      for k in 0..<Int(e.count) where Checksum(of: Array(bytes[(k * Self.blockSize)..<((k + 1) * Self.blockSize)])) != e.checksums[k] {
        throw .corrupt(.checksum(e.physical + UInt64(k)))
      }
    }
    _ = try engine.check(dataBlocks: data)
    try checkIndices(inodes.map { ($0.ino, $0.node) }, entries)
    return inodes.count
  }

  /// Every ready index holds exactly the keys the nodes call for: rebuilt
  /// from scratch and compared, as the query fuzzer will by query.
  mutating func checkIndices(_ inodes: [(ino: UInt64, node: Inode)], _ entries: [(dir: UInt64, entry: DirectoryEntry)])
    throws(TaisceError)
  {
    func sorted(_ keys: [[UInt8]]) -> [[UInt8]] { keys.sorted { $0.lexicographicallyPrecedes($1) } }
    for index in indices where !index.building {
      var expected: [[UInt8]] = []
      switch index.tree {
      case Self.nameIndex: expected = entries.map { Self.nameKey($0.entry.name, $0.entry.ino, $0.dir) }
      case Self.sizeIndex: expected = inodes.map { Self.fieldKey(.uint64($0.node.size), $0.ino) }
      case Self.mtimeIndex: expected = inodes.map { Self.fieldKey(.time(Int64(bitPattern: $0.node.mtime)), $0.ino) }
      default:
        for n in inodes {
          if let v = try attribute(n.ino, index.name), index.accepts(v) {
            expected.append(index.key(v) + FSKey.u64(n.ino))
          }
        }
      }
      let actual = try engine.scan(index.tree, from: []).map { $0.key }
      guard actual == sorted(expected) else { throw .corrupt(.fileSystem(.indexMismatch)) }
    }
  }

  // MARK: Indices and the journal, as operations change things

  /// Writes an inode, keeping the size and mtime indices with it.
  mutating func putInode(_ ino: UInt64, _ n: Inode, _ c: inout Changes) throws(TaisceError) {
    let old: Inode?
    if let v = try c.get(FSKey.make(ino, FSKey.inode), &engine) { old = try Inode.decode(v) } else { old = nil }
    c.set(FSKey.make(ino, FSKey.inode), n.encode())
    if old?.size != n.size {
      if let o = old { c.other.append(.delete(tree: Self.sizeIndex, key: Self.fieldKey(.uint64(o.size), ino))) }
      c.other.append(.insert(tree: Self.sizeIndex, key: Self.fieldKey(.uint64(n.size), ino), value: []))
    }
    if old?.mtime != n.mtime {
      if let o = old { c.other.append(.delete(tree: Self.mtimeIndex, key: Self.fieldKey(.time(Int64(bitPattern: o.mtime)), ino))) }
      c.other.append(.insert(tree: Self.mtimeIndex, key: Self.fieldKey(.time(Int64(bitPattern: n.mtime)), ino), value: []))
    }
  }

  static func fieldKey(_ v: AttributeValue, _ ino: UInt64) -> [UInt8] { IndexKey.encode(v, .exact) + FSKey.u64(ino) }

  /// The name index's key: the name, then the node, then its directory, so
  /// each hard link has its own entry.
  static func nameKey(_ name: [UInt8], _ ino: UInt64, _ dir: UInt64) -> [UInt8] {
    IndexKey.escaped(name) + FSKey.u64(ino) + FSKey.u64(dir)
  }

  /// Adds a change-journal record to `c`.
  mutating func journal(_ c: inout Changes, _ ino: UInt64, parent: UInt64, _ reasons: ChangeReason,
                        name: [UInt8] = []) {
    let e = JournalEntry(seq: nextSeq, txg: engine.txg, ino: ino, parent: parent, reasons: reasons, name: name)
    c.other.append(.insert(tree: Self.journal, key: FSKey.u64(nextSeq), value: e.encode()))
    nextSeq += 1
  }

  /// Journals a data change. Every one: a live query that has read the
  /// last one must hear of the next.
  mutating func journalData(_ c: inout Changes, _ ino: UInt64, _ parent: UInt64) {
    journal(&c, ino, parent: parent, .data)
  }

  /// Applies an operation's changes as one batch; if it fails, the
  /// journal numbers it took are given back.
  mutating func applyChanges(_ c: Changes) throws(TaisceError) {
    let seq = nextSeq - UInt64(c.other.count { if case .insert(let t, _, _) = $0 { t == Self.journal } else { false } })
    do {
      try engine.apply(c.messages(FSKey.tree) + c.orphanMessages(Self.orphans) + c.other)
    } catch {
      nextSeq = seq
      throw error
    }
  }

  // MARK: Helpers

  static func checkName(_ name: [UInt8]) throws(TaisceError) {
    guard name.count <= maxName else { throw .nameTooLong }
    guard !name.isEmpty, name != [0x2E], name != [0x2E, 0x2E], !name.contains(0x2F), !name.contains(0) else {
      throw .invalid
    }
  }

  mutating func inode(_ ino: UInt64, _ c: inout Changes) throws(TaisceError) -> Inode {
    guard let v = try c.get(FSKey.make(ino, FSKey.inode), &engine) else { throw .notFound }
    return try Inode.decode(v)
  }

  mutating func entry(_ dir: UInt64, _ name: [UInt8], _ c: inout Changes) throws(TaisceError) -> DirectoryEntry? {
    guard let v = try c.get(FSKey.make(dir, FSKey.dirent, FSKey.u64(Bucket.hash(name))), &engine) else { return nil }
    return try Bucket.decode(v).first { $0.name == name }
  }

  mutating func addEntry(_ dir: UInt64, _ e: DirectoryEntry, _ c: inout Changes) throws(TaisceError) {
    let key = FSKey.make(dir, FSKey.dirent, FSKey.u64(Bucket.hash(e.name)))
    var bucket: [DirectoryEntry] = []
    if let v = try c.get(key, &engine) { bucket = try Bucket.decode(v) }
    bucket.append(e)
    c.set(key, Bucket.encode(bucket))
    c.other.append(.insert(tree: Self.nameIndex, key: Self.nameKey(e.name, e.ino, dir), value: []))
    c.set(FSKey.make(e.ino, FSKey.name, FSKey.u64(dir) + e.name), [])
  }

  mutating func removeEntry(_ dir: UInt64, _ name: [UInt8], _ c: inout Changes) throws(TaisceError) {
    let key = FSKey.make(dir, FSKey.dirent, FSKey.u64(Bucket.hash(name)))
    guard let v = try c.get(key, &engine) else { return }
    let all = try Bucket.decode(v)
    for e in all where e.name == name {
      c.other.append(.delete(tree: Self.nameIndex, key: Self.nameKey(name, e.ino, dir)))
      c.delete(FSKey.make(e.ino, FSKey.name, FSKey.u64(dir) + name))
    }
    let bucket = all.filter { $0.name != name }
    if bucket.isEmpty { c.delete(key) } else { c.set(key, Bucket.encode(bucket)) }
  }

  mutating func isEmpty(_ dir: UInt64) throws(TaisceError) -> Bool {
    try engine.scan(FSKey.tree, from: FSKey.make(dir, FSKey.dirent), to: FSKey.make(dir, FSKey.dirent + 1), limit: 1)
      .isEmpty
  }

  /// Drops one link to `ino`; the last makes it an orphan. True if it's
  /// to be freed now; one that's open waits for its last close.
  mutating func dropLink(_ ino: UInt64, _ now: UInt64, _ c: inout Changes) throws(TaisceError) -> Bool {
    var node = try inode(ino, &c)
    node.links = node.type == .directory ? 0 : node.links - 1
    node.ctime = now
    node.version += 1
    try putInode(ino, node, &c)
    guard node.links == 0 else { return false }
    // An orphan either way: one that's open is freed at its last close;
    // otherwise the caller frees it in a second batch, and if a commit
    // comes between the two (a reclaim) and then a crash, mount frees it.
    c.orphans.append(ino)
    return !isOpen(ino)
  }

  /// Frees a node with no links: its keys, its blocks, its orphan entry.
  mutating func destroy(_ ino: UInt64) throws(TaisceError) {
    try reclaiming { (fs: inout Self) throws(TaisceError) in try fs.destroyNode(ino) }
  }

  mutating func destroyNode(_ ino: UInt64) throws(TaisceError) {
    var c = Changes()
    c.other.append(.delete(tree: Self.orphans, key: FSKey.u64(ino)))
    var freed: [Extent] = []
    var parent: UInt64 = 0
    for (key, value) in try engine.scan(FSKey.tree, from: FSKey.make(ino, 0), to: FSKey.make(ino + 1, 0)) {
      c.other.append(.delete(tree: FSKey.tree, key: key))
      switch key[8] {
      case FSKey.inode:
        let n = try Inode.decode(value)
        parent = n.parent
        c.other.append(.delete(tree: Self.sizeIndex, key: Self.fieldKey(.uint64(n.size), ino)))
        c.other.append(.delete(tree: Self.mtimeIndex, key: Self.fieldKey(.time(Int64(bitPattern: n.mtime)), ino)))
      case FSKey.attribute:
        let name = Array(key[9...])
        if let v = try attribute(ino, name) { indexChange(ino, name, old: v, new: nil, &c) }
      case FSKey.extent where value.count >= 16:
        freed.append(Extent(start: value.get(UInt64.self, at: 0), count: value.get(UInt64.self, at: 8)))
      default: break
      }
    }
    journal(&c, ino, parent: parent, .removed)
    try applyChanges(c)
    for e in freed { engine.store.volume.allocator.free(e) }
    engine.noteFreed(freed)
  }

  func touch(_ n: inout Inode, _ now: UInt64) {
    n.mtime = now
    n.ctime = now
    n.version += 1
  }
  func touchData(_ n: inout Inode, _ now: UInt64) { touch(&n, now) }
}

/// An operation's changes before they're applied: reads see them, so two
/// edits of one key compose, and they go to the engine as one batch.
struct Changes {
  var entries: [(key: [UInt8], value: [UInt8]?)] = []  // nil: deleted
  var orphans: [UInt64] = []
  /// Messages for other trees: indices, the journal, the registry.
  var other: [Message] = []
  /// Blocks allocated for this operation's data, to release if it fails.
  var allocated: [Extent] = []
  /// Blocks its data rewrote in place, with what they held before, to put
  /// back if it fails.
  var overwritten: [(block: UInt64, bytes: [UInt8])] = []

  mutating func get<D>(_ key: [UInt8], _ engine: inout Engine<D>) throws(TaisceError) -> [UInt8]? {
    if let e = entries.last(where: { $0.key == key }) { return e.value }
    return try engine.get(FSKey.tree, key)
  }

  mutating func set(_ key: [UInt8], _ value: [UInt8]) { entries.append((key, value)) }
  mutating func delete(_ key: [UInt8]) { entries.append((key, nil)) }

  mutating func setExtent(_ ino: UInt64, _ start: UInt64, _ physical: UInt64, _ checksums: [Checksum]) {
    set(FSKey.make(ino, FSKey.extent, FSKey.u64(start)),
        FileExtent(start: start, physical: physical, checksums: checksums).encode())
  }

  /// The batch: the last change to each key, in the order made.
  func messages(_ tree: UInt64) -> [Message] {
    entries.map { e in
      if let v = e.value { .insert(tree: tree, key: e.key, value: v) } else { .delete(tree: tree, key: e.key) }
    }
  }

  func orphanMessages(_ tree: UInt64) -> [Message] { orphans.map { .insert(tree: tree, key: FSKey.u64($0), value: []) } }
}

/// A run of a file's blocks (filesystem.md §3, EXTENT): where it is, and
/// each block's BLAKE3-128 (S1), checked on every read. On disk: physical
/// start u64, count u64, then the checksums, 16 bytes each.
struct FileExtent {
  var start: UInt64  // the first file block
  var physical: UInt64
  var checksums: [Checksum]

  var count: UInt64 { UInt64(checksums.count) }

  /// At most this many blocks an extent (512 KiB), so its value fits a node.
  static let maxBlocks = 128

  func encode() -> [UInt8] {
    var v = [UInt8](repeating: 0, count: 16 + 16 * checksums.count)
    v.put(physical, at: 0)
    v.put(count, at: 8)
    for (i, c) in checksums.enumerated() {
      v.put(c.a, at: 16 + 16 * i)
      v.put(c.b, at: 24 + 16 * i)
    }
    return v
  }

  static func decode(start: UInt64, _ v: [UInt8]) throws(TaisceError) -> FileExtent {
    guard v.count >= 16 else { throw .corrupt(.extent) }
    let count = Int(v.get(UInt64.self, at: 8))
    guard count > 0, count <= maxBlocks, v.count == 16 + 16 * count else { throw .corrupt(.extent) }
    return FileExtent(start: start, physical: v.get(UInt64.self, at: 0), checksums: (0..<count).map {
      Checksum(a: v.get(UInt64.self, at: 16 + 16 * $0), b: v.get(UInt64.self, at: 24 + 16 * $0))
    })
  }
}
