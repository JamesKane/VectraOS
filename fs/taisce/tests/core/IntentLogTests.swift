// SPDX-License-Identifier: BSD-3-Clause

// S1e: fsync through the intent log.

import Taisce
import Testing

@Test func anFsyncSurvivesACrashAndWhatFollowsDoesNot() throws {
  var fs = try newFS(blocks: 4096)
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  try fs.write(f, offset: 0, n("committed"), now: 3)
  try fs.sync()
  let txg = fs.engine.store.volume.superblock.txg
  try fs.write(f, offset: 0, n("fsynced!!"), now: 4)
  try fs.setAttribute(f, n("user:x"), .int64(7), now: 4)
  let g = try fs.create(root, n("g"), .file, mode: 0o644, now: 4)
  try fs.fsync()
  #expect(fs.engine.store.volume.superblock.txg == txg)  // no group commit
  try fs.write(f, offset: 0, n("lost....."), now: 5)
  _ = try fs.create(root, n("h"), .file, mode: 0o644, now: 5)
  // A crash: the device as it is.
  var after = try FileSystem.mount(fs.engine.store.volume.device)
  #expect(try after.read(f, offset: 0, count: 9) == n("fsynced!!"))
  #expect(try after.attribute(f, n("user:x")) == .int64(7))
  #expect(try after.lookup(root, n("g")) == g)
  #expect(throws: TaisceError.notFound) { try after.lookup(root, n("h")) }
  try after.check()
  // Mounting replayed and committed it; again, it's all still there.
  var again = try FileSystem.mount(after.engine.store.volume.device)
  #expect(try again.read(f, offset: 0, count: 9) == n("fsynced!!"))
}

@Test func writesAfterAnFsyncDontOverwriteWhatItPromised() throws {
  var fs = try newFS(blocks: 4096)
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  let first = [UInt8](repeating: 1, count: 20_000)
  try fs.write(f, offset: 0, first, now: 3)  // fresh blocks, written in place until...
  try fs.fsync()  // ...the log names them: from now on, new writes go elsewhere
  try fs.write(f, offset: 0, [UInt8](repeating: 2, count: 20_000), now: 4)
  var after = try FileSystem.mount(fs.engine.store.volume.device)
  #expect(try after.read(f, offset: 0, count: 20_000) == first)
  try after.check()
}

@Test func aFullIntentLogCommitsInstead() throws {
  var fs = try newFS(blocks: 4096)  // a 256-block intent log
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  let txg = fs.engine.store.volume.superblock.txg
  for i in 0..<400 {
    try fs.setAttribute(f, n("user:big"), .bytes([UInt8](repeating: UInt8(i & 0xff), count: 3000)), now: 3)
    try fs.fsync()
  }
  #expect(fs.engine.store.volume.superblock.txg > txg)  // it filled, and committed
  var after = try FileSystem.mount(fs.engine.store.volume.device)
  #expect(try after.attribute(f, n("user:big")) == .bytes([UInt8](repeating: UInt8(399 & 0xff), count: 3000)))
  try after.check()
}

@Test func aDamagedRecordEndsReplay() throws {
  var fs = try newFS(blocks: 4096)
  let layout = fs.engine.store.volume.superblock.layout
  _ = try fs.create(root, n("one"), .file, mode: 0o644, now: 2)
  try fs.fsync()  // record 0, at the start of the log
  _ = try fs.create(root, n("two"), .file, mode: 0o644, now: 3)
  try fs.fsync()  // record 1, after it
  var image = fs.engine.store.volume.device
  // Find record 1's header (the second "TInt" block) and damage it.
  var headers: [UInt64] = []
  for b in layout.intentStart..<(layout.intentStart + layout.intentBlocks) {
    let block = try image.read(b, count: 1)
    if block[0] == 0x54, block[1] == 0x49, block[2] == 0x6E, block[3] == 0x74 { headers.append(b) }
  }
  #expect(headers.count == 2)
  var block = try image.read(headers[1], count: 1)
  block[60] ^= 1
  try image.write(headers[1], block)
  var after = try FileSystem.mount(image)
  #expect(try after.lookup(root, n("one")) > 0)
  #expect(throws: TaisceError.notFound) { try after.lookup(root, n("two")) }
  try after.check()
}

@Test func replayNeverPutsANodeOnFsyncedData() throws {
  // Commit, free, then a group of metadata changes and new file data,
  // fsynced, then a crash. Replay, which has blocks free that the run
  // didn't (nothing is deferred after a mount), must not hand an earlier
  // operation's node a block a later one's data is in.
  for seed in 0..<40 {
    var rng = SplitMix(state: UInt64(seed) &* 7919 &+ 1)
    var fs = try newFS(blocks: 4096)
    var files: [UInt64] = []
    for i in 0..<12 {
      let f = try fs.create(root, n("f\(i)"), .file, mode: 0o644, now: 2)
      try fs.write(f, offset: 0, [UInt8](repeating: UInt8(i), count: 4096 * (1 + rng.below(6))), now: 2)
      files.append(f)
    }
    try fs.sync()
    var kept = Array(0..<12)
    for i in stride(from: 0, to: 12, by: 2 + rng.below(3)) {
      try fs.unlink(root, n("f\(i)"), now: 3)
      kept.removeAll { $0 == i }
    }
    try fs.sync()  // their blocks are deferred through the next group
    var expected: [(UInt64, [UInt8])] = []
    for k in 0..<(4 + rng.below(8)) {
      try fs.setAttribute(files[kept[rng.below(kept.count)]], n("user:k\(k)"), .int64(Int64(k)), now: 4)
      let g = try fs.create(root, n("g\(k)"), .file, mode: 0o644, now: 4)
      let data = [UInt8](repeating: UInt8(0x80 + k), count: 4096 * (1 + rng.below(4)))
      try fs.write(g, offset: 0, data, now: 4)
      expected.append((g, data))
    }
    try fs.fsync()
    var after = try FileSystem.mount(fs.engine.store.volume.device)  // the crash
    for (g, data) in expected {
      #expect(try after.read(g, offset: 0, count: data.count) == data, "seed \(seed): fsynced data overwritten")
    }
    try after.check()
  }
}

@Test func replayClaimsEveryLoggedBlockBeforeApplyingAny() throws {
  var e = try newEngine()
  try e.apply((0..<50).map { .insert(tree: 1, key: bigEndian($0), value: [1]) })
  try e.commitGroup()
  // Where tree 1's next node would go: the block replay will pick.
  let near = e.root(1)!.root.block
  let x = try e.store.volume.allocator.allocateContiguous(4, near: near)
  // In the run, x is taken while the first operation copies its node, so
  // the node goes elsewhere; then x is let go, and the second
  // operation's file data gets it.
  try e.apply([.insert(tree: 1, key: bigEndian(1000), value: [2])])
  e.store.volume.allocator.free(x)  // fresh: available at once
  let data = try e.store.volume.allocator.allocate(1, near: x.start)
  #expect(data == [Extent(start: x.start, count: 1)])
  try e.store.volume.device.write(x.start, [UInt8](repeating: 0xAB, count: 4096))
  e.noteAllocated(data)
  try e.apply([.insert(tree: 2, key: [1], value: [UInt8](repeating: 0, count: 8))])
  try e.fsync()
  // A crash, and replay: the first operation's node mustn't land on x.
  var after = try Engine<MemoryDevice>.mount(e.store.volume.device)
  #expect(try after.get(1, bigEndian(1000)) == [2])
  #expect(try after.store.volume.device.read(x.start, count: 1) == [UInt8](repeating: 0xAB, count: 4096))
  _ = try after.check(dataBlocks: 1)
}

@Test func aBlockFreedAndAllocatedAgainInOneRecordStaysInUse() throws {
  var e = try newEngine()
  try e.commitGroup()
  let first = try e.store.volume.allocator.allocate(1)
  e.noteAllocated(first)
  try e.apply([.insert(tree: 2, key: [1], value: [1])])
  e.store.volume.allocator.free(first[0])  // fresh: available again at once
  e.noteFreed(first)
  let again = try e.store.volume.allocator.allocate(1, near: first[0].start)
  #expect(again == first)
  e.noteAllocated(again)
  try e.apply([.insert(tree: 2, key: [2], value: [2])])
  try e.fsync()
  var after = try Engine<MemoryDevice>.mount(e.store.volume.device)
  #expect(after.store.volume.allocator.isUsed(first[0].start))
  _ = try after.check(dataBlocks: 1)
}

@Test func aRecordHeaderWithAnImpossibleLengthEndsReplay() throws {
  var e = try newEngine()
  try e.commitGroup()
  let sb = e.store.volume.superblock
  // Magic, txg and seq right, the length damaged: the checksum would
  // reject it, but the length mustn't trap before it gets the chance.
  var header = [UInt8](repeating: 0, count: 4096)
  for (i, b) in [0x54, 0x49, 0x6E, 0x74].enumerated() { header[i] = UInt8(b) }  // "TInt"
  header[4] = 1  // one payload block
  for i in 0..<8 { header[8 + i] = UInt8(truncatingIfNeeded: sb.txg >> (8 * UInt64(i))) }
  for i in 32..<40 { header[i] = 0xFF }  // the length: 2^64 - 1
  try e.store.volume.device.write(sb.layout.intentStart, header)
  var after = try Engine<MemoryDevice>.mount(e.store.volume.device)
  _ = try after.check()
}

@Test func aReplayThatChangesNothingStillRetiresItsRecords() throws {
  var e = try newEngine()
  try e.commitGroup()
  // Session 1: two records that change nothing (deletes of a key that
  // isn't there), then a crash.
  for _ in 0..<2 {
    try e.apply([.delete(tree: 1, key: [7])])
    try e.fsync()
  }
  // Session 2 replays them (nothing changes), inserts the key, logs that
  // as its own first record, and crashes.
  var second = try Engine<MemoryDevice>.mount(e.store.volume.device)
  try second.apply([.insert(tree: 1, key: [7], value: [1])])
  try second.fsync()
  // Session 1's second record, behind session 2's first, mustn't replay.
  var third = try Engine<MemoryDevice>.mount(second.store.volume.device)
  #expect(try third.get(1, [7]) == [1])
}
