// SPDX-License-Identifier: BSD-3-Clause

// proto=noise-ik: two factotums run Noise IK through their apps, which
// pass the messages and get sessions that talk to each other; factotum
// against Noise's own handshake; the node's key made once, from the
// randomness, and listed with its secret hidden; a wrong responder key,
// and a pattern outside the app's scope, refused.

@testable import Factotum
@testable import Noise
import Testing

/// A factotum whose randomness counts up from `seed`.
func noiseFactotum(_ seed: UInt8) -> Factotum {
  var n = seed
  return Factotum(nonce: { "" }) { count in
    n &+= 1
    return Array(repeating: n, count: count)
  }
}

let pattern = try! KeyPattern("proto=noise-ik")
let prologue = Array("9gate".utf8)

func step(_ s: AuthSession) throws -> Step { try s.next() }

/// The responder's and initiator's results, run through their sessions.
func handshake(_ responder: Factotum, _ initiator: Factotum, remote: [UInt8]? = nil) throws
  -> (AuthResult, AuthResult)
{
  let r = try responder.start(pattern, role: .server, app: "9gate", scope: [pattern])
  let i = try initiator.start(pattern, role: .client, app: "9gate", scope: [pattern])
  let serverKey = try remote ?? responder.publicKey(pattern, app: "9gate", scope: [])
  #expect(try step(r) == .need)
  try r.feed(prologue)
  #expect(try step(i) == .need)
  try i.feed(serverKey + prologue)
  guard case .send(let first) = try step(i) else { throw AuthFailure.order }
  #expect(try step(i) == .need)
  #expect(try step(r) == .need)
  try r.feed(first)
  guard case .done(let rr) = try step(r) else { throw AuthFailure.order }
  try i.feed(rr.bytes)
  guard case .done(let ir) = try step(i) else { throw AuthFailure.order }
  return (rr, ir)
}

@Test func twoFactotumsMakeASession() throws {
  let a = noiseFactotum(10), b = noiseFactotum(20)
  let (rr, ir) = try handshake(a, b)
  let aKey = try a.publicKey(pattern, app: "9gate", scope: []), bKey = try b.publicKey(pattern, app: "9gate", scope: [])
  #expect(rr.user == hex(aKey) && rr.peer == hex(bKey))
  #expect(ir.user == hex(bKey) && ir.peer == hex(aKey))
  var server = try #require(Session(secret: rr.secret)), client = try #require(Session(secret: ir.secret))
  #expect(server.hash == client.hash)
  let s1 = client.seal(Array("hello".utf8))
  let opened = server.open(try #require(s1))
  #expect(opened == Array("hello".utf8))
  let s2 = server.seal(Array("back".utf8))
  let returned = client.open(try #require(s2))
  #expect(returned == Array("back".utf8))
  // The key was made once, and is listed with its secret hidden.
  #expect(a.store.listing == "key proto=noise-ik !private?\n")
  _ = try handshake(a, b)
  #expect(a.store.keys.count == 1 && b.store.keys.count == 1)
}

@Test func factotumSpeaksNoiseIKAsTheLibraryDoes() throws {
  // factotum responding to Noise's own initiator.
  let a = noiseFactotum(30)
  let caller = StaticKey(privateKey: Array(repeating: 5, count: 32))
  var h = Handshake(initiator: caller, remote: try a.publicKey(pattern, app: "x", scope: []),
                    ephemeral: Array(repeating: 6, count: 32), prologue: prologue)
  let r = try a.start(pattern, role: .server, app: "x", scope: [])
  _ = try r.next()
  try r.feed(prologue)
  _ = try r.next()
  let first = h.write()
  try r.feed(try #require(first))
  guard case .done(let result) = try r.next() else { throw AuthFailure.order }
  #expect(result.peer == hex(caller.publicKey))
  let read = h.read(result.bytes)
  #expect(read != nil)
  let split = h.split()
  var mine = try #require(split), theirs = try #require(Session(secret: result.secret))
  let m = mine.seal([1, 2, 3])
  let opened = theirs.open(try #require(m))
  #expect(opened == [1, 2, 3])
}

@Test func noiseIKRefusesTheWrongKeyAndTheWrongScope() throws {
  let a = noiseFactotum(40), b = noiseFactotum(50)
  let stranger = StaticKey(privateKey: Array(repeating: 9, count: 32)).publicKey
  #expect(throws: AuthFailure.self) { _ = try handshake(a, b, remote: stranger) }
  let signing = try KeyPattern("proto=ed25519")
  #expect(throws: AuthFailure.notAllowed) { _ = try a.start(pattern, role: .server, app: "x", scope: [signing]) }
  #expect(throws: AuthFailure.notAllowed) { _ = try a.publicKey(pattern, app: "x", scope: [signing]) }
  // Without randomness factotum makes no key.
  #expect(throws: AuthFailure.noKey) { _ = try Factotum(nonce: { "" }).publicKey(pattern, app: "x", scope: []) }
}
