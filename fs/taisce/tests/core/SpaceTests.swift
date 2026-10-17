// SPDX-License-Identifier: BSD-3-Clause

// Running out of space: freed blocks come back by committing, a commit
// always has room, and an operation that fails leaves everything as it was.

@testable import Taisce
import Testing

@Test func aWriteThatNeedsFreedBlocksReclaimsThem() throws {
  var fs = try newFS(blocks: 4096)
  let big = [UInt8](repeating: 0xAB, count: 2900 * 4096)  // most of the volume
  let a = try fs.create(root, n("a"), .file, mode: 0o644, now: 2)
  try fs.write(a, offset: 0, big, now: 2)
  try fs.sync()
  try fs.unlink(root, n("a"), now: 3)  // its blocks are held for this group
  #expect(fs.engine.reclaimable >= 2900)
  let txg = fs.engine.store.volume.superblock.txg
  // There's room for this only once a's blocks are reusable: two commits.
  let b = try fs.create(root, n("b"), .file, mode: 0o644, now: 4)
  let other = [UInt8](repeating: 0xCD, count: 2900 * 4096)
  try fs.write(b, offset: 0, other, now: 4)
  #expect(fs.engine.store.volume.superblock.txg >= txg + 2)
  #expect(try fs.read(b, offset: 0, count: other.count) == other)
  try fs.check()
  try fs.sync()
  var again = try FileSystem.mount(fs.engine.store.volume.device)
  #expect(try again.read(b, offset: 0, count: other.count) == other)
}

@Test func aFullVolumeStillCommits() throws {
  var fs = try newFS(blocks: 4096)
  var files: [UInt64] = []
  // Fill it to the last block: writes halving in size as they stop
  // fitting, down to one block that doesn't.
  var size = 64
  var i = 0
  while size > 0 {
    defer { i += 1 }
    do {
      let f = try fs.create(root, n("f\(i)"), .file, mode: 0o644, now: 2)
      files.append(f)
      try fs.write(f, offset: 0, [UInt8](repeating: UInt8(truncatingIfNeeded: i), count: size * 4096), now: 2)
    } catch .noSpace {
      size /= 2
    }
  }
  #expect(fs.engine.store.volume.allocator.availableCount < 64)  // the rest too scattered for a node
  // The reserve: the commit has the room it needs.
  try fs.sync()
  try fs.sync()
  try fs.check()
  var again = try FileSystem.mount(fs.engine.store.volume.device)
  try again.check()
  #expect(try again.read(files[0], offset: 0, count: 4096) == [UInt8](repeating: 0, count: 4096))
}

@Test func freesMoveOnOnlyWithANewSuperblock() throws {
  var fs = try newFS(blocks: 2048)
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  try fs.write(f, offset: 0, [UInt8](repeating: 1, count: 200_000), now: 3)
  try fs.sync()  // T1: f's first version
  try fs.write(f, offset: 0, [UInt8](repeating: 2, count: 200_000), now: 4)
  try fs.sync()  // T2 frees the first version's blocks
  let t2 = fs.engine.store.volume.superblock.txg
  // Nothing else changed, but those frees wait on a commit: this one must
  // write a superblock before they can be reused.
  try fs.sync()
  #expect(fs.engine.store.volume.superblock.txg == t2 + 1)
  let g = try fs.create(root, n("g"), .file, mode: 0o644, now: 5)
  try fs.write(g, offset: 0, [UInt8](repeating: 3, count: 600_000), now: 5)  // may reuse them
  // A crash, and the newest superblock is unreadable: the fallback must
  // find nothing it points at reused.
  var image = fs.engine.store.volume.device
  let sb = fs.engine.store.volume.superblock
  let garbage = [UInt8](repeating: 0x5A, count: 4096)
  try image.write(sb.layout.headSlot(txg: sb.txg), garbage)
  try image.write(sb.layout.footerSlot(txg: sb.txg), garbage)
  var back = try FileSystem.mount(image)
  try back.check()
  #expect(try back.read(f, offset: 0, count: 200_000) == [UInt8](repeating: 2, count: 200_000))
}

@Test func aFailedWritePutsBackWhatItRewroteInPlace() throws {
  var fs = try newFS(blocks: 4096)
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  let before = [UInt8](repeating: 1, count: 8192)
  try fs.write(f, offset: 0, before, now: 2)  // fresh blocks: rewritten in place from here on
  var c = Changes()
  let freed = try fs.replaceBlocks(f, 0, [UInt8](repeating: 2, count: 8192), &c)
  #expect(!c.overwritten.isEmpty, "the blocks were rewritten in place")
  // The batch fails (a delta to a key that isn't there).
  c.other.append(.delta(tree: 99, key: [1], .add(offset: 0, value: 1)))
  #expect(throws: TaisceError.missingKey) {
    do {
      try fs.commitData(c, freed)
    } catch {
      fs.abandon(c)  // as write does
      throw error
    }
  }
  #expect(try fs.read(f, offset: 0, count: 8192) == before)
  try fs.sync()
  var again = try FileSystem.mount(fs.engine.store.volume.device)
  #expect(try again.read(f, offset: 0, count: 8192) == before)
  try again.check()
}

@Test func aCommitHasItsReserve() throws {
  var fs = try newFS(blocks: 4096)
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  try fs.sync()
  try fs.sync()
  try fs.setAttribute(f, n("user:x"), .int64(1), now: 3)  // the commit must copy catalog nodes
  // Everything an ordinary allocation may take, taken.
  let taken = try fs.engine.store.volume.allocator.allocate(fs.engine.store.volume.allocator.availableCount)
  #expect(fs.engine.store.volume.allocator.availableCount == 0)
  #expect(throws: TaisceError.noSpace) { try fs.engine.store.volume.allocator.allocateContiguous(4) }
  try fs.sync()  // from the reserve
  for e in taken { fs.engine.store.volume.allocator.free(e) }
  try fs.sync()
  try fs.sync()
  var again = try FileSystem.mount(fs.engine.store.volume.device)
  #expect(try again.attribute(f, n("user:x")) == .int64(1))
  try again.check()
}

@Test func aNodeUnlinkedButNotYetFreedSurvivesACommitAsAnOrphan() throws {
  var fs = try newFS(blocks: 4096)
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  try fs.write(f, offset: 0, [UInt8](repeating: 1, count: 40_000), now: 2)
  let d = try fs.create(root, n("d"), .directory, mode: 0o755, now: 2)
  try fs.sync()
  let free = fs.engine.store.volume.allocator.freeCount
  // The first batch of unlink and of rmdir, then a commit before the
  // second (as a reclaim between them makes), then a crash.
  #expect(try fs.removeName(root, n("f"), now: 3) == f)
  #expect(try fs.removeDirectory(root, n("d"), now: 3) == d)
  try fs.sync()
  var after = try FileSystem.mount(fs.engine.store.volume.device)  // frees what orphans it finds
  try after.check()
  #expect(throws: TaisceError.notFound) { try after.stat(f) }
  #expect(after.engine.store.volume.allocator.freeCount + after.engine.reclaimable >= free + 10)
}

@Test func aWriteThatFailsOnTheDeviceIsUndoneWhole() throws {
  let flakiness = Flakiness()
  var fs = try FileSystem.format(FlakyDevice(base: MemoryDevice(blocks: 4096), flakiness: flakiness), label: [],
                                 uuid: Array(1...16), now: 1)
  let f = try fs.create(1, n("f"), .file, mode: 0o644, now: 2)
  let g = try fs.create(1, n("g"), .file, mode: 0o644, now: 2)
  let before = [UInt8](repeating: 1, count: 8192)
  try fs.write(f, offset: 0, before, now: 2)  // fresh: rewritten in place from now on
  try fs.write(g, offset: 0, [UInt8](repeating: 7, count: 4096), now: 2)  // so f's next blocks aren't next to these
  let free = fs.engine.store.volume.allocator.freeCount
  // Four blocks: two in place, two new elsewhere. The first run reaches
  // the device; the second fails.
  flakiness.writesLeft = 1
  #expect(throws: TaisceError.io(5)) { try fs.write(f, offset: 0, [UInt8](repeating: 2, count: 16384), now: 3) }
  #expect(try fs.read(f, offset: 0, count: 16384) == before)
  #expect(fs.engine.store.volume.allocator.freeCount == free)
  try fs.sync()
  var again = try FileSystem.mount(fs.engine.store.volume.device.base)
  #expect(try again.read(f, offset: 0, count: 16384) == before)  // from the device, checked
  try again.check()
}

@Test func aWriteWhoseUndoCantReachTheDeviceStopsWrites() throws {
  let flakiness = Flakiness()
  var fs = try FileSystem.format(FlakyDevice(base: MemoryDevice(blocks: 4096), flakiness: flakiness), label: [],
                                 uuid: Array(1...16), now: 1)
  let f = try fs.create(1, n("f"), .file, mode: 0o644, now: 2)
  try fs.write(f, offset: 0, [UInt8](repeating: 1, count: 4096), now: 2)
  flakiness.failWrites = true  // the in-place rewrite fails, and so does putting it back
  #expect(throws: TaisceError.io(5)) { try fs.write(f, offset: 0, [UInt8](repeating: 2, count: 4096), now: 3) }
  flakiness.failWrites = false
  #expect(try fs.read(f, offset: 0, count: 4096) == [UInt8](repeating: 1, count: 4096))
  #expect(throws: TaisceError.readOnly) { try fs.write(f, offset: 0, [UInt8](repeating: 3, count: 1), now: 4) }
}
