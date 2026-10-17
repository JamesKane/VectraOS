// SPDX-License-Identifier: BSD-3-Clause

// S0c: transactions and group commit.

import Taisce
import Testing

func newEngine(blocks: UInt64 = 4096) throws -> Engine<MemoryDevice> {
  try Engine.format(MemoryDevice(blocks: blocks), label: [], uuid: Array(1...16), now: 0)
}

/// Every tree's contents.
func contents<D>(_ e: inout Engine<D>) throws -> [UInt64: [[UInt8]: [UInt8]]] {
  var out: [UInt64: [[UInt8]: [UInt8]]] = [:]
  for id in e.treeIDs {
    for (k, v) in try e.scan(id, from: []) { out[id, default: [:]][k] = v }
  }
  return out
}

@Test func aBatchAppliesInKeyOrderKeepingOrderWithinAKey() throws {
  var e = try newEngine()
  try e.apply([
    .insert(tree: 1, key: [2], value: [20]),
    .insert(tree: 1, key: [1], value: [10]),
    .delete(tree: 1, key: [2]),
    .insert(tree: 2, key: [9], value: [0, 0, 0, 0, 0, 0, 0, 0, 5]),
    .delta(tree: 2, key: [9], .add(offset: 0, value: 3)),
    .delta(tree: 2, key: [9], .put(offset: 8, bytes: [6])),
  ])
  #expect(try e.get(1, [1]) == [10])
  #expect(try e.get(1, [2]) == nil)  // inserted, then deleted
  #expect(try e.get(2, [9]) == [3, 0, 0, 0, 0, 0, 0, 0, 6])
}

@Test func aFailingBatchChangesNothing() throws {
  var e = try newEngine()
  try e.apply([.insert(tree: 1, key: [1], value: [1]), .insert(tree: 1, key: [2], value: [2])])
  #expect(throws: TaisceError.missingKey) {
    try e.apply([.insert(tree: 1, key: [3], value: [3]), .delete(tree: 1, key: [1]),
                 .insert(tree: 4, key: [1], value: [1]), .delta(tree: 5, key: [7], .add(offset: 0, value: 1))])
  }
  #expect(throws: TaisceError.badDelta) {
    try e.apply([.insert(tree: 1, key: [1], value: [9]), .delta(tree: 1, key: [2], .add(offset: 0, value: 1))])
  }
  #expect(try contents(&e) == [1: [[1]: [1], [2]: [2]]])
}

@Test func aBatchThatRunsOutOfSpaceChangesNothing() throws {
  var e = try newEngine(blocks: 640)  // room for about 90 nodes
  let value = [UInt8](repeating: 7, count: 200)
  try e.apply((0..<500).map { .insert(tree: 1, key: bigEndian($0), value: value) })
  try e.commitGroup()
  try e.apply([.insert(tree: 2, key: [1], value: [1])])  // a change in this group, fresh nodes
  let before = try contents(&e)
  let free = e.store.volume.allocator.freeCount
  // Some 330 nodes' worth: it runs out part-way, splitting nodes.
  #expect(throws: TaisceError.noSpace) {
    try e.apply((500..<6500).map { .insert(tree: 1, key: bigEndian($0), value: value) })
  }
  #expect(try contents(&e) == before)
  #expect(e.store.volume.allocator.freeCount == free)  // nothing it allocated is left in use
  _ = try e.check()
  // And what fits still applies, and commits.
  try e.apply([.insert(tree: 1, key: bigEndian(9999), value: value)])
  try e.commitGroup()
  _ = try e.check()
}

@Test func committedGroupsSurviveARemount() throws {
  var e = try newEngine()
  for g in 0..<5 {
    var batch: [Message] = []
    for k in 0..<200 { batch.append(.insert(tree: UInt64(1 + g % 2), key: [UInt8(g), UInt8(k)], value: [UInt8](repeating: UInt8(k), count: 200))) }
    try e.apply(batch)
    try e.commitGroup()
  }
  try e.apply([.insert(tree: 3, key: [1], value: [1])])  // not committed: lost on remount
  let before = try contents(&e)
  var m = try Engine.mount(e.store.volume.device)
  var expected = before
  expected[3] = nil
  #expect(try contents(&m) == expected)
  #expect(try m.check().entries == 1000)
}

@Test func manyCommitsGoAroundTheRing() throws {
  var e = try newEngine(blocks: 2048)
  for g in 0..<40 {
    try e.apply([.insert(tree: 1, key: [UInt8(g)], value: [UInt8](repeating: UInt8(g), count: 1000))])
    try e.commitGroup()
  }
  var m = try Engine.mount(e.store.volume.device)
  #expect(try m.scan(1, from: []).count == 40)
  _ = try m.check()
}

/// Whether a FlakyDevice's writes fail, shared by its copies.
final class Flakiness {
  var failWrites = false
  /// Writes that succeed before one fails (just that one); nil: none.
  var writesLeft: Int?
}

/// A memory device whose writes can be made to fail.
struct FlakyDevice: BlockDevice {
  var base: MemoryDevice
  let flakiness: Flakiness
  var blockSize: Int { base.blockSize }
  var blockCount: UInt64 { base.blockCount }
  mutating func read(_ block: UInt64, count: Int) throws(TaisceError) -> [UInt8] { try base.read(block, count: count) }
  mutating func write(_ block: UInt64, _ bytes: [UInt8]) throws(TaisceError) {
    if let left = flakiness.writesLeft {
      flakiness.writesLeft = left == 0 ? nil : left - 1
      if left == 0 { throw .io(5) }
    }
    if flakiness.failWrites { throw .io(5) }
    try base.write(block, bytes)
  }
  mutating func flush() throws(TaisceError) {}
}

@Test func aCommitThatFailsOnTheDeviceStopsWritesUntilARemount() throws {
  let flakiness = Flakiness()
  var e = try Engine.format(FlakyDevice(base: MemoryDevice(blocks: 4096), flakiness: flakiness), label: [],
                            uuid: Array(1...16), now: 1)
  try e.apply((0..<300).map { .insert(tree: 1, key: bigEndian($0), value: [UInt8](repeating: 1, count: 100)) })
  try e.commitGroup()
  try e.apply((300..<600).map { .insert(tree: 1, key: bigEndian($0), value: [UInt8](repeating: 2, count: 100)) })
  flakiness.failWrites = true
  #expect(throws: TaisceError.io(5)) { try e.commitGroup() }
  flakiness.failWrites = false  // the device recovers, but what that commit wrote can't be trusted
  let stopped = e.stopped
  #expect(stopped)
  #expect(throws: TaisceError.readOnly) { try e.commitGroup() }
  #expect(throws: TaisceError.readOnly) { try e.apply([.insert(tree: 1, key: [9], value: [9])]) }
  #expect(throws: TaisceError.readOnly) { try e.fsync() }
  #expect(try e.get(1, bigEndian(500)) == [UInt8](repeating: 2, count: 100))  // reads go on
  // Mounted again: the last commit that completed, whole.
  var after = try Engine<MemoryDevice>.mount(e.store.volume.device.base)
  #expect(try after.get(1, bigEndian(299)) == [UInt8](repeating: 1, count: 100))
  #expect(try after.get(1, bigEndian(300)) == nil)
  _ = try after.check()
}
