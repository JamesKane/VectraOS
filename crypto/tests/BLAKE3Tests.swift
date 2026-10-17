// SPDX-License-Identifier: BSD-3-Clause

// BLAKE3 against the official test vectors (data/blake3): every input
// length, all three modes, the full extended outputs and their prefixes,
// and the same input fed in pieces.

import FoundationEssentials
import TDCrypto
import Testing

struct Vectors: Decodable {
  struct Case: Decodable {
    let input_len: Int
    let hash: String
    let keyed_hash: String
    let derive_key: String
  }
  let key: String
  let context_string: String
  let cases: [Case]
}

func hex(_ b: [UInt8]) -> String { b.map { String($0, radix: 16).count == 1 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined() }

let vectors: Vectors = {
  var dir = #filePath
  for _ in 0..<3 { dir = String(dir[..<dir.lastIndex(of: "/")!]) }
  let data = FileManager.default.contents(atPath: dir + "/data/blake3/test_vectors.json")!
  return try! JSONDecoder().decode(Vectors.self, from: data)
}()

func input(_ n: Int) -> [UInt8] { (0..<n).map { UInt8($0 % 251) } }

@Test func blake3MatchesTheOfficialVectors() {
  #expect(vectors.cases.count == 35)
  for c in vectors.cases {
    let bytes = input(c.input_len)
    let outLength = c.hash.count / 2  // 131 bytes: the extended output
    #expect(hex(BLAKE3.hash(bytes, count: outLength)) == c.hash, "hash, \(c.input_len) bytes")
    #expect(hex(BLAKE3.hash(bytes)) == String(c.hash.prefix(64)), "hash prefix, \(c.input_len) bytes")
    var keyed = BLAKE3(key: Array(vectors.key.utf8))
    keyed.update(bytes)
    #expect(hex(keyed.finalize(count: outLength)) == c.keyed_hash, "keyed, \(c.input_len) bytes")
    var derive = BLAKE3(deriveKeyContext: Array(vectors.context_string.utf8))
    derive.update(bytes)
    #expect(hex(derive.finalize(count: outLength)) == c.derive_key, "derive_key, \(c.input_len) bytes")
    // In pieces of awkward sizes, the same answer.
    var pieces = BLAKE3()
    var at = 0, step = 1
    while at < bytes.count {
      let n = min(step, bytes.count - at)
      pieces.update(Array(bytes[at..<(at + n)]))
      at += n
      step = step * 3 + 1
    }
    #expect(hex(pieces.finalize()) == String(c.hash.prefix(64)), "pieces, \(c.input_len) bytes")
  }
}
