// SPDX-License-Identifier: BSD-3-Clause

// Integers modulo the group order L = 2^252 + 27742317777372353535851937790883648493
// (N1a), Ed25519's scalars (RFC 8032). Ours, tier 0.
//
// A scalar is little-endian 64-bit words. Products come from
// `multipliedFullWidth` (no library call; see Field25519), and a 512-bit
// value is reduced by Barrett's method (Handbook of Applied Cryptography,
// 14.42, base 2^64, k = 4) with mu = floor(2^512 / L), then two
// subtractions of L taken by mask. Loops run over fixed counts, so the
// work is the same for every secret.

enum Scalar25519 {
  /// L, 4 words.
  static let order: [UInt64] = [0x5812_631A_5CF5_D3ED, 0x14DE_F9DE_A2F7_9CD6, 0, 0x1000_0000_0000_0000]

  /// floor(2^512 / L), 5 words (crypto/tests checks it).
  static let mu: [UInt64] = [0xED9C_E5A3_0A2C_131B, 0x2106_215D_0863_29A7, 0xFFFF_FFFF_FFFF_FFEB, 0xFFFF_FFFF_FFFF_FFFF, 0xF]

  /// Little-endian bytes as words.
  static func words(_ b: [UInt8]) -> [UInt64] {
    var w = [UInt64](repeating: 0, count: b.count / 8)
    for i in 0..<w.count {
      for j in 0..<8 { w[i] |= UInt64(b[8 * i + j]) << UInt64(8 * j) }
    }
    return w
  }

  /// Words as little-endian bytes.
  static func bytes(_ w: [UInt64]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 8 * w.count)
    for i in 0..<w.count {
      for j in 0..<8 { out[8 * i + j] = UInt8(truncatingIfNeeded: w[i] >> UInt64(8 * j)) }
    }
    return out
  }

  /// a times b, truncated to `n` words.
  static func multiply(_ a: [UInt64], _ b: [UInt64], words n: Int) -> [UInt64] {
    var out = [UInt64](repeating: 0, count: n)
    for i in 0..<min(a.count, n) {
      var carry: UInt64 = 0
      for j in 0..<min(b.count, n - i) {
        let t = UInt128(out[i + j]) &+ Field25519.wide(a[i], b[j]) &+ UInt128(carry)
        out[i + j] = UInt64(truncatingIfNeeded: t)
        carry = UInt64(truncatingIfNeeded: t >> 64)
      }
      if i + b.count < n { out[i + b.count] = carry }
    }
    return out
  }

  /// a - b over a's words (b no longer), and the borrow out (0 or 1).
  static func subtract(_ a: [UInt64], _ b: [UInt64]) -> ([UInt64], UInt64) {
    var out = a
    var borrow: UInt64 = 0
    for i in 0..<a.count {
      let d = UInt128(a[i]) &- UInt128(i < b.count ? b[i] : 0) &- UInt128(borrow)
      out[i] = UInt64(truncatingIfNeeded: d)
      borrow = UInt64(truncatingIfNeeded: d >> 127)
    }
    return (out, borrow)
  }

  /// A 512-bit value (8 words) mod L, 4 words.
  static func reduced(_ x: [UInt64]) -> [UInt64] {
    precondition(x.count == 8)
    let q3 = Array(multiply(Array(x[3..<8]), mu, words: 10)[5..<10])
    var (r, _) = subtract(Array(x[0..<5]), multiply(q3, order, words: 5))
    // r < 3L now: take r - L where it doesn't borrow, twice.
    for _ in 0..<2 {
      let (t, borrow) = subtract(r, order)
      let keep = 0 &- borrow
      for i in 0..<5 { r[i] = (r[i] & keep) | (t[i] & ~keep) }
    }
    return Array(r[0..<4])
  }

  /// 64 bytes (a SHA-512 digest) mod L, as 32 bytes.
  static func reduced(bytes b: [UInt8]) -> [UInt8] { bytes(reduced(words(b))) }

  /// (a * b + c) mod L, each 32 bytes, as 32 bytes.
  static func mulAdd(_ a: [UInt8], _ b: [UInt8], _ c: [UInt8]) -> [UInt8] {
    var p = multiply(words(a), words(b), words: 8)
    var carry: UInt64 = 0
    let cw = words(c)
    for i in 0..<8 {
      let t = UInt128(p[i]) &+ UInt128(i < 4 ? cw[i] : 0) &+ UInt128(carry)
      p[i] = UInt64(truncatingIfNeeded: t)
      carry = UInt64(truncatingIfNeeded: t >> 64)
    }
    return bytes(reduced(p))
  }

  /// Whether 32 bytes are below L (a signature's S must be: RFC 8032
  /// §5.1.7). Public values only.
  static func isCanonical(_ b: [UInt8]) -> Bool { subtract(words(b), order).1 == 1 }
}
