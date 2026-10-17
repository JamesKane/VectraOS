// SPDX-License-Identifier: BSD-3-Clause

// The readers' shared cache: hits match what was verified, collisions keep
// two ways, and threads filling and reading one slot never see a mix.

import Glibc
import Synchronization
import Taisce
import TaisceHost
import Testing

/// An entry's bytes for (block, version), with a checksum that names them.
func entry(_ block: UInt64, _ version: UInt64, size: Int) -> (Checksum, [UInt8]) {
  var bytes = [UInt8](repeating: 0, count: size)
  for i in 0..<size { bytes[i] = UInt8(truncatingIfNeeded: block &* 0x9E37_79B9 ^ version &* 31 ^ UInt64(i / 8)) }
  return (Checksum(a: block, b: version), bytes)
}

@Test func theSharedCacheKeepsWhatWasVerified() {
  let cache = SharedCache(entries: 8, entryBytes: 64)  // four sets of two
  let (sum, bytes) = entry(5, 1, size: 64)
  var out: [UInt8] = []
  #expect(!cache.get(5, sum, set: 5, into: &out) && out.isEmpty)
  cache.put(5, sum, set: 5, bytes)
  #expect(cache.get(5, sum, set: 5, into: &out) && out == bytes)
  out = []
  #expect(!cache.get(5, Checksum(a: 5, b: 2), set: 5, into: &out), "another version of the block is a miss")
  // Blocks 9 and 13 share block 5's set: two ways keep 5 and 9; 13
  // replaces the one filled first.
  let (s9, b9) = entry(9, 1, size: 64), (s13, b13) = entry(13, 1, size: 64)
  cache.put(9, s9, set: 9, b9)
  #expect(cache.get(5, sum, set: 5, into: &out))
  cache.put(13, s13, set: 13, b13)
  out = []
  #expect(!cache.get(5, sum, set: 5, into: &out))
  #expect(cache.get(9, s9, set: 9, into: &out) && cache.get(13, s13, set: 13, into: &out) && out == b9 + b13)
}

final class Hammer: Sendable {
  let cache = SharedCache(entries: 16, entryBytes: 4096)
  let hits = Atomic<Int>(0), torn = Atomic<Int>(0)
}

@Test func threadsFillingAndReadingTheSameSlotsNeverSeeAMix() {
  let h = Hammer()
  var threads: [pthread_t] = []
  for t in 0..<4 {
    threads.append(ToolSupport.spawn {
      var rng = UInt64(t + 1) &* 0x2545_F491_4F6C_DD1D
      func next() -> UInt64 {
        rng ^= rng << 13
        rng ^= rng >> 7
        rng ^= rng << 17
        return rng
      }
      var out: [UInt8] = []
      for _ in 0..<40_000 {
        let block = next() % 24, version = next() % 3
        let (sum, bytes) = entry(block, version, size: 4096)
        if next() % 2 == 0 {
          h.cache.put(block, sum, set: block, bytes)
        } else {
          out.removeAll(keepingCapacity: true)
          if h.cache.get(block, sum, set: block, into: &out) {
            h.hits.add(1, ordering: .relaxed)
            if out != bytes { h.torn.add(1, ordering: .relaxed) }
          }
        }
      }
    })
  }
  for t in threads { ToolSupport.join(t) }
  #expect(h.hits.load(ordering: .relaxed) > 1000)
  #expect(h.torn.load(ordering: .relaxed) == 0)
}
