// SPDX-License-Identifier: BSD-3-Clause

// S0d: files and directories.

import Taisce
import Testing

func newFS(blocks: UInt64 = 8192) throws -> FileSystem<MemoryDevice> {
  try FileSystem.format(MemoryDevice(blocks: blocks), label: [], uuid: Array(1...16), now: 1)
}
func n(_ s: String) -> [UInt8] { Array(s.utf8) }
let root = FileSystem<MemoryDevice>.root

@Test func namesAreCreatedLookedUpAndListed() throws {
  var fs = try newFS()
  let docs = try fs.create(root, n("docs"), .directory, mode: 0o755, now: 2)
  let a = try fs.create(docs, n("a.txt"), .file, mode: 0o644, now: 3)
  #expect(try fs.lookup(docs, n("a.txt")) == a)
  #expect(throws: TaisceError.exists) { try fs.create(docs, n("a.txt"), .file, mode: 0o644, now: 4) }
  #expect(throws: TaisceError.notFound) { try fs.lookup(docs, n("b.txt")) }
  #expect(throws: TaisceError.notDirectory) { try fs.create(a, n("x"), .file, mode: 0o644, now: 4) }
  #expect(throws: TaisceError.invalid) { try fs.create(docs, n(".."), .file, mode: 0o644, now: 4) }
  #expect(throws: TaisceError.nameTooLong) { try fs.create(docs, [UInt8](repeating: 0x61, count: 256), .file, mode: 0, now: 4) }
  #expect(try fs.stat(root).links == 3)  // ., .. and docs/..
  #expect(try fs.stat(docs).mtime == 3)
  for i in 0..<300 { _ = try fs.create(docs, n("f\(i)"), .file, mode: 0o644, now: 5) }
  // Listed in pages, every name once.
  var names: [String] = []
  var cookie: UInt64? = nil
  while true {
    let page = try fs.list(docs, after: cookie, limit: 7)
    if page.isEmpty { break }
    names += page.map { String(decoding: $0.entry.name, as: UTF8.self) }
    cookie = page.last!.cookie
  }
  #expect(names.count == 301 && Set(names).count == 301)
  try fs.check()
}

@Test func dataReadsBackWithHolesAsZeros() throws {
  var fs = try newFS()
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  try fs.write(f, offset: 0, n("hello"), now: 3)
  try fs.write(f, offset: 100_000, n("world"), now: 4)  // a hole between
  #expect(try fs.stat(f).size == 100_005)
  #expect(try fs.read(f, offset: 0, count: 5) == n("hello"))
  #expect(try fs.read(f, offset: 50_000, count: 3) == [0, 0, 0])
  #expect(try fs.read(f, offset: 99_998, count: 100) == [0, 0] + n("world"))
  // A write across blocks, after a commit: copy-on-write.
  try fs.sync()
  let big = (0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
  try fs.write(f, offset: 3, big, now: 5)
  #expect(try fs.read(f, offset: 0, count: 20_003) == n("hel") + big)
  try fs.check()
  // Shrinking zeroes past the end, so growing again reads zeros.
  try fs.truncate(f, size: 10, now: 6)
  try fs.truncate(f, size: 5000, now: 7)
  #expect(try fs.read(f, offset: 0, count: 20) == n("hel") + big.prefix(7) + [UInt8](repeating: 0, count: 10))
  try fs.check()
}

@Test func renameFollowsPOSIX() throws {
  var fs = try newFS()
  let a = try fs.create(root, n("a"), .directory, mode: 0o755, now: 2)
  let b = try fs.create(a, n("b"), .directory, mode: 0o755, now: 2)
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  #expect(throws: TaisceError.invalid) { try fs.rename(root, n("a"), b, n("a"), now: 3) }  // into itself
  #expect(throws: TaisceError.isDirectory) { try fs.rename(root, n("f"), root, n("a"), now: 3) }
  try fs.rename(a, n("b"), root, n("b"), now: 3)
  #expect(try fs.stat(b).parent == root)
  #expect(try fs.stat(a).links == 2 && fs.stat(root).links == 4)
  try fs.link(f, a, n("g"), now: 4)
  try fs.rename(root, n("f"), a, n("g"), now: 5)  // the same file: nothing happens
  #expect(try fs.stat(f).links == 2)
  try fs.check()
}

@Test func anOpenFileOutlivesItsNameAndACrash() throws {
  var fs = try newFS()
  let f = try fs.create(root, n("tmp"), .file, mode: 0o600, now: 2)
  try fs.write(f, offset: 0, [UInt8](repeating: 9, count: 50_000), now: 3)
  fs.opened(f)
  try fs.unlink(root, n("tmp"), now: 4)
  #expect(try fs.read(f, offset: 0, count: 3) == [9, 9, 9])  // still readable while open
  try fs.sync()
  try fs.check()
  // A crash while it's open: the mount frees it.
  var after = try FileSystem.mount(fs.engine.store.volume.device)
  #expect(throws: TaisceError.notFound) { try after.stat(f) }
  try after.check()
  // Without a crash, the last close frees it.
  fs.opened(f)
  try fs.closed(f)
  try fs.closed(f)
  #expect(throws: TaisceError.notFound) { try fs.stat(f) }
  try fs.check()
}

@Test func largeFilesSplitIntoCappedExtents() throws {
  var fs = try newFS()
  let f = try fs.create(root, n("big"), .file, mode: 0o644, now: 2)
  var rng = SplitMix(state: 3)
  let data = (0..<(1 << 20)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }  // 256 blocks
  try fs.write(f, offset: 0, data, now: 3)
  try fs.sync()
  #expect(try fs.read(f, offset: 0, count: data.count) == data)
  // Each extent holds at most 128 blocks' checksums, so a value fits a node.
  let extents = try fs.engine.scan(1, from: [UInt8](repeating: 0, count: 7) + [UInt8(f), 3],
                                   to: [UInt8](repeating: 0, count: 7) + [UInt8(f), 4])
  #expect(extents.count >= 2)
  #expect(extents.allSatisfy { $0.value.count <= 16 + 16 * 128 })
  var again = try FileSystem.mount(fs.engine.store.volume.device)
  #expect(try again.read(f, offset: 500_000, count: 70_000) == Array(data[500_000..<570_000]))
  try again.check()
}
