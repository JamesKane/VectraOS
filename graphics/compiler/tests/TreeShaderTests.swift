// SPDX-License-Identifier: BSD-3-Clause

// The SPIR-V the tree already has (Radharc's compose shaders and Loinnir's
// test shaders, made by `vx shaders`). Every one lowers; a shader that did not would be pinned here with what it needs, by name,
// and the refusal, which says which instruction, capability or model, never a crash or a guess.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import ShaderCompiler
import Testing

func readFile(_ path: String) -> [UInt8]? {
  guard let f = fopen(path, "rb") else { return nil }
  defer { fclose(f) }
  var out: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 4096)
  while case let n = fread(&chunk, 1, chunk.count, f), n > 0 { out += chunk[..<n] }
  return out
}

/// A path from the repository's root, found from this file's own (with
/// links resolved: this file is `graphics/compiler/tests/TreeShaderTests.swift`).
func repoPath(_ rel: String, file: String = #filePath) -> String {
  var resolved = file
  if let r = realpath(file, nil) {
    resolved = String(cString: r)
    free(r)
  }
  var parts = resolved.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
  parts.removeLast(4)
  return parts.joined(separator: "/") + "/" + rel
}

func wordsOf(_ bytes: [UInt8]) -> [UInt32] {
  var words: [UInt32] = []
  var k = 0
  while k + 3 < bytes.count {
    words.append(UInt32(bytes[k]) | UInt32(bytes[k + 1]) << 8 | UInt32(bytes[k + 2]) << 16 | UInt32(bytes[k + 3]) << 24)
    k += 4
  }
  return words
}

/// What each shader needs that the compiler doesn't have yet, by name, and the first refusal a parse or a lowering
/// gives (nil: it lowers, and the backend compiles it: graphics/compiler/valhall/backend/tests).
let treeNeeds: [(path: String, needs: [String], refusal: String?)] = [
  ("services/radharc/shaders/compose.vert.spv", [], nil),
  ("services/radharc/shaders/compose.frag.spv", [], nil),
  ("graphics/loinnir/tests/shaders/triangle.vert.spv", [], nil),
  ("graphics/loinnir/tests/shaders/triangle.frag.spv", [], nil),
  ("graphics/loinnir/tests/shaders/textured.vert.spv", [], nil),
  ("graphics/loinnir/tests/shaders/textured.frag.spv", [], nil),
]

@Suite struct TreeShaderTests {
  @Test func theTreesShadersLower() throws {
    for s in treeNeeds {
      guard let bytes = readFile(repoPath(s.path)) else {
        Issue.record("\(s.path): not found")
        continue
      }
      let words = wordsOf(bytes)
      #expect(SPIRVModule.unsupported(words: words) == s.needs, "\(s.path)")
      do {
        let m = try SPIRVModule.parse(words: words)
        let ir = try IRModule.lower(m)
        try ir.verify()
        #expect(s.refusal == nil, "\(s.path): accepted")
      } catch {
        #expect(error.message == s.refusal, "\(s.path): \(error)")
      }
    }
  }
}
