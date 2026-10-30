// SPDX-License-Identifier: BSD-3-Clause

// BLAKE3 four chunks at a time: each lane of a SIMD4<UInt32> is one
// chunk's state, so one compression's work compresses four chunks' blocks
// (the specification's `hash_many`). A 4 KiB block, Taisce's, is four
// chunks. SIMD4 is NEON on arm64 and SSE on amd64, both in the baselines;
// rv64's baseline has no vectors, and runs the lanes one by one. The
// results are the scalar hasher's (BLAKE3.swift), which hashes what
// isn't four whole chunks.

extension BLAKE3 {
  typealias Lanes = SIMD4<UInt32>

  // Rotations as two shifts added (their bits are disjoint): written with
  // `|`, LLVM sees a rotate and, without a vector rotate (Ivy Bridge,
  // amd64's baseline), rotates lane by lane. arm64 makes it shl and usra.
  @inline(__always) static func rotr16(_ x: Lanes) -> Lanes { (x &>> 16) &+ (x &<< 16) }
  @inline(__always) static func rotr12(_ x: Lanes) -> Lanes { (x &>> 12) &+ (x &<< 20) }
  @inline(__always) static func rotr8(_ x: Lanes) -> Lanes { (x &>> 8) &+ (x &<< 24) }
  @inline(__always) static func rotr7(_ x: Lanes) -> Lanes { (x &>> 7) &+ (x &<< 25) }

  /// Four little-endian words from `p + at`, as every target is.
  @inline(__always) static func load(_ p: UnsafeRawPointer, _ at: Int) -> Lanes {
    unsafe p.loadUnaligned(fromByteOffset: at, as: Lanes.self)
  }

  /// Four compressions' states, a lane each: stored properties, so the
  /// rounds reach them without captures (a local function capturing
  /// them boxed them, checked at every access).
  struct State {
    var s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15: Lanes

    @inline(__always) static func g(_ a: inout Lanes, _ b: inout Lanes, _ c: inout Lanes, _ d: inout Lanes,
                                    _ x: Lanes, _ y: Lanes) {
      a = a &+ b &+ x
      d = rotr16(d ^ a)
      c = c &+ d
      b = rotr12(b ^ c)
      a = a &+ b &+ y
      d = rotr8(d ^ a)
      c = c &+ d
      b = rotr7(b ^ c)
    }

    /// A round, the block's words read in schedule `i`.
    @inline(__always) mutating func round(_ m: borrowing InlineArray<16, Lanes>, _ i: InlineArray<16, Int>) {
      Self.g(&s0, &s4, &s8, &s12, m[i[0]], m[i[1]])
      Self.g(&s1, &s5, &s9, &s13, m[i[2]], m[i[3]])
      Self.g(&s2, &s6, &s10, &s14, m[i[4]], m[i[5]])
      Self.g(&s3, &s7, &s11, &s15, m[i[6]], m[i[7]])
      Self.g(&s0, &s5, &s10, &s15, m[i[8]], m[i[9]])
      Self.g(&s1, &s6, &s11, &s12, m[i[10]], m[i[11]])
      Self.g(&s2, &s7, &s8, &s13, m[i[12]], m[i[13]])
      Self.g(&s3, &s4, &s9, &s14, m[i[14]], m[i[15]])
    }
  }

  /// The chaining values of the four whole chunks from `p`, chunks
  /// `counter` to `counter + 3` of a hash's input, keyed by `key` if there
  /// is one.
  static func fourChunks(_ p: UnsafeRawPointer, counter: UInt64, key: BLAKE3Key?) -> (Words8, Words8, Words8, Words8) {
    let (k, flags) = start(key)
    var h0 = Lanes(repeating: k[0]), h1 = Lanes(repeating: k[1]), h2 = Lanes(repeating: k[2])
    var h3 = Lanes(repeating: k[3]), h4 = Lanes(repeating: k[4]), h5 = Lanes(repeating: k[5])
    var h6 = Lanes(repeating: k[6]), h7 = Lanes(repeating: k[7])
    let iv0 = Lanes(repeating: iv[0]), iv1 = Lanes(repeating: iv[1])
    let iv2 = Lanes(repeating: iv[2]), iv3 = Lanes(repeating: iv[3])
    let low = Lanes(UInt32(truncatingIfNeeded: counter), UInt32(truncatingIfNeeded: counter &+ 1),
                    UInt32(truncatingIfNeeded: counter &+ 2), UInt32(truncatingIfNeeded: counter &+ 3))
    let high = Lanes(UInt32(truncatingIfNeeded: counter >> 32), UInt32(truncatingIfNeeded: (counter &+ 1) >> 32),
                     UInt32(truncatingIfNeeded: (counter &+ 2) >> 32), UInt32(truncatingIfNeeded: (counter &+ 3) >> 32))
    let length = Lanes(repeating: UInt32(blockLength))
    let (first, end) = (chunkStart, chunkEnd)
    for b in 0..<16 {
      // The block's words, four at a time from each chunk and transposed,
      // so lane k of word i is chunk k's.
      var m = InlineArray<16, Lanes>(repeating: Lanes())
      for q in 0..<4 {
        let at = b &* 64 &+ 16 &* q
        let a = unsafe load(p, at), c = unsafe load(p, at &+ 1024)
        let d = unsafe load(p, at &+ 2048), e = unsafe load(p, at &+ 3072)
        m[4 &* q] = Lanes(a[0], c[0], d[0], e[0])
        m[4 &* q &+ 1] = Lanes(a[1], c[1], d[1], e[1])
        m[4 &* q &+ 2] = Lanes(a[2], c[2], d[2], e[2])
        m[4 &* q &+ 3] = Lanes(a[3], c[3], d[3], e[3])
      }
      var s = State(s0: h0, s1: h1, s2: h2, s3: h3, s4: h4, s5: h5, s6: h6, s7: h7, s8: iv0, s9: iv1, s10: iv2,
                    s11: iv3, s12: low, s13: high, s14: length,
                    s15: Lanes(repeating: flags | (b == 0 ? first : 0) | (b == 15 ? end : 0)))
      // The seven rounds written out, each reading the words in the
      // specification's schedule (its permutation applied r times).
      s.round(m, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])
      s.round(m, [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8])
      s.round(m, [3, 4, 10, 12, 13, 2, 7, 14, 6, 5, 9, 0, 11, 15, 8, 1])
      s.round(m, [10, 7, 12, 9, 14, 3, 13, 15, 4, 0, 11, 2, 5, 8, 1, 6])
      s.round(m, [12, 13, 9, 11, 15, 10, 14, 8, 7, 2, 5, 3, 0, 1, 6, 4])
      s.round(m, [9, 14, 11, 5, 8, 12, 15, 1, 13, 3, 0, 10, 2, 6, 4, 7])
      s.round(m, [11, 15, 5, 0, 1, 9, 8, 6, 14, 10, 2, 12, 3, 4, 7, 13])
      h0 = s.s0 ^ s.s8
      h1 = s.s1 ^ s.s9
      h2 = s.s2 ^ s.s10
      h3 = s.s3 ^ s.s11
      h4 = s.s4 ^ s.s12
      h5 = s.s5 ^ s.s13
      h6 = s.s6 ^ s.s14
      h7 = s.s7 ^ s.s15
    }
    @inline(__always) func lane(_ j: Int) -> Words8 { [h0[j], h1[j], h2[j], h3[j], h4[j], h5[j], h6[j], h7[j]] }
    return (lane(0), lane(1), lane(2), lane(3))
  }

  /// The chaining values of `count` chunks from `p` (whole ones but the
  /// last, which may be short), chunk `first` first: four at a time while
  /// four whole ones are left. Not for an input of one chunk (its root).
  static func chunkValues(_ p: UnsafeRawPointer, length: Int, first: Int, count: Int, key: BLAKE3Key?) -> [Words8] {
    var values: [Words8] = []
    values.reserveCapacity(count)
    var c = 0
    while c &+ 4 <= count, (c &+ 4) &* chunkLength <= length {
      let (a, b, d, e) = unsafe fourChunks(p + c &* chunkLength, counter: UInt64(first &+ c), key: key)
      values.append(a)
      values.append(b)
      values.append(d)
      values.append(e)
      c &+= 4
    }
    while c < count {
      let at = c &* chunkLength
      let n = Swift.min(chunkLength, length &- at)
      var h = BLAKE3(key: key)
      h.chunkCounter = UInt64(first &+ c)
      h.update(unsafe Array(UnsafeRawBufferPointer(start: p + at, count: n)))
      values.append(h.chunkOutput().chainingValue)
      c &+= 1
    }
    return values
  }

  /// The chaining value of the subtree of `values[first..<end]` (more
  /// than one), BLAKE3's split: the largest power of two on the left.
  static func reduce(_ values: [Words8], _ first: Int, _ end: Int, key: BLAKE3Key?) -> Words8 {
    let n = end &- first
    if n == 1 { return values[first] }
    let left = leftChunks(n)
    return parentValue(reduce(values, first, first &+ left, key: key), reduce(values, first &+ left, end, key: key),
                       key: key)
  }

  /// The hash of `length` bytes from `p`, `count` bytes long: four chunks
  /// or more (fewer are the scalar hasher's).
  static func wideHash(_ p: UnsafeRawPointer, length: Int, count: Int, key: BLAKE3Key?) -> [UInt8] {
    let chunks = (length &+ chunkLength &- 1) / chunkLength
    let values = unsafe chunkValues(p, length: length, first: 0, count: chunks, key: key)
    let left = leftChunks(chunks)
    let (k, flags) = start(key)
    return Output(cv: k, block: join(reduce(values, 0, left, key: key), reduce(values, left, chunks, key: key)),
                  counter: 0, length: UInt32(blockLength), flags: flags | parent).rootBytes(count)
  }
}
