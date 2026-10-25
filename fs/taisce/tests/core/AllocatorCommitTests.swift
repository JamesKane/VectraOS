// SPDX-License-Identifier: BSD-3-Clause

// A commit's allocator work, kept to what changed: the bitmap's checksum
// from cached block hashes is the BLAKE3 of every byte as written, and a
// commit that visits only touched words retires what a walk of every word
// would: a group's frees, at the commit after the one that closed it.

@testable import Taisce
import Testing

/// BLAKE3-128 of the bitmap's words as stored: the reference.
func wholeChecksum(_ a: Allocator) -> Checksum {
  var bytes: [UInt8] = []
  for (i, word) in a.words.enumerated() {
    var w = word
    if i == a.words.count - 1, a.blockCount % 64 != 0 { w &= (1 << (a.blockCount % 64)) - 1 }
    for k in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: w >> (8 * UInt64(k)))) }
  }
  return Checksum(of: bytes)
}

@Test func theCachedChecksumAndTheTouchedWordsMatchAWholeWalk() throws {
  // 5 bitmap blocks and a ragged tail (a word cut short, a partial chunk).
  for blocks: UInt64 in [5 * 32768 + 1000 * 64 + 37, 3 * 32768, 4000] {
    var a = Allocator(blockCount: blocks, reserved: 16)
    var rng = SystemRandomNumberGenerator()
    // Blocks freed in each group (committed ones only: a fresh block freed
    // in its own group comes back at once).
    var freedIn: [[UInt64]] = []
    var live: [Extent] = []
    for group in 0..<12 {
      var freed: [UInt64] = []
      for _ in 0..<40 {
        if live.isEmpty || Bool.random(using: &rng) {
          let near = UInt64.random(in: 0..<blocks, using: &rng)
          live += try a.allocate(UInt64.random(in: 1...70, using: &rng), near: near)
        } else {
          let e = live.remove(at: Int.random(in: 0..<live.count, using: &rng))
          for b in e.start..<e.end where !a.isFresh(b) { freed.append(b) }
          a.free(e)
        }
      }
      #expect(a.checksum() == wholeChecksum(a), "\(blocks) blocks, group \(group)")
      let retired = a.groupCommitted()
      var back: [UInt64] = []
      for e in retired { for b in e.start..<e.end { back.append(b) } }
      // What the previous group freed comes back at this commit (deferred
      // through this group), in order, merged into extents.
      let expected = (freedIn.last ?? []).sorted()
      #expect(back == expected, "\(blocks) blocks, group \(group)")
      // Merged: no two extents touch.
      for i in retired.indices.dropFirst() { #expect(retired[i - 1].end < retired[i].start) }
      for e in retired { a.release(retired: e) }
      freedIn.append(freed)
      // The same checksum again, nothing changed: from the cache alone.
      #expect(a.checksum() == wholeChecksum(a))
    }
  }
}
