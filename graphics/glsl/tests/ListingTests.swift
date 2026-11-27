// SPDX-License-Identifier: BSD-3-Clause

// A listing for a look, not a check: GLSL_LISTING_VS and GLSL_LISTING_FS name two files (glmark2's dump in .cache, or
// any path), and the test prints each stage's optimised IR and its Valhall instructions. Skipped unless both are set.

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif
@testable import GLSL
import ShaderCompiler
import Testing
import ValhallBackend

private func environment(_ name: String) -> String? { getenv(name).map { String(cString: $0) } }

@Suite struct ListingTests {
  @Test(.enabled(if: environment("GLSL_LISTING_VS") != nil && environment("GLSL_LISTING_FS") != nil))
  func listing() throws {
    func source(_ n: String) -> String {
      let path = n.hasPrefix("/") ? n : repositoryRoot() + "/.cache/ports/glmark2-shaders/" + n
      return String(decoding: readFile(path) ?? [], as: UTF8.self)
    }
    let p = try linkProgram(source(environment("GLSL_LISTING_VS")!), source(environment("GLSL_LISTING_FS")!))
    for stage in [GLSLStage.vertex, .fragment] {
      let variants = try lowerAndCompile(p, stage, run: false)
      print("==== \(stage): \((stage == .vertex ? p.vertexSPIRV : p.fragmentSPIRV).count) SPIR-V words")
      print(variants[2].1.text)
      let g = try ValhallBackend.compileGraphics(variants[0].1)
      print("==== \(stage): \(g.instructions.count) Valhall instructions, \(g.registersUsed) registers, \(g.spillSlots) spills")
      print(g.listing)
    }
  }
}
