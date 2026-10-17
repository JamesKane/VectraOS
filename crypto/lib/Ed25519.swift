// SPDX-License-Identifier: BSD-3-Clause

// Ed25519 (RFC 8032 §5.1): ours, tier 0. SSH's host and user keys
// (ssh-ed25519, RFC 8709) are it (N1a); the keyring signs with it (N1c).
//
// A private key is its 32-byte seed. Signing takes the same time for
// every seed and message length. Verifying is RFC 8032 §5.1.7's
// cofactorless check, as OpenSSL and OpenSSH do it: S must be below L,
// A must decode, and [S]B - [k]A must encode to R's bytes exactly (so a
// non-canonical R never verifies).

public enum Ed25519 {
  public static let seedSize = 32
  public static let publicKeySize = 32
  public static let signatureSize = 64

  /// The seed's hash: the clamped scalar s and the prefix that makes r.
  static func expand(_ seed: [UInt8]) -> (scalar: [UInt8], prefix: [UInt8]) {
    precondition(seed.count == 32)
    let h = SHA512.hash(seed)
    var s = Array(h[0..<32])
    s[0] &= 248
    s[31] &= 127
    s[31] |= 64
    return (s, Array(h[32..<64]))
  }

  /// SHA-512 of the parts, mod L.
  static func hashToScalar(_ parts: [UInt8]...) -> [UInt8] {
    var h = SHA512()
    for p in parts { h.update(p) }
    return Scalar25519.reduced(bytes: h.finalize())
  }

  /// The public key for a 32-byte seed.
  public static func publicKey(seed: [UInt8]) -> [UInt8] { EdwardsPoint.base.times(expand(seed).scalar).bytes }

  /// The 64-byte signature of `message` by the seed's key.
  public static func sign(_ message: [UInt8], seed: [UInt8]) -> [UInt8] {
    let (s, prefix) = expand(seed)
    let a = EdwardsPoint.base.times(s).bytes
    let r = hashToScalar(prefix, message)
    let rr = EdwardsPoint.base.times(r).bytes
    let k = hashToScalar(rr, a, message)
    return rr + Scalar25519.mulAdd(k, s, r)
  }

  /// Whether `signature` is `publicKey`'s on `message`.
  public static func verify(_ signature: [UInt8], of message: [UInt8], publicKey: [UInt8]) -> Bool {
    guard signature.count == 64 && publicKey.count == 32 else { return false }
    let rr = Array(signature[0..<32]), s = Array(signature[32..<64])
    guard Scalar25519.isCanonical(s), let a = EdwardsPoint(bytes: publicKey) else { return false }
    let k = hashToScalar(rr, publicKey, message)
    return (EdwardsPoint.base.times(s) + (-a).times(k)).bytes == rr
  }
}
