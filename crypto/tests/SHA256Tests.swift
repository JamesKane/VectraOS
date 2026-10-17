// SPDX-License-Identifier: BSD-3-Clause

// SHA-256, HMAC-SHA-256 and PBKDF2-HMAC-SHA-256 (M6k part k4a): against
// NIST CAVP's byte vectors (every short and long message, and the Monte
// Carlo test, data/nist-cavp), Project Wycheproof's (data/wycheproof:
// valid and invalid tags, truncated tags, RFC 7914's PBKDF2 cases), FIPS
// 180-4's constants computed again, the padding's boundaries fed in
// pieces, and 9front's libsec on random inputs (architecture §17).
// TODHCHAI_CRYPTO_CASES=N runs N random cases a function instead of 300.

import FoundationEssentials
import Glibc
import LibsecOracle
import TDCrypto
import Testing

let repository: String = {
  var dir = #filePath
  for _ in 0..<3 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }
  return dir
}()

func unhex(_ s: some StringProtocol) -> [UInt8] {
  let b = Array(s.utf8)
  func v(_ c: UInt8) -> UInt8 { c <= 0x39 ? c - 0x30 : (c | 0x20) - 0x57 }
  return stride(from: 0, to: b.count - 1, by: 2).map { v(b[$0]) << 4 | v(b[$0 + 1]) }
}

/// A CAVP response file's records: each `NAME = VALUE` line, a record per
/// blank-line-separated group.
func cavp(_ name: String) -> [[String: String]] {
  let text = String(decoding: FileManager.default.contents(atPath: repository + "/data/nist-cavp/" + name)!, as: UTF8.self)
  var records: [[String: String]] = [], current: [String: String] = [:]
  func trim(_ s: Substring) -> Substring { s.drop { $0 == " " || $0 == "\r" }.reversed().drop { $0 == " " || $0 == "\r" }.reversed().map { $0 }.reduce(into: Substring()) { $0.append($1) } }
  // (The files' lines end in CR LF, one Character.)
  for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
    let l = trim(line)
    if l.isEmpty {
      if !current.isEmpty { records.append(current) }
      current = [:]
    } else if !l.hasPrefix("#"), !l.hasPrefix("["), let eq = l.firstIndex(of: "=") {
      current[String(trim(l[..<eq]))] = String(trim(l[l.index(after: eq)...]))
    }
  }
  if !current.isEmpty { records.append(current) }
  return records
}

var randomCases: Int { ProcessInfo.processInfo.environment["TODHCHAI_CRYPTO_CASES"].flatMap { Int($0) } ?? 300 }

// MARK: SHA-256

@Test func sha256MatchesCAVPsShortAndLongMessages() {
  var n = 0
  for file in ["SHA256ShortMsg.rsp", "SHA256LongMsg.rsp"] {
    for r in cavp(file) {
      guard let len = r["Len"].flatMap({ Int($0) }), let msg = r["Msg"], let md = r["MD"] else { continue }
      let bytes = len == 0 ? [] : unhex(msg)
      #expect(bytes.count * 8 == len)
      #expect(hex(SHA256.hash(bytes)) == md, "\(file) Len = \(len)")
      n += 1
    }
  }
  #expect(n == 65 + 64)
}

@Test func sha256PassesCAVPsMonteCarloTest() {
  // SHAVS §6.4: from the seed, each checkpoint is 1000 iterations of
  // MD_i = SHA-256(MD_{i-3} || MD_{i-2} || MD_{i-1}).
  let records = cavp("SHA256Monte.rsp")
  var seed = unhex(records.first { $0["Seed"] != nil }!["Seed"]!)
  let checkpoints = records.compactMap { $0["MD"] }
  #expect(checkpoints.count == 100)
  for expected in checkpoints {
    var md = [seed, seed, seed]
    for _ in 0..<1000 {
      let next = SHA256.hash(md[0] + md[1] + md[2])
      md = [md[1], md[2], next]
    }
    seed = md[2]
    #expect(hex(seed) == expected)
  }
}

@Test func sha256sConstantsAreFIPS180s() {
  // K: the cube roots of the first 64 primes; H(0): the square roots of
  // the first 8. The first 32 bits of each fractional part.
  var primes: [Int] = []
  var c = 2
  while primes.count < 64 {
    if !primes.contains(where: { c % $0 == 0 }) { primes.append(c) }
    c += 1
  }
  func fraction(_ x: Double) -> UInt32 { UInt32((x - x.rounded(.down)) * 4_294_967_296) }
  for i in 0..<64 { #expect(SHA256.constant(i) == fraction(cbrt(Double(primes[i]))), "K[\(i)]") }
  for i in 0..<8 { #expect(SHA256.initialWord(i) == fraction(Double(primes[i]).squareRoot()), "H(0)[\(i)]") }
}

@Test func sha256InPiecesIsSHA256Whole() {
  for n in [0, 1, 55, 56, 57, 63, 64, 65, 119, 120, 121, 127, 128, 129, 1000] {
    let bytes = (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
    let whole = SHA256.hash(bytes)
    for piece in 1...70 {
      var h = SHA256()
      var i = 0
      while i < n {
        h.update(Array(bytes[i..<min(n, i + piece)]))
        i += piece
      }
      #expect(h.finalize() == whole, "\(n) bytes in pieces of \(piece)")
    }
  }
  // FIPS 180-2's long example: a million "a".
  var h = SHA256()
  let a = [UInt8](repeating: 0x61, count: 1000)
  for _ in 0..<1000 { h.update(a) }
  #expect(hex(h.finalize()) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
}

// MARK: HMAC and PBKDF2

struct Wycheproof<Case: Decodable>: Decodable {
  struct Group: Decodable {
    let tagSize: Int?
    let tests: [Case]
  }
  let testGroups: [Group]
}

struct MacCase: Decodable {
  let tcId: Int
  let key: String
  let msg: String
  let tag: String
  let result: String
}

struct PBKDF2Case: Decodable {
  let tcId: Int
  let password: String
  let salt: String
  let iterationCount: Int
  let dkLen: Int
  let dk: String
  let result: String
}

func wycheproof<C: Decodable>(_ name: String, _: C.Type) -> Wycheproof<C> {
  let data = FileManager.default.contents(atPath: repository + "/data/wycheproof/" + name)!
  return try! JSONDecoder().decode(Wycheproof<C>.self, from: data)
}

@Test func hmacMatchesWycheproof() {
  var n = 0
  for g in wycheproof("hmac_sha256_test.json", MacCase.self).testGroups {
    let bytes = (g.tagSize ?? 256) / 8
    for t in g.tests {
      let tag = Array(HMACSHA256.authenticate(unhex(t.msg), key: unhex(t.key)).prefix(bytes))
      // A valid case's tag is ours; an invalid one's (a tag changed) isn't.
      #expect(constantTimeEqual(tag, unhex(t.tag)) == (t.result == "valid"), "tcId \(t.tcId)")
      n += 1
    }
  }
  #expect(n > 100)
}

@Test func pbkdf2MatchesWycheproof() {
  var n = 0
  for g in wycheproof("pbkdf2_hmacsha256_test.json", PBKDF2Case.self).testGroups {
    for t in g.tests where t.iterationCount <= 100_000 {
      let dk = PBKDF2.sha256(password: unhex(t.password), salt: unhex(t.salt), iterations: t.iterationCount,
                             length: t.dkLen)
      #expect((dk == unhex(t.dk)) == (t.result == "valid"), "tcId \(t.tcId)")
      n += 1
    }
  }
  #expect(n > 30)
}

@Test func constantTimeEqualIsEquality() {
  #expect(constantTimeEqual([], []) && constantTimeEqual([1, 2], [1, 2]))
  #expect(!constantTimeEqual([1, 2], [1, 3]) && !constantTimeEqual([1], [1, 0]))
}

// MARK: Against libsec

struct Generator: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

func bytes(_ n: Int, _ g: inout Generator) -> [UInt8] { (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) } }

@Test func sameAsLibsecOnRandomInputs() {
  var g = Generator(state: 0x5348_4132_3536)
  for i in 0..<randomCases {
    let message = bytes(Int.random(in: 0...(i % 10 == 0 ? 5000 : 300), using: &g), &g)
    let key = bytes(Int.random(in: 0...(i % 7 == 0 ? 200 : 64), using: &g), &g)
    var digest = [UInt8](repeating: 0, count: 32), tag = [UInt8](repeating: 0, count: 32)
    #expect(libsec_sha256(message, message.count, &digest) == 0)
    #expect(SHA256.hash(message) == digest, "SHA-256, case \(i)")
    #expect(libsec_hmac_sha256(key, key.count, message, message.count, &tag) == 0)
    #expect(HMACSHA256.authenticate(message, key: key) == tag, "HMAC, case \(i)")
    if i % 10 == 0 {
      let salt = bytes(Int.random(in: 0...40, using: &g), &g)
      let iterations = Int.random(in: 1...300, using: &g), length = Int.random(in: 1...100, using: &g)
      var dk = [UInt8](repeating: 0, count: length)
      #expect(libsec_pbkdf2_sha256(key, key.count, salt, salt.count, Int32(iterations), &dk, length) == 0)
      #expect(PBKDF2.sha256(password: key, salt: salt, iterations: iterations, length: length) == dk,
              "PBKDF2, case \(i)")
    }
  }
}
