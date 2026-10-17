// SPDX-License-Identifier: BSD-3-Clause

// SHA-512 (FIPS 180-4): ours, tier 0. Ed25519 hashes with it (RFC 8032),
// and SSH's curve25519-sha256 key exchange signs a hash with Ed25519
// (N1a).
//
// SHA-256's shape at twice the width: the message is padded with a 1
// bit, zeros to 896 bits mod 1024, and its length in bits (128 bits,
// big-endian); each 1024-bit block, as sixteen big-endian 64-bit words
// expanded to a schedule of eighty, goes through eighty rounds over the
// eight working variables. The digest is the state, big-endian. Its time
// depends only on the message's length.

public struct SHA512 {
  typealias Words8 = InlineArray<8, UInt64>

  /// FIPS 180-4 §4.2.3's K: the first 64 bits of the fractional parts of
  /// the cube roots of the first eighty primes.
  static let k: InlineArray<80, UInt64> = [
    0x428A_2F98_D728_AE22, 0x7137_4491_23EF_65CD, 0xB5C0_FBCF_EC4D_3B2F, 0xE9B5_DBA5_8189_DBBC,
    0x3956_C25B_F348_B538, 0x59F1_11F1_B605_D019, 0x923F_82A4_AF19_4F9B, 0xAB1C_5ED5_DA6D_8118,
    0xD807_AA98_A303_0242, 0x1283_5B01_4570_6FBE, 0x2431_85BE_4EE4_B28C, 0x550C_7DC3_D5FF_B4E2,
    0x72BE_5D74_F27B_896F, 0x80DE_B1FE_3B16_96B1, 0x9BDC_06A7_25C7_1235, 0xC19B_F174_CF69_2694,
    0xE49B_69C1_9EF1_4AD2, 0xEFBE_4786_384F_25E3, 0x0FC1_9DC6_8B8C_D5B5, 0x240C_A1CC_77AC_9C65,
    0x2DE9_2C6F_592B_0275, 0x4A74_84AA_6EA6_E483, 0x5CB0_A9DC_BD41_FBD4, 0x76F9_88DA_8311_53B5,
    0x983E_5152_EE66_DFAB, 0xA831_C66D_2DB4_3210, 0xB003_27C8_98FB_213F, 0xBF59_7FC7_BEEF_0EE4,
    0xC6E0_0BF3_3DA8_8FC2, 0xD5A7_9147_930A_A725, 0x06CA_6351_E003_826F, 0x1429_2967_0A0E_6E70,
    0x27B7_0A85_46D2_2FFC, 0x2E1B_2138_5C26_C926, 0x4D2C_6DFC_5AC4_2AED, 0x5338_0D13_9D95_B3DF,
    0x650A_7354_8BAF_63DE, 0x766A_0ABB_3C77_B2A8, 0x81C2_C92E_47ED_AEE6, 0x9272_2C85_1482_353B,
    0xA2BF_E8A1_4CF1_0364, 0xA81A_664B_BC42_3001, 0xC24B_8B70_D0F8_9791, 0xC76C_51A3_0654_BE30,
    0xD192_E819_D6EF_5218, 0xD699_0624_5565_A910, 0xF40E_3585_5771_202A, 0x106A_A070_32BB_D1B8,
    0x19A4_C116_B8D2_D0C8, 0x1E37_6C08_5141_AB53, 0x2748_774C_DF8E_EB99, 0x34B0_BCB5_E19B_48A8,
    0x391C_0CB3_C5C9_5A63, 0x4ED8_AA4A_E341_8ACB, 0x5B9C_CA4F_7763_E373, 0x682E_6FF3_D6B2_B8A3,
    0x748F_82EE_5DEF_B2FC, 0x78A5_636F_4317_2F60, 0x84C8_7814_A1F0_AB72, 0x8CC7_0208_1A64_39EC,
    0x90BE_FFFA_2363_1E28, 0xA450_6CEB_DE82_BDE9, 0xBEF9_A3F7_B2C6_7915, 0xC671_78F2_E372_532B,
    0xCA27_3ECE_EA26_619C, 0xD186_B8C7_21C0_C207, 0xEADA_7DD6_CDE0_EB1E, 0xF57D_4F7F_EE6E_D178,
    0x06F0_67AA_7217_6FBA, 0x0A63_7DC5_A2C8_98A6, 0x113F_9804_BEF9_0DAE, 0x1B71_0B35_131C_471B,
    0x28DB_77F5_2304_7D84, 0x32CA_AB7B_40C7_2493, 0x3C9E_BE0A_15C9_BEBC, 0x431D_67C4_9C10_0D4C,
    0x4CC5_D4BE_CB3E_42B6, 0x597F_299C_FC65_7E2A, 0x5FCB_6FAB_3AD6_FAEC, 0x6C44_198C_4A47_5817,
  ]
  /// §5.3.5's initial hash value: the first 64 bits of the fractional
  /// parts of the square roots of the first eight primes.
  static let initial: Words8 = [
    0x6A09_E667_F3BC_C908, 0xBB67_AE85_84CA_A73B, 0x3C6E_F372_FE94_F82B, 0xA54F_F53A_5F1D_36F1,
    0x510E_527F_ADE6_82D1, 0x9B05_688C_2B3E_6C1F, 0x1F83_D9AB_FB41_BD6B, 0x5BE0_CD19_137E_2179,
  ]

  /// The digest's size, and a block's.
  public static let digestSize = 64
  public static let blockSize = 128

  var state: Words8 = SHA512.initial
  /// Bytes of the current block so far, and the message's length (a
  /// message under 2^64 bytes: the length's high half is its top bits).
  var block = InlineArray<128, UInt8>(repeating: 0)
  var filled = 0
  var length: UInt64 = 0

  public init() {}

  /// Adds `input` to the message.
  public mutating func update(_ input: borrowing Span<UInt8>) {
    length &+= UInt64(input.count)
    var i = 0
    // Fill a partial block first, then whole blocks straight from the input.
    if filled > 0 {
      while filled < 128 && i < input.count {
        block[filled] = input[i]
        filled += 1
        i += 1
      }
      if filled < 128 { return }
      compressBlock()
      filled = 0
    }
    while input.count - i >= 128 {
      for k in 0..<128 { block[k] = input[i + k] }
      compressBlock()
      i += 128
    }
    while i < input.count {
      block[filled] = input[i]
      filled += 1
      i += 1
    }
  }

  public mutating func update(_ input: [UInt8]) { update(input.span) }

  /// The 64-byte digest of the message so far.
  public func finalize() -> [UInt8] {
    var m = self
    // The length in bits, 128 bits: the byte count's top three bits, then
    // the rest shifted.
    let high = length >> 61, low = length &* 8
    var pad = InlineArray<144, UInt8>(repeating: 0)
    pad[0] = 0x80
    let n = (filled < 112 ? 112 : 240) - filled
    for k in 0..<8 { pad[n + k] = UInt8(truncatingIfNeeded: high >> UInt64(56 - 8 * k)) }
    for k in 0..<8 { pad[n + 8 + k] = UInt8(truncatingIfNeeded: low >> UInt64(56 - 8 * k)) }
    for k in 0..<(n + 16) {
      m.block[m.filled] = pad[k]
      m.filled += 1
      if m.filled == 128 {
        m.compressBlock()
        m.filled = 0
      }
    }
    var out = [UInt8](repeating: 0, count: 64)
    for w in 0..<8 {
      for b in 0..<8 { out[8 * w + b] = UInt8(truncatingIfNeeded: m.state[w] >> UInt64(56 - 8 * b)) }
    }
    return out
  }

  /// SHA-512 of `bytes`.
  public static func hash(_ bytes: [UInt8]) -> [UInt8] {
    var h = SHA512()
    h.update(bytes)
    return h.finalize()
  }

  @inline(__always) static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { x >> n | x << (64 - n) }

  mutating func compressBlock() {
    var w = InlineArray<80, UInt64>(repeating: 0)
    for t in 0..<16 {
      var v: UInt64 = 0
      for b in 0..<8 { v = v << 8 | UInt64(block[8 * t + b]) }
      w[t] = v
    }
    for t in 16..<80 {
      let s0 = Self.rotr(w[t - 15], 1) ^ Self.rotr(w[t - 15], 8) ^ (w[t - 15] >> 7)
      let s1 = Self.rotr(w[t - 2], 19) ^ Self.rotr(w[t - 2], 61) ^ (w[t - 2] >> 6)
      w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
    }
    var a = state[0], b = state[1], c = state[2], d = state[3]
    var e = state[4], f = state[5], g = state[6], h = state[7]
    for t in 0..<80 {
      let s1 = Self.rotr(e, 14) ^ Self.rotr(e, 18) ^ Self.rotr(e, 41)
      let ch = (e & f) ^ (~e & g)
      let t1 = h &+ s1 &+ ch &+ Self.k[t] &+ w[t]
      let s0 = Self.rotr(a, 28) ^ Self.rotr(a, 34) ^ Self.rotr(a, 39)
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
  public static func constant(_ i: Int) -> UInt64 { k[i] }
  /// The initial hash value's word `i` (tests).
  public static func initialWord(_ i: Int) -> UInt64 { initial[i] }
}
