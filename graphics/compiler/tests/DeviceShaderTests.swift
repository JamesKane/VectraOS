// SPDX-License-Identifier: BSD-3-Clause

// The SPIR-V gpu-test (drivers/gpu/tests/native) compiles on the device, as Swift arrays
// (drivers/gpu/tests/native/generated/CompilerShaders.swift). SPIR-V is made on the host (D55); these
// are the corpus's shaders, assembled. The test regenerates the file's text and fails when the committed
// file differs; `VX_REGENERATE_SHADERS=1 swift test --filter DeviceShaderTests` rewrites it.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
import ShaderCompiler
import ShaderTestKit
import Testing

/// The shaders gpu-test compiles, by the name its array has.
let deviceShaders: [(name: String, text: String)] = [
  ("globalID", Corpus.globalID), ("saxpy", Corpus.saxpy), ("reduce", Corpus.reduce),
  ("triangleVertex", Corpus.triangleVertex), ("triangleFragment", Corpus.triangleFragment),
]

func deviceShadersSwift() throws -> String {
  var out = """
    // SPDX-License-Identifier: BSD-3-Clause
    //
    // Generated from graphics/compiler/testkit/Corpus.swift by the ShaderCompilerTests' DeviceShaderTests.
    // Do not edit; regenerate (VX_REGENERATE_SHADERS=1 swift test --filter DeviceShaderTests).
    // The SPIR-V gpu-test compiles on the device, as words.

    enum CompilerShaders {

    """
  for (name, text) in deviceShaders {
    let words = try assemble(text)
    out += "  static let \(name): [UInt32] = [\n"
    var i = 0
    while i < words.count {
      var row = ""
      for w in words[i..<min(i + 8, words.count)] {
        var h = String(w, radix: 16)
        while h.count < 8 { h = "0" + h }
        row += (row.isEmpty ? "" : ", ") + "0x" + h
      }
      out += "    " + row + ",\n"
      i += 8
    }
    out += "  ]\n"
  }
  return out + "}\n"
}

/// SPIR-V of the tree's own shaders that gpu-test compiles too (the generated file TexturedShaders.swift): Loinnir's
/// textured quad, the shaders its draw tests run, so the board draws what Loinnir would.
let deviceTreeShaders: [(name: String, path: String)] = [
  ("texturedVertex", "graphics/loinnir/tests/shaders/textured.vert.spv"),
  ("texturedFragment", "graphics/loinnir/tests/shaders/textured.frag.spv"),
]

struct TreeShaderError: Error { var text: String }

func treeShadersSwift() throws -> String {
  var out = """
    // SPDX-License-Identifier: BSD-3-Clause
    //
    // Generated from the SPIR-V in the tree (graphics/loinnir/tests/shaders) by the ShaderCompilerTests' DeviceShaderTests.
    // Do not edit; regenerate (VX_REGENERATE_SHADERS=1 swift test --filter DeviceShaderTests).
    // Loinnir's textured quad: gpu-test compiles these on the device (Textured.swift).

    enum TexturedShaders {

    """
  for (name, path) in deviceTreeShaders {
    guard let bytes = readFile(repoPath(path)) else { throw TreeShaderError(text: "\(path): not found") }
    let words = wordsOf(bytes)
    out += "  static let \(name): [UInt32] = [\n"
    var i = 0
    while i < words.count {
      var row = ""
      for w in words[i..<min(i + 8, words.count)] {
        var h = String(w, radix: 16)
        while h.count < 8 { h = "0" + h }
        row += (row.isEmpty ? "" : ", ") + "0x" + h
      }
      out += "    " + row + ",\n"
      i += 8
    }
    out += "  ]\n"
  }
  return out + "}\n"
}

@Suite struct DeviceShaderTests {
  @Test func committedTreeArraysAreCurrent() throws {
    let path = repoPath("drivers/gpu/tests/native/generated/TexturedShaders.swift")
    let text = try treeShadersSwift()
    if getenv("VX_REGENERATE_SHADERS") != nil {
      guard let f = fopen(path, "wb") else {
        Issue.record("can't write \(path)")
        return
      }
      _ = Array(text.utf8).withUnsafeBufferPointer { fwrite($0.baseAddress, 1, $0.count, f) }
      fclose(f)
    }
    let committed = readFile(path).map { String(decoding: $0, as: UTF8.self) }
    #expect(committed == text, "\(path) is stale: VX_REGENERATE_SHADERS=1 swift test --filter DeviceShaderTests")
  }

  @Test func committedArraysAreCurrent() throws {
    let path = repoPath("drivers/gpu/tests/native/generated/CompilerShaders.swift")
    let text = try deviceShadersSwift()
    if getenv("VX_REGENERATE_SHADERS") != nil {
      guard let f = fopen(path, "wb") else {
        Issue.record("can't write \(path)")
        return
      }
      _ = Array(text.utf8).withUnsafeBufferPointer { fwrite($0.baseAddress, 1, $0.count, f) }
      fclose(f)
    }
    let committed = readFile(path).map { String(decoding: $0, as: UTF8.self) }
    #expect(committed == text, "\(path) is stale: VX_REGENERATE_SHADERS=1 swift test --filter DeviceShaderTests")
  }
}
