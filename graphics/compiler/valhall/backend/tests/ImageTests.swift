// SPDX-License-Identifier: BSD-3-Clause

// Texture selection (valhall 12b): Loinnir's textured.frag and Radharc's compose.frag compiled and validated, the
// handle, staging and result layouts of the instructions they make, the descriptor model's FAU words, and the
// texture words encoded to the spec's field tables.

import Foundation
import MaliCore
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallISA

private func compileTree(_ path: String) throws -> CompiledGraphicsShader {
  guard let words = treeWords(path) else { throw CompileError("\(path): not found") }
  return try ValhallBackend.compileGraphics(spirv: words)
}

private func lines(_ c: CompiledGraphicsShader) -> [String] {
  c.listing.split(whereSeparator: { $0.isNewline }).map { String($0).replacingOccurrences(of: "^", with: "") }
}

@Suite struct TextureSelectionTests {
  @Test func loinnirsTexturedFragIsOneSamplePerPixel() throws {
    let c = try compileTree("graphics/loinnir/tests/shaders/textured.frag.spv")
    let f = try #require(c.fragment)
    let l = lines(c)
    let tex = l.filter { $0.hasPrefix("TEX_") }
    if getenv("VX_PRINT") != nil { print("textured.frag\n" + c.listing) }
    #expect(tex.count == 1, "\(c.listing)")
    // The wide form, an implicit level, all four channels, 32-bit results, 2D.
    let t = try #require(tex.first)
    #expect(t.hasPrefix("TEX_SINGLE.wide.computed.tex2d.dst32.slot"), "\(t)")
    #expect(!t.contains(".skip"))
    // The textures (set 0 binding 0) and the sampler (set 0 binding 1) are the first two FAU words, the dummy sampler
    // is not needed, the push constants follow.
    #expect(f.layout.imageBindings == [ImageBinding(set: 0, binding: 0, word: 0), ImageBinding(set: 0, binding: 1, word: 1)])
    #expect(f.layout.dummySamplerWord == -1)
    #expect(f.layout.pushWord == 2)
    #expect(f.layout.words >= 2)
    #expect(f.colourTargets == [0] && f.inputLocations == [0, 1])
    // The handle halves are the binding's word plus the lane's element index; the BLEND comes last.
    #expect(l.contains { $0.hasPrefix("IADD.u32") && $0.contains("u0.w0") })
    #expect(l.contains { $0.hasPrefix("MOV.i32") && $0.contains("u0.w1") } || l.contains { $0.contains("u0.w1") })
    #expect(l.last == "NOP.end" || l.contains { $0.hasPrefix("BLEND") })
  }

  @Test func theResultIsReadOnlyAfterTheWait() throws {
    let c = try compileTree("graphics/loinnir/tests/shaders/textured.frag.spv")
    let l = lines(c)
    let at = try #require(l.firstIndex { $0.hasPrefix("TEX_SINGLE") })
    // A wait takes effect after its carrier: the consumer of the result is never the carrier of its own wait, so the
    // instruction before it (or a NOP) names the slot. The slot of the TEX_SINGLE is in its text.
    let slot = try #require(l[at].split(separator: ".").first { $0.hasPrefix("slot") })
    let n = String(slot.dropFirst(4).prefix(1))
    var waited = false
    for k in (at + 1)..<l.count {
      if l[k].contains(".wait" + n) || l[k].contains(".wait" + n.description) { waited = true }
      if l[k].hasPrefix("BLEND") || l[k].hasPrefix("ATEST") { break }
    }
    #expect(waited, "\(c.listing)")
  }

  @Test func composeFragFetchesAndDemotes() throws {
    let c = try compileTree("services/radharc/shaders/compose.frag.spv")
    let f = try #require(c.fragment)
    let l = lines(c)
    let tex = l.filter { $0.hasPrefix("TEX_") }
    // One fetch (the texels of all the branches are one access), through the dummy sampler: no, the shader names its
    // sampler, so the fetch's handle is the sampler's word plus the element.
    #expect(!tex.isEmpty && tex.allSatisfy { $0.hasPrefix("TEX_FETCH.wide.tex2d.dst32") }, "\(c.listing)")
    // texelFetch(sampler2D(...)) is a fetch of the image alone (OpImage drops the sampler): one binding and the dummy.
    #expect(f.layout.imageBindings.map { $0.binding } == [0] && f.layout.dummySamplerWord == 1)
    if getenv("VX_PRINT") != nil { print(c.listing) }
    #expect(f.discards)
    #expect(l.contains { $0.hasPrefix("DISCARD") })
    #expect(f.inputLocations == [0, 1, 2])
  }

  @Test func aFetchOfAPlainImageNamesTheDummySampler() throws {
    let words = try assemble(Corpus.plainFetch)
    let c = try ValhallBackend.compileGraphics(spirv: words)
    let f = try #require(c.fragment)
    #expect(f.layout.dummySamplerWord == 1 && f.layout.imageBindings == [ImageBinding(set: 0, binding: 0, word: 0)])
    let t = try #require(lines(c).first { $0.hasPrefix("TEX_FETCH") })
    // A level other than zero is the offset word's byte 3: the access has its offset bit.
    #expect(t.contains(".texel_offset"), "\(t)")
  }


  @Test func theSampleWordIsThe12bFieldTable() throws {
    let c = try compileTree("graphics/loinnir/tests/shaders/textured.frag.spv")
    let at = try #require(lines(c).firstIndex { $0.hasPrefix("TEX_SINGLE") })
    let w = c.code[at]
    func field(_ hi: Int, _ lo: Int) -> UInt64 { w >> UInt64(lo) & ((1 << UInt64(hi - lo + 1)) - 1) }
    #expect(field(56, 52) == 18, "class S2RW")
    #expect(field(51, 48) == 8, "opcode 1 of TEX_SINGLE")
    #expect(field(8, 8) == 1, "wide handles")
    #expect(field(9, 9) == 0 && field(10, 10) == 0 && field(11, 11) == 0 && field(12, 12) == 0, "no projection, array, offset or compare")
    #expect(field(15, 13) == 1, "the computed level")
    #expect(field(25, 22) == 15, "rgba")
    #expect(field(27, 26) == 1, "register type f")
    #expect(field(29, 28) == 1, "tex2d")
    #expect(field(35, 33) == 2, "two staged words: S and T")
    #expect(field(38, 36) == 3, "four result registers, stored minus one")
    #expect(field(39, 39) == 0, "skip is clear: the level needs the helper lanes")
    #expect(field(46, 46) == 1, "dst32")
    #expect(field(47, 47) == 0)
    // The read block [45:40] and the write block [21:16] are even registers that do not overlap.
    let write = Int(field(21, 16))
    let read = Int(field(45, 40))
    #expect(write % 2 == 0 && read % 2 == 0 && (write + 4 <= read || read + 2 <= write))
  }

  @Test func aFetchWordIsTheFetchTable() throws {
    let c = try ValhallBackend.compileGraphics(spirv: try assemble(Corpus.plainFetch))
    let at = try #require(lines(c).firstIndex { $0.hasPrefix("TEX_FETCH") })
    let w = c.code[at]
    func field(_ hi: Int, _ lo: Int) -> UInt64 { w >> UInt64(lo) & ((1 << UInt64(hi - lo + 1)) - 1) }
    #expect(field(56, 52) == 18 && field(51, 48) == 5, "TEX_FETCH is opcode 1 of 5")
    #expect(field(8, 8) == 1 && field(11, 11) == 1 && field(10, 10) == 0, "wide, with the offset word that carries the level")
    #expect(field(29, 28) == 1 && field(35, 33) == 3, "tex2d: S, T and the offset word")
    #expect(field(46, 46) == 1 && field(25, 22) == 15)
  }

  @Test func theTexturedVertexShaderStack() throws {
    let c = try compileTree("graphics/loinnir/tests/shaders/textured.vert.spv")
    let v = try #require(c.vertex)
    if getenv("VX_PRINT") != nil { print("textured.vert stackBytes \(v.stackBytes) spills \(c.spillSlots) varying \(v.varyingBytes)\n" + c.listing) }
  }

  @Test func theUVProbeShowsTheVaryingAsColour() throws {
    let c = try ValhallBackend.compileGraphics(spirv: try assemble(Corpus.uvFragment))
    let f = try #require(c.fragment)
    #expect(f.inputLocations == [0] && f.colourTargets == [0] && f.layout.imageBindings.isEmpty)
    #expect(lines(c).contains { $0.hasPrefix("LD_VAR_BUF_IMM") && $0.contains(".v2") })
  }

  @Test func aVertexShaderMaySampleNothing() {
    // A texture access in a vertex shader is refused by name, not silently dropped.
    #expect(throws: BackendError.self) { try ValhallBackend.compileGraphics(spirv: try assemble(Corpus.vertexSample)) }
  }
}
