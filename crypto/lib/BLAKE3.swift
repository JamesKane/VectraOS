// SPDX-License-Identifier: BSD-3-Clause

// BLAKE3 (the BLAKE3 specification, 2020): ours, tier 0, portable (no
// SIMD yet). One function for hashing, keyed hashing (MACs) and key
// derivation, with output of any length. Taisce checksums every block with
// its first 128 bits (docs/milestones/S1.md); the crypto stack uses it as is.
//
// The structure: input splits into 1 KiB chunks of 64-byte blocks, each
// chunk compressed into a chaining value, and chaining values combined in a
// binary tree; the root is compressed with ROOT, once per 64 bytes of output.

public struct BLAKE3 {
  typealias Words8 = InlineArray<8, UInt32>
  typealias Words16 = InlineArray<16, UInt32>

  static let iv: Words8 = [
    0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A, 0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
  ]
  static let chunkStart: UInt32 = 1
  static let chunkEnd: UInt32 = 2
  static let parent: UInt32 = 4
  static let root: UInt32 = 8
  static let keyedHash: UInt32 = 16
  static let deriveKeyContext: UInt32 = 32
  static let deriveKeyMaterial: UInt32 = 64
  static let chunkLength = 1024
  static let blockLength = 64

  /// The compression function: a chaining value and a 64-byte block (as 16
  /// words) to 16 words of output.
  static func compress(_ cv: Words8, _ m: Words16, counter: UInt64, length: UInt32, flags: UInt32) -> Words16 {
    var s0 = cv[0], s1 = cv[1], s2 = cv[2], s3 = cv[3], s4 = cv[4], s5 = cv[5], s6 = cv[6], s7 = cv[7]
    var s8 = iv[0], s9 = iv[1], s10 = iv[2], s11 = iv[3]
    var s12 = UInt32(truncatingIfNeeded: counter), s13 = UInt32(truncatingIfNeeded: counter >> 32)
    var s14 = length, s15 = flags
    @inline(__always) func g(_ a: inout UInt32, _ b: inout UInt32, _ c: inout UInt32, _ d: inout UInt32,
                             _ x: UInt32, _ y: UInt32) {
      a = a &+ b &+ x
      d = (d ^ a).rotr(16)
      c = c &+ d
      b = (b ^ c).rotr(12)
      a = a &+ b &+ y
      d = (d ^ a).rotr(8)
      c = c &+ d
      b = (b ^ c).rotr(7)
    }
    // Seven rounds; the message words are permuted between rounds, so each
    // G reads fixed positions (the specification's own structure).
    var w0 = m[0], w1 = m[1], w2 = m[2], w3 = m[3], w4 = m[4], w5 = m[5], w6 = m[6], w7 = m[7]
    var w8 = m[8], w9 = m[9], w10 = m[10], w11 = m[11], w12 = m[12], w13 = m[13], w14 = m[14], w15 = m[15]
    for round in 0..<7 {
      g(&s0, &s4, &s8, &s12, w0, w1)
      g(&s1, &s5, &s9, &s13, w2, w3)
      g(&s2, &s6, &s10, &s14, w4, w5)
      g(&s3, &s7, &s11, &s15, w6, w7)
      g(&s0, &s5, &s10, &s15, w8, w9)
      g(&s1, &s6, &s11, &s12, w10, w11)
      g(&s2, &s7, &s8, &s13, w12, w13)
      g(&s3, &s4, &s9, &s14, w14, w15)
      if round == 6 { break }
      // The permutation [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8].
      (w0, w1, w2, w3, w4, w5, w6, w7, w8, w9, w10, w11, w12, w13, w14, w15) =
        (w2, w6, w3, w10, w7, w0, w4, w13, w1, w11, w12, w5, w9, w14, w15, w8)
    }
    return [s0 ^ s8, s1 ^ s9, s2 ^ s10, s3 ^ s11, s4 ^ s12, s5 ^ s13, s6 ^ s14, s7 ^ s15,
            s8 ^ cv[0], s9 ^ cv[1], s10 ^ cv[2], s11 ^ cv[3], s12 ^ cv[4], s13 ^ cv[5], s14 ^ cv[6], s15 ^ cv[7]]
  }

  /// A block's 16 little-endian words (zero-padded).
  static func words(_ b: [UInt8], _ from: Int, _ count: Int) -> Words16 {
    var w = Words16(repeating: 0)
    if count == 64 {  // a whole block: four bytes a word
      for i in 0..<16 {
        let o = from + 4 * i
        w[i] = UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
      }
      return w
    }
    for i in 0..<count { w[i >> 2] |= UInt32(b[from + i]) << (8 * UInt32(i & 3)) }
    return w
  }

  /// What a final compression needs: its inputs, compressed once for a
  /// chaining value or with ROOT for output.
  struct Output {
    var cv: Words8
    var block: Words16
    var counter: UInt64
    var length: UInt32
    var flags: UInt32

    var chainingValue: Words8 { first8(compress(cv, block, counter: counter, length: length, flags: flags)) }

    func rootBytes(_ count: Int) -> [UInt8] {
      var out: [UInt8] = []
      out.reserveCapacity(count)
      var n: UInt64 = 0
      while out.count < count {
        let words = compress(cv, block, counter: n, length: length, flags: flags | BLAKE3.root)
        for i in 0..<16 where out.count < count {
          for k in 0..<4 where out.count < count { out.append(UInt8(truncatingIfNeeded: words[i] >> (8 * UInt32(k)))) }
        }
        n += 1
      }
      return out
    }
  }

  // The hasher's state.
  let key: Words8
  let flags: UInt32
  var cv: Words8
  var chunkCounter: UInt64 = 0
  var buffer: [UInt8] = []
  var blocksCompressed = 0
  var stack: [Words8] = []

  static func first8(_ w: Words16) -> Words8 {
    var out = Words8(repeating: 0)
    for i in 0..<8 { out[i] = w[i] }
    return out
  }

  /// A parent node's block: its two children's chaining values.
  static func join(_ left: Words8, _ right: Words8) -> Words16 {
    var out = Words16(repeating: 0)
    for i in 0..<8 {
      out[i] = left[i]
      out[8 + i] = right[i]
    }
    return out
  }

  init(key: Words8, flags: UInt32) {
    self.key = key
    self.flags = flags
    cv = key
  }

  /// A hasher for plain hashing.
  public init() { self.init(key: Self.iv, flags: 0) }

  /// A keyed hasher (a MAC); `key` must be 32 bytes.
  public init(key: [UInt8]) {
    precondition(key.count == 32, "a BLAKE3 key is 32 bytes")
    self.init(key: Self.first8(Self.words(key, 0, 32)), flags: Self.keyedHash)
  }

  /// A hasher deriving keys for `context`: hash the key material into it.
  public init(deriveKeyContext context: [UInt8]) {
    var c = BLAKE3(key: Self.iv, flags: Self.deriveKeyContext)
    c.update(context)
    let contextKey = c.finalize(count: 32)
    self.init(key: Self.first8(Self.words(contextKey, 0, 32)), flags: Self.deriveKeyMaterial)
  }

  /// The chunk being filled, as an Output.
  func chunkOutput() -> Output {
    Output(cv: cv, block: Self.words(buffer, 0, buffer.count), counter: chunkCounter, length: UInt32(buffer.count),
           flags: flags | (blocksCompressed == 0 ? Self.chunkStart : 0) | Self.chunkEnd)
  }

  /// Adds a completed chunk's chaining value to the tree, merging subtrees
  /// as the count of chunks says they're complete.
  mutating func pushChunk(_ newCV: Words8, total: UInt64) {
    var cv = newCV, n = total
    while n & 1 == 0 {
      let left = stack.removeLast()
      cv = Output(cv: key, block: Self.join(left, cv), counter: 0, length: UInt32(Self.blockLength),
                  flags: flags | Self.parent).chainingValue
      n >>= 1
    }
    stack.append(cv)
  }

  /// Feeds `input` to the hasher.
  public mutating func update(_ input: [UInt8]) {
    var at = 0
    while at < input.count {
      // A full chunk with more coming: finish it into the tree.
      if blocksCompressed * Self.blockLength + buffer.count == Self.chunkLength {
        let chunkCV = chunkOutput().chainingValue
        pushChunk(chunkCV, total: chunkCounter + 1)
        chunkCounter += 1
        cv = key
        blocksCompressed = 0
        buffer.removeAll(keepingCapacity: true)
      }
      // A full block with more coming: compress it.
      if buffer.count == Self.blockLength {
        cv = Self.first8(Self.compress(cv, Self.words(buffer, 0, Self.blockLength), counter: chunkCounter,
                                       length: UInt32(Self.blockLength),
                                       flags: flags | (blocksCompressed == 0 ? Self.chunkStart : 0)))
        blocksCompressed += 1
        buffer.removeAll(keepingCapacity: true)
      }
      // Whole blocks straight from the input, when more follows and the
      // block isn't its chunk's last (that one is finished by chunkOutput).
      while buffer.isEmpty, blocksCompressed < 15, input.count - at > Self.blockLength {
        cv = Self.first8(Self.compress(cv, Self.words(input, at, Self.blockLength), counter: chunkCounter,
                                       length: UInt32(Self.blockLength),
                                       flags: flags | (blocksCompressed == 0 ? Self.chunkStart : 0)))
        blocksCompressed += 1
        at += Self.blockLength
      }
      let take = min(Self.blockLength - buffer.count, input.count - at)
      buffer.append(contentsOf: input[at..<(at + take)])
      at += take
    }
  }

  /// The digest: `count` bytes (32 is BLAKE3's standard; any length works,
  /// and shorter outputs are prefixes of longer ones).
  public func finalize(count: Int = 32) -> [UInt8] {
    var out = chunkOutput()
    for left in stack.reversed() {
      out = Output(cv: key, block: Self.join(left, out.chainingValue), counter: 0, length: UInt32(Self.blockLength),
                   flags: flags | Self.parent)
    }
    return out.rootBytes(count)
  }

  /// The hash of `input`, `count` bytes long.
  public static func hash(_ input: [UInt8], count: Int = 32) -> [UInt8] {
    var h = BLAKE3()
    h.update(input)
    return h.finalize(count: count)
  }
}

extension UInt32 {
  @inline(__always) func rotr(_ n: UInt32) -> UInt32 { self >> n | self << (32 - n) }
}
