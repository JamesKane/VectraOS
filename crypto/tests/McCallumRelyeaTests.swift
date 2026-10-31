// SPDX-License-Identifier: BSD-3-Clause

// McCallum-Relyea over Edwards25519 (crypto/lib/McCallumRelyea.swift):
// the secret recovered is the one provisioned, on random keys; another
// server's answer recovers something else; requests don't repeat; and a
// request with a small-order part gets the same answer as without it,
// while a small-order request gets none.

@testable import TDCrypto
import Testing

private func bytes(_ n: Int, _ g: inout SystemRandomNumberGenerator) -> [UInt8] {
  (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
}

@Test func theSecretRecoveredIsTheOneProvisioned() throws {
  var g = SystemRandomNumberGenerator()
  for _ in 0..<16 {
    let s = McCallumRelyea.privateKey(bytes(32, &g)), other = McCallumRelyea.privateKey(bytes(32, &g))
    let server = McCallumRelyea.publicKey(s)
    let (point, secret) = try #require(McCallumRelyea.provision(server, random: bytes(64, &g)))
    let first = try #require(McCallumRelyea.ask(point, random: bytes(64, &g)))
    let second = try #require(McCallumRelyea.ask(point, random: bytes(64, &g)))
    #expect(first.request != second.request && first.request != point)
    for asked in [first, second] {
      let answer = try #require(McCallumRelyea.answer(asked.request, key: s))
      #expect(McCallumRelyea.recover(answer, blinding: asked.blinding, publicKey: server) == secret)
      let wrong = try #require(McCallumRelyea.answer(asked.request, key: other))
      #expect(McCallumRelyea.recover(wrong, blinding: asked.blinding, publicKey: server) != secret)
    }
  }
}

@Test func smallOrderPartsTellNothing() throws {
  var g = SystemRandomNumberGenerator()
  // (0, -1), of order 2: y = p - 1.
  var two = [UInt8](repeating: 0xFF, count: 32)
  two[0] = 0xEC
  two[31] = 0x7F
  let t = try #require(EdwardsPoint(bytes: two))
  #expect(t.doubled.bytes == EdwardsPoint.identity.bytes && t.bytes != EdwardsPoint.identity.bytes)
  let s = McCallumRelyea.privateKey(bytes(32, &g))
  #expect(s[0] & 7 == 0 && s[31] >> 6 == 1)
  let (point, _) = try #require(McCallumRelyea.provision(McCallumRelyea.publicKey(s), random: bytes(64, &g)))
  let x = try #require(McCallumRelyea.ask(point, random: bytes(64, &g))).request
  let shifted = (try #require(EdwardsPoint(bytes: x)) + t).bytes
  #expect(shifted != x)
  #expect(McCallumRelyea.answer(shifted, key: s) == McCallumRelyea.answer(x, key: s))
  #expect(McCallumRelyea.answer(two, key: s) == nil)
  #expect(McCallumRelyea.answer(EdwardsPoint.identity.bytes, key: s) == nil)
  // y = 2 has no x.
  var off = [UInt8](repeating: 0, count: 32)
  off[0] = 2
  #expect(McCallumRelyea.answer(off, key: s) == nil)
}
