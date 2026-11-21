// SPDX-License-Identifier: BSD-3-Clause

// Images, samplers and sampled images lowered to `tex` instructions (ir/LowerImage.swift), from the SPIR-V the tree
// has: Loinnir's textured.frag (a runtime array of textures indexed non-uniformly, one sampler, an implicit
// level) (compose.frag, which calls
// functions, is compiled whole by the backend: valhall/backend/tests/ImageTests.swift).

import ShaderCompiler
import ShaderTestKit
import Testing

func lowerTree(_ path: String) throws -> IRModule {
  guard let bytes = readFile(repoPath(path)) else { throw CompileError("\(path): not found") }
  let m = try SPIRVModule.parse(words: wordsOf(bytes))
  var ir = try IRModule.lower(m)
  try ir.optimize()
  try ir.verify(scalar: true)
  return ir
}

func texInstructions(_ ir: IRModule) -> [Inst] {
  var out: [Inst] = []
  let f = ir.functions[ir.entry]
  for b in f.blocks {
    for id in b.insts where f.insts[id].op == .tex { out.append(f.insts[id]) }
  }
  return out
}

@Suite struct ImageLowerTests {
  @Test func texturedFragIsFourImplicitSamplesOfTheArray() throws {
    let ir = try lowerTree("graphics/loinnir/tests/shaders/textured.frag.spv")
    let t = texInstructions(ir)
    #expect(t.count == 4)
    for (k, i) in t.enumerated() {
      #expect(i.imm2 == k)
      #expect(TexFlags.kind(i.imm) == TexFlags.implicit)
      #expect(TexFlags.dims(i.imm) == 2 && !TexFlags.isArrayed(i.imm))
      #expect(TexFlags.texel(i.imm) == 0)
      #expect(i.imm & TexFlags.noSampler == 0)
      // The textures are (set 0, binding 0), the sampler (set 0, binding 1).
      #expect(i.payload == [0, 1])
      #expect(i.args.count == 4)
      #expect(i.type == .f32)
    }
    // Every component is the same access: one message in the backend.
    #expect(t[0].args == t[3].args)
  }

}
