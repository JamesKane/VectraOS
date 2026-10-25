// SPDX-License-Identifier: BSD-3-Clause

// The oracle itself (D89): 9front's libsec, through its shim, on the same
// published vectors ours meets (data/nist-cavp, data/wycheproof, RFC 5869),
// so a fault in the shim fails here, as the oracle, and not as a
// disagreement with ours.

import FoundationEssentials
import LibsecOracle
import TDCrypto
import Testing

@Test func libsecsSHA2MatchesCAVP() {
  var n = 0
  for (file, size) in [("SHA256ShortMsg.rsp", 32), ("SHA256LongMsg.rsp", 32), ("SHA512ShortMsg.rsp", 64),
                       ("SHA512LongMsg.rsp", 64)] {
    for r in cavp(file) {
      guard let len = r["Len"].flatMap({ Int($0) }), let msg = r["Msg"], let md = r["MD"] else { continue }
      let bytes = len == 0 ? [] : unhex(msg)
      var out = [UInt8](repeating: 0, count: size)
      #expect((size == 32 ? libsec_sha256(bytes, bytes.count, &out) : libsec_sha512(bytes, bytes.count, &out)) == 0)
      #expect(hex(out) == md, "\(file) Len = \(len)")
      n += 1
    }
  }
  #expect(n == 65 + 64 + 129 + 128)
}

@Test func libsecsHMACAndPBKDF2MatchWycheproof() {
  var n = 0
  for g in wycheproof("hmac_sha256_test.json", MacCase.self).testGroups {
    let bytes = (g.tagSize ?? 256) / 8
    for t in g.tests where t.result == "valid" {
      let key = unhex(t.key), msg = unhex(t.msg)
      var tag = [UInt8](repeating: 0, count: 32)
      #expect(libsec_hmac_sha256(key, key.count, msg, msg.count, &tag) == 0)
      #expect(Array(tag.prefix(bytes)) == unhex(t.tag), "tcId \(t.tcId)")
      n += 1
    }
  }
  for g in wycheproof("pbkdf2_hmacsha256_test.json", PBKDF2Case.self).testGroups {
    for t in g.tests where t.result == "valid" && t.iterationCount <= 100_000 {
      let password = unhex(t.password), salt = unhex(t.salt)
      var dk = [UInt8](repeating: 0, count: t.dkLen)
      #expect(libsec_pbkdf2_sha256(password, password.count, salt, salt.count, Int32(t.iterationCount), &dk, t.dkLen) == 0)
      #expect(dk == unhex(t.dk), "tcId \(t.tcId)")
      n += 1
    }
  }
  #expect(n > 60)
}

@Test func libsecsHKDFIsRFC5869s() {
  // A.1, test case 1.
  let ikm = [UInt8](repeating: 0x0B, count: 22), salt = (0x00...0x0C).map { UInt8($0) }
  let info = (0xF0...0xF9).map { UInt8($0) }
  var okm = [UInt8](repeating: 0, count: 42)
  #expect(libsec_hkdf_sha256(salt, salt.count, info, info.count, ikm, ikm.count, &okm, okm.count) == 0)
  #expect(hex(okm) == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
}

@Test func libsecsChaCha20Poly1305MatchesWycheproof() throws {
  let data = try #require(FileManager.default.contents(atPath: repository + "/data/wycheproof/chacha20_poly1305_test.json"))
  let file = try JSONDecoder().decode(Wycheproof<AEADCase>.self, from: data)
  var n = 0
  for group in file.testGroups {
    for t in group.tests where t.result == "valid" {
      let key = unhex(t.key), nonce = unhex(t.iv), aad = unhex(t.aad), msg = unhex(t.msg)
      guard key.count == 32, nonce.count == 12 else { continue }
      var sealed = [UInt8](repeating: 0, count: msg.count + 16)
      #expect(libsec_chacha20_poly1305_seal(key, nonce, aad, aad.count, msg, msg.count, &sealed) == 0)
      #expect(sealed == unhex(t.ct) + unhex(t.tag), "case \(t.tcId)")
      n += 1
    }
  }
  #expect(n > 100)
}

@Test func libsecsX25519MatchesWycheproof() throws {
  let data = try #require(FileManager.default.contents(atPath: repository + "/data/wycheproof/x25519_test.json"))
  let file = try JSONDecoder().decode(Wycheproof<X25519Case>.self, from: data)
  var n = 0
  for group in file.testGroups {
    for t in group.tests {
      var out = [UInt8](repeating: 0, count: 32)
      let zero = libsec_x25519(unhex(t.private), unhex(t.public), &out) != 0
      #expect(hex(out) == t.shared, "case \(t.tcId)")
      #expect(zero == out.allSatisfy { $0 == 0 }, "case \(t.tcId)")
      n += 1
    }
  }
  #expect(n == 518)
}
