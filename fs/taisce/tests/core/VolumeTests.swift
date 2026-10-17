// SPDX-License-Identifier: BSD-3-Clause

// S0a: checksums, the superblock, free space, and format/open.

import Glibc
import Taisce
import TaisceHost
import Testing

@Test func crc32cMatchesRFC3720() {
  // RFC 3720 §B.4's test vectors, and the common check value.
  #expect(CRC32C.checksum([UInt8](repeating: 0, count: 32)) == 0x8A91_36AA)
  #expect(CRC32C.checksum([UInt8](repeating: 0xFF, count: 32)) == 0x62A8_AB43)
  #expect(CRC32C.checksum(Array(0...31)) == 0x46DD_794E)
  #expect(CRC32C.checksum(Array("123456789".utf8)) == 0xE306_9283)
}

@Test func theLayoutPacksRegionsInOrder() throws {
  let l = try Layout(blockCount: 262_144)  // 1 GiB
  #expect(l.bitmapBlocks == 8)  // 262,144 bits
  #expect(l.bitmapStart(txg: 2) == 4 && l.bitmapStart(txg: 3) == 4 + 8)  // two regions, alternating
  #expect(l.intentStart == 4 + 16 && l.intentBlocks == 2621)  // the intent log: 1% of the volume
  #expect(l.dataStart == 4 + 16 + 2621)
  #expect(l.dataEnd == 262_144 - 4)  // the footer ring after the data
  #expect(l.headSlot(txg: 6) == 2 && l.footerSlot(txg: 6) == 262_144 - 4 + 2)
  #expect(l.reserved == 4 + 16 + 2621 + 4)
  #expect(try Layout(blockCount: 4096).intentBlocks == 256)  // at least 1 MiB
  #expect(try Layout(blockCount: 1 << 30).intentBlocks == 4096)  // at most 16 MiB
  #expect(throws: TaisceError.tooSmall) { try Layout(blockCount: 280) }  // no room left for data
}

@Test func aSuperblockRoundTripsAndRejectsDamage() throws {
  var s = Superblock(layout: try Layout(blockCount: 10_000), uuid: Array(1...16), label: Array("home".utf8),
                     createdNs: 42)
  s.catalogRoot = NodePointer(block: 777, checksum: Checksum(a: 1, b: 2), birth: 3)
  s.txg = 9
  var block = s.encode()
  #expect(try Superblock.decode(block) == s)
  block[200] ^= 1  // a flipped bit anywhere fails the BLAKE3 check
  #expect(try Superblock.decode(block) == nil)
  #expect(try Superblock.decode([UInt8](repeating: 0, count: 4096)) == nil)
}

@Test func theAllocatorHandsOutExtentsAndPersists() throws {
  var a = Allocator(blockCount: 1000, reserved: 10, reservedTail: 4)
  #expect(a.freeCount == 986)
  let first = try a.allocate(100)
  #expect(first == [Extent(start: 10, count: 100)])
  let node = try a.allocateContiguous(4, near: 500)
  #expect(node == Extent(start: 500, count: 4))
  a.free(Extent(start: 20, count: 10))  // allocated in this group: free again at once
  let spread = try a.allocate(15, near: 15)
  #expect(spread == [Extent(start: 20, count: 10), Extent(start: 110, count: 5)])
  #expect(a.freeCount == 986 - 100 - 4 + 10 - 15)
  #expect(throws: TaisceError.noSpace) { try a.allocate(10_000) }
  for block in UInt64(996)..<1000 { #expect(a.isUsed(block)) }  // the footer ring is never handed out
  #expect(try a.allocateContiguous(10, near: 995).end <= 996)

  // Stored (either region) and loaded, it's the same.
  var bitmap: [UInt8] = []
  for (_, bytes) in a.dirtyBlocks(region: 0) { bitmap += bytes }
  let b = try Allocator(blockCount: 1000, bitmap: bitmap)
  #expect(b.freeCount == a.freeCount)
  for block in UInt64(0)..<1000 { #expect(b.isUsed(block) == a.isUsed(block)) }
  #expect(a.dirtyBlocks(region: 0).isEmpty && a.dirtyBlocks(region: 1).count == 1)  // region 1 still owed it
}

@Test func freedBlocksWaitAGroupAfterTheirCommit() throws {
  var a = Allocator(blockCount: 200, reserved: 10)
  let e = try a.allocate(5)[0]
  a.groupCommitted()  // e is committed
  a.free(e)
  #expect(try a.allocate(1, near: e.start)[0].start != e.start)  // held: committed state points at it
  a.groupCommitted()  // the group that freed it commits
  #expect(try a.allocate(1, near: e.start)[0].start != e.start)  // deferred: a fallback superblock might
  let retired = a.groupCommitted()
  #expect(retired == [e])
  #expect(try a.allocate(1, near: e.start)[0].start != e.start)  // retired: a reader might still see it
  a.release(retired: e)
  #expect(try a.allocate(1, near: e.start)[0].start == e.start)  // now it's free
}

@Test func aFormattedVolumeOpens() throws {
  let v = try Volume.format(MemoryDevice(blocks: 4096), label: Array("test".utf8), uuid: Array(1...16), now: 7)
  let device = v.device
  let opened = try Volume.open(device)
  #expect(opened.superblock == v.superblock)
  #expect(opened.allocator.freeCount == v.allocator.freeCount)
  #expect(throws: TaisceError.notAVolume) { try Volume.open(MemoryDevice(blocks: 64)) }
}

@Test func theNewestValidSuperblockWinsFromEitherCopy() throws {
  var v = try Volume.format(MemoryDevice(blocks: 4096), label: [], uuid: Array(1...16), now: 0)
  for i in UInt64(1)...9 {
    try v.commit { $0.nextInode = 100 + i }  // around the ring twice
  }
  let newest = v.superblock
  #expect(newest.txg == 10)
  #expect(try Volume.open(v.device).superblock == newest)
  let layout = newest.layout
  let garbage = [UInt8](repeating: 0xAB, count: 4096)
  // A torn head copy: the footer copy of the same group wins.
  var oneTorn = v.device
  try oneTorn.write(layout.headSlot(txg: 10), garbage)
  #expect(try Volume.open(oneTorn).superblock == newest)
  // Both copies torn: the group before it.
  var bothTorn = oneTorn
  try bothTorn.write(layout.footerSlot(txg: 10), garbage)
  let fallback = try Volume.open(bothTorn).superblock
  #expect(fallback.txg == 9 && fallback.nextInode == 108)
}

@Test func aCommitIsOrderedByBarriers() throws {
  let v = try Volume.format(MemoryDevice(blocks: 4096), label: [], uuid: Array(1...16), now: 0)
  var r = try Volume.open(RecordingDevice(v.device))
  _ = try r.allocator.allocate(50)
  try r.commit()
  let log = r.device.log
  // The bitmap's region for this group, a barrier, the head and footer copies, a barrier.
  #expect(log.count == 5)
  guard case .write(let bitmapBlock, _) = log[0], case .write(let head, _) = log[2], case .write(let footer, _) = log[3]
  else {
    Issue.record("unexpected log \(log)")
    return
  }
  let layout = r.superblock.layout
  #expect(bitmapBlock == layout.bitmapStart(txg: 2))
  #expect(log[1] == .flush && log[4] == .flush)
  #expect(head == layout.headSlot(txg: 2) && footer == layout.footerSlot(txg: 2))
  // Any prefix of the log mounts, before or after the commit.
  for k in 0...log.count {
    let opened = try Volume.open(v.device.applying(log.prefix(k)))
    #expect(opened.superblock.txg == (k >= 3 ? 2 : 1))
  }
}

@Test func aFileDeviceHoldsAVolume() throws {
  let path = "/tmp/taisce-test-\(getpid()).img"
  defer { unlink(path) }
  let v = try Volume.format(FileDevice(path: path, blocks: 2048), label: Array("img".utf8), uuid: Array(1...16), now: 1)
  let sb = v.superblock
  _ = consume v
  let opened = try Volume.open(FileDevice(path: path))
  #expect(opened.superblock == sb)
}

/// A device that keeps only the blocks written: big volumes for tests.
struct SparseDevice: BlockDevice {
  let blockSize = 4096
  let blockCount: UInt64
  var blocks: [UInt64: [UInt8]] = [:]

  init(blocks: UInt64) { blockCount = blocks }

  mutating func read(_ block: UInt64, count: Int) throws(TaisceError) -> [UInt8] {
    guard block + UInt64(count) <= blockCount else { throw .outOfRange }
    var out: [UInt8] = []
    for b in block..<(block + UInt64(count)) { out += blocks[b] ?? [UInt8](repeating: 0, count: blockSize) }
    return out
  }

  mutating func write(_ block: UInt64, _ bytes: [UInt8]) throws(TaisceError) {
    guard bytes.count % blockSize == 0, block + UInt64(bytes.count / blockSize) <= blockCount else { throw .outOfRange }
    for k in 0..<(bytes.count / blockSize) { blocks[block + UInt64(k)] = Array(bytes[(k * blockSize)..<((k + 1) * blockSize)]) }
  }

  mutating func flush() throws(TaisceError) {}
}

@Test func aBigVolumeRemountsAfterACommit() throws {
  // Over 32,768 blocks: more than one bitmap block per region.
  var e = try Engine.format(SparseDevice(blocks: 70_000), label: [], uuid: Array(1...16), now: 1)
  #expect(e.store.volume.superblock.layout.bitmapBlocks == 3)
  // A change in the second bitmap block, committed (to one region).
  _ = try e.store.volume.allocator.allocate(1, near: 40_000)
  try e.apply([.insert(tree: 1, key: [1], value: [1])])
  try e.commitGroup()
  // Remount and commit once more (to the other region, which last saw
  // the volume two groups ago), then mount again.
  var again = try Engine.mount(e.store.volume.device)
  try again.apply([.insert(tree: 1, key: [2], value: [2])])
  try again.commitGroup()
  var third = try Engine.mount(again.store.volume.device)
  #expect(try third.get(1, [2]) == [2])
}
