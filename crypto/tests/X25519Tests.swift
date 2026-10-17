// SPDX-License-Identifier: BSD-3-Clause

// X25519 and its field (N1a): RFC 7748's examples (a scalar product, the
// iterated test to 1000, §6.1's exchange), every Wycheproof X25519 case
// (data/wycheproof: twist points, non-canonical values, small orders),
// the host's OpenSSL on random keys, and the field's arithmetic checked
// directly (inverses, and the bytes of values around p).

import FoundationEssentials
import OpenSSLOracle
@testable import TDCrypto
import Testing

@Test func x25519IsRFC7748s() {
  // §5.2's first vector.
  #expect(hex(X25519.scalarMult(unhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
                                unhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")))
    == "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
  // §5.2's iteration: k = u = 9; each step k, u = X25519(k, u), k.
  var k = X25519.basePoint, u = X25519.basePoint
  for i in 1...1000 {
    let next = X25519.scalarMult(k, u)
    u = k
    k = next
    if i == 1 { #expect(hex(k) == "422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079") }
  }
  #expect(hex(k) == "684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51")
  // §6.1: Alice and Bob.
  let a = unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
  let b = unhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
  #expect(hex(X25519.publicKey(a)) == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
  #expect(hex(X25519.publicKey(b)) == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
  let shared = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
  #expect(X25519.sharedSecret(a, X25519.publicKey(b)).map(hex) == shared)
  #expect(X25519.sharedSecret(b, X25519.publicKey(a)).map(hex) == shared)
}

struct X25519Case: Decodable {
  let tcId: Int
  let `public`: String
  let `private`: String
  let shared: String
  let result: String
}

@Test func x25519PassesWycheproof() throws {
  let data = try #require(FileManager.default.contents(atPath: repository + "/data/wycheproof/x25519_test.json"))
  let file = try JSONDecoder().decode(Wycheproof<X25519Case>.self, from: data)
  var n = 0, zeros = 0
  for group in file.testGroups {
    for t in group.tests {
      // Valid and acceptable alike: each says what the product is.
      #expect(t.result != "invalid", "case \(t.tcId)")
      let out = X25519.scalarMult(unhex(t.private), unhex(t.public))
      #expect(hex(out) == t.shared, "case \(t.tcId)")
      if out.allSatisfy({ $0 == 0 }) {
        #expect(X25519.sharedSecret(unhex(t.private), unhex(t.public)) == nil, "case \(t.tcId)")
        zeros += 1
      }
      n += 1
    }
  }
  #expect(n == 518 && zeros > 0)
}

@Test func x25519MatchesOpenSSL() {
  var g = SystemRandomNumberGenerator()
  func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) } }
  for _ in 0..<min(randomCases, 100) {
    let mine = bytes(32), theirs = X25519.publicKey(bytes(32))
    var out = [UInt8](repeating: 0, count: 32)
    #expect(td_openssl_x25519(mine, theirs, &out) == 0)
    #expect(X25519.scalarMult(mine, theirs) == out)
  }
}

@Test func theFieldsArithmeticHolds() {
  var g = SystemRandomNumberGenerator()
  func element() -> Field25519 {
    var b = (0..<32).map { _ in UInt8.random(in: 0...255, using: &g) }
    b[31] &= 0x7F
    return Field25519(bytes: b.span)
  }
  for _ in 0..<200 {
    let a = element(), b = element(), c = element()
    #expect((a * b).bytes == (b * a).bytes)
    #expect(((a + b) * c).bytes == (a * c + b * c).bytes)
    #expect(((a - b) + b).bytes == a.carried.bytes)
    #expect((-a + a).isZero)
    if !a.isZero { #expect((a * a.inverse).bytes == Field25519.one.bytes) }
  }
  // Values at and around p = 2^255 - 19 reduce: p is 0, p + 1 is 1,
  // 2^255 - 1 (all ones, top bit cleared) is 18.
  let p = [0xED] + [UInt8](repeating: 0xFF, count: 30) + [0x7F]
  #expect(Field25519(bytes: p.span).bytes == [UInt8](repeating: 0, count: 32))
  var p1 = p
  p1[0] = 0xEE
  #expect(Field25519(bytes: p1.span).bytes == [1] + [UInt8](repeating: 0, count: 31))
  let ones = [UInt8](repeating: 0xFF, count: 31) + [0x7F]
  #expect(Field25519(bytes: ones.span).bytes == [18] + [UInt8](repeating: 0, count: 31))
  // The top bit is ignored.
  #expect(Field25519(bytes: ([5] + [UInt8](repeating: 0, count: 30) + [0x80]).span).bytes == [5] + [UInt8](repeating: 0, count: 31))
}
