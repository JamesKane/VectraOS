// SPDX-License-Identifier: BSD-3-Clause

// MD5 against RFC 1321's test suite (A.5), its sine table computed again,
// every length around the padding's boundaries fed whole and in pieces,
// and a million bytes.

import FoundationEssentials
import Glibc
import TDCrypto
import Testing

@Test func md5MatchesRFC1321sTestSuite() {
  let suite: [(String, String)] = [
    ("", "d41d8cd98f00b204e9800998ecf8427e"),
    ("a", "0cc175b9c0f1b6a831c399e269772661"),
    ("abc", "900150983cd24fb0d6963f7d28e17f72"),
    ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
    ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
    ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", "d174ab98d277d9f5a5611c2c9f419d9f"),
    ("12345678901234567890123456789012345678901234567890123456789012345678901234567890",
     "57edf4a22be3c955ac49da2e2107b67a"),
  ]
  for (text, digest) in suite { #expect(hex(MD5.hash(Array(text.utf8))) == digest, "MD5(\"\(text)\")") }
}

@Test func md5sSineTableIsRFC1321s() {
  // T[i] = floor(2^32 * |sin(i + 1)|): the digests above would catch a
  // wrong constant too, but this names it.
  for i in 0..<64 {
    let t = UInt32(floor(4_294_967_296 * abs(sin(Double(i + 1)))))
    #expect(MD5.sine(i) == t, "T[\(i + 1)]")
  }
}

@Test func md5InPiecesIsMD5Whole() {
  // Lengths around 56 and 64 bytes (where the padding takes another
  // block), fed in pieces of every size up to 70.
  for n in [0, 1, 55, 56, 57, 63, 64, 65, 119, 120, 121, 127, 128, 129, 1000] {
    let bytes = (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
    let whole = MD5.hash(bytes)
    for piece in [1, 3, 7, 63, 64, 65, 70] {
      var m = MD5()
      var at = 0
      while at < n {
        let end = min(n, at + piece)
        m.update(Array(bytes[at..<end]))
        at = end
      }
      #expect(m.finalize() == whole, "\(n) bytes in pieces of \(piece)")
    }
    // finalize doesn't end the message: more can follow.
    var m = MD5()
    m.update(bytes)
    _ = m.finalize()
    m.update([1, 2, 3])
    #expect(m.finalize() == MD5.hash(bytes + [1, 2, 3]))
  }
}

@Test func md5OfAMillionAs() {
  // A common extra vector: a million 'a's.
  var m = MD5()
  let chunk = [UInt8](repeating: 0x61, count: 1000)
  for _ in 0..<1000 { m.update(chunk) }
  #expect(hex(m.finalize()) == "7707d6ae4e027c70eea2a935c2296f21")
}
