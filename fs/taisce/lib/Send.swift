// SPDX-License-Identifier: BSD-3-Clause

/// Send and receive (S2, D153 §2): a volume's changes from one snapshot to
/// another, as a stream another volume applies.
///
/// The stream is logical, not blocks: the sender walks the two snapshots'
/// file trees, skipping every leaf both share (equal pointers, so equal
/// bytes), and sends each node whose keys differ, whole but for its data,
/// of which only the blocks whose checksums differ. The receiver applies
/// it with ordinary operations, so its own indices, journal and live
/// queries follow, and writes with its own key. Records, each a kind u8, a
/// length u32 and its payload (integers little-endian):
///
///     header  "TSnd" u32, version u32 (1), the sender volume's uuid (16),
///             the txg sent from (0: everything) and to
///     node    ino, type u8, mode u32, mtime u64, size u64, the symlink's
///             target (u32 length, bytes), its names (u32 count, each its
///             directory u64 and name, u16 length), its attributes (u32
///             count, each name (u16 length), kind u8, value (u32 length))
///     data    ino, offset u64, the bytes there (a node's, after it)
///     gone    ino: in the first snapshot, not in the second
///     end     how many node and gone records came before it
///
/// Attributes named `sys:sent-` are the receiver's own, never sent.
public enum SendRecord {
  static let magic: UInt32 = 0x646E_5354  // "TSnd"
  static let version: UInt32 = 1
  static let header: UInt8 = 1, node: UInt8 = 2, data: UInt8 = 3, gone: UInt8 = 4, end: UInt8 = 5
  /// Blocks in one data record, at most.
  static let dataBlocks = 16
  /// A received node's sender, and its inode there: the volume's uuid and
  /// the inode, indexed (`indexLookup`).
  public static let sentIno = Array("sys:sent-ino".utf8)
  /// On a directory received into: the sender's uuid and the txg it holds.
  public static let sentFrom = Array("sys:sent-from".utf8)
  public static let sentTxg = Array("sys:sent-txg".utf8)
  static let ours = Array("sys:sent-".utf8)

  static func isOurs(_ name: [UInt8]) -> Bool { name.count >= ours.count && Array(name[..<ours.count]) == ours }
}

/// Little-endian encoding into a record.
struct RecordWriter {
  var b: [UInt8] = []
  mutating func u8(_ v: UInt8) { b.append(v) }
  mutating func u16(_ v: UInt16) { for i in 0..<2 { b.append(UInt8(truncatingIfNeeded: v >> (8 * UInt16(i)))) } }
  mutating func u32(_ v: UInt32) { for i in 0..<4 { b.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
  mutating func u64(_ v: UInt64) { for i in 0..<8 { b.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
  mutating func bytes(_ v: [UInt8]) {
    u32(UInt32(v.count))
    b += v
  }
  mutating func name(_ v: [UInt8]) {
    u16(UInt16(v.count))
    b += v
  }

  static func record(_ kind: UInt8, _ body: (inout RecordWriter) -> Void) -> [UInt8] {
    var w = RecordWriter()
    body(&w)
    var out = RecordWriter()
    out.u8(kind)
    out.u32(UInt32(w.b.count))
    return out.b + w.b
  }
}

struct RecordReader {
  let b: [UInt8]
  var at = 0
  mutating func u8() throws(TaisceError) -> UInt8 {
    guard at < b.count else { throw .invalid }
    defer { at += 1 }
    return b[at]
  }
  mutating func u16() throws(TaisceError) -> UInt16 {
    guard at + 2 <= b.count else { throw .invalid }
    defer { at += 2 }
    return b.get(UInt16.self, at: at)
  }
  mutating func u32() throws(TaisceError) -> UInt32 {
    guard at + 4 <= b.count else { throw .invalid }
    defer { at += 4 }
    return b.get(UInt32.self, at: at)
  }
  mutating func u64() throws(TaisceError) -> UInt64 {
    guard at + 8 <= b.count else { throw .invalid }
    defer { at += 8 }
    return b.get(UInt64.self, at: at)
  }
  mutating func take(_ n: Int) throws(TaisceError) -> [UInt8] {
    guard n >= 0, at + n <= b.count else { throw .invalid }
    defer { at += n }
    return Array(b[at..<(at + n)])
  }
  mutating func bytes() throws(TaisceError) -> [UInt8] { try take(Int(try u32())) }
  mutating func name() throws(TaisceError) -> [UInt8] { try take(Int(try u16())) }
}

/// A stream being sent: what's left to send of it.
public struct SendStream: Sendable {
  public let from: SnapshotRecord?
  public let to: SnapshotRecord
  let uuid: [UInt8]
  /// The nodes whose keys may differ, in order, and the next to send.
  let inos: [UInt64]
  var next = 0
  /// Encoded and not yet read.
  var out: [UInt8] = []
  var started = false
  public internal(set) var ended = false
  /// The current file's blocks still to send.
  var blocks: [UInt64] = []
  var blocksOf: UInt64 = 0
  var records: UInt64 = 0
}

extension FileSystem {
  /// A stream of the changes from snapshot `from` (nil: from nothing) to
  /// `to`, for `read(_:max:)`.
  public mutating func send(from: SnapshotRecord?, to: SnapshotRecord) throws(TaisceError) -> SendStream {
    if let from { guard from.txg < to.txg else { throw .invalid } }
    let before = try from.map { (s: SnapshotRecord) throws(TaisceError) in try fileTree(of: s) } ?? BTree()
    let after = try fileTree(of: to)
    // The leaves either has that the other hasn't: only their keys can
    // differ.
    func sorted(_ p: [NodePointer]) -> [NodePointer] {
      p.sorted { $0.block != $1.block ? $0.block < $1.block : $0.checksum.a < $1.checksum.a }
    }
    let a = sorted(try before.leaves(&engine.store)), b = sorted(try after.leaves(&engine.store))
    func has(_ list: [NodePointer], _ p: NodePointer) -> Bool {
      var lo = 0, hi = list.count
      while lo < hi {
        let mid = (lo + hi) / 2
        let m = list[mid]
        if m.block < p.block || (m.block == p.block && m.checksum.a < p.checksum.a) { lo = mid + 1 } else { hi = mid }
      }
      return lo < list.count && list[lo] == p
    }
    var inos: [UInt64] = []
    for (list, other) in [(a, b), (b, a)] {
      for p in list where !has(other, p) {
        let n = try engine.store.node(p)
        for i in 0..<n.count { inos.append(FSKey.readU64(n.key(i), at: 0)) }
      }
    }
    inos.sort()
    var unique: [UInt64] = []
    for i in inos where unique.last != i { unique.append(i) }
    return SendStream(from: from, to: to, uuid: engine.store.volume.superblock.uuid, inos: unique)
  }

  /// A snapshot's file tree.
  mutating func fileTree(of s: SnapshotRecord) throws(TaisceError) -> BTree {
    try engine.snapshotTrees(s).first { $0.id == FSKey.tree }?.tree ?? BTree()
  }

  /// The stream's next bytes, at most `max`; none once it has all been read.
  public mutating func read(_ s: inout SendStream, max: Int) throws(TaisceError) -> [UInt8] {
    while s.out.count < max && !s.ended { try produce(&s) }
    let n = Swift.min(max, s.out.count)
    let bytes = Array(s.out[..<n])
    s.out.removeFirst(n)
    return bytes
  }

  /// Encodes the stream's next record or records.
  mutating func produce(_ s: inout SendStream) throws(TaisceError) {
    if !s.started {
      s.started = true
      s.out += RecordWriter.record(SendRecord.header) { w in
        w.u32(SendRecord.magic)
        w.u32(SendRecord.version)
        w.b += s.uuid
        w.u64(s.from?.txg ?? 0)
        w.u64(s.to.txg)
      }
      return
    }
    if !s.blocks.isEmpty {
      // A run of consecutive blocks, read from the snapshot sent to.
      var run = 1
      while run < s.blocks.count, run < SendRecord.dataBlocks, s.blocks[run] == s.blocks[run - 1] + 1 { run += 1 }
      let first = s.blocks[0], ino = s.blocksOf
      s.blocks.removeFirst(run)
      let bs = UInt64(Self.blockSize)
      let bytes = try withSnapshot(s.to) { (v: inout Self) throws(TaisceError) in
        try v.read(ino, offset: first * bs, count: run * Self.blockSize)
      }
      if !bytes.isEmpty {
        s.out += RecordWriter.record(SendRecord.data) { w in
          w.u64(ino)
          w.u64(first * bs)
          w.b += bytes
        }
      }
      return
    }
    guard s.next < s.inos.count else {
      s.out += RecordWriter.record(SendRecord.end) { w in w.u64(s.records) }
      s.ended = true
      return
    }
    let ino = s.inos[s.next]
    s.next += 1
    // Its keys in each snapshot: alike, it hasn't changed.
    let range = (FSKey.make(ino, 0), FSKey.make(ino + 1, 0))
    let old = try s.from.map { (f: SnapshotRecord) throws(TaisceError) in
      try withSnapshot(f) { (v: inout Self) throws(TaisceError) in try v.scan(FSKey.tree, from: range.0, to: range.1) }
    } ?? []
    let new = try withSnapshot(s.to) { (v: inout Self) throws(TaisceError) in
      try v.scan(FSKey.tree, from: range.0, to: range.1)
    }
    guard old.count != new.count || zip(old, new).contains(where: { $0.key != $1.key || $0.value != $1.value }) else {
      return
    }
    let inOld = try s.from.map { (f: SnapshotRecord) throws(TaisceError) in
      try withSnapshot(f) { (v: inout Self) throws(TaisceError) in try Self.isLive(&v, ino) }
    } ?? false
    let inNew = try withSnapshot(s.to) { (v: inout Self) throws(TaisceError) in try Self.isLive(&v, ino) }
    if !inNew {
      if inOld {
        s.out += RecordWriter.record(SendRecord.gone) { w in w.u64(ino) }
        s.records += 1
      }
      return
    }
    // The node, and which of its blocks to send: those whose checksums
    // differ from the first snapshot's, holes there included (as zeros).
    let bs = UInt64(Self.blockSize)
    let oldSums = try s.from.map { (f: SnapshotRecord) throws(TaisceError) in
      try withSnapshot(f) { (v: inout Self) throws(TaisceError) in try Self.blockSums(&v, ino) }
    } ?? []
    var record: [UInt8] = []
    var blocks: [UInt64] = []
    try withSnapshot(s.to) { (v: inout Self) throws(TaisceError) in
      let n = try v.stat(ino)
      let target = n.type == .symlink ? try v.readlink(ino) : []
      let names = ino == Self.root ? [] : try v.names(ino)
      var attributes: [(name: [UInt8], value: AttributeValue)] = []
      for a in try v.attributes(ino) where !SendRecord.isOurs(a.name) {
        if let value = try v.attribute(ino, a.name) { attributes.append((a.name, value)) }
      }
      record = RecordWriter.record(SendRecord.node) { w in
        w.u64(ino)
        w.u8(n.type.rawValue)
        w.u32(n.mode)
        w.u64(n.mtime)
        w.u64(n.size)
        w.bytes(target)
        w.u32(UInt32(names.count))
        for (dir, name) in names {
          w.u64(dir)
          w.name(name)
        }
        w.u32(UInt32(attributes.count))
        for (name, value) in attributes {
          w.name(name)
          w.u8(value.kind.rawValue)
          w.bytes(value.payload())
        }
      }
      guard n.type == .file else { return }
      let newSums = try Self.blockSums(&v, ino)
      let count = (n.size + bs - 1) / bs
      var i = 0, j = 0
      for block in 0..<count {
        while i < newSums.count, newSums[i].block < block { i += 1 }
        while j < oldSums.count, oldSums[j].block < block { j += 1 }
        let now = i < newSums.count && newSums[i].block == block ? newSums[i].sum : nil
        let was = j < oldSums.count && oldSums[j].block == block ? oldSums[j].sum : nil
        if now != was { blocks.append(block) }
      }
    }
    s.out += record
    s.records += 1
    s.blocks = blocks
    s.blocksOf = ino
  }

  /// Whether a node is in a snapshot with a name (an open file's orphan,
  /// with none, isn't sent).
  static func isLive(_ v: inout Self, _ ino: UInt64) throws(TaisceError) -> Bool {
    do throws(TaisceError) {
      let n = try v.stat(ino)
      return ino == root || n.links > 0
    } catch .notFound {
      return false
    }
  }

  /// A file's mapped blocks and their checksums, in order.
  static func blockSums(_ v: inout Self, _ ino: UInt64) throws(TaisceError) -> [(block: UInt64, sum: Checksum)] {
    var out: [(block: UInt64, sum: Checksum)] = []
    for e in try v.storedExtents(ino, 0, UInt64.max) {
      for (k, sum) in e.checksums.enumerated() { out.append((e.start + UInt64(k), sum)) }
    }
    return out
  }
}

// MARK: Receiving

/// A stream being received into a directory: its records as they come.
public struct Receiver: Sendable {
  /// The directory received into, and the staging directory in it, where
  /// nodes wait to be put in place.
  public let dir: UInt64
  var staging: UInt64 = 0
  var buffer: [UInt8] = []
  public internal(set) var uuid: [UInt8] = []
  public internal(set) var from: UInt64 = 0
  public internal(set) var to: UInt64 = 0
  var started = false
  public internal(set) var done = false
  /// Each node received: the sender's inode, this volume's, its names
  /// (the sender's directories) and its time.
  var placed: [(sent: UInt64, ino: UInt64, names: [(dir: UInt64, name: [UInt8])], mtime: UInt64)] = []
  var gone: [UInt64] = []
  /// The file being written, its size and time once its data is in.
  var current: (ino: UInt64, size: UInt64)?
  /// The directories whose entries this changed, with their times before:
  /// put back, but for those the stream sets.
  var times: [(dir: UInt64, mtime: UInt64)] = []
  /// Nodes this changed: a page cache over them is stale.
  public internal(set) var touched: [UInt64] = []
  public internal(set) var records: UInt64 = 0

  static let stagingName = Array(".receiving".utf8)
}

extension FileSystem {
  /// A receiver of a stream into directory `dir`.
  public func receiver(into dir: UInt64) -> Receiver { Receiver(dir: dir) }

  /// Takes the next bytes of a stream, applying each record they complete.
  /// A record that fails stops the stream: what came before it is applied.
  public mutating func receive(_ r: inout Receiver, _ bytes: [UInt8], now: UInt64) throws(TaisceError) {
    guard !r.done else { throw .invalid }
    r.buffer += bytes
    var at = 0
    while r.buffer.count - at >= 5 {
      let length = Int(r.buffer.get(UInt32.self, at: at + 1))
      guard r.buffer.count - at - 5 >= length else { break }
      let kind = r.buffer[at]
      let payload = Array(r.buffer[(at + 5)..<(at + 5 + length)])
      at += 5 + length
      try apply(&r, kind, payload, now: now)
    }
    r.buffer.removeFirst(at)
  }

  mutating func apply(_ r: inout Receiver, _ kind: UInt8, _ payload: [UInt8], now: UInt64) throws(TaisceError) {
    var p = RecordReader(b: payload)
    guard r.started || kind == SendRecord.header else { throw .invalid }
    switch kind {
    case SendRecord.header:
      guard !r.started, try p.u32() == SendRecord.magic, try p.u32() == SendRecord.version else { throw .invalid }
      r.uuid = try p.take(16)
      r.from = try p.u64()
      r.to = try p.u64()
      try startReceiving(&r, now: now)
      r.started = true
    case SendRecord.node:
      try finishFile(&r, now: now)
      try receiveNode(&r, &p, now: now)
      r.records += 1
    case SendRecord.data:
      let ino = try p.u64(), offset = try p.u64()
      guard let c = r.current, ino == r.placed.last?.sent else { throw .invalid }
      try write(c.ino, offset: offset, Array(payload[p.at...]), now: now)
    case SendRecord.gone:
      try finishFile(&r, now: now)
      r.gone.append(try p.u64())
      r.records += 1
    case SendRecord.end:
      try finishFile(&r, now: now)
      guard try p.u64() == r.records else { throw .invalid }
      try finishReceiving(&r, now: now)
    default:
      throw .invalid
    }
  }

  /// The directory's base must be what the stream builds on: none for
  /// everything, else the sender's and the snapshot sent from.
  mutating func startReceiving(_ r: inout Receiver, now: UInt64) throws(TaisceError) {
    let base = try attribute(r.dir, SendRecord.sentFrom)
    let held = try attribute(r.dir, SendRecord.sentTxg)
    if r.from == 0 {
      guard base == nil else { throw .exists }
    } else {
      guard base == .bytes(r.uuid), held == .uint64(r.from) else { throw .invalid }
    }
    if !indices.contains(where: { $0.name == SendRecord.sentIno }) {
      try declareIndex(SendRecord.sentIno, .bytes)
    }
    while try !backfill(budget: 4096) {}
    do throws(TaisceError) {
      r.staging = try lookup(r.dir, Receiver.stagingName)
    } catch .notFound {
      r.staging = try create(r.dir, Receiver.stagingName, .directory, mode: 0o700, now: now)
    }
  }

  /// This volume's node for the sender's `sent`, if it has one.
  mutating func received(_ r: Receiver, _ sent: UInt64) throws(TaisceError) -> UInt64? {
    if sent == Self.root { return r.dir }
    return try indexLookup(SendRecord.sentIno, equal: .bytes(r.uuid + FSKey.u64(sent))).first
  }

  /// A staging name: the sender's inode in hex.
  static func stagingName(_ sent: UInt64) -> [UInt8] {
    let digits = Array("0123456789abcdef".utf8)
    return (0..<16).map { digits[Int((sent >> (60 - 4 * UInt64($0))) & 0xF)] }
  }

  /// Keeps `dir`'s time before its entries change.
  mutating func remember(_ r: inout Receiver, _ dir: UInt64) throws(TaisceError) {
    guard dir != r.staging, !r.times.contains(where: { $0.dir == dir }) else { return }
    r.times.append((dir, try stat(dir).mtime))
  }

  /// Moves a node's names into the staging directory: one there, by its
  /// sender's inode, the rest unlinked.
  mutating func stage(_ r: inout Receiver, _ ino: UInt64, _ sent: UInt64, now: UInt64) throws(TaisceError) {
    let names = try self.names(ino)
    let here = Self.stagingName(sent)
    var kept = names.contains { $0.dir == r.staging && $0.name == here }
    for (dir, name) in names where !(dir == r.staging && name == here) {
      try remember(&r, dir)
      if kept {
        try unlink(dir, name, now: now)
      } else {
        try rename(dir, name, r.staging, here, now: now)
        kept = true
      }
    }
  }

  mutating func receiveNode(_ r: inout Receiver, _ p: inout RecordReader, now: UInt64) throws(TaisceError) {
    let sent = try p.u64()
    guard let type = NodeType(rawValue: try p.u8()) else { throw .invalid }
    let mode = try p.u32(), mtime = try p.u64(), size = try p.u64()
    let target = try p.bytes()
    var names: [(dir: UInt64, name: [UInt8])] = []
    for _ in 0..<(try p.u32()) { names.append((try p.u64(), try p.name())) }
    var attributes: [(name: [UInt8], value: AttributeValue)] = []
    for _ in 0..<(try p.u32()) {
      let name = try p.name()
      guard let kind = AttributeKind(rawValue: try p.u8()) else { throw .invalid }
      attributes.append((name, try AttributeValue.decode(kind, try p.bytes())))
    }
    guard sent == Self.root ? type == .directory : !names.isEmpty else { throw .invalid }
    var ino = try received(r, sent)
    if let have = ino, sent != Self.root {
      // Another kind now, or a link to elsewhere: made again.
      let n = try stat(have)
      let relink = n.type == .symlink ? try readlink(have) != target : false
      if n.type != type || relink {
        try stage(&r, have, sent, now: now)
        try remove(r.staging, Self.stagingName(sent), type: n.type, now: now)
        ino = nil
      } else {
        try stage(&r, have, sent, now: now)
      }
    }
    if ino == nil {
      let here = Self.stagingName(sent)
      let made = type == .symlink
        ? try symlink(r.staging, here, target: target, now: now)
        : try create(r.staging, here, type, mode: mode, now: now)
      try setAttribute(made, SendRecord.sentIno, .bytes(r.uuid + FSKey.u64(sent)), now: now)
      ino = made
    }
    let local = ino!
    if type != .symlink { try setAttributes(local, mode: mode, now: now) }
    // Its attributes, as sent; those not sent go.
    for a in try self.attributes(local) where !SendRecord.isOurs(a.name) {
      if !attributes.contains(where: { $0.name == a.name }) { _ = try removeAttribute(local, a.name, now: now) }
    }
    for (name, value) in attributes where try attribute(local, name) != value {
      try setAttribute(local, name, value, now: now)
    }
    r.placed.append((sent, local, names, mtime))
    r.touched.append(local)
    if type == .file { r.current = (local, size) }
  }

  /// The current file's data is all in: it takes its size.
  mutating func finishFile(_ r: inout Receiver, now: UInt64) throws(TaisceError) {
    guard let c = r.current else { return }
    r.current = nil
    if try stat(c.ino).size != c.size { try truncate(c.ino, size: c.size, now: now) }
  }

  /// Removes `name` in `dir`, a `type`.
  mutating func remove(_ dir: UInt64, _ name: [UInt8], type: NodeType, now: UInt64) throws(TaisceError) {
    if type == .directory { try rmdir(dir, name, now: now) } else { try unlink(dir, name, now: now) }
  }

  /// The end: what's gone goes, every node received takes its names, and
  /// the directory records what it now holds.
  mutating func finishReceiving(_ r: inout Receiver, now: UInt64) throws(TaisceError) {
    // Gone nodes to the staging directory, then out: its directories are
    // empty by now, their children staged or gone themselves.
    var going: [(ino: UInt64, sent: UInt64, type: NodeType)] = []
    for sent in r.gone {
      guard let ino = try received(r, sent), ino != r.dir else { continue }
      try stage(&r, ino, sent, now: now)
      going.append((ino, sent, try stat(ino).type))
    }
    for g in going where g.type != .directory { try unlink(r.staging, Self.stagingName(g.sent), now: now) }
    for g in going where g.type == .directory { try rmdir(r.staging, Self.stagingName(g.sent), now: now) }
    // Every node to its names: the first by rename, the others links.
    for p in r.placed where p.sent != Self.root {
      for (i, (sentDir, name)) in p.names.enumerated() {
        guard let dir = try received(r, sentDir) else { throw .notFound }
        try remember(&r, dir)
        if i == 0 {
          try rename(r.staging, Self.stagingName(p.sent), dir, name, now: now)
        } else {
          try link(p.ino, dir, name, now: now)
        }
      }
    }
    try rmdir(r.dir, Receiver.stagingName, now: now)
    // Those still here (a directory gone with its children was touched).
    for t in r.times where !r.placed.contains(where: { $0.ino == t.dir }) && !going.contains(where: { $0.ino == t.dir }) {
      try setAttributes(t.dir, mtime: t.mtime, now: now)
    }
    for p in r.placed { try setAttributes(p.ino, mtime: p.mtime, now: now) }
    try setAttribute(r.dir, SendRecord.sentFrom, .bytes(r.uuid), now: now)
    try setAttribute(r.dir, SendRecord.sentTxg, .uint64(r.to), now: now)
    r.done = true
  }
}
