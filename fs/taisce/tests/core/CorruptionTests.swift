// SPDX-License-Identifier: BSD-3-Clause

// S1: a flipped bit anywhere is detected, never silently used. A volume
// with real content gets hundreds of random bit flips, one per fresh copy
// of the image, in every kind of block it uses: superblock copies, both
// bitmaps, every node, and file data. Each copy must fail to mount, fail
// its check (the scrub reads every block), or come up exactly as it was
// (a flip in a redundant or unused copy).

import Taisce
import Testing

/// A volume with directories, files, attributes, an index and a journal,
/// committed over several groups.
func corruptionWorkload() throws -> MemoryDevice {
  var fs = try FileSystem.format(MemoryDevice(blocks: 2048), label: [], uuid: Array(1...16), now: 1)
  try fs.declareIndex(Array("user:tag".utf8), .string)
  var rng = SplitMix(state: 77)
  var files: [UInt64] = []
  for d in 0..<4 {
    let dir = try fs.create(FileSystem<MemoryDevice>.root, Array("d\(d)".utf8), .directory, mode: 0o755, now: 2)
    for f in 0..<60 {
      let ino = try fs.create(dir, Array("file-\(f)-with-a-longer-name".utf8), .file, mode: 0o644, now: 3)
      try fs.write(ino, offset: 0, (0..<(1 + rng.below(9000))).map { UInt8(truncatingIfNeeded: $0) }, now: 4)
      try fs.setAttribute(ino, Array("user:tag".utf8), .string(Array("t\(rng.below(20))".utf8)), now: 5)
      files.append(ino)
    }
    try fs.sync()
  }
  for _ in 0..<50 { try fs.rename(1, Array("d0".utf8), 1, Array("d0".utf8), now: 6) }
  try fs.sync()
  return fs.engine.store.volume.device
}

/// Everything the trees hold.
func everything(_ fs: inout FileSystem<MemoryDevice>) throws -> [UInt64: [[UInt8]: [UInt8]]] { try contents(&fs.engine) }

@Test func flippedBitsAreDetectedNeverUsed() throws {
  let image = try corruptionWorkload()
  var clean = try FileSystem.mount(image)
  let expected = try everything(&clean)
  try clean.check()
  let layout = clean.engine.store.volume.superblock.layout
  // Every block in use: the rings, both bitmaps, every node, all file data.
  var targets = Array(0..<layout.dataStart) + Array(layout.dataEnd..<layout.blockCount)
  let metadata = targets.count + (try clean.engine.nodeBlocks().count)
  targets += try clean.engine.nodeBlocks()
  for b in layout.dataStart..<layout.dataEnd where clean.engine.store.volume.allocator.isUsed(b) && !targets.contains(b) {
    targets.append(b)  // file data
  }
  #expect(targets.count > metadata + 100, "the workload has file data")
  #expect(targets.count > 60)
  var rng = SplitMix(state: 5)
  var detected = 0, harmless = 0
  for _ in 0..<600 {
    let block = targets[rng.below(targets.count)]
    var damaged = image
    var bytes = try damaged.read(block, count: 1)
    bytes[rng.below(4096)] ^= UInt8(1 << rng.below(8))
    try damaged.write(block, bytes)
    do {
      var fs = try FileSystem.mount(damaged)
      try fs.check()
      if try everything(&fs) == expected {
        harmless += 1
      } else {
        Issue.record("a flip in block \(block) changed the volume without being detected")
      }
    } catch {
      detected += 1
    }
  }
  // Both kinds happened, and nothing else did.
  #expect(detected > 200 && harmless > 3, "detected \(detected), harmless \(harmless)")
}

@Test func freedBlocksSurviveFallingBackPastADamagedSuperblock() throws {
  var fs = try FileSystem.format(MemoryDevice(blocks: 2048), label: [], uuid: Array(1...16), now: 1)
  let f = try fs.create(1, Array("f".utf8), .file, mode: 0o644, now: 2)
  let first = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 3) }
  try fs.write(f, offset: 0, first, now: 3)
  try fs.sync()  // T1: f holds `first`
  try fs.write(f, offset: 0, [UInt8](repeating: 9, count: 200_000), now: 4)
  try fs.sync()  // T2 frees `first`'s blocks
  let t2 = fs.engine.store.volume.superblock
  // T3, never committed, writes a lot of new data.
  let g = try fs.create(1, Array("g".utf8), .file, mode: 0o644, now: 5)
  try fs.write(g, offset: 0, [UInt8](repeating: 7, count: 600_000), now: 6)
  // A crash, and T2's superblock copies are both unreadable: mount falls
  // back to T1. T3 must not have reused T1's blocks, which T2 freed.
  var image = fs.engine.store.volume.device
  let garbage = [UInt8](repeating: 0x5A, count: 4096)
  try image.write(t2.layout.headSlot(txg: t2.txg), garbage)
  try image.write(t2.layout.footerSlot(txg: t2.txg), garbage)
  var back = try FileSystem.mount(image)
  #expect(back.engine.store.volume.superblock.txg == t2.txg - 1)
  try back.check()
  #expect(try back.read(f, offset: 0, count: 200_000) == first)
}

@Test func aDamagedFileBlockFailsItsReadAndNothingElse() throws {
  var fs = try FileSystem.format(MemoryDevice(blocks: 2048), label: [], uuid: Array(1...16), now: 1)
  let a = try fs.create(1, Array("a".utf8), .file, mode: 0o644, now: 2)
  let b = try fs.create(1, Array("b".utf8), .file, mode: 0o644, now: 2)
  var rng = SplitMix(state: 9)  // not periodic, so each block's contents are its own
  let bytes = (0..<20_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
  try fs.write(a, offset: 0, bytes, now: 3)
  let other = bytes.map { $0 ^ 0xFF }  // so a search for a's block can't find b's
  try fs.write(b, offset: 0, other, now: 3)
  try fs.sync()
  // Which block holds a's third block? Flip a bit in it.
  var image = fs.engine.store.volume.device
  var hit: UInt64 = 0
  for block in UInt64(0)..<2048 {
    let content = try image.read(block, count: 1)
    if content == Array(bytes[8192..<12288]) {
      hit = block
      break
    }
  }
  #expect(hit != 0)
  var content = try image.read(hit, count: 1)
  content[123] ^= 0x04
  try image.write(hit, content)
  var damaged = try FileSystem.mount(image)
  #expect(throws: TaisceError.corrupt(.checksum(hit))) { try damaged.read(a, offset: 0, count: 20_000) }
  #expect(try damaged.read(a, offset: 0, count: 8192) == Array(bytes[..<8192]))  // the blocks before it are fine
  #expect(try damaged.read(b, offset: 0, count: 20_000) == other)
  #expect(throws: TaisceError.corrupt(.checksum(hit))) { try damaged.check() }  // the scrub finds it too
}
