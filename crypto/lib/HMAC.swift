// SPDX-License-Identifier: BSD-3-Clause

// HMAC-SHA-256 (RFC 2104, FIPS 198-1): ours, tier 0. A key longer than a
// block is hashed first; the key, padded with zeros to a block, is XORed
// with 0x36 for the inner hash and 0x5c for the outer:
// H(K ^ opad || H(K ^ ipad || message)). Tags are compared in constant
// time (`constantTimeEqual`): a verifier mustn't say how much matched.

public struct HMACSHA256 {
  var inner: SHA256
  var outer: SHA256

  public init(key: [UInt8]) {
    var k = key.count > SHA256.blockSize ? SHA256.hash(key) : key
    k += [UInt8](repeating: 0, count: SHA256.blockSize - k.count)
    inner = SHA256()
    inner.update(k.map { $0 ^ 0x36 })
    outer = SHA256()
    outer.update(k.map { $0 ^ 0x5C })
  }

  /// Adds `input` to the message.
  public mutating func update(_ input: [UInt8]) { inner.update(input) }

  /// The 32-byte tag of the message so far.
  public func finalize() -> [UInt8] {
    var o = outer
    o.update(inner.finalize())
    return o.finalize()
  }

  /// The tag of `message` under `key`.
  public static func authenticate(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
    var h = HMACSHA256(key: key)
    h.update(message)
    return h.finalize()
  }
}

/// Whether `a` and `b` are equal, in time that depends only on their
/// lengths (tags, proofs, signatures: never compare secrets with `==`).
public func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
  guard a.count == b.count else { return false }
  var d: UInt8 = 0
  for i in 0..<a.count { d |= a[i] ^ b[i] }
  return d == 0
}
