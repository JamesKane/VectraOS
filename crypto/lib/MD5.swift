// SPDX-License-Identifier: BSD-3-Clause

// MD5 (RFC 1321): ours, tier 0. For integrity checks against an MD5 a
// format already records (FLAC's STREAMINFO signature of its samples,
// C0d), never for security: MD5's collisions are cheap to make, so
// nothing new should trust it to tell data from an adversary's.
//
// The message is padded with a 1 bit, zeros to 448 bits mod 512, and its
// length in bits (64 bits, little-endian); each 512-bit block, as sixteen
// little-endian words, goes through four rounds of sixteen steps over the
// state A, B, C, D. The digest is the state, little-endian.

public struct MD5 {
  typealias Words4 = InlineArray<4, UInt32>

  /// RFC 1321's T[i]: the integer part of 2^32 * |sin(i + 1)| (i in
  /// radians), 3.4's table. (crypto/tests computes them again.)
  static let t: InlineArray<64, UInt32> = [
    0xD76A_A478, 0xE8C7_B756, 0x2420_70DB, 0xC1BD_CEEE, 0xF57C_0FAF, 0x4787_C62A, 0xA830_4613, 0xFD46_9501,
    0x6980_98D8, 0x8B44_F7AF, 0xFFFF_5BB1, 0x895C_D7BE, 0x6B90_1122, 0xFD98_7193, 0xA679_438E, 0x49B4_0821,
    0xF61E_2562, 0xC040_B340, 0x265E_5A51, 0xE9B6_C7AA, 0xD62F_105D, 0x0244_1453, 0xD8A1_E681, 0xE7D3_FBC8,
    0x21E1_CDE6, 0xC337_07D6, 0xF4D5_0D87, 0x455A_14ED, 0xA9E3_E905, 0xFCEF_A3F8, 0x676F_02D9, 0x8D2A_4C8A,
    0xFFFA_3942, 0x8771_F681, 0x6D9D_6122, 0xFDE5_380C, 0xA4BE_EA44, 0x4BDE_CFA9, 0xF6BB_4B60, 0xBEBF_BC70,
    0x289B_7EC6, 0xEAA1_27FA, 0xD4EF_3085, 0x0488_1D05, 0xD9D4_D039, 0xE6DB_99E5, 0x1FA2_7CF8, 0xC4AC_5665,
    0xF429_2244, 0x432A_FF97, 0xAB94_23A7, 0xFC93_A039, 0x655B_59C3, 0x8F0C_CC92, 0xFFEF_F47D, 0x8584_5DD1,
    0x6FA8_7E4F, 0xFE2C_E6E0, 0xA301_4314, 0x4E08_11A1, 0xF753_7E82, 0xBD3A_F235, 0x2AD7_D2BB, 0xEB86_D391,
  ]
  /// Each round's four rotations (3.4).
  static let shifts: InlineArray<16, UInt32> = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21]

  var state: Words4 = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476]
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

  /// The 16-byte digest of the message so far.
  public func finalize() -> [UInt8] {
    var m = self
    let bits = length &* 8
    var pad = InlineArray<72, UInt8>(repeating: 0)
    pad[0] = 0x80
    let n = (filled < 56 ? 56 : 120) - filled
    for k in 0..<8 { pad[n + k] = UInt8(truncatingIfNeeded: bits >> UInt64(8 * k)) }
    for k in 0..<(n + 8) {
      m.block[m.filled] = pad[k]
      m.filled += 1
      if m.filled == 64 {
        m.compressBlock()
        m.filled = 0
      }
    }
    var out = [UInt8](repeating: 0, count: 16)
    for w in 0..<4 {
      for k in 0..<4 { out[4 * w + k] = UInt8(truncatingIfNeeded: m.state[w] >> UInt32(8 * k)) }
    }
    return out
  }

  /// T[i + 1], for the tests that compute the table again.
  public static func sine(_ i: Int) -> UInt32 { t[i] }

  public static func hash(_ input: [UInt8]) -> [UInt8] {
    var m = MD5()
    m.update(input)
    return m.finalize()
  }

  /// 3.4: the block in `block` into the state.
  mutating func compressBlock() {
    var x = InlineArray<16, UInt32>(repeating: 0)
    for w in 0..<16 {
      x[w] = UInt32(block[4 * w]) | UInt32(block[4 * w + 1]) << 8 | UInt32(block[4 * w + 2]) << 16
        | UInt32(block[4 * w + 3]) << 24
    }
    var a = state[0], b = state[1], c = state[2], d = state[3]
    for i in 0..<64 {
      var f: UInt32
      var g: Int
      switch i >> 4 {
      case 0:
        f = (b & c) | (~b & d)  // F
        g = i
      case 1:
        f = (b & d) | (c & ~d)  // G
        g = (5 &* i &+ 1) & 15
      case 2:
        f = b ^ c ^ d  // H
        g = (3 &* i &+ 5) & 15
      default:
        f = c ^ (b | ~d)  // I
        g = (7 &* i) & 15
      }
      f = f &+ a &+ Self.t[i] &+ x[g]
      a = d
      d = c
      c = b
      let s = Self.shifts[(i >> 4) * 4 + (i & 3)]
      b = b &+ (f << s | f >> (32 - s))
    }
    state[0] = state[0] &+ a
    state[1] = state[1] &+ b
    state[2] = state[2] &+ c
    state[3] = state[3] &+ d
  }
}
