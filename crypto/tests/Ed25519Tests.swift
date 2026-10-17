// SPDX-License-Identifier: BSD-3-Clause

// Ed25519 and its group (N1a): RFC 8032's examples, every Wycheproof
// Ed25519 case (data/wycheproof: S at and past L, non-canonical and
// altered R, truncated and padded signatures), its own signatures on
// random keys and messages (libsec has no Ed25519), the scalars mod L
// against a long division, and the curve's constants and laws checked
// directly.

import FoundationEssentials
@testable import TDCrypto
import Testing

@Test func ed25519IsRFC8032s() {
  // §7.1: TEST 1, 2, 3 and SHA(abc), whose message is SHA-512("abc").
  let cases: [(seed: String, publicKey: String, message: [UInt8], signature: String)] = [
    ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
     "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", [],
     "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
    ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
     "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", [0x72],
     "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
    ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
     "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", [0xaf, 0x82],
     "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
    ("833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42",
     "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf", SHA512.hash(Array("abc".utf8)),
     "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704"),
  ]
  for c in cases {
    let seed = unhex(c.seed)
    #expect(hex(Ed25519.publicKey(seed: seed)) == c.publicKey)
    #expect(hex(Ed25519.sign(c.message, seed: seed)) == c.signature)
    #expect(Ed25519.verify(unhex(c.signature), of: c.message, publicKey: unhex(c.publicKey)))
    #expect(!Ed25519.verify(unhex(c.signature), of: c.message + [0], publicKey: unhex(c.publicKey)))
  }
}

struct Ed25519Group: Decodable {
  struct Key: Decodable { let pk: String }
  struct Case: Decodable {
    let tcId: Int
    let msg: String
    let sig: String
    let result: String
  }
  let publicKey: Key
  let tests: [Case]
}

@Test func ed25519PassesWycheproof() throws {
  let data = try #require(FileManager.default.contents(atPath: repository + "/data/wycheproof/ed25519_test.json"))
  struct File: Decodable { let testGroups: [Ed25519Group] }
  let file = try JSONDecoder().decode(File.self, from: data)
  var valid = 0, invalid = 0
  for group in file.testGroups {
    let pk = unhex(group.publicKey.pk)
    for t in group.tests {
      #expect(t.result != "acceptable", "case \(t.tcId)")
      let ok = Ed25519.verify(unhex(t.sig), of: unhex(t.msg), publicKey: pk)
      #expect(ok == (t.result == "valid"), "case \(t.tcId)")
      if t.result == "valid" { valid += 1 } else { invalid += 1 }
    }
  }
  #expect(valid == 88 && invalid == 63)
}

@Test func ed25519VerifiesItsOwnSignatures() {
  var g = SystemRandomNumberGenerator()
  func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) } }
  for _ in 0..<min(randomCases, 100) {
    let seed = bytes(32), message = bytes(Int.random(in: 0...300, using: &g))
    let pk = Ed25519.publicKey(seed: seed)
    let signature = Ed25519.sign(message, seed: seed)
    #expect(Ed25519.verify(signature, of: message, publicKey: pk))
    // One bit changed anywhere in the signature: refused.
    var bad = signature
    let bit = Int.random(in: 0..<512, using: &g)
    bad[bit >> 3] ^= UInt8(1 << (bit & 7))
    #expect(!Ed25519.verify(bad, of: message, publicKey: pk))
  }
}

/// x mod L by long division, a bit at a time (variable time: tests only).
func slowReduced(_ x: [UInt64]) -> [UInt64] {
  var r = [UInt64](repeating: 0, count: 5)
  for bit in stride(from: 64 * x.count - 1, through: 0, by: -1) {
    var carry = (x[bit >> 6] >> UInt64(bit & 63)) & 1
    for i in 0..<5 {
      let top = r[i] >> 63
      r[i] = r[i] << 1 | carry
      carry = top
    }
    let (t, borrow) = Scalar25519.subtract(r, Scalar25519.order)
    if borrow == 0 { r = t }
  }
  return Array(r[0..<4])
}

@Test func theScalarsReduceModL() {
  let order = Scalar25519.order
  // mu is floor(2^512 / L): mu L fits in 512 bits and leaves less than L.
  let muL = Scalar25519.multiply(Scalar25519.mu, order, words: 10)
  #expect(muL[8] == 0 && muL[9] == 0)
  let (rest, _) = Scalar25519.subtract([UInt64](repeating: 0, count: 8), Array(muL[0..<8]))
  #expect(rest[4..<8].allSatisfy { $0 == 0 } && Scalar25519.isCanonical(Scalar25519.bytes(Array(rest[0..<4]))))
  // The edges and random values, against the long division.
  let ones = [UInt64](repeating: ~0, count: 8)
  let lMinusOne = Scalar25519.subtract(order, [1]).0
  let edges: [[UInt64]] = [[UInt64](repeating: 0, count: 8), order + [0, 0, 0, 0], lMinusOne + [0, 0, 0, 0],
                           Scalar25519.multiply(order, [2], words: 8), ones]
  var g = SystemRandomNumberGenerator()
  let random = (0..<300).map { _ in (0..<8).map { _ in UInt64.random(in: 0...UInt64.max, using: &g) } }
  for x in edges + random { #expect(Scalar25519.reduced(x) == slowReduced(x)) }
  #expect(Scalar25519.reduced(order + [0, 0, 0, 0]) == [0, 0, 0, 0])
  #expect(Scalar25519.reduced(ones) == slowReduced(ones))
  // a b + c, and S's bound.
  for _ in 0..<100 {
    let a = (0..<32).map { _ in UInt8.random(in: 0...255, using: &g) }
    let b = (0..<32).map { _ in UInt8.random(in: 0...255, using: &g) }
    let c = Scalar25519.reduced(bytes: (0..<64).map { _ in UInt8.random(in: 0...255, using: &g) })
    var p = Scalar25519.multiply(Scalar25519.words(a), Scalar25519.words(b), words: 8)
    let cw = Scalar25519.words(c)
    var carry: UInt64 = 0
    for i in 0..<8 {
      let (s1, o1) = p[i].addingReportingOverflow(i < 4 ? cw[i] : 0)
      let (s2, o2) = s1.addingReportingOverflow(carry)
      p[i] = s2
      carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
    }
    #expect(Scalar25519.words(Scalar25519.mulAdd(a, b, c)) == slowReduced(p))
  }
  #expect(!Scalar25519.isCanonical(Scalar25519.bytes(order)))
  #expect(Scalar25519.isCanonical(Scalar25519.bytes(lMinusOne)))
}

@Test func theCurvesConstantsAndLawsHold() {
  let d = EdwardsPoint.d, i = EdwardsPoint.sqrtMinusOne
  // d 121666 = -121665, i^2 = -1, and d's known bytes (RFC 8032 §5.1).
  #expect((d * Field25519(121_666, 0, 0, 0, 0)).equals(-Field25519(121_665, 0, 0, 0, 0)))
  #expect(i.squared.equals(-Field25519.one))
  #expect(hex(d.bytes) == "a3785913ca4deb75abd841414d0a700098e879777940c78c73fe6f2bee6c0352")
  // B is on the curve, encodes as RFC 8032 says, and has order L.
  let b = EdwardsPoint.base
  let xx = b.x.squared, yy = b.y.squared
  #expect((yy - xx).equals(.one + d * xx * yy))
  #expect(hex(b.bytes) == "58" + String(repeating: "66", count: 31))
  let identity = [1] + [UInt8](repeating: 0, count: 31)
  #expect(b.times(Scalar25519.bytes(Scalar25519.order)).bytes == identity)
  #expect(b.times([1] + [UInt8](repeating: 0, count: 31)).bytes == b.bytes)
  // Doubling, negation and the identity agree with addition; scalar
  // multiples add.
  var g = SystemRandomNumberGenerator()
  for _ in 0..<20 {
    let k = Scalar25519.reduced(bytes: (0..<64).map { _ in UInt8.random(in: 0...255, using: &g) })
    let m = Scalar25519.reduced(bytes: (0..<64).map { _ in UInt8.random(in: 0...255, using: &g) })
    let p = b.times(k), q = b.times(m)
    #expect(p.doubled.bytes == (p + p).bytes)
    #expect((p + -p).bytes == identity)
    #expect((p + .identity).bytes == p.bytes)
    let sum = Scalar25519.mulAdd([1] + [UInt8](repeating: 0, count: 31), k, m)
    #expect((p + q).bytes == b.times(sum).bytes)
    #expect(EdwardsPoint(bytes: p.bytes).map { $0.bytes } == p.bytes)
  }
  // Decoding refuses y at or past p, and x = 0 with its sign bit set.
  let p = [0xED] + [UInt8](repeating: 0xFF, count: 30) + [0x7F]
  #expect(EdwardsPoint(bytes: p) == nil)
  #expect(EdwardsPoint(bytes: [1] + [UInt8](repeating: 0, count: 30) + [0x80]) == nil)
}
