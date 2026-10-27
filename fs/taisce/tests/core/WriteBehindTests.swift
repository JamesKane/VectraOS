// SPDX-License-Identifier: BSD-3-Clause

// Writes behind (D131): a page cache holds the bytes, the volume shows
// their size and times at once, and a group gets them only together.

import Taisce
import Testing

func page(_ byte: UInt8, _ count: Int = 1) -> [UInt8] { [UInt8](repeating: byte, count: count * 4096) }

@Test func aWriteBehindShowsAtOnceButReachesNoGroupWithoutItsBytes() throws {
  var fs = try newFS(blocks: 4096)
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  try fs.write(f, offset: 0, page(1), now: 3)
  try fs.sync()
  let seq = fs.nextSeq
  try fs.wroteBehind(f, through: 10_000, now: 4)
  #expect(try fs.stat(f).size == 10_000)
  #expect(try fs.stat(f).mtime == 4)
  #expect(try fs.journal(after: seq - 1).contains { $0.ino == f && $0.reasons.contains(.data) })
  #expect(try fs.stats([f]).first?.size == 10_000)
  // A commit, then a crash, before it is written back: the old file, whole.
  try fs.sync()
  var after = try FileSystem.mount(fs.engine.store.volume.device)
  #expect(try after.stat(f).size == 4096)
  #expect(try after.read(f, offset: 0, count: 8192) == page(1))
  try after.check()
}

@Test func aWriteBackCarriesTheSizeAndTimesWithTheBytes() throws {
  var fs = try newFS(blocks: 4096)
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  try fs.write(f, offset: 0, page(1, 2), now: 3)
  try fs.sync()
  try fs.wroteBehind(f, through: 4096 + 100, now: 4)
  try fs.wroteBehind(f, through: 3 * 4096 + 10, now: 5)
  var last = page(3)
  for i in 10..<4096 { last[i] = 0 }  // past the end: zeros
  try fs.writeBack(f, [(offset: 4096, bytes: page(2)), (offset: 3 * 4096, bytes: last), (offset: 5 * 4096, bytes: page(9))])
  let behind = fs.hasWritesBehind
  #expect(!behind)
  try fs.sync()
  var after = try FileSystem.mount(fs.engine.store.volume.device)
  let s = try after.stat(f)
  #expect(s.size == 3 * 4096 + 10)
  #expect(s.mtime == 5)
  #expect(try after.read(f, offset: 0, count: 1 << 20) == page(1) + page(2) + page(0) + Array(last[..<10]))
  try after.check()  // the page past the end took no block
}

@Test func aTruncateEndsTheWritesBehindAtItsSize() throws {
  var fs = try newFS(blocks: 4096)
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  try fs.wroteBehind(f, through: 3 * 4096, now: 3)
  try fs.truncate(f, size: 4096, now: 4)
  #expect(try fs.stat(f).size == 4096)
  #expect(try fs.stat(f).mtime == 4)
  try fs.writeBack(f, [(offset: 0, bytes: page(7, 3))])
  try fs.sync()
  #expect(try fs.read(f, offset: 0, count: 1 << 20) == page(7))
  try fs.check()
}

@Test func anUnlinkedFileDropsItsWritesBehind() throws {
  var fs = try newFS(blocks: 4096)
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  try fs.wroteBehind(f, through: 4096, now: 3)
  try fs.unlink(root, n("f"), now: 4)
  let behind = fs.hasWritesBehind
  #expect(!behind)
  #expect(throws: TaisceError.notFound) { try fs.writeBack(f, [(offset: 0, bytes: page(1))]) }
  try fs.check()
}

@Test func aTimeSetAfterAWriteBehindStands() throws {
  var fs = try newFS(blocks: 4096)
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  try fs.wroteBehind(f, through: 4096, now: 3)
  try fs.setAttributes(f, mtime: 100, now: 4)
  #expect(try fs.stat(f).mtime == 100)
  try fs.writeBack(f, [(offset: 0, bytes: page(1))])
  #expect(try fs.stat(f).mtime == 100)
  #expect(try fs.stat(f).size == 4096)
}
