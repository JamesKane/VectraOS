// SPDX-License-Identifier: BSD-3-Clause

// PBKDF2 with HMAC-SHA-256 (RFC 8018 §5.2): ours, tier 0. SCRAM's Hi
// (RFC 5802) is PBKDF2 for one block. Block i of the key is
// U1 ^ U2 ^ ... ^ Uc, where U1 = HMAC(P, S || INT(i)) and
// Uj = HMAC(P, Uj-1); the key is the blocks concatenated, cut to its
// length. The password's HMAC keys are made once, not per iteration.

public enum PBKDF2 {
  /// `length` bytes derived from `password` and `salt` over `iterations`
  /// (at least 1).
  public static func sha256(password: [UInt8], salt: [UInt8], iterations: Int, length: Int) -> [UInt8] {
    precondition(iterations >= 1 && length >= 0)
    let keyed = HMACSHA256(key: password)
    var out: [UInt8] = []
    out.reserveCapacity(length)
    var i: UInt32 = 1
    while out.count < length {
      var h = keyed
      h.update(salt + [UInt8(i >> 24), UInt8(truncatingIfNeeded: i >> 16), UInt8(truncatingIfNeeded: i >> 8),
                       UInt8(truncatingIfNeeded: i)])
      var u = h.finalize()
      var t = u
      for _ in 1..<iterations {
        var next = keyed
        next.update(u)
        u = next.finalize()
        for k in 0..<t.count { t[k] ^= u[k] }
      }
      out += t.prefix(length - out.count)
      i += 1
    }
    return out
  }
}
