// SPDX-License-Identifier: BSD-3-Clause

// Noise IK: every `Noise_IK_25519_ChaChaPoly_SHA256` vector in
// cacophony's and snow's files (data/noise), replayed through both
// sides; then handshakes between random keys, and the ways one must
// fail (the wrong responder key, a changed byte, a message out of turn,
// a replayed transport message), and the stream's framing.

import FoundationEssentials
@testable import Noise
import Testing

let repository: String = {
  var dir = #filePath
  for _ in 0..<4 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }
  return dir
}()

func unhex(_ s: some StringProtocol) -> [UInt8] {
  let b = Array(s.utf8)
  func v(_ c: UInt8) -> UInt8 { c <= 0x39 ? c - 0x30 : (c | 0x20) - 0x57 }
  return stride(from: 0, to: b.count - 1, by: 2).map { v(b[$0]) << 4 | v(b[$0 + 1]) }
}

func hex(_ b: [UInt8]) -> String {
  let digits = Array("0123456789abcdef".utf8)
  var out: [UInt8] = []
  for x in b { out += [digits[Int(x >> 4)], digits[Int(x & 15)]] }
  return String(decoding: out, as: UTF8.self)
}

/// splitmix64: the tests' random inputs, the same each run.
struct Seeded: RandomNumberGenerator {
  var state: UInt64
  init(_ seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9e37_79b9_7f4a_7c15
    var z = state
    z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
    z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
    return z ^ (z >> 31)
  }
  mutating func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8.random(in: 0...255, using: &self) } }
}

struct VectorFile: Decodable { let vectors: [Vector] }
struct Vector: Decodable {
  struct Step: Decodable {
    let payload: String
    let ciphertext: String
  }
  let protocol_name: String
  let init_prologue: String
  let init_static: String?
  let init_ephemeral: String
  let init_remote_static: String?
  let init_psks: [String]?
  let resp_prologue: String
  let resp_static: String?
  let resp_ephemeral: String?
  let resp_psks: [String]?
  let handshake_hash: String?
  let messages: [Step]
}

func vectors(_ file: String) throws -> [Vector] {
  let data = try #require(FileManager.default.contents(atPath: repository + "/data/noise/" + file))
  return try JSONDecoder().decode(VectorFile.self, from: data).vectors.filter {
    $0.protocol_name == Noise.protocolName && ($0.init_psks ?? []).isEmpty
  }
}

@Test(arguments: ["cacophony.txt", "snow.txt"])
func noiseReplaysTheVectors(_ file: String) throws {
  let all = try vectors(file)
  #expect(all.count >= 1)
  for v in all {
    let initiatorKey = StaticKey(privateKey: unhex(try #require(v.init_static)))
    let responderKey = StaticKey(privateKey: unhex(try #require(v.resp_static)))
    #expect(hex(responderKey.publicKey) == v.init_remote_static)
    var i = Handshake(initiator: initiatorKey, remote: responderKey.publicKey, ephemeral: unhex(v.init_ephemeral),
                      prologue: unhex(v.init_prologue))
    var r = Handshake(responder: responderKey, ephemeral: unhex(try #require(v.resp_ephemeral)),
                      prologue: unhex(v.resp_prologue))
    let wrote = i.write(unhex(v.messages[0].payload))
    let first = try #require(wrote)
    #expect(hex(first) == v.messages[0].ciphertext)
    let read = r.read(first)
    #expect(read.map(hex) == v.messages[0].payload)
    #expect(r.remoteStatic == initiatorKey.publicKey)
    let answered = r.write(unhex(v.messages[1].payload))
    let second = try #require(answered)
    #expect(hex(second) == v.messages[1].ciphertext)
    let reply = i.read(second)
    #expect(reply.map(hex) == v.messages[1].payload)
    if let h = v.handshake_hash {
      #expect(hex(i.hash) == h)
      #expect(hex(r.hash) == h)
    }
    let sa = i.split(), sb = r.split()
    var a = try #require(sa), b = try #require(sb)
    let again = i.split()
    #expect(again == nil)  // given once
    // The initiator sends the even messages, the responder the odd.
    for (n, step) in v.messages.enumerated().dropFirst(2) {
      let sealed = n % 2 == 0 ? a.seal(unhex(step.payload)) : b.seal(unhex(step.payload))
      #expect(sealed.map(hex) == step.ciphertext, "\(file) message \(n)")
      let message = try #require(sealed)
      let opened = n % 2 == 0 ? b.open(message) : a.open(message)
      #expect(opened.map(hex) == step.payload, "\(file) message \(n)")
    }
  }
}

/// Two sides' handshake over random keys, its messages passed through
/// `tamper` on the way.
func handshake(_ rng: inout Seeded, payloads: ([UInt8], [UInt8]) = ([], []),
               tamper: (Int, inout [UInt8]) -> Void = { _, _ in })
  -> (Handshake<StaticKey>, Handshake<StaticKey>, [UInt8]?, [UInt8]?) {
  let ik = StaticKey(privateKey: rng.bytes(32)), rk = StaticKey(privateKey: rng.bytes(32))
  var i = Handshake(initiator: ik, remote: rk.publicKey, ephemeral: rng.bytes(32), prologue: Array("9gate".utf8))
  var r = Handshake(responder: rk, ephemeral: rng.bytes(32), prologue: Array("9gate".utf8))
  guard var m1 = i.write(payloads.0) else { return (i, r, nil, nil) }
  tamper(0, &m1)
  let p1 = r.read(m1)
  guard var m2 = r.write(payloads.1) else { return (i, r, p1, nil) }
  tamper(1, &m2)
  let p2 = i.read(m2)
  return (i, r, p1, p2)
}

@Test func noiseHandshakesBetweenRandomKeys() throws {
  var rng = Seeded(1)
  for _ in 0..<20 {
    let p = (rng.bytes(Int.random(in: 0...64, using: &rng)), rng.bytes(Int.random(in: 0...64, using: &rng)))
    var (i, r, p1, p2) = handshake(&rng, payloads: p)
    #expect(p1 == p.0 && p2 == p.1)
    #expect(i.complete && r.complete && i.hash == r.hash)
    let sa = i.split(), sb = r.split()
    var a = try #require(sa), b = try #require(sb)
    for n in 0..<10 {
      let m = rng.bytes(Int.random(in: 0...2000, using: &rng))
      if n % 3 == 0 {
        let s = b.seal(m)
        let sealed = try #require(s)
        let own = b.open(sealed), theirs = a.open(sealed)
        #expect(own == nil)  // its own message isn't the peer's
        #expect(theirs == m)
      } else {
        let s = a.seal(m)
        let opened = b.open(try #require(s))
        #expect(opened == m)
      }
    }
  }
}

@Test func noiseRefusesTheWrongResponder() {
  var rng = Seeded(2)
  let ik = StaticKey(privateKey: rng.bytes(32)), rk = StaticKey(privateKey: rng.bytes(32))
  let other = StaticKey(privateKey: rng.bytes(32))
  var i = Handshake(initiator: ik, remote: other.publicKey, ephemeral: rng.bytes(32))
  var r = Handshake(responder: rk, ephemeral: rng.bytes(32))
  let m1 = i.write()!
  #expect(r.read(m1) == nil)
  #expect(r.remoteStatic == nil)
  #expect(r.write() == nil)
  #expect(r.split() == nil)
}

@Test func noiseRefusesAnyChangedByte() {
  var rng = Seeded(3)
  // Message 1 is e (32), s sealed (48), and an empty payload's tag (16);
  // message 2 is e and the tag. Every byte is covered.
  for (which, size) in [(0, 96), (1, 48)] {
    for at in 0..<size {
      var (i, r, p1, p2) = handshake(&rng) { n, m in if n == which { m[at] ^= 0x01 } }
      if which == 0 {
        #expect(p1 == nil, "message 1 byte \(at)")
      } else {
        #expect(p1 == [] && p2 == nil, "message 2 byte \(at)")
      }
      let sa = i.split(), sb = r.split()
      #expect(sa == nil || sb == nil)
    }
  }
  // Short, long, and empty messages.
  for cut in [0, 31, 32, 95] {
    let (_, _, p1, _) = handshake(&rng) { n, m in if n == 0 { m = Array(m.prefix(cut)) } }
    #expect(p1 == nil, "message 1 cut to \(cut)")
  }
  let (_, _, p1, _) = handshake(&rng) { n, m in if n == 0 { m += [0] } }
  #expect(p1 == nil)
}

@Test func noiseKeepsTurns() {
  var rng = Seeded(4)
  let ik = StaticKey(privateKey: rng.bytes(32)), rk = StaticKey(privateKey: rng.bytes(32))
  var i = Handshake(initiator: ik, remote: rk.publicKey, ephemeral: rng.bytes(32))
  var r = Handshake(responder: rk, ephemeral: rng.bytes(32))
  #expect(r.write() == nil)  // the responder can't speak first
  var i2 = Handshake(initiator: ik, remote: rk.publicKey, ephemeral: rng.bytes(32))
  #expect(i2.read(Array(repeating: 1, count: 48)) == nil)  // nor the initiator read first
  let m1 = i.write()!
  #expect(i.write() == nil)  // and it can't write twice
  #expect(i.split() == nil)
  // A refused write ends the handshake, as any failure does.
  #expect(r.read(m1) == nil)
  var fresh = Handshake(responder: rk, ephemeral: rng.bytes(32))
  #expect(fresh.read(m1) != nil)
}

@Test func noiseRefusesReplayAndReorder() throws {
  var rng = Seeded(5)
  var (i, r, _, _) = handshake(&rng)
  let sa = i.split(), sb = r.split()
  var a = try #require(sa), b = try #require(sb)
  let s0 = a.seal([1]), s1 = a.seal([2])
  let m0 = try #require(s0), m1 = try #require(s1)
  let early = b.open(m1), first = b.open(m0), again = b.open(m0), second = b.open(m1)
  #expect(early == nil)  // out of order
  #expect(first == [1])
  #expect(again == nil)
  #expect(second == [2])
  let full = a.seal(Array(repeating: 0, count: Noise.maxPayload))
  let over = a.seal(Array(repeating: 0, count: Noise.maxPayload + 1))
  #expect(full != nil && over == nil)
  var spent = a
  spent.send.n = .max
  let none = spent.seal([1])
  #expect(none == nil)
}

@Test func framesComeOutWholeHoweverTheBytesArrive() {
  var rng = Seeded(6)
  var messages: [[UInt8]] = [[], Array(repeating: 7, count: Noise.maxMessage)]
  for _ in 0..<50 { messages.append(rng.bytes(Int.random(in: 0...3000, using: &rng))) }
  let stream = messages.flatMap(Frame.wrap)
  var d = Deframer()
  var got: [[UInt8]] = []
  var at = 0
  while at < stream.count {
    let n = min(stream.count - at, Int.random(in: 1...5000, using: &rng))
    d.push(Array(stream[at..<at + n]))
    at += n
    while let m = d.next() { got.append(m) }
  }
  #expect(got == messages)
  #expect(d.next() == nil)
}
