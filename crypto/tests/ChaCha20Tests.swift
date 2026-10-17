// SPDX-License-Identifier: BSD-3-Clause

// ChaCha20, Poly1305, RFC 8439's AEAD and OpenSSH's chacha20-poly1305
// (N1a): RFC 8439's examples, every Wycheproof ChaCha20-Poly1305 case
// (data/wycheproof: valid and invalid tags, edge-case lengths), and
// 9front's libsec on random inputs, both nonce forms; OpenSSH's
// construction checked against one built from libsec's ChaCha20 and
// Poly1305 (PROTOCOL.chacha20poly1305).

import FoundationEssentials
import LibsecOracle
import TDCrypto
import Testing

@Test func chacha20sBlockIsRFC8439s() {
  // §2.3.2.
  let key = (0..<32).map { UInt8($0) }
  let block = ChaCha20.block(key: key, counter: 1, nonce: unhex("000000090000004a00000000"))
  #expect(hex(block) == "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4e"
    + "d2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e")
}

@Test func poly1305IsRFC8439s() {
  // §2.5.2.
  let key = unhex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
  let tag = Poly1305.authenticate(Array("Cryptographic Forum Research Group".utf8), key: key)
  #expect(hex(tag) == "a8061dc1305136c6c22b8baf0c0127a9")
}

struct AEADCase: Decodable {
  let tcId: Int
  let key: String
  let iv: String
  let aad: String
  let msg: String
  let ct: String
  let tag: String
  let result: String
}

@Test func chacha20Poly1305PassesWycheproof() throws {
  let data = try #require(FileManager.default.contents(atPath: repository + "/data/wycheproof/chacha20_poly1305_test.json"))
  let file = try JSONDecoder().decode(Wycheproof<AEADCase>.self, from: data)
  var valid = 0, invalid = 0
  for group in file.testGroups {
    for t in group.tests {
      let key = unhex(t.key), nonce = unhex(t.iv), aad = unhex(t.aad), msg = unhex(t.msg)
      let sealed = unhex(t.ct) + unhex(t.tag)
      // Only RFC 8439's sizes: a 32-byte key, a 12-byte nonce.
      guard key.count == 32, nonce.count == 12 else {
        #expect(t.result == "invalid", "case \(t.tcId)")
        continue
      }
      let opened = ChaCha20Poly1305.open(sealed, key: key, nonce: nonce, aad: aad)
      if t.result == "valid" {
        #expect(ChaCha20Poly1305.seal(msg, key: key, nonce: nonce, aad: aad) == sealed, "case \(t.tcId)")
        #expect(opened == msg, "case \(t.tcId)")
        valid += 1
      } else {
        #expect(opened == nil, "case \(t.tcId) opened")
        invalid += 1
      }
    }
  }
  #expect(valid > 100 && invalid > 50)
}

@Test func chacha20AndPoly1305MatchLibsec() {
  var g = SystemRandomNumberGenerator()
  func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) } }
  for _ in 0..<randomCases {
    let key = bytes(32), msg = bytes(Int.random(in: 0...600, using: &g))
    var out = [UInt8](repeating: 0, count: msg.count)
    // RFC 8439's form: the counter, then a 96-bit nonce.
    let counter = UInt32.random(in: 0...1000, using: &g), nonce = bytes(12)
    let iv12 = (0..<4).map { UInt8(truncatingIfNeeded: counter >> UInt32(8 * $0)) } + nonce
    #expect(libsec_chacha20(key, iv12, 12, msg, msg.count, &out) == 0)
    #expect(ChaCha20.xor(msg, key: key, nonce: nonce, counter: counter) == out)
    // The original form: a 64-bit counter, a 64-bit nonce.
    let counter64 = UInt64.random(in: 0...1000, using: &g), nonce8 = bytes(8)
    let iv8 = (0..<8).map { UInt8(truncatingIfNeeded: counter64 >> UInt64(8 * $0)) } + nonce8
    #expect(libsec_chacha20(key, iv8, 8, msg, msg.count, &out) == 0)
    #expect(ChaCha20.xor(msg, key: key, nonce8: nonce8, counter: counter64) == out)
    // Poly1305, whole and in pieces.
    var tag = [UInt8](repeating: 0, count: 16)
    #expect(libsec_poly1305(key, msg, msg.count, &tag) == 0)
    #expect(Poly1305.authenticate(msg, key: key) == tag)
    var p = Poly1305(key: key)
    var i = 0
    while i < msg.count {
      let n = min(msg.count - i, Int.random(in: 1...40, using: &g))
      p.update(Array(msg[i..<(i + n)]))
      i += n
    }
    #expect(p.finalize() == tag)
    // The AEAD.
    let aad = bytes(Int.random(in: 0...40, using: &g))
    var sealed = [UInt8](repeating: 0, count: msg.count + 16)
    #expect(libsec_chacha20_poly1305_seal(key, nonce, aad, aad.count, msg, msg.count, &sealed) == 0)
    #expect(ChaCha20Poly1305.seal(msg, key: key, nonce: nonce, aad: aad) == sealed)
    #expect(ChaCha20Poly1305.open(sealed, key: key, nonce: nonce, aad: aad) == msg)
  }
}

@Test func poly1305sTopValuesReduce() {
  // h near 2^130 - 5 and the all-ones key: the final reduction's both arms.
  for key in [[UInt8](repeating: 0xFF, count: 32), [UInt8](repeating: 0, count: 32),
              [UInt8](repeating: 0x0F, count: 16) + [UInt8](repeating: 0xFF, count: 16)]
  {
    for msg in [[UInt8](repeating: 0xFF, count: 16), [UInt8](repeating: 0xFF, count: 64), [0xFB] + [UInt8](repeating: 0xFF, count: 15)] {
      var tag = [UInt8](repeating: 0, count: 16)
      #expect(libsec_poly1305(key, msg, msg.count, &tag) == 0)
      #expect(Poly1305.authenticate(msg, key: key) == tag)
    }
  }
}

@Test func opensshsChaChaPolyIsItsConstruction() {
  var g = SystemRandomNumberGenerator()
  func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) } }
  for _ in 0..<50 {
    let key = bytes(64), seq = UInt32.random(in: 0...UInt32.max, using: &g)
    let packet = bytes(4 + 8 * Int.random(in: 1...40, using: &g))
    let sealed = OpenSSHChaChaPoly(key: key).seal(packet, seq: seq)
    // The same from libsec's pieces: the nonce the sequence number,
    // big-endian; K_1 (key[32...]) on the length at counter 0, K_2
    // (key[..<32]) from counter 1 on the rest, Poly1305's key K_2's block 0.
    let nonce = (0..<8).map { UInt8(truncatingIfNeeded: UInt64(seq) >> UInt64(56 - 8 * $0)) }
    func stream(_ k: [UInt8], _ counter: UInt64, _ data: [UInt8]) -> [UInt8] {
      var out = [UInt8](repeating: 0, count: data.count)
      let iv = (0..<8).map { UInt8(truncatingIfNeeded: counter >> UInt64(8 * $0)) } + nonce
      _ = libsec_chacha20(k, iv, 8, data, data.count, &out)
      return out
    }
    let k2 = Array(key[0..<32]), k1 = Array(key[32..<64])
    let body = stream(k1, 0, Array(packet[0..<4])) + stream(k2, 1, Array(packet[4...]))
    var tag = [UInt8](repeating: 0, count: 16)
    _ = libsec_poly1305(stream(k2, 0, [UInt8](repeating: 0, count: 32)), body, body.count, &tag)
    #expect(sealed == body + tag)
    let box = OpenSSHChaChaPoly(key: key)
    #expect(box.open(sealed, seq: seq) == packet)
    #expect(box.length(Array(sealed[0..<4]), seq: seq) == Array(packet[0..<4]))
    // Anything changed, or another sequence number: refused.
    var bad = sealed
    bad[Int.random(in: 0..<bad.count, using: &g)] ^= 1
    #expect(box.open(bad, seq: seq) == nil)
    #expect(box.open(sealed, seq: seq &+ 1) == nil)
  }
}
