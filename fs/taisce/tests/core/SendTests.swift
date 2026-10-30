// SPDX-License-Identifier: BSD-3-Clause

// S2: send and receive. A volume's snapshots are sent whole, then as
// changes, into a directory of another volume, which must then hold
// exactly the snapshot: names, kinds, links, bytes, attributes and times.

import Taisce
import Testing

/// Sends `from` to `to` of `sender` into `dir` of `receiver`, in pieces of
/// `piece` bytes; returns the stream's length.
@discardableResult
func transfer(_ sender: inout FileSystem<MemoryDevice>, from: SnapshotRecord?, to: SnapshotRecord,
              _ receiver: inout FileSystem<MemoryDevice>, into dir: UInt64, piece: Int = 5000) throws -> Int {
  var stream = try sender.send(from: from, to: to)
  var r = receiver.receiver(into: dir)
  var total = 0
  while true {
    let bytes = try sender.read(&stream, max: piece)
    if bytes.isEmpty { break }
    total += bytes.count
    try receiver.receive(&r, bytes, now: 99)
  }
  #expect(r.done)
  return total
}

/// The tree under `a` in `x`'s snapshot `s` against the tree under `b` in
/// `y`: every name, kind, link count, byte, attribute (but the receiver's
/// own) and time.
func expectSame(_ x: inout FileSystem<MemoryDevice>, _ s: SnapshotRecord, _ a: UInt64,
                _ y: inout FileSystem<MemoryDevice>, _ b: UInt64, _ path: String = "") throws {
  struct Seen {
    var type: NodeType
    var links: UInt32
    var mtime: UInt64
    var data: [UInt8]
    var attributes: [[UInt8]: AttributeValue]
    var children: [[UInt8]: UInt64]
  }
  func look(_ v: inout FileSystem<MemoryDevice>, _ ino: UInt64) throws -> Seen {
    let n = try v.stat(ino)
    var attributes: [[UInt8]: AttributeValue] = [:]
    for a in try v.attributes(ino) where !a.name.starts(with: Array("sys:sent-".utf8)) {
      attributes[a.name] = try v.attribute(ino, a.name)
    }
    var children: [[UInt8]: UInt64] = [:]
    if n.type == .directory {
      for e in try v.list(ino) where e.entry.name != Array(".receiving".utf8) { children[e.entry.name] = e.entry.ino }
    }
    let data = n.type == .file ? try v.read(ino, offset: 0, count: Int(n.size)) : n.type == .symlink ? try v.readlink(ino) : []
    return Seen(type: n.type, links: n.links, mtime: n.mtime, data: data, attributes: attributes, children: children)
  }
  let one = try x.withSnapshot(s) { (v: inout FileSystem<MemoryDevice>) throws(TaisceError) -> Seen in
    do { return try look(&v, a) } catch let e as TaisceError { throw e } catch { throw .invalid }
  }
  let two = try look(&y, b)
  #expect(one.type == two.type, "\(path): kind")
  #expect(one.data == two.data, "\(path): bytes (\(one.data.count) and \(two.data.count))")
  #expect(one.attributes == two.attributes, "\(path): attributes")
  if path != "" {
    #expect(one.links == two.links, "\(path): links")
    #expect(one.mtime == two.mtime, "\(path): time")
  }
  #expect(Set(one.children.keys) == Set(two.children.keys), "\(path): names")
  for (name, child) in one.children {
    guard let other = two.children[name] else { continue }
    try expectSame(&x, s, child, &y, other, path + "/" + String(decoding: name, as: UTF8.self))
  }
}

@Test func aSnapshotIsSentWholeThenAsItsChanges() throws {
  var a = try newFS(blocks: 16_384)
  let docs = try a.create(root, n("docs"), .directory, mode: 0o755, now: 2)
  let f = try a.create(docs, n("f"), .file, mode: 0o640, now: 3)
  try a.write(f, offset: 0, pattern(1, 300_000), now: 3)
  try a.setAttribute(f, n("user:tag"), .string(n("rock")), now: 3)
  try a.setAttribute(f, n("user:big"), .bytes(pattern(2, 5000)), now: 3)
  let g = try a.create(root, n("g"), .file, mode: 0o644, now: 4)
  try a.write(g, offset: 1_000_000, n("far"), now: 4)  // a hole first
  try a.link(f, root, n("f-too"), now: 4)
  _ = try a.symlink(docs, n("to-g"), target: n("../g"), now: 4)
  let deep = try a.create(docs, n("deep"), .directory, mode: 0o700, now: 5)
  for i in 0..<30 { _ = try a.create(deep, n("e\(i)"), .file, mode: 0o644, now: 5) }
  let one = try a.takeSnapshot(now: noon)

  var b = try newFS(blocks: 16_384)
  let into = try b.create(root, n("recv"), .directory, mode: 0o755, now: 2)
  let whole = try transfer(&a, from: nil, to: one, &b, into: into)
  try expectSame(&a, one, root, &b, into)
  try b.check()

  // Changes of every kind, then only they are sent.
  try a.write(f, offset: 100_000, pattern(9, 10_000), now: 6)
  try a.truncate(g, size: 5, now: 6)
  try a.setAttribute(f, n("user:tag"), .string(n("jazz")), now: 6)
  _ = try a.removeAttribute(f, n("user:big"), now: 6)
  try a.unlink(root, n("f-too"), now: 6)
  try a.rename(docs, n("deep"), root, n("moved"), now: 6)
  try a.unlink(deep, n("e3"), now: 6)
  for i in 4..<10 { try a.unlink(deep, n("e\(i)"), now: 6) }
  let h = try a.create(deep, n("new"), .file, mode: 0o600, now: 7)
  try a.write(h, offset: 0, n("new bytes"), now: 7)
  try a.rename(root, n("g"), deep, n("g"), now: 7)
  let gone = try a.create(root, n("gone"), .directory, mode: 0o755, now: 7)
  _ = try a.create(gone, n("x"), .file, mode: 0o644, now: 7)
  let two = try a.takeSnapshot(now: noon + 1)
  try transfer(&a, from: one, to: two, &b, into: into)
  try expectSame(&a, two, root, &b, into)
  // A directory with something in it goes whole.
  try a.unlink(gone, n("x"), now: 8)
  try a.rmdir(root, n("gone"), now: 8)
  let three = try a.takeSnapshot(now: noon + 2)
  let small = try transfer(&a, from: two, to: three, &b, into: into, piece: 7)
  try expectSame(&a, three, root, &b, into)
  #expect(small < whole / 50, "an incremental of one removal is \(small) bytes, the whole \(whole)")
  try b.check()
  // On another base, or everything again over something: refused.
  var stale = try a.send(from: one, to: three)
  var r = b.receiver(into: into)
  let first = try a.read(&stale, max: 1 << 20)
  #expect(throws: TaisceError.invalid) { try b.receive(&r, first, now: 9) }
  var everything = try a.send(from: nil, to: three)
  var again = b.receiver(into: into)
  let all = try a.read(&everything, max: 1 << 20)
  #expect(throws: TaisceError.exists) { try b.receive(&again, all, now: 9) }
}

/// Random changes, a snapshot and an incremental after each round: the
/// receiver must match every snapshot in turn.
@Test(arguments: [UInt64(31), 32])
func incrementalsFollowRandomChanges(seed: UInt64) throws {
  var rng = SplitMix(state: seed)
  var a = try newFS(blocks: 32_768)
  var b = try newFS(blocks: 32_768)
  let into = try b.create(root, n("recv"), .directory, mode: 0o755, now: 2)
  var dirs: [UInt64] = [root]
  var last: SnapshotRecord? = nil
  for round in 0..<12 {
    for _ in 0..<40 {
      let dir = dirs[rng.below(dirs.count)]
      let names = try a.list(dir).map { $0.entry }
      switch rng.below(10) {
      case 0..<3:
        let name = n("n\(rng.below(30))")
        if names.contains(where: { $0.name == name }) { continue }
        if rng.below(4) == 0 {
          dirs.append(try a.create(dir, name, .directory, mode: 0o755, now: 10))
        } else {
          let f = try a.create(dir, name, .file, mode: 0o644, now: 10)
          try a.write(f, offset: UInt64(rng.below(20_000)), pattern(UInt8(rng.below(200)), rng.below(30_000)), now: 10)
        }
      case 3..<6:
        guard let e = names.filter({ $0.type == .file }).pick(&rng) else { continue }
        try a.write(e.ino, offset: UInt64(rng.below(40_000)), pattern(UInt8(rng.below(200)), 1 + rng.below(9000)), now: 11)
      case 6:
        guard let e = names.filter({ $0.type == .file }).pick(&rng) else { continue }
        try a.truncate(e.ino, size: UInt64(rng.below(10_000)), now: 12)
      case 7:
        guard let e = names.filter({ $0.type == .file }).pick(&rng) else { continue }
        try a.unlink(dir, e.name, now: 13)
      case 8:
        guard let e = names.pick(&rng) else { continue }
        let to = dirs[rng.below(dirs.count)]
        do { try a.rename(dir, e.name, to, n("r\(rng.below(30))"), now: 14) } catch {}
      default:
        guard let e = names.pick(&rng) else { continue }
        try a.setAttribute(e.ino, n("user:n"), .uint64(UInt64(rng.below(5))), now: 15)
      }
      dirs = try dirs.filter { d in (try? a.stat(d)) != nil }
    }
    let s = try a.takeSnapshot(now: noon + UInt64(round))
    try transfer(&a, from: last, to: s, &b, into: into, piece: 1 + rng.below(20_000))
    try expectSame(&a, s, root, &b, into)
    last = s
  }
  try b.check()
}

extension Array {
  func pick(_ rng: inout SplitMix) -> Element? { isEmpty ? nil : self[rng.below(count)] }
}
