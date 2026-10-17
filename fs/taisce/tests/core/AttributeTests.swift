// SPDX-License-Identifier: BSD-3-Clause

// S0f: attributes, indices with back-fill, and the change journal.

import Taisce
import Testing

@Test func attributesAreTypedNormalizedAndOverflow() throws {
  var fs = try newFS()
  let f = try fs.create(root, n("song"), .file, mode: 0o644, now: 2)
  try fs.setAttribute(f, n("Audio:Artist"), .string(Array("Beyonce\u{301}".utf8)), now: 3)
  #expect(try fs.attribute(f, n("Audio:Artist")) == .string(Array("Beyoncé".utf8)))  // stored in NFC
  try fs.setAttribute(f, n("Audio:Year"), .int64(-44), now: 3)
  try fs.setAttribute(f, n("user:rating"), .double(4.5), now: 3)
  let big = (0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }
  try fs.setAttribute(f, n("user:thumb"), .bytes(big), now: 4)  // overflow chunks
  #expect(try fs.attribute(f, n("user:thumb")) == .bytes(big))
  try fs.setAttribute(f, n("user:thumb"), .bytes([1, 2, 3]), now: 5)  // back inline: chunks go
  #expect(try fs.attribute(f, n("user:thumb")) == .bytes([1, 2, 3]))
  #expect(try fs.attributes(f).map(\.name) == [n("Audio:Artist"), n("Audio:Year"), n("user:rating"), n("user:thumb")])
  #expect(try fs.removeAttribute(f, n("Audio:Year"), now: 6))
  #expect(try fs.attribute(f, n("Audio:Year")) == nil)
  #expect(throws: TaisceError.invalid) { try fs.setAttribute(f, n("nonamespace"), .bool(true), now: 7) }
  #expect(throws: TaisceError.invalid) { try fs.setAttribute(f, n("user:x"), .string([0xFF]), now: 7) }
  try fs.check()
  try fs.sync()
  var again = try FileSystem.mount(fs.engine.store.volume.device)
  #expect(try again.attribute(f, n("Audio:Artist")) == .string(Array("Beyoncé".utf8)))
  try again.check()
}

@Test func theDefaultIndicesAnswerAndFollowChanges() throws {
  var fs = try newFS()
  let a = try fs.create(root, n("a.txt"), .file, mode: 0o644, now: 2)
  let b = try fs.create(root, n("b.txt"), .file, mode: 0o644, now: 2)
  try fs.write(a, offset: 0, [UInt8](repeating: 1, count: 100), now: 3)
  try fs.setAttribute(b, n("sys:type"), .type(n("text/plain")), now: 4)
  #expect(try fs.indexLookup(n("name"), equal: .string(n("a.txt"))) == [a])
  #expect(try fs.indexLookup(n("size"), equal: .uint64(100)) == [a])
  #expect(try fs.indexLookup(n("size"), equal: .uint64(0)).contains(b))
  #expect(try fs.indexLookup(n("mtime"), equal: .time(3)) == [a])
  #expect(try fs.indexLookup(n("sys:type"), equal: .string(n("text/plain"))) == [b])
  #expect(try fs.removeAttribute(b, n("sys:type"), now: 4))
  #expect(try fs.indexLookup(n("sys:type"), equal: .string(n("text/plain"))).isEmpty)
  try fs.setAttribute(b, n("sys:type"), .type(n("text/plain")), now: 4)
  try fs.rename(root, n("a.txt"), root, n("c.txt"), now: 5)
  #expect(try fs.indexLookup(n("name"), equal: .string(n("a.txt"))).isEmpty)
  #expect(try fs.indexLookup(n("name"), equal: .string(n("c.txt"))) == [a])
  try fs.unlink(root, n("c.txt"), now: 6)
  #expect(try fs.indexLookup(n("size"), equal: .uint64(100)).isEmpty)
  try fs.check()
}

@Test func aDeclaredIndexBackfills() throws {
  var fs = try newFS()
  var tagged: [UInt64] = []
  for i in 0..<120 {
    let f = try fs.create(root, n("f\(i)"), .file, mode: 0o644, now: 2)
    if i % 3 == 0 {
      try fs.setAttribute(f, n("Audio:Artist"), .string(n(i % 2 == 0 ? "The Band" : "the BAND")), now: 3)
      tagged.append(f)
    }
  }
  try fs.setAttribute(tagged[0], n("Audio:Artist"), .int64(7), now: 3)  // another type: not indexed
  try fs.declareIndex(n("Audio:Artist"), .string, collation: .caseFolded)
  #expect(throws: TaisceError.notFound) { try fs.indexLookup(n("Audio:Artist"), equal: .string(n("the band"))) }
  // Writes during the back-fill are indexed too.
  let late = try fs.create(root, n("late"), .file, mode: 0o644, now: 4)
  try fs.setAttribute(late, n("Audio:Artist"), .string(n("THE BAND")), now: 4)
  var steps = 0
  while try !fs.backfill(budget: 10) { steps += 1 }
  #expect(steps >= 10)
  let found = try fs.indexLookup(n("Audio:Artist"), equal: .string(n("tHe BaNd")))
  #expect(Set(found) == Set(tagged.dropFirst() + [late]))
  try fs.check()
  try fs.sync()
  var again = try FileSystem.mount(fs.engine.store.volume.device)
  #expect(again.indices.contains { $0.name == n("Audio:Artist") && !$0.building })
  try again.check()
}

@Test func theJournalRecordsResumesAndTrims() throws {
  var fs = try newFS()
  let start = fs.nextSeq
  let d = try fs.create(root, n("d"), .directory, mode: 0o755, now: 2)
  let f = try fs.create(d, n("f"), .file, mode: 0o644, now: 3)
  try fs.write(f, offset: 0, [1], now: 4)
  try fs.write(f, offset: 1, [2], now: 5)  // every write: a live query must hear of each
  try fs.setAttribute(f, n("user:x"), .bool(true), now: 6)
  #expect(throws: TaisceError.exists) { try fs.create(d, n("f"), .file, mode: 0, now: 7) }  // takes no number
  try fs.rename(d, n("f"), root, n("g"), now: 8)
  let all = try fs.journal(after: start - 1)
  // Each change, and each directory it touched.
  #expect(all.map(\.reasons) == [.created, .metadata, .created, .metadata, .data, .data, .attribute,
                                 .metadata, .metadata, .renamed])
  #expect(all.map(\.ino) == [d, root, f, d, f, f, f, d, root, f])
  #expect(all.map(\.seq) == Array(start..<(start + 10)))
  #expect(all[9].name == n("g") && all[9].parent == root)
  // A consumer resumes after a remount from the last seq it saw.
  try fs.sync()
  var again = try FileSystem.mount(fs.engine.store.volume.device)
  #expect(try again.journal(after: all[5].seq).map(\.seq) == Array(all[6].seq...all[9].seq))
  #expect(again.nextSeq == all[9].seq + 1)
  try again.trimJournal(through: all[3].seq)
  #expect(try again.journal(after: 0).first?.seq == all[4].seq)
}
