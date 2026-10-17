// SPDX-License-Identifier: BSD-3-Clause

// proto=noise-ik (D75, D77): factotum runs Noise IK's handshake
// (noise(2)) with the node's static key, which no app holds; the app
// passes the messages and gets the session's keys. Each role's first
// message from the app is the handshake's parameters, not the peer's:
//
//     responder: need  feed(the prologue)
//                need  feed(the caller's first message)
//                done  peer: the caller's public key, in hex; bytes: the
//                      reply, which the app sends only if it accepts the
//                      caller; secret: the session (Session(secret:))
//     initiator: need  feed(the responder's public key, 32 bytes, then
//                      the prologue)
//                send  the first message
//                need  feed(the reply)
//                done  peer: the responder's key; secret: the session
//
// `user` is this node's public key, in hex. The key is `key
// proto=noise-ik !private=BASE64` (X25519's 32 bytes); when none
// matches, factotum makes one from its randomness with the pattern's
// attributes, so the node has an identity from first use. Ephemeral
// keys come from the same randomness.

import Noise

struct NoiseMachine {
  enum Phase {
    case parameters
    case first
    case reply
    case finished(AuthResult)
    case spent
  }

  let key: StaticKey
  let initiator: Bool
  let random: (Int) -> [UInt8]
  var handshake: Handshake<StaticKey>?
  var phase = Phase.parameters
  var outgoing: [UInt8]?

  init(privateKey: [UInt8], initiator: Bool, random: @escaping (Int) -> [UInt8]) {
    key = StaticKey(privateKey: privateKey)
    self.initiator = initiator
    self.random = random
  }

  mutating func next() -> MachineStep {
    if let m = outgoing {
      outgoing = nil
      return .send(m)
    }
    switch phase {
    case .parameters, .first, .reply: return .need
    case .finished(let r):
      phase = .spent
      return .done(r)
    case .spent: return .need
    }
  }

  mutating func feed(_ message: [UInt8]) throws(AuthFailure) {
    switch phase {
    case .parameters:
      if initiator {
        guard message.count >= Noise.keySize else { throw .peer("no responder key") }
        var h = Handshake(initiator: key, remote: Array(message.prefix(Noise.keySize)), ephemeral: random(32),
                          prologue: Array(message.dropFirst(Noise.keySize)))
        guard let first = h.write() else { throw .peer("the handshake failed") }
        handshake = h
        outgoing = first
        phase = .reply
      } else {
        handshake = Handshake(responder: key, ephemeral: random(32), prologue: message)
        phase = .first
      }
    case .first:
      guard var h = handshake, h.read(message) != nil, let caller = h.remoteStatic, let reply = h.write(),
            let session = h.split()
      else { throw .peer("the handshake failed") }
      handshake = nil
      phase = .finished(AuthResult(user: hex(key.publicKey), peer: hex(caller), secret: session.secret, bytes: reply))
    case .reply:
      guard var h = handshake, h.read(message) != nil, let remote = h.remoteStatic, let session = h.split()
      else { throw .peer("the handshake failed") }
      handshake = nil
      phase = .finished(AuthResult(user: hex(key.publicKey), peer: hex(remote), secret: session.secret))
    case .finished, .spent:
      throw .order
    }
  }
}

extension Factotum {
  /// The noise-ik key for `pattern`: the first matching, else a new one
  /// (when factotum has randomness).
  func noiseKey(_ pattern: KeyPattern) throws(AuthFailure) -> [UInt8] {
    if let k = store.matching(pattern).first {
      guard let p = k["private"].flatMap({ Base64.decode($0) }), p.count == Noise.keySize else { throw .noKey }
      return p
    }
    guard let random else { throw .noKey }
    let p = random(Noise.keySize)
    guard p.count == Noise.keySize else { throw .noKey }
    var attributes: [KeyAttribute] = []
    for t in pattern.terms {
      if let v = t.value { attributes.append(KeyAttribute(t.name, v)) }
    }
    attributes.append(KeyAttribute("private", Base64.encode(p), secret: true))
    store.add(Key(attributes))
    return p
  }
}

/// Lowercase hex.
func hex(_ bytes: [UInt8]) -> String {
  let digits = Array("0123456789abcdef".utf8)
  var out: [UInt8] = []
  for b in bytes { out += [digits[Int(b >> 4)], digits[Int(b & 15)]] }
  return String(decoding: out, as: UTF8.self)
}
