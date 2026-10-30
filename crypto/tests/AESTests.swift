// SPDX-License-Identifier: BSD-3-Clause

// AES-256 and XTS (crypto/lib/AES.swift, D153): the S-box's circuit over
// every byte against the S-box computed from its definition, CAVP's
// known answers (data/nist-cavp: ECB GFSbox, KeySbox, VarKey and VarTxt;
// XTSGen's whole-block data units), and libsec's AES and XTS on random
// keys, units and data. The CPU's instructions and the software must give
// the same bytes, each checked alone.

import LibsecOracle
import Testing

@testable import TDCrypto

/// The S-box from its definition (FIPS 197 §5.1.1): the inverse in GF(2^8)
/// then the affine map.
func definedSbox(_ x: UInt8) -> UInt8 {
  func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
    var a = a, b = b, p: UInt8 = 0
    for _ in 0..<8 {
      if b & 1 != 0 { p ^= a }
      a = a & 0x80 != 0 ? a << 1 ^ 0x1B : a << 1
      b >>= 1
    }
    return p
  }
  var inverse: UInt8 = 0
  if x != 0 { inverse = (1...255).map { UInt8($0) }.first { multiply(x, $0) == 1 }! }
  var out: UInt8 = 0x63
  for i in 0..<8 {
    let bit = (inverse >> i ^ inverse >> ((i + 4) % 8) ^ inverse >> ((i + 5) % 8) ^ inverse >> ((i + 6) % 8)
      ^ inverse >> ((i + 7) % 8)) & 1
    out ^= bit << i
  }
  return out
}

@Test func theCircuitIsTheSbox() {
  let sbox = (0...255).map { definedSbox(UInt8($0)) }
  // All 256 bytes in four states of 64.
  for group in 0..<4 {
    var s = AESCore.State(repeating: 0)
    for i in 0..<16 {
      for k in 0..<4 { s[i] |= UInt32(group * 64 + 4 * i + k) << (8 * UInt32(k)) }
    }
    var inverse = s
    AESCore.subBytes(&s, inverse: false)
    AESCore.subBytes(&inverse, inverse: true)
    for i in 0..<16 {
      for k in 0..<4 {
        let x = group * 64 + 4 * i + k
        #expect(UInt8(truncatingIfNeeded: s[i] >> (8 * UInt32(k))) == sbox[x], "S(\(x))")
        #expect(sbox[Int(UInt8(truncatingIfNeeded: inverse[i] >> (8 * UInt32(k))))] == UInt8(x), "S⁻¹(\(x))")
      }
    }
  }
}

/// FIPS 197 appendix C.3: AES-256 (CryptoSuite checks it on each arch).
@Test func aesIsFIPS197s() {
  let aes = AES256(key: (0..<32).map { UInt8($0) })
  let plain = (0..<16).map { UInt8($0 * 0x11) }
  #expect(hex(aes.encrypt(plain)) == "8ea2b7ca516745bfeafc49904b496089")
  #expect(aes.decrypt(aes.encrypt(plain)) == plain)
}

@Test func aesMatchesCAVPsKnownAnswers() {
  var n = 0
  for file in ["ECBGFSbox256.rsp", "ECBKeySbox256.rsp", "ECBVarKey256.rsp", "ECBVarTxt256.rsp"] {
    for r in cavp(file) {
      guard let key = r["KEY"], let pt = r["PLAINTEXT"], let ct = r["CIPHERTEXT"] else { continue }
      let aes = AES256(key: unhex(key))
      #expect(hex(aes.encrypt(unhex(pt))) == ct, "\(file) \(r["COUNT"] ?? "")")
      #expect(hex(aes.decrypt(unhex(ct))) == pt, "\(file) \(r["COUNT"] ?? "")")
      n += 1
    }
  }
  #expect(n == 2 * (5 + 16 + 256 + 128))
}

/// XTSGen's vectors with whole blocks (its 140- and 250-bit units steal
/// ciphertext, which 4 KiB units never need).
@Test(arguments: [false, true])
func xtsMatchesCAVP(software: Bool) {
  var n = 0
  for r in cavp("XTSGenAES256.rsp") {
    guard let bits = r["DataUnitLen"].flatMap({ Int($0) }), bits % 128 == 0, let key = r["Key"],
      let unit = r["DataUnitSeqNumber"].flatMap({ UInt64($0) }), let pt = r["PT"], let ct = r["CT"]
    else { continue }
    let xts = AESXTS(key: unhex(key))
    var bytes = unhex(pt)
    xts.encrypt(&bytes, firstUnit: unit, unitSize: bits / 8, software: software)
    #expect(hex(bytes) == ct, "COUNT \(r["COUNT"] ?? "")")
    xts.decrypt(&bytes, firstUnit: unit, unitSize: bits / 8, software: software)
    #expect(hex(bytes) == pt, "COUNT \(r["COUNT"] ?? "")")
    n += 1
  }
  #expect(n == 1000 - 400)
}

@Test func libsecsAESIsCAVPs() {
  for r in cavp("ECBVarTxt256.rsp") {
    guard let key = r["KEY"], let pt = r["PLAINTEXT"], let ct = r["CIPHERTEXT"] else { continue }
    let k = unhex(key)
    var out = [UInt8](repeating: 0, count: 16), back = out
    #expect(libsec_aes_encrypt(k, 32, unhex(pt), &out) == 0)
    #expect(libsec_aes_decrypt(k, 32, unhex(ct), &back) == 0)
    #expect(hex(out) == ct && hex(back) == pt, "COUNT \(r["COUNT"] ?? "")")
  }
  for r in cavp("XTSGenAES256.rsp") {
    guard let bits = r["DataUnitLen"].flatMap({ Int($0) }), bits % 128 == 0, let key = r["Key"],
      let unit = r["DataUnitSeqNumber"].flatMap({ UInt64($0) }), let pt = r["PT"], let ct = r["CT"]
    else { continue }
    let p = unhex(pt)
    var out = [UInt8](repeating: 0, count: p.count)
    #expect(libsec_aes_xts(unhex(key), unit, 0, p, p.count, &out) == 0)
    #expect(hex(out) == ct, "COUNT \(r["COUNT"] ?? "")")
  }
}

@Test func aesAndXTSMatchLibsec() {
  var g = SystemRandomNumberGenerator()
  func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) } }
  for _ in 0..<randomCases {
    let key = bytes(32), block = bytes(16)
    let aes = AES256(key: key)
    var out = [UInt8](repeating: 0, count: 16), back = out
    _ = libsec_aes_encrypt(key, 32, block, &out)
    _ = libsec_aes_decrypt(key, 32, block, &back)
    #expect(aes.encrypt(block) == out)
    #expect(aes.decrypt(block) == back)
  }
  for i in 0..<randomCases {
    // Units of 16 bytes to 4 KiB, so the four-block groups end every way.
    let key = bytes(64), size = 16 * Int.random(in: 1...256, using: &g), unit = UInt64.random(in: 0...UInt64.max)
    let units = 1 + i % 3, data = bytes(size * units)
    var expected: [UInt8] = []
    for u in 0..<units {
      var out = [UInt8](repeating: 0, count: size)
      _ = libsec_aes_xts(key, unit &+ UInt64(u), 0, Array(data[(u * size)..<((u + 1) * size)]), size, &out)
      expected += out
    }
    let xts = AESXTS(key: key)
    for software in [true, false] {
      var b = data
      xts.encrypt(&b, firstUnit: unit, unitSize: size, software: software)
      #expect(b == expected, "\(size)-byte units, software \(software)")
      xts.decrypt(&b, firstUnit: unit, unitSize: size, software: software)
      #expect(b == data)
    }
  }
}

@Test func theHostRunsAESInHardware() {
  // Every amd64 host since 2010 has AES-NI, so the other tests compare
  // the instructions' path as well as the software's.
  #expect(AESXTS.hardware)
}
