// SPDX-License-Identifier: BSD-3-Clause

// The field of integers modulo p = 2^255 - 19 (N1a), for X25519 (RFC
// 7748) and Ed25519 (RFC 8032). Ours, tier 0.
//
// An element is five 51-bit limbs, little-endian, each kept below about
// 2^52 between operations. A product's limbs are 128-bit sums of 64-bit
// products (`multipliedFullWidth`: the machine's multiply, no library
// call); 2^255 = 19 mod p folds the top limbs back times 19. Every
// operation does the same work whatever the values: no branch or index
// depends on a secret, swaps are by masks, and the output is fully
// reduced by a subtraction and a mask.

struct Field25519 {
  var l: InlineArray<5, UInt64>

  static let mask51: UInt64 = (1 << 51) - 1

  init(_ l0: UInt64, _ l1: UInt64, _ l2: UInt64, _ l3: UInt64, _ l4: UInt64) {
    l = [l0, l1, l2, l3, l4]
  }

  static let zero = Field25519(0, 0, 0, 0, 0)
  static let one = Field25519(1, 0, 0, 0, 0)

  /// From 32 little-endian bytes, the top bit ignored (RFC 7748 §5).
  init(bytes b: borrowing Span<UInt8>) {
    func load(_ at: Int) -> UInt64 {
      var v: UInt64 = 0
      for i in 0..<8 { v |= UInt64(b[at + i]) << UInt64(8 * i) }
      return v
    }
    let m = Field25519.mask51
    l = [load(0) & m, (load(6) >> 3) & m, (load(12) >> 6) & m, (load(19) >> 1) & m, (load(24) >> 12) & m]
  }

  /// 32 little-endian bytes, fully reduced (below p).
  var bytes: [UInt8] {
    var t = carried
    // t < 2p here: subtract p if t >= p, by a mask. q is 1 when t + 19
    // reaches 2^255.
    var q = (t.l[0] &+ 19) >> 51
    q = (t.l[1] &+ q) >> 51
    q = (t.l[2] &+ q) >> 51
    q = (t.l[3] &+ q) >> 51
    q = (t.l[4] &+ q) >> 51
    t.l[0] &+= 19 &* q
    let m = Field25519.mask51
    t.l[1] &+= t.l[0] >> 51; t.l[0] &= m
    t.l[2] &+= t.l[1] >> 51; t.l[1] &= m
    t.l[3] &+= t.l[2] >> 51; t.l[2] &= m
    t.l[4] &+= t.l[3] >> 51; t.l[3] &= m
    t.l[4] &= m
    let words: [UInt64] = [
      t.l[0] | t.l[1] << 51, t.l[1] >> 13 | t.l[2] << 38, t.l[2] >> 26 | t.l[3] << 25, t.l[3] >> 39 | t.l[4] << 12,
    ]
    var out = [UInt8](repeating: 0, count: 32)
    for w in 0..<4 {
      for i in 0..<8 { out[8 * w + i] = UInt8(truncatingIfNeeded: words[w] >> UInt64(8 * i)) }
    }
    return out
  }

  /// Limbs carried down to 51 bits (the top's carry folded back times 19).
  var carried: Field25519 {
    var t = self
    let m = Field25519.mask51
    for _ in 0..<2 {
      t.l[1] &+= t.l[0] >> 51; t.l[0] &= m
      t.l[2] &+= t.l[1] >> 51; t.l[1] &= m
      t.l[3] &+= t.l[2] >> 51; t.l[2] &= m
      t.l[4] &+= t.l[3] >> 51; t.l[3] &= m
      t.l[0] &+= 19 &* (t.l[4] >> 51); t.l[4] &= m
    }
    return t
  }

  static func + (a: Field25519, b: Field25519) -> Field25519 {
    Field25519(a.l[0] &+ b.l[0], a.l[1] &+ b.l[1], a.l[2] &+ b.l[2], a.l[3] &+ b.l[3], a.l[4] &+ b.l[4]).carried
  }

  /// a - b, as a + 4p - b (limbs stay positive).
  static func - (a: Field25519, b: Field25519) -> Field25519 {
    let p0: UInt64 = 0x1F_FFFF_FFFF_FFB4  // 4 * (2^51 - 19)
    let pi: UInt64 = 0x1F_FFFF_FFFF_FFFC  // 4 * (2^51 - 1)
    return Field25519(a.l[0] &+ p0 &- b.l[0], a.l[1] &+ pi &- b.l[1], a.l[2] &+ pi &- b.l[2], a.l[3] &+ pi &- b.l[3],
                      a.l[4] &+ pi &- b.l[4]).carried
  }

  static prefix func - (a: Field25519) -> Field25519 { zero - a }

  @inline(__always) static func wide(_ a: UInt64, _ b: UInt64) -> UInt128 {
    let (h, lo) = a.multipliedFullWidth(by: b)
    return UInt128(h) << 64 | UInt128(lo)
  }

  static func * (a: Field25519, b: Field25519) -> Field25519 {
    let a0 = a.l[0], a1 = a.l[1], a2 = a.l[2], a3 = a.l[3], a4 = a.l[4]
    let b0 = b.l[0], b1 = b.l[1], b2 = b.l[2], b3 = b.l[3], b4 = b.l[4]
    let b1_19 = b1 &* 19, b2_19 = b2 &* 19, b3_19 = b3 &* 19, b4_19 = b4 &* 19
    let c0 = wide(a0, b0) &+ wide(a1, b4_19) &+ wide(a2, b3_19) &+ wide(a3, b2_19) &+ wide(a4, b1_19)
    let c1 = wide(a0, b1) &+ wide(a1, b0) &+ wide(a2, b4_19) &+ wide(a3, b3_19) &+ wide(a4, b2_19)
    let c2 = wide(a0, b2) &+ wide(a1, b1) &+ wide(a2, b0) &+ wide(a3, b4_19) &+ wide(a4, b3_19)
    let c3 = wide(a0, b3) &+ wide(a1, b2) &+ wide(a2, b1) &+ wide(a3, b0) &+ wide(a4, b4_19)
    let c4 = wide(a0, b4) &+ wide(a1, b3) &+ wide(a2, b2) &+ wide(a3, b1) &+ wide(a4, b0)
    return reduce(c0, c1, c2, c3, c4)
  }

  /// Five 128-bit limb sums back to 51-bit limbs.
  @inline(__always) static func reduce(_ c0: UInt128, _ c1: UInt128, _ c2: UInt128, _ c3: UInt128, _ c4: UInt128)
    -> Field25519
  {
    let m = UInt128(mask51)
    var c1 = c1, c2 = c2, c3 = c3, c4 = c4
    c1 &+= c0 >> 51
    let r0 = UInt64(truncatingIfNeeded: c0 & m)
    c2 &+= c1 >> 51
    let r1 = UInt64(truncatingIfNeeded: c1 & m)
    c3 &+= c2 >> 51
    let r2 = UInt64(truncatingIfNeeded: c2 & m)
    c4 &+= c3 >> 51
    let r3 = UInt64(truncatingIfNeeded: c3 & m)
    let carry = UInt64(truncatingIfNeeded: c4 >> 51)
    let r4 = UInt64(truncatingIfNeeded: c4 & m)
    var out = Field25519(r0 &+ carry &* 19, r1, r2, r3, r4)
    out.l[1] &+= out.l[0] >> 51
    out.l[0] &= mask51
    return out
  }

  var squared: Field25519 { self * self }

  /// Times a small constant (X25519's a24, 121665).
  func times(_ k: UInt64) -> Field25519 {
    Field25519.reduce(Field25519.wide(l[0], k), Field25519.wide(l[1], k), Field25519.wide(l[2], k),
                      Field25519.wide(l[3], k), Field25519.wide(l[4], k))
  }

  /// self squared `n` times.
  func squared(_ n: Int) -> Field25519 {
    var t = self
    for _ in 0..<n { t = t.squared }
    return t
  }

  /// self^(2^250 - 1), and self^11 on the way: both p - 2 (the inverse)
  /// and (p - 5) / 8 (Ed25519's square root) end with it.
  func pow2_250_1() -> (Field25519, Field25519) {
    let z2 = squared
    let z9 = z2.squared(2) * self
    let z11 = z9 * z2
    let z2_5_0 = z11.squared * z9  // 2^5 - 1
    let z2_10_0 = z2_5_0.squared(5) * z2_5_0
    let z2_20_0 = z2_10_0.squared(10) * z2_10_0
    let z2_40_0 = z2_20_0.squared(20) * z2_20_0
    let z2_50_0 = z2_40_0.squared(10) * z2_10_0
    let z2_100_0 = z2_50_0.squared(50) * z2_50_0
    let z2_200_0 = z2_100_0.squared(100) * z2_100_0
    let z2_250_0 = z2_200_0.squared(50) * z2_50_0
    return (z2_250_0, z11)
  }

  /// The inverse, self^(p - 2) (0 for 0).
  var inverse: Field25519 {
    let (t, z11) = pow2_250_1()
    return t.squared(5) * z11  // 2^255 - 32 + 11 = p - 2
  }

  /// self^((p - 5) / 8) = self^(2^252 - 3), for square roots.
  var powP58: Field25519 {
    let (t, _) = pow2_250_1()
    return t.squared(2) * self
  }

  /// Swaps a and b if `bit` is 1, by a mask.
  static func swap(_ a: inout Field25519, _ b: inout Field25519, _ bit: UInt64) {
    let mask = 0 &- bit
    for i in 0..<5 {
      let x = mask & (a.l[i] ^ b.l[i])
      a.l[i] ^= x
      b.l[i] ^= x
    }
  }

  /// Whether it's zero mod p, and whether its reduced form is odd (RFC
  /// 8032's sign): from the bytes, with no early exit.
  var isZero: Bool {
    var acc: UInt8 = 0
    for b in bytes { acc |= b }
    return acc == 0
  }
  var isNegative: Bool { bytes[0] & 1 == 1 }

  /// Whether self and o are the same mod p.
  func equals(_ o: Field25519) -> Bool { (self - o).isZero }
}
