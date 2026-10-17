// SPDX-License-Identifier: BSD-3-Clause

import Synchronization

/// Verified bytes that every reader thread of a file system shares: file
/// blocks, and nodes as stored (S1f's follow-up). Each entry is keyed by
/// its block and the checksum it was verified against, so a hit is always
/// what the asking snapshot expects and nothing ever needs invalidating.
///
/// Readers never wait on it. Each slot has a sequence number, odd while
/// its bytes change (a seqlock): a lookup copies the bytes out and keeps
/// them only if the sequence was even and unchanged across the copy; a
/// slot being written is a miss. An insert claims its slot with one
/// compare-and-swap and skips caching if another thread holds it. Entries
/// are bytes in one arena, not shared objects or arrays, so hits share no
/// reference counts between threads. Slots come in sets of two ways; an
/// insert takes the way not filled last.
@safe public final class SharedCache: @unchecked Sendable {
  /// Bytes an entry holds.
  public let entryBytes: Int
  let sets: Int
  let arena: UnsafeMutableRawPointer
  /// Per slot: its sequence, then its key (block + 1, checksum halves).
  let sequences: UnsafeMutablePointer<Atomic<UInt64>>
  let keys: UnsafeMutablePointer<Atomic<UInt64>>
  /// Per set: the way filled last.
  let filled: UnsafeMutablePointer<Atomic<UInt8>>

  /// A cache of `entries` entries of `entryBytes` each.
  public init(entries: Int, entryBytes: Int) {
    self.entryBytes = entryBytes
    sets = max(1, (entries + 1) / 2)
    let slots = 2 * sets
    let memory = UnsafeMutableRawPointer.allocate(byteCount: slots * entryBytes, alignment: 64)
    let s = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: slots)
    let k = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: 3 * slots)
    let f = UnsafeMutablePointer<Atomic<UInt8>>.allocate(capacity: sets)
    for i in 0..<slots { unsafe (s + i).initialize(to: Atomic(0)) }
    for i in 0..<(3 * slots) { unsafe (k + i).initialize(to: Atomic(0)) }
    for i in 0..<sets { unsafe (f + i).initialize(to: Atomic(1)) }
    unsafe arena = memory
    unsafe sequences = s
    unsafe keys = k
    unsafe filled = f
  }

  deinit {
    unsafe sequences.deinitialize(count: 2 * sets)
    unsafe keys.deinitialize(count: 6 * sets)
    unsafe filled.deinitialize(count: sets)
    unsafe sequences.deallocate()
    unsafe keys.deallocate()
    unsafe filled.deallocate()
    unsafe arena.deallocate()
  }

  func matches(_ slot: Int, _ block: UInt64, _ checksum: Checksum) -> Bool {
    let key = unsafe (keys[3 * slot].load(ordering: .relaxed), keys[3 * slot + 1].load(ordering: .relaxed),
                      keys[3 * slot + 2].load(ordering: .relaxed))
    return key == (block + 1, checksum.a, checksum.b)
  }

  /// Appends the entry for `block` verified as `checksum` to `out`; false
  /// (and `out` as it was) if there's none. `set` picks its set.
  public func get(_ block: UInt64, _ checksum: Checksum, set: UInt64, into out: inout [UInt8]) -> Bool {
    let s = Int(set % UInt64(sets))
    for way in 0..<2 {
      let slot = 2 * s + way
      let before = unsafe sequences[slot].load(ordering: .acquiring)
      guard before & 1 == 0, matches(slot, block, checksum) else { continue }
      let start = out.count
      out.reserveCapacity(start + entryBytes)
      unsafe out.append(contentsOf: UnsafeRawBufferPointer(start: arena + slot * entryBytes, count: entryBytes))
      atomicMemoryFence(ordering: .acquiring)
      if unsafe sequences[slot].load(ordering: .relaxed) == before { return true }
      out.removeSubrange(start...)  // it changed under us: a miss
    }
    return false
  }

  /// Keeps `bytes` (`entryBytes` of them, from `offset`) for `block`
  /// verified as `checksum`, unless another thread is filling its slot.
  public func put(_ block: UInt64, _ checksum: Checksum, set: UInt64, _ bytes: [UInt8], from offset: Int = 0) {
    guard offset + entryBytes <= bytes.count else { return }
    let s = Int(set % UInt64(sets))
    let last = unsafe filled[s].load(ordering: .relaxed)
    let way = matches(2 * s, block, checksum) ? 0 : matches(2 * s + 1, block, checksum) ? 1 : 1 - Int(last)
    let slot = 2 * s + way
    let sequence = unsafe sequences[slot].load(ordering: .relaxed)
    guard sequence & 1 == 0,
      unsafe sequences[slot].compareExchange(expected: sequence, desired: sequence + 1, ordering: .acquiring).exchanged
    else { return }
    // The odd sequence must be visible before any of the new bytes: an
    // acquiring compare-and-swap doesn't order its own store before later
    // ones on weakly ordered CPUs (arm64), so a reader could see new bytes
    // under the old, even, sequence. (Linux's seqcount writers have
    // smp_wmb() here.)
    atomicMemoryFence(ordering: .releasing)
    unsafe keys[3 * slot].store(block + 1, ordering: .relaxed)
    unsafe keys[3 * slot + 1].store(checksum.a, ordering: .relaxed)
    unsafe keys[3 * slot + 2].store(checksum.b, ordering: .relaxed)
    unsafe bytes.withUnsafeBytes { b in
      unsafe (arena + slot * entryBytes).copyMemory(from: b.baseAddress! + offset, byteCount: entryBytes)
    }
    unsafe sequences[slot].store(sequence + 2, ordering: .releasing)
    unsafe filled[s].store(UInt8(way), ordering: .relaxed)
  }
}

/// The caches a file system's reader threads share: verified file blocks,
/// and verified nodes as stored.
public final class ReaderCaches: Sendable {
  public let blocks: SharedCache
  public let nodes: SharedCache

  public init(blocks: Int, nodes: Int) {
    self.blocks = SharedCache(entries: blocks, entryBytes: Layout.blockSize)
    self.nodes = SharedCache(entries: nodes, entryBytes: Layout.nodeBlocks * Layout.blockSize)
  }
}
