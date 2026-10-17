// SPDX-License-Identifier: BSD-3-Clause

// SHA-512 (N1a): against NIST CAVP's byte vectors (every short and long
// message, and the Monte Carlo test, data/nist-cavp), the padding's
// boundaries fed in pieces, and the host's OpenSSL on random inputs.
// (Its constants are checked through the vectors: computing 64-bit
// fractions of cube roots again needs wider integers than the test has.)

import OpenSSLOracle
import TDCrypto
import Testing

@Test func sha512MatchesCAVPsShortAndLongMessages() {
  var n = 0
  for file in ["SHA512ShortMsg.rsp", "SHA512LongMsg.rsp"] {
    for r in cavp(file) {
      guard let len = r["Len"].flatMap({ Int($0) }), let msg = r["Msg"], let md = r["MD"] else { continue }
      let bytes = len == 0 ? [] : unhex(msg)
      #expect(bytes.count * 8 == len)
      #expect(hex(SHA512.hash(bytes)) == md, "\(file) Len = \(len)")
      n += 1
    }
  }
  #expect(n == 129 + 128)
}

@Test func sha512PassesCAVPsMonteCarloTest() {
  let records = cavp("SHA512Monte.rsp")
  var seed = unhex(records.first { $0["Seed"] != nil }!["Seed"]!)
  let checkpoints = records.compactMap { $0["MD"] }
  #expect(checkpoints.count == 100)
  for expected in checkpoints {
    var md = [seed, seed, seed]
    for _ in 0..<1000 {
      let next = SHA512.hash(md[0] + md[1] + md[2])
      md = [md[1], md[2], next]
    }
    seed = md[2]
    #expect(hex(seed) == expected)
  }
}

@Test func sha512InPiecesIsSHA512Whole() {
  for n in [0, 1, 111, 112, 113, 127, 128, 129, 239, 240, 241, 255, 256, 257, 2000] {
    let bytes = (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
    let whole = SHA512.hash(bytes)
    for piece in [1, 2, 3, 7, 63, 64, 65, 111, 127, 128, 129, 200] {
      var h = SHA512()
      var i = 0
      while i < n {
        h.update(Array(bytes[i..<min(n, i + piece)]))
        i += piece
      }
      #expect(h.finalize() == whole, "\(n) bytes in pieces of \(piece)")
    }
  }
  // FIPS 180-2's long example: a million "a".
  var h = SHA512()
  let a = [UInt8](repeating: 0x61, count: 1000)
  for _ in 0..<1000 { h.update(a) }
  #expect(hex(h.finalize()) == "e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973eb"
    + "de0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b")
}

@Test func sha512MatchesOpenSSL() {
  var g = SystemRandomNumberGenerator()
  for _ in 0..<randomCases {
    let bytes = (0..<Int.random(in: 0...600, using: &g)).map { _ in UInt8.random(in: 0...255, using: &g) }
    var theirs = [UInt8](repeating: 0, count: 64)
    #expect(td_openssl_sha512(bytes, bytes.count, &theirs) == 0)
    #expect(SHA512.hash(bytes) == theirs)
  }
}
