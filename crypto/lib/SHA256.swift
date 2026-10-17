// SPDX-License-Identifier: BSD-3-Clause

// SHA-256 (FIPS 180-4): ours, tier 0. HMAC and PBKDF2 over it give the
// keyring SCRAM-SHA-256 (M6k).
//
// The message is padded with a 1 bit, zeros to 448 bits mod 512, and its
// length in bits (64 bits, big-endian); each 512-bit block, as sixteen
// big-endian words expanded to a schedule of sixty-four, goes through
// sixty-four rounds over the eight working variables. The digest is the
// state, big-endian. Its time depends only on the message's length.

public struct SHA256 {
  typealias Words8 = InlineArray<8, UInt32>

  /// FIPS 180-4 §4.2.2's K: the first 32 bits of the fractional parts of
  /// the cube roots of the first sixty-four primes. (crypto/tests computes
  /// them again.)
  static let k: InlineArray<64, UInt32> = [
    0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
    0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
    0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
    0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
    0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
    0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
    0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
    0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
  ]
  /// §5.3.3's initial hash value: the first 32 bits of the fractional
  /// parts of the square roots of the first eight primes.
  static let initial: Words8 = [
    0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A, 0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
  ]

  /// The digest's size, and a block's (HMAC's B).
  public static let digestSize = 32
  public static let blockSize = 64

  var state: Words8 = SHA256.initial
  /// Bytes of the current block so far, and the message's length.
  var block = InlineArray<64, UInt8>(repeating: 0)
  var filled = 0
  var length: UInt64 = 0

  public init() {}

  /// Adds `input` to the message.
  public mutating func update(_ input: borrowing Span<UInt8>) {
    length &+= UInt64(input.count)
    var i = 0
    // Fill a partial block first, then whole blocks straight from the input.
    if filled > 0 {
      while filled < 64 && i < input.count {
        block[filled] = input[i]
        filled += 1
        i += 1
      }
      if filled < 64 { return }
      compressBlock()
      filled = 0
    }
    while input.count - i >= 64 {
      for k in 0..<64 { block[k] = input[i + k] }
      compressBlock()
      i += 64
    }
    while i < input.count {
      block[filled] = input[i]
      filled += 1
      i += 1
    }
  }

  public mutating func update(_ input: [UInt8]) { update(input.span) }

  /// The 32-byte digest of the message so far.
  public func finalize() -> [UInt8] {
    var m = self
    let bits = length &* 8
    var pad = InlineArray<72, UInt8>(repeating: 0)
    pad[0] = 0x80
    let n = (filled < 56 ? 56 : 120) - filled
    for k in 0..<8 { pad[n + k] = UInt8(truncatingIfNeeded: bits >> UInt64(56 - 8 * k)) }
    for k in 0..<(n + 8) {
      m.block[m.filled] = pad[k]
      m.filled += 1
      if m.filled == 64 {
        m.compressBlock()
        m.filled = 0
      }
    }
    var out = [UInt8](repeating: 0, count: 32)
    for w in 0..<8 {
      for b in 0..<4 { out[4 * w + b] = UInt8(truncatingIfNeeded: m.state[w] >> UInt32(24 - 8 * b)) }
    }
    return out
  }

  /// SHA-256 of `bytes`.
  public static func hash(_ bytes: [UInt8]) -> [UInt8] {
    var h = SHA256()
    h.update(bytes)
    return h.finalize()
  }

  @inline(__always) static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { x >> n | x << (32 - n) }

  mutating func compressBlock() {
    var w = InlineArray<64, UInt32>(repeating: 0)
    for t in 0..<16 {
      w[t] = UInt32(block[4 * t]) << 24 | UInt32(block[4 * t + 1]) << 16 | UInt32(block[4 * t + 2]) << 8
        | UInt32(block[4 * t + 3])
    }
    for t in 16..<64 {
      let s0 = Self.rotr(w[t - 15], 7) ^ Self.rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
      let s1 = Self.rotr(w[t - 2], 17) ^ Self.rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
      w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
    }
    var a = state[0], b = state[1], c = state[2], d = state[3]
    var e = state[4], f = state[5], g = state[6], h = state[7]
    for t in 0..<64 {
      let s1 = Self.rotr(e, 6) ^ Self.rotr(e, 11) ^ Self.rotr(e, 25)
      let ch = (e & f) ^ (~e & g)
      let t1 = h &+ s1 &+ ch &+ Self.k[t] &+ w[t]
      let s0 = Self.rotr(a, 2) ^ Self.rotr(a, 13) ^ Self.rotr(a, 22)
      let maj = (a & b) ^ (a & c) ^ (b & c)
      let t2 = s0 &+ maj
      h = g
      g = f
      f = e
      e = d &+ t1
      d = c
      c = b
      b = a
      a = t1 &+ t2
    }
    state[0] &+= a
    state[1] &+= b
    state[2] &+= c
    state[3] &+= d
    state[4] &+= e
    state[5] &+= f
    state[6] &+= g
    state[7] &+= h
  }

  /// K's word `i` (tests: computed again from the primes).
  public static func constant(_ i: Int) -> UInt32 { k[i] }
  /// The initial hash value's word `i` (tests).
  public static func initialWord(_ i: Int) -> UInt32 { initial[i] }
}
