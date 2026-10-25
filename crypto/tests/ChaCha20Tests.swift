// SPDX-License-Identifier: BSD-3-Clause

// ChaCha20, Poly1305 and RFC 8439's AEAD (N1a): RFC 8439's examples,
// every Wycheproof ChaCha20-Poly1305 case (data/wycheproof: valid and
// invalid tags, edge-case lengths), and 9front's libsec on random inputs.

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
