// SPDX-License-Identifier: BSD-3-Clause

// S0g: the query language, planning, and live queries.

import Taisce
import Testing

func q(_ s: String) throws -> Query { try Query(Array(s.utf8)) }

@Test func queriesParse() throws {
  // BFS's own syntax still works.
  let bfs = try q(#"((MAIL:status=="New")&&(sys:type=="text/x-email"))"#)
  guard case .and(let parts) = bfs.expr, parts.count == 2 else {
    Issue.record("\(bfs.expr)")
    return
  }
  #expect(parts[0] == .term(QueryTerm(attribute: n("MAIL:status"), op: .equal, values: [.string(n("New"))])))
  // Typed literals, ranges, lists, caseless, ordering.
  let v2 = try q(#"size in 1MiB..<1GiB && mtime >= 2026-10-09T00:00Z && user:tag in ["a", "b"] && name ~= "*.MP3" order by size desc limit 10"#)
  #expect(v2.orderBy == n("size") && v2.descending && v2.limit == 10)
  guard case .and(let terms) = v2.expr else { return }
  #expect(terms[0] == .term(QueryTerm(attribute: n("size"), op: .range(inclusive: false), values: [.int(1 << 20), .int(1 << 30)])))
  #expect(terms[1] == .term(QueryTerm(attribute: n("mtime"), op: .greaterOrEqual, values: [.time(1_759_968_000 * 1_000_000_000 + 365 * 86_400 * 1_000_000_000)])))
  #expect(terms[3] == .term(QueryTerm(attribute: n("name"), op: .caseless, values: [.pattern([.any, .text(n(".MP3"))])])))
  #expect(try q(#"!(size > 0) || user:x == -2.5"#).expr == .or([
    .not(.term(QueryTerm(attribute: n("size"), op: .greater, values: [.int(0)]))),
    .term(QueryTerm(attribute: n("user:x"), op: .equal, values: [.double(-2.5)])),
  ]))
  #expect(try q(#"name == "a\*b""#).expr == .term(QueryTerm(attribute: n("name"), op: .equal, values: [.string(n("a*b"))])))
  // Errors say where.
  #expect(throws: TaisceError.badQuery(6)) { try q("size >") }  // at the end: a value was due
  #expect(throws: TaisceError.badQuery(13)) { try q("size == 3 && ") }
  #expect(throws: TaisceError.badQuery(10)) { try q(#"name == "x"#) }  // the string never ends
  #expect(try q("size < 4.5MB").expr == .term(QueryTerm(attribute: n("size"), op: .less, values: [.int(4_500_000)])))
}

/// A small library: songs with artists, years and sizes.
func library(_ fs: inout FileSystem<MemoryDevice>) throws -> [String: UInt64] {
  var ids: [String: UInt64] = [:]
  try fs.declareIndex(n("Audio:Artist"), .string, collation: .caseFolded)
  try fs.declareIndex(n("Audio:Year"), .int64)
  while try !fs.backfill(budget: 100) {}
  for (name, artist, year, size) in [("one.mp3", "Björk", 1993, 4_000_000), ("two.mp3", "björk", 1995, 5_000_000),
                                     ("three.flac", "Air", 1998, 30_000_000), ("four.mp3", "Air", 2004, 3_000_000),
                                     ("notes.txt", "", 0, 100)] {
    let f = try fs.create(root, n(name), .file, mode: 0o644, now: 2)
    try fs.write(f, offset: UInt64(size - 1), [1], now: 3)
    if !artist.isEmpty {
      try fs.setAttribute(f, n("Audio:Artist"), .string(n(artist)), now: 4)
      try fs.setAttribute(f, n("Audio:Year"), .int64(Int64(year)), now: 4)
    }
    ids[name] = f
  }
  return ids
}

@Test func queriesAnswer() throws {
  var fs = try newFS()
  let ids = try library(&fs)
  func names(_ query: String, scan: Bool = false) throws -> Set<String> {
    Set(try fs.query(Array(query.utf8), scan: scan).compactMap { ino in ids.first { $0.value == ino }?.key })
  }
  #expect(try names(#"Audio:Artist ~= "BJÖRK""#) == ["one.mp3", "two.mp3"])
  #expect(try names(#"Audio:Artist == "Björk""#) == ["one.mp3"])
  #expect(try names(#"Audio:Year in 1994...2004"#) == ["two.mp3", "three.flac", "four.mp3"])
  #expect(try names(#"Audio:Year in 1994..<2004"#) == ["two.mp3", "three.flac"])
  #expect(try names(#"name == "*.mp3" && size < 4.5MB"#) == ["one.mp3", "four.mp3"])
  #expect(try names(#"name == "t*""#) == ["two.mp3", "three.flac"])
  #expect(try names(#"size > 10MiB || Audio:Artist == "Air""#) == ["three.flac", "four.mp3"])
  #expect(try names(#"Audio:Year in [1993, 2004]"#) == ["one.mp3", "four.mp3"])
  #expect(try names(#"name in ["*.flac", "notes*"]"#, scan: true) == ["three.flac", "notes.txt"])  // each element as ==, wildcards too
  // No index on the term, or a negation: refused unless scanning.
  #expect(throws: TaisceError.needsIndex) { try fs.query(n(#"user:none == 1"#)) }
  #expect(throws: TaisceError.needsIndex) { try fs.query(n(#"!(size > 0)"#)) }
  #expect(throws: TaisceError.needsIndex) { try fs.query(n(#"name == "*.mp3""#)) }  // a leading wildcard
  #expect(try names(#"name == "*.mp3""#, scan: true) == ["one.mp3", "two.mp3", "four.mp3"])
  #expect(try names(#"Audio:Artist != "Air" && size > 0"#) == ["one.mp3", "two.mp3"])  // missing: no match
  // Ordered and limited.
  let ordered = try fs.query(n(#"size > 0 order by size desc limit 3"#))
  #expect(ordered == [ids["three.flac"]!, ids["two.mp3"]!, ids["one.mp3"]!])
}

@Test func liveQueriesFollowTheJournal() throws {
  var fs = try newFS()
  let ids = try library(&fs)
  var live = try fs.live(n(#"Audio:Artist ~= "air""#))
  #expect(live.results == [ids["three.flac"]!, ids["four.mp3"]!].sorted())
  // A matching write, an unmatching one, a removal.
  try fs.setAttribute(ids["notes.txt"]!, n("Audio:Artist"), .string(n("AIR")), now: 5)
  try fs.setAttribute(ids["one.mp3"]!, n("Audio:Year"), .int64(2000), now: 5)
  try fs.write(ids["four.mp3"]!, offset: 0, [9], now: 6)
  try fs.unlink(root, n("three.flac"), now: 7)
  let updates = try fs.update(&live)
  #expect(updates.contains { if case .added(ids["notes.txt"]!, _) = $0 { true } else { false } })
  #expect(updates.contains { if case .changed(ids["four.mp3"]!, _) = $0 { true } else { false } })
  #expect(updates.contains { if case .removed(ids["three.flac"]!, _) = $0 { true } else { false } })
  #expect(!updates.contains { if case .added(ids["one.mp3"]!, _) = $0 { true } else { false } })
  #expect(live.results == [ids["notes.txt"]!, ids["four.mp3"]!].sorted())
  #expect(try fs.update(&live).isEmpty)
  // Kept by its consumer, it resumes after a remount.
  try fs.sync()
  var again = try FileSystem.mount(fs.engine.store.volume.device)
  try again.removeAttribute(ids["notes.txt"]!, n("Audio:Artist"), now: 8)
  #expect(try again.update(&live).contains { if case .removed(ids["notes.txt"]!, _) = $0 { true } else { false } })
  // Past the journal's end (a crash lost what it had seen), or trimmed away: run it again.
  var ahead = live
  ahead.seq = again.nextSeq + 5
  #expect(throws: TaisceError.journalTrimmed) { try again.update(&ahead) }
  var behind = live
  try again.setAttribute(ids["two.mp3"]!, n("user:x"), .bool(true), now: 9)
  try again.trimJournal(through: again.nextSeq - 1)
  try again.setAttribute(ids["two.mp3"]!, n("user:x"), .bool(false), now: 9)
  #expect(throws: TaisceError.journalTrimmed) { try again.update(&behind) }
}
