// SPDX-License-Identifier: BSD-3-Clause

// proto=mcr (D153 §3): factotum answers McCallum-Relyea requests with a
// key no app holds, the swarm member's half of unlocking another node's
// volume (crypto/lib/McCallumRelyea.swift). A server-role session:
//
//     next() -> send(public key, 32 bytes)
//     next() -> need          feed(the request, a point)
//     next() -> send(the answer, a point)
//     next() -> done
//
// The key is `key proto=mcr !private=BASE64` (a clamped scalar, 32
// bytes). When none matches, factotum makes one from its randomness, as
// it makes the node's noise-ik key, and the service keeps both on the
// volume (lib/factotum/node).

import TDCrypto

struct Unlocker {
  enum Phase { case key, request, answer([UInt8]), finished }
  let key: [UInt8]
  var phase = Phase.key

  mutating func next() -> MachineStep {
    switch phase {
    case .key:
      phase = .request
      return .send(McCallumRelyea.publicKey(key))
    case .request: return .need
    case .answer(let a):
      phase = .finished
      return .send(a)
    case .finished: return .done(AuthResult(user: "", peer: "", secret: []))
    }
  }

  mutating func feed(_ message: [UInt8]) throws(AuthFailure) {
    guard case .request = phase else { throw .order }
    guard let a = McCallumRelyea.answer(message, key: key) else { throw .peer("not a point of the group") }
    phase = .answer(a)
  }
}

extension Factotum {
  /// The mcr key for `pattern`: the first matching, else a new one (when
  /// factotum has randomness).
  func unlockKey(_ pattern: KeyPattern) throws(AuthFailure) -> [UInt8] {
    if let k = store.matching(pattern).first {
      guard let s = k["private"].flatMap({ Base64.decode($0) }), s.count == 32 else { throw .noKey }
      return s
    }
    guard let random else { throw .noKey }
    let r = random(32)
    guard r.count == 32 else { throw .noKey }
    let s = McCallumRelyea.privateKey(r)
    var attributes: [KeyAttribute] = []
    for t in pattern.terms {
      if let v = t.value { attributes.append(KeyAttribute(t.name, v)) }
    }
    attributes.append(KeyAttribute("private", Base64.encode(s), secret: true))
    store.add(Key(attributes))
    return s
  }
}
