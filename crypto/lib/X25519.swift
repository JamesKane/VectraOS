// SPDX-License-Identifier: BSD-3-Clause

// X25519 (RFC 7748 §5): ours, tier 0. SSH's curve25519-sha256 key
// exchange (RFC 8731) is it (N1a).
//
// The Montgomery ladder over every bit of the clamped scalar, the
// points' x and z swapped by mask each step, so its time and memory
// accesses are the same for every key; the result is x / z, fully
// reduced. A peer's point is taken as its 32 bytes say (the top bit
// ignored, non-canonical values reduced), as the RFC asks; a result of
// all zeros (a small-order point) is the caller's to refuse, as RFC 8731
// §3 says SSH does.

public enum X25519 {
  public static let keySize = 32

  /// The base point's u, 9.
  public static let basePoint: [UInt8] = [9] + [UInt8](repeating: 0, count: 31)

  /// `scalar` (32 bytes, clamped here) times the point `u` (32 bytes).
  public static func scalarMult(_ scalar: [UInt8], _ u: [UInt8]) -> [UInt8] {
    precondition(scalar.count == 32 && u.count == 32)
    var k = scalar
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    let x1 = Field25519(bytes: u.span)
    var x2 = Field25519.one, z2 = Field25519.zero
    var x3 = x1, z3 = Field25519.one
    var swap: UInt64 = 0
    for t in stride(from: 254, through: 0, by: -1) {
      let bit = UInt64(k[t >> 3] >> UInt8(t & 7)) & 1
      swap ^= bit
      Field25519.swap(&x2, &x3, swap)
      Field25519.swap(&z2, &z3, swap)
      swap = bit
      let a = x2 + z2, aa = a.squared
      let b = x2 - z2, bb = b.squared
      let e = aa - bb
      let c = x3 + z3, d = x3 - z3
      let da = d * a, cb = c * b
      x3 = (da + cb).squared
      z3 = x1 * (da - cb).squared
      x2 = aa * bb
      z2 = e * (aa + e.times(121_665))
    }
    Field25519.swap(&x2, &x3, swap)
    Field25519.swap(&z2, &z3, swap)
    return (x2 * z2.inverse).bytes
  }

  /// The public key for a 32-byte private key.
  public static func publicKey(_ privateKey: [UInt8]) -> [UInt8] { scalarMult(privateKey, basePoint) }

  /// The shared secret with a peer's public key, or nil if it's all zeros
  /// (the peer's point had small order: RFC 7748 §6.1, RFC 8731 §3).
  public static func sharedSecret(_ privateKey: [UInt8], _ peer: [UInt8]) -> [UInt8]? {
    let s = scalarMult(privateKey, peer)
    var acc: UInt8 = 0
    for b in s { acc |= b }
    return acc == 0 ? nil : s
  }
}
