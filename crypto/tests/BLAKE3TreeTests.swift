// SPDX-License-Identifier: BSD-3-Clause

// BLAKE3 from cached subtrees (BLAKE3Tree.swift) against BLAKE3.hash of
// the same bytes: groups of 1, 2 and 4 chunks, inputs that end on a
// group, inside a chunk, and a byte past a group.

import Testing
import TDCrypto

func pattern(_ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) } }

@Test func aHashFromCachedGroupsIsTheHashOfTheBytes() {
  for groupChunks in [1, 2, 4] {
    let g = groupChunks * 1024
    for length in [g + 1, 2 * g, 2 * g + 7, 3 * g, 5 * g + 1023, 7 * g + 1024, 8 * g, 31 * g + 1500, 64 * g + 3] {
      let bytes = pattern(length)
      let whole = length / g
      let groups = (0..<whole).map { BLAKE3.subtree(bytes, offset: $0 * g, chunks: groupChunks, first: $0 * groupChunks) }
      let tree = BLAKE3.hash(length: length, groupChunks: groupChunks, group: { groups[$0] },
                             tail: Array(bytes[(whole * g)...]), count: 16)
      #expect(tree == BLAKE3.hash(bytes, count: 16), "\(length) bytes in groups of \(groupChunks) chunks")
    }
  }
}

@Test func aChangedGroupChangesOnlyItsValue() {
  var bytes = pattern(6 * 4096 + 100)
  let before = (0..<6).map { BLAKE3.subtree(bytes, offset: $0 * 4096, chunks: 4, first: $0 * 4) }
  bytes[2 * 4096 + 5] ^= 1
  let after = (0..<6).map { BLAKE3.subtree(bytes, offset: $0 * 4096, chunks: 4, first: $0 * 4) }
  #expect((0..<6).filter { !(before[$0] == after[$0]) } == [2])
  let tree = BLAKE3.hash(length: bytes.count, groupChunks: 4, group: { after[$0] }, tail: Array(bytes[(6 * 4096)...]),
                         count: 16)
  #expect(tree == BLAKE3.hash(bytes, count: 16))
}
