// SPDX-License-Identifier: BSD-3-Clause

// BLAKE3's tree, reused: an input kept as aligned groups of whole chunks
// whose chaining values are cached is hashed again from those values and
// the groups that changed, the same hash `BLAKE3.hash` gives its bytes.
// Taisce's bitmap checksum is its user: one 4 KiB bitmap block (4 chunks)
// a group, so a commit rehashes the blocks it changed and merges the rest,
// not the whole bitmap (tens of MB on a TB volume).
//
// Why it holds: BLAKE3 splits n chunks (n > 1) into a left subtree of the
// largest power of two below n and a right one of the rest. Every split of
// a range that starts at a multiple of a group's chunks (a power of two)
// and is longer than one group leaves both halves starting at multiples of
// it, so each whole aligned group is a subtree of its own, whose chaining
// value depends only on its bytes and its first chunk's index.

/// A subtree's chaining value: kept, it stands for the subtree's bytes.
public struct BLAKE3Subtree: Sendable {
  let cv: InlineArray<8, UInt32>

  init(_ cv: InlineArray<8, UInt32>) { self.cv = cv }

  public static func == (a: BLAKE3Subtree, b: BLAKE3Subtree) -> Bool {
    for i in 0..<8 where a.cv[i] != b.cv[i] { return false }
    return true
  }
}

extension BLAKE3 {
  /// The largest power of two below `n` (n > 1): the left subtree's chunks.
  static func leftChunks(_ n: Int) -> Int {
    var p = 1
    while p * 2 < n { p *= 2 }
    return p
  }

  /// Chunk `index`'s chaining value, from `bytes` (at most a chunk's).
  static func chunkValue(_ bytes: ArraySlice<UInt8>, index: UInt64) -> Words8 {
    var h = BLAKE3()
    h.chunkCounter = index
    h.update(Array(bytes))
    return h.chunkOutput().chainingValue
  }

  /// A parent node's chaining value.
  static func parentValue(_ left: Words8, _ right: Words8) -> Words8 {
    Output(cv: iv, block: join(left, right), counter: 0, length: UInt32(blockLength), flags: parent).chainingValue
  }

  /// The chaining value of chunks `first..<end` (not the whole input),
  /// each chunk's bytes from `chunk`, and each whole group of `group`
  /// chunks (aligned, below `wholeGroups`) from `cached` instead.
  static func value(_ first: Int, _ end: Int, group: Int, wholeGroups: Int, cached: (Int) -> BLAKE3Subtree,
                    chunk: (Int) -> ArraySlice<UInt8>) -> Words8 {
    let n = end - first
    if n == group, first % group == 0, first / group < wholeGroups { return cached(first / group).cv }
    if n == 1 { return chunkValue(chunk(first), index: UInt64(first)) }
    let left = leftChunks(n)
    return parentValue(value(first, first + left, group: group, wholeGroups: wholeGroups, cached: cached, chunk: chunk),
                       value(first + left, end, group: group, wholeGroups: wholeGroups, cached: cached, chunk: chunk))
  }

  /// The chaining value of `chunks` whole chunks (a power of two) of
  /// `bytes` from `offset`, as the subtree starting at chunk `first` of a
  /// longer input.
  public static func subtree(_ bytes: [UInt8], offset: Int, chunks: Int, first: Int) -> BLAKE3Subtree {
    precondition(chunks > 0 && chunks & (chunks - 1) == 0 && first % chunks == 0, "a subtree is an aligned power of two")
    if chunks >= 4 {  // four at a time (BLAKE3Wide.swift)
      precondition(offset >= 0 && offset + chunks * chunkLength <= bytes.count, "the subtree's chunks are whole")
      let values = unsafe bytes.withUnsafeBytes { b in
        unsafe chunkValues(b.baseAddress! + offset, length: chunks * chunkLength, first: first, count: chunks)
      }
      return BLAKE3Subtree(reduce(values, 0, chunks))
    }
    let v = value(first, first + chunks, group: chunks, wholeGroups: 0, cached: { _ in fatalError() }) { c in
      let at = offset + (c - first) * chunkLength
      return bytes[at..<(at + chunkLength)]
    }
    return BLAKE3Subtree(v)
  }

  /// The hash, `count` bytes, of `length` bytes kept as groups of
  /// `groupChunks` chunks (a power of two): whole group `i`'s chaining
  /// value is `group(i)` (`subtree` of its bytes, chunk `i * groupChunks`
  /// first), and the bytes after the last whole group are `tail`. The
  /// input must be longer than one group (one group alone is the root).
  public static func hash(length: Int, groupChunks: Int, group: (Int) -> BLAKE3Subtree, tail: [UInt8],
                          count: Int = 32) -> [UInt8] {
    let groupBytes = groupChunks * chunkLength
    precondition(length > groupBytes, "the input is longer than a group")
    let wholeGroups = length / groupBytes
    precondition(tail.count == length - wholeGroups * groupBytes, "the tail is the bytes after the whole groups")
    let chunks = (length + chunkLength - 1) / chunkLength
    let tailStart = wholeGroups * groupChunks
    let chunk = { (c: Int) -> ArraySlice<UInt8> in
      let at = (c - tailStart) * chunkLength
      return tail[at..<min(at + chunkLength, tail.count)]
    }
    let left = leftChunks(chunks)
    let l = value(0, left, group: groupChunks, wholeGroups: wholeGroups, cached: group, chunk: chunk)
    let r = value(left, chunks, group: groupChunks, wholeGroups: wholeGroups, cached: group, chunk: chunk)
    return Output(cv: iv, block: join(l, r), counter: 0, length: UInt32(blockLength), flags: parent).rootBytes(count)
  }
}
