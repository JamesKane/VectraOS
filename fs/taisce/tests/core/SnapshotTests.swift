// SPDX-License-Identifier: BSD-3-Clause

// S2: snapshots, their deadlist, and what deleting one gives back.

import Taisce
import Testing

/// 2026-10-30, 12:00 UTC, in nanoseconds.
let noon: UInt64 = 1_793_361_600 * 1_000_000_000

func pattern(_ seed: UInt8, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: $0) &+ seed } }

@Test func aSnapshotKeepsTheVolumeAsItWas() throws {
  var fs = try newFS()
  let docs = try fs.create(root, n("docs"), .directory, mode: 0o755, now: 2)
  let f = try fs.create(docs, n("f"), .file, mode: 0o644, now: 3)
  try fs.write(f, offset: 0, pattern(1, 50_000), now: 4)
  try fs.setAttribute(f, n("user:tag"), .string(n("old")), now: 4)
  let s = try fs.takeSnapshot(now: noon)
  #expect(s.name == n("2026/1030"))
  // The live volume moves on: an overwrite, a new file, a removal.
  try fs.write(f, offset: 10_000, pattern(9, 20_000), now: 5)
  try fs.setAttribute(f, n("user:tag"), .string(n("new")), now: 5)
  _ = try fs.create(docs, n("g"), .file, mode: 0o644, now: 5)
  try fs.sync()
  try fs.check()
  try fs.withSnapshot(s) { (v: inout FileSystem<MemoryDevice>) throws(TaisceError) in
    #expect(try v.read(f, offset: 0, count: 60_000) == pattern(1, 50_000))
    #expect(try v.attribute(f, n("user:tag")) == .string(n("old")))
    #expect(try v.list(docs).map { $0.entry.name } == [n("f")])
    #expect(throws: TaisceError.readOnly) { try v.create(docs, n("h"), .file, mode: 0o644, now: 6) }
  }
  #expect(try fs.read(f, offset: 10_000, count: 20_000) == pattern(9, 20_000))
  #expect(try fs.list(docs).count == 2)
  // Removed from the live volume, the file is still in the snapshot.
  try fs.unlink(docs, n("f"), now: 7)
  try fs.sync()
  try fs.check()
  #expect(try fs.withSnapshot(s) { (v: inout FileSystem<MemoryDevice>) throws(TaisceError) in
    try v.read(f, offset: 0, count: 10)
  } == pattern(1, 10))
}

@Test func snapshotsOnOneDayAreNumberedAndOutliveAMount() throws {
  var fs = try newFS()
  _ = try fs.takeSnapshot(now: noon)
  _ = try fs.takeSnapshot(now: noon + 1_000_000_000)
  _ = try fs.takeSnapshot(now: noon + 86_400_000_000_000)
  var again = try FileSystem<MemoryDevice>.mount(fs.engine.store.volume.device)
  #expect(try again.snapshots().map { $0.name } == [n("2026/1030"), n("2026/1030.1"), n("2026/1031")])
  #expect(again.engine.store.newestSnapshot == (try again.snapshots().last!.txg))
  try again.check()
}

/// What deleting snapshots gives back: once all are gone and the frees
/// have come round, the volume has as much free as one that never had them.
@Test func deletingEverySnapshotGivesBackWhatTheyKept() throws {
  func run(snapshots: Bool) throws -> UInt64 {
    var fs = try newFS()
    var files: [UInt64] = []
    for i in 0..<6 {
      let f = try fs.create(root, n("f\(i)"), .file, mode: 0o644, now: 2)
      try fs.write(f, offset: 0, pattern(UInt8(i), 40_000), now: 2)
      files.append(f)
    }
    try fs.sync()
    var taken: [SnapshotRecord] = []
    for round in 0..<4 {
      if snapshots { taken.append(try fs.takeSnapshot(now: noon + UInt64(round))) }
      try fs.write(files[0], offset: 4096 * UInt64(round + 1), pattern(77, 12_000), now: 3)
      try fs.unlink(root, n("f\(round + 1)"), now: 3)
      for i in 0..<40 { _ = try fs.create(root, n("r\(round)-\(i)"), .file, mode: 0o644, now: 3) }
      try fs.sync()
      try fs.check()
    }
    // Middle ones first, then the ends: each order of neighbours.
    for i in [2, 1, 3, 0] where i < taken.count {
      let before = try fs.snapshots()
      try fs.deleteSnapshot(taken[i])
      #expect(try fs.snapshots().count == before.count - 1)
      try fs.check()
      // What's left still reads as it was taken.
      for s in try fs.snapshots() {
        try fs.withSnapshot(s) { (v: inout FileSystem<MemoryDevice>) throws(TaisceError) in
          #expect(try v.read(files[0], offset: 0, count: 4096) == pattern(0, 4096))
        }
      }
    }
    try fs.engine.reclaim()
    try fs.engine.reclaim()
    try fs.check()
    return fs.engine.store.volume.allocator.freeCount
  }
  let plain = try run(snapshots: false)
  let kept = try run(snapshots: true)
  #expect(kept == plain)
}

@Test func aSnapshotHoldsItsBlocksUntilDeleted() throws {
  var fs = try newFS()
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  try fs.write(f, offset: 0, pattern(3, 400_000), now: 2)
  try fs.sync()
  let s = try fs.takeSnapshot(now: noon)
  try fs.unlink(root, n("f"), now: 3)
  try fs.engine.reclaim()
  let held = fs.engine.store.volume.allocator.freeCount
  try fs.deleteSnapshot(s)
  try fs.engine.reclaim()
  try fs.engine.reclaim()
  #expect(fs.engine.store.volume.allocator.freeCount >= held + 400_000 / 4096)
  #expect(throws: TaisceError.notFound) { try fs.deleteSnapshot(s) }
  try fs.check()
}

/// A file's blocks let go through the intent log, after a snapshot, and a
/// crash: replay puts them on the deadlist, not back in the free space.
@Test func replayedFreesASnapshotSeesStayHeld() throws {
  var fs = try newFS()
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  try fs.write(f, offset: 0, pattern(5, 100_000), now: 2)
  let s = try fs.takeSnapshot(now: noon)
  try fs.write(f, offset: 0, pattern(6, 100_000), now: 3)
  try fs.truncate(f, size: 4096, now: 3)
  try fs.fsync()
  var after = try FileSystem<MemoryDevice>.mount(fs.engine.store.volume.device)
  try after.check()
  try after.withSnapshot(s) { (v: inout FileSystem<MemoryDevice>) throws(TaisceError) in
    #expect(try v.read(f, offset: 0, count: 100_000) == pattern(5, 100_000))
  }
  #expect(try after.read(f, offset: 0, count: 5000) == pattern(6, 4096))
}
