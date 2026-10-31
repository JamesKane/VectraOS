// SPDX-License-Identifier: BSD-3-Clause

// McCallum and Relyea's key exchange (Tang and Clevis's, 2017; D153 §3)
// over Edwards25519: a server holds s and S = sB, and a client gets back
// a secret it bound to S without the server learning it.
//
//     provision   c random; keeps C = cB, the secret K = cS; forgets c
//     ask         e random; sends X = C + eB, which is uniform: X says
//                 nothing of C
//     answer      the server sends sX
//     recover     K = sX - eS = scB
//
// The server's s is clamped as X25519's scalars are (RFC 7748 §5): a
// multiple of 8, so sX drops any small-order part of an X that a caller
// made up, and the answer tells nothing of s mod 8. The client's
// scalars are 64 random bytes mod L. Points travel in RFC 8032's
// encoding; a point that doesn't decode, and an answer that is the
// identity, are refused.

public enum McCallumRelyea {
  /// A server's private key from 32 random bytes.
  public static func privateKey(_ random: [UInt8]) -> [UInt8] {
    precondition(random.count == 32)
    var s = random
    s[0] &= 0xF8
    s[31] = s[31] & 0x7F | 0x40
    return s
  }

  /// S = sB.
  public static func publicKey(_ s: [UInt8]) -> [UInt8] { EdwardsPoint.base.times(s).bytes }

  /// sX, the server's answer to `request`; nil if X isn't a point, or is
  /// one of small order.
  public static func answer(_ request: [UInt8], key s: [UInt8]) -> [UInt8]? {
    guard request.count == 32, let x = EdwardsPoint(bytes: request) else { return nil }
    let y = x.times(s).bytes
    return y == EdwardsPoint.identity.bytes ? nil : y
  }

  /// A new binding to the server whose key is `publicKey`, from 64
  /// random bytes: (C, kept with the secret's use, and K, the secret).
  public static func provision(_ publicKey: [UInt8], random: [UInt8]) -> (point: [UInt8], secret: [UInt8])? {
    guard publicKey.count == 32, let server = EdwardsPoint(bytes: publicKey), random.count == 64 else { return nil }
    let c = Scalar25519.reduced(bytes: random)
    return (EdwardsPoint.base.times(c).bytes, server.times(c).bytes)
  }

  /// A request for the secret bound at `point` (C), from 64 random bytes:
  /// (X, to send, and e, to recover with).
  public static func ask(_ point: [UInt8], random: [UInt8]) -> (request: [UInt8], blinding: [UInt8])? {
    guard point.count == 32, let c = EdwardsPoint(bytes: point), random.count == 64 else { return nil }
    let e = Scalar25519.reduced(bytes: random)
    return ((c + EdwardsPoint.base.times(e)).bytes, e)
  }

  /// K from the server's `answer` to the request made with `blinding`
  /// (e): sX - eS.
  public static func recover(_ answer: [UInt8], blinding e: [UInt8], publicKey: [UInt8]) -> [UInt8]? {
    guard answer.count == 32, let y = EdwardsPoint(bytes: answer), publicKey.count == 32,
      let server = EdwardsPoint(bytes: publicKey)
    else { return nil }
    return (y + -server.times(e)).bytes
  }
}
