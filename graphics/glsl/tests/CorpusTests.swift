// SPDX-License-Identifier: BSD-3-Clause

// glmark2's shaders (GPLv3, so never in the tree): the final sources glmark2 2023.01 passed to glShaderSource on the
// board, dumped into .cache/ports/glmark2-shaders (VS_<sha>.glsl, FS_<sha>.glsl), and its data/shaders templates. Each
// must compile; each vertex shader with each fragment shader whose varyings it declares must link, lower, and compile for
// Valhall. The test is skipped where .cache has none.

@testable import GLSL
import Testing

private let dumpDirectory = repositoryRoot() + "/.cache/ports/glmark2-shaders"

private func dump() -> [(name: String, stage: GLSLStage, source: String)] {
  var out: [(String, GLSLStage, String)] = []
  for n in listDirectory(dumpDirectory) where n.hasSuffix(".glsl") {
    guard let bytes = readFile(dumpDirectory + "/" + n) else { continue }
    let stage: GLSLStage = n.hasPrefix("VS_") ? .vertex : .fragment
    out.append((n, stage, String(decoding: bytes, as: UTF8.self)))
  }
  return out
}

@Suite struct CorpusTests {
  @Test(.enabled(if: !listDirectory(dumpDirectory).isEmpty)) func everyShaderGlmark2CompilesCompiles() throws {
    var failed: [String] = []
    for s in dump() {
      if case .failure(let e) = compile(source: Array(s.source.utf8), stage: s.stage) { failed.append("\(s.name):\n\(e.log)") }
    }
    #expect(failed.isEmpty, "\(failed.count) failed:\n\(failed.joined(separator: "\n"))")
    #expect(dump().count >= 60)
  }

  @Test(.enabled(if: !listDirectory(dumpDirectory).isEmpty)) func everyMatchingPairLinksLowersAndCompiles() throws {
    let all = dump()
    var vs: [(String, GLSLShader)] = []
    var fs: [(String, GLSLShader)] = []
    for s in all {
      guard case .success(let c) = compile(source: Array(s.source.utf8), stage: s.stage) else { continue }
      if s.stage == .vertex { vs.append((s.name, c)) } else { fs.append((s.name, c)) }
    }
    var pairs = 0
    var failed: [String] = []
    var fragmentsLinked = Set<String>()
    var vertexLinked = Set<String>()
    for (fn, f) in fs {
      // The varyings the fragment shader reads, which a partner must declare with the same types.
      let (_, used) = CodeGen.reach(f.program)
      let reads = used.filter { f.program.variables[$0].storage == .varying }.map { f.program.variables[$0] }
      for (vn, v) in vs {
        let declares = reads.allSatisfy { r in
          v.program.variables.contains { $0.storage == .varying && $0.name == r.name && Program.sameType($0.type, v.program, r.type, f.program) }
        }
        guard declares else { continue }
        // glmark2's pairs share their uniforms' types; a vertex shader whose uniform clashes with the fragment
        // shader's is another scene's.
        let clash = v.program.variables.contains { x in
          x.storage == .uniform && f.program.variables.contains { $0.storage == .uniform && $0.name == x.name && !Program.sameType($0.type, f.program, x.type, v.program) }
        }
        if clash { continue }
        pairs += 1
        do {
          let p = try link(vertex: v, fragment: f, attributeBindings: [])
          _ = try lowerAndCompile(p, .vertex, run: false)
          try withKnownIssue("the Valhall backend has no texture access in a vertex shader (glmark2's terrain)") {
            _ = try lowerAndCompile(p, .vertex)
          } when: {
            v.program.variables.contains { $0.storage == .uniform && $0.type.isSampler && $0.read }
          }
          _ = try lowerAndCompile(p, .fragment)
          fragmentsLinked.insert(fn)
          vertexLinked.insert(vn)
        } catch let e as GLSLError {
          failed.append("\(vn) + \(fn): link: \(e.log)")
        } catch {
          failed.append("\(vn) + \(fn): \(error)")
        }
      }
    }
    #expect(failed.isEmpty, "\(failed.count) of \(pairs) pairs failed:\n\(failed.prefix(12).joined(separator: "\n"))")
    // Every fragment shader and every vertex shader has a partner.
    #expect(fragmentsLinked.count == fs.count, "fragment shaders with no partner: \(fs.map { $0.0 }.filter { !fragmentsLinked.contains($0) })")
    #expect(vertexLinked.count == vs.count, "vertex shaders with no partner: \(vs.map { $0.0 }.filter { !vertexLinked.contains($0) })")
  }
}
