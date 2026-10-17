// SPDX-License-Identifier: BSD-3-Clause

// proto=ed25519 (N1c): the keyring signs with a key no app holds, as
// sshd's host key. A server-role session:
//
//     next() -> send(public key, 32 bytes)
//     next() -> need          feed(the bytes to sign)
//     next() -> send(signature, 64 bytes)
//     next() -> done
//
// The key is `key proto=ed25519 ... !seed=BASE64` (RFC 8032's 32-byte
// private key). When none matches, the keyring makes one from its
// randomness with the pattern's attributes, so a host key exists from
// the first connection on (until the keybag, it lasts as long as the
// keyring runs).

import TDCrypto

struct Signer {
  enum Phase { case key, data, signature([UInt8]), finished }
  let seed: [UInt8]
  let peer: String
  var phase = Phase.key

  mutating func next() -> MachineStep {
    switch phase {
    case .key:
      phase = .data
      return .send(Ed25519.publicKey(seed: seed))
    case .data: return .need
    case .signature(let s):
      phase = .finished
      return .send(s)
    case .finished: return .done(AuthResult(user: "", peer: peer, secret: []))
    }
  }

  mutating func feed(_ message: [UInt8]) throws(AuthFailure) {
    guard case .data = phase else { throw .order }
    phase = .signature(Ed25519.sign(message, seed: seed))
  }
}

extension Keyring {
  /// The signing key for `pattern`: the first matching, else a new one
  /// (when the keyring has randomness).
  func signingKey(_ pattern: KeyPattern) throws(AuthFailure) -> [UInt8] {
    if let k = store.matching(pattern).first {
      guard let seed = k["seed"].flatMap({ Base64.decode($0) }), seed.count == 32 else { throw .noKey }
      return seed
    }
    guard let random else { throw .noKey }
    let seed = random(32)
    guard seed.count == 32 else { throw .noKey }
    var attributes: [KeyAttribute] = []
    for t in pattern.terms {
      if let v = t.value { attributes.append(KeyAttribute(t.name, v)) }
    }
    attributes.append(KeyAttribute("seed", Base64.encode(seed), secret: true))
    store.add(Key(attributes))
    return seed
  }
}
