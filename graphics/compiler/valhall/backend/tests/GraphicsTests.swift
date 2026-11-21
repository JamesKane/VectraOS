// SPDX-License-Identifier: BSD-3-Clause

// The vertex and fragment stages: the triangle's shaders (and Loinnir's, with a varying) compiled and validated,
// the ABI they follow (preloads, FAU words, epilogues), their listings, and the compiled position shader run on the
// interpreter against the hand-assembled one the board ran.

import Foundation
import MaliCore
import ShaderCompiler
import ShaderTestKit
import Testing
import ValhallBackend
import ValhallBridge
import ValhallISA

func compileGraphicsText(_ text: String, options: BackendOptions = BackendOptions()) throws -> CompiledGraphicsShader {
  try ValhallBackend.compileGraphics(try lowered(text), options: options)
}

private func bits(_ f: Float) -> UInt32 { f.bitPattern }

private func bytesOf(_ words: [UInt32]) -> [UInt8] {
  var out: [UInt8] = []
  for w in words { out += [UInt8(w & 0xFF), UInt8(w >> 8 & 0xFF), UInt8(w >> 16 & 0xFF), UInt8(w >> 24)] }
  return out
}

private let isa = ISATable.shared

/// The listing with the last-use marks left out, for comparisons with hand-written text.
private func plain(_ listing: String) -> [String] {
  var out: [String] = []
  for line in listing.split(whereSeparator: { $0.isNewline }) { out.append(String(line).replacingOccurrences(of: "^", with: "")) }
  return out
}

@Suite struct GraphicsABITests {
  @Test func theTrianglesVertexShaderFollowsTheDocumentedABI() throws {
    let c = try compileGraphicsText(Corpus.triangleVertex)
    let v = try #require(c.vertex)
    // r59 (the internal vertex id) and r60 (the vertex index): the hand-assembled shader's mask.
    #expect(v.preloadMask == TriangleShaders.positionPreloadMask)
    #expect(v.registerClass == .r64)
    #expect(v.layout.viewportWord == 0 && v.layout.nonPerspectiveWord == -1)
    // The root pointer is the first push constant: words 6 and 7, after the viewport's three slots.
    #expect(v.layout.pushWord == 6 && v.layout.pushWords == 2 && v.layout.words == 8)
    #expect(v.varyingBytes == 0 && v.outputLocations == [] && v.attributeLocations == [])
    #expect(c.code.count == c.instructions.count)
  }

  @Test func theTrianglesFragmentShaderFollowsTheDocumentedABI() throws {
    let c = try compileGraphicsText(Corpus.triangleFragment)
    let f = try #require(c.fragment)
    #expect(f.preloadMask == TriangleShaders.fragmentPreloadMask)
    #expect(f.colourTargets == [0] && f.inputLocations == [] && !f.discards && f.nonPerspectiveMask == 0)
    #expect(f.layout.words == 0)
    // Everything after the colour is the hand-assembled epilogue: ATEST, the wait, BLEND with `end`.
    let list = plain(c.listing)
    let hand = try TriangleShaders.fragmentWords(colour: [bits(1), bits(0.5), 0, bits(1)]).map { isa.disassemble(try isa.decode($0, arch: 12, aliases: true)) }
    #expect(list.suffix(2) == hand.suffix(2), "\(list.suffix(2)) \(hand.suffix(2))")
    #expect(list[list.count - 3].hasPrefix("ATEST @r60, r60, "))
    #expect(list[list.count - 4] == "NOP.wait0126")
  }

  @Test func theVaryingShadersAgreeOnWhereAVaryingIs() throws {
    let v = try #require(try compileGraphicsText(Corpus.varyingVertex).vertex)
    let f = try #require(try compileGraphicsText(Corpus.varyingFragment).fragment)
    #expect(v.outputLocations == [0] && f.inputLocations == [0])
    #expect(v.varyingBytes == UInt32(VaryingLayout.slotBytes))
    #expect(f.layout.words == 0 && v.layout.pushWords == 2)
    // The vertex stores at the location's slot; the fragment loads from it.
    let vs = plain(try compileGraphicsText(Corpus.varyingVertex).listing)
    #expect(vs.contains("STORE.i128.estream.slot1 @r12:r13:r14:r15, [r0:r1], offset:0") || vs.contains { $0.contains("estream") })
    let fs = plain(try compileGraphicsText(Corpus.varyingFragment).listing)
    #expect(fs[0] == "LD_VAR_BUF_IMM.f32.src_f32.v4.slot0.center.store @r0:r1:r2:r3, 0x0, offset:0")
  }

  @Test func theFeatureFragmentShaderUsesWhatItReads() throws {
    let f = try #require(try compileGraphicsText(Corpus.fragmentFeatures).fragment)
    // r58 (facing), r59 (pixel position) and r60 (coverage).
    #expect(f.preloadMask == (1 << 10 | 1 << 11 | 1 << 12))
    #expect(f.colourTargets == [0, 1] && f.inputLocations == [0, 1])
    #expect(f.nonPerspectiveMask == 1 && f.discards)
    let list = plain(try compileGraphicsText(Corpus.fragmentFeatures).listing)
    #expect(list.contains("DISCARD.f32.eq 0x0, 0x0"))
    #expect(list.contains { $0.hasPrefix("BLEND.f32.slot") && $0.contains("blend_descriptor_1") && $0.contains(".end") })
    #expect(list.contains { $0.hasPrefix("LD_VAR_BUF_IMM.f32.src_flat32") && $0.hasSuffix("offset:16") })
  }

  @Test func theVertexFeatureShaderUsesWhatItReads() throws {
    let c = try compileGraphicsText(Corpus.vertexFeatures)
    let v = try #require(c.vertex)
    // r59, r60 (the attribute fetch's vertex index) and r61 (its instance index, and the instance index builtin).
    #expect(v.preloadMask == (1 << 11 | 1 << 12 | 1 << 13))
    #expect(v.attributeLocations == [0, 1] && v.outputLocations == [0, 1] && v.varyingBytes == 32)
    // The point size is accepted and not stored: the position record keeps its basic format.
    #expect(!v.storesPointSize)
    let list = plain(c.listing)
    #expect(list.contains { $0.hasPrefix("LD_ATTR_IMM.f32.v2.slot") && $0.hasSuffix("r60, r61, table:0, index:0") })
    #expect(list.contains { $0.hasPrefix("LD_ATTR_IMM.f32.v4.slot") && $0.hasSuffix("r60, r61, table:0, index:1") })
    // A component of the position written on its own stays in registers: this stage has no thread storage.
    #expect(c.spillSlots == 0)
    #expect(v.stackBytes == 0)
    // The varyings: a vec4 at location 0's slot and a flat integer at location 1's.
    #expect(list.contains { $0.hasPrefix("STORE.i128.estream") && $0.hasSuffix("offset:0") })
    #expect(list.contains { $0.hasPrefix("STORE.i32.estream") && $0.hasSuffix("offset:16") })
  }

  @Test func aClipDistanceWrittenIsRefusedByName() throws {
    let text = Corpus.vertexFeatures.replacingOccurrences(of: "%u1 = OpConstant %uint 1", with: "%u1 = OpConstant %uint 1\n%i2 = OpConstant %int 2")
      .replacingOccurrences(of: "OpReturn", with: "%cd = OpAccessChain %ptr_out_float %out %i2 %i0\nOpStore %cd %f4\nOpReturn")
    do {
      _ = try compileGraphicsText(text)
      Issue.record("accepted")
    } catch let e as CompileError {
      #expect(e.message.contains("gl_ClipDistance"), "\(e.message)")
    }
  }

  @Test func theNonPerspectiveMaskCanBeReadAtRunTime() throws {
    // A vertex shader compiled before its fragment shader is known reads the mask from the FAU.
    var o = BackendOptions()
    o.nonPerspectiveMask = nil
    let v = try #require(try compileGraphicsText(Corpus.varyingVertex, options: o).vertex)
    #expect(v.layout.nonPerspectiveWord == 6 && v.layout.pushWord == 8)
    let known = try #require(try compileGraphicsText(Corpus.varyingVertex, options: BackendOptions(nonPerspectiveMask: 1)).vertex)
    #expect(known.layout.nonPerspectiveWord == -1)
  }

  @Test func aShaderThatIsNotAGraphicsShaderIsRefused() throws {
    #expect(throws: BackendError.self) { _ = try ValhallBackend.compileGraphics(try lowered(Corpus.globalID)) }
    #expect(throws: BackendError.self) { _ = try ValhallBackend.compile(try lowered(Corpus.triangleFragment)) }
  }
}

@Suite struct GraphicsGoldenTests {
  /// The triangle's vertex shader as the backend writes it. A change to this listing is a change to the code the board
  /// runs: look at it, then update the text.
  static let triangleVertex = """
    MOV.i32 r0, u3.w0
    MOV.i32 r1, u3.w1
    MOV.i32 r2, r60
    ARSHIFT_OR.i32 r3, r60^, 0x1F1E1D1C.b3, 0x0
    IADD_IMM.i32 r4, 0x0, #0x10
    MOV.i32 r6, r4
    IMUL.u64 r6:r7, r2:r3.w0, r6^:r7^.w0
    IMUL.u32 r2, r3^, r4^
    IADD.u32 r7, r7^, r2^
    IADD.u64 r0:r1, r0^:r1^, r6^:r7^
    LOAD.i32.slot0 @r2, [r0:r1], offset:0
    LOAD.i32.slot1 @r3, [r0:r1], offset:4
    LOAD.i32.slot2 @r4, [r0:r1], offset:8
    LOAD.i32.slot0 @r5, [r0^:r1^], offset:12
    NOP.wait0
    FRCP.f32 r0, r5^
    FMA.f32 r0, 0x3F800000, r0^, 0x0.neg
    IADD_IMM.i32 r1, 0x0, #0xC7000000
    FMAX.f32 r0, r0^, r1^
    IADD_IMM.i32 r1, 0x0, #0x47000000
    FMIN.f32 r0, r0^, r1^
    FMA.f32 r1, r2^, r0, 0x0.neg
    FMA.f32.wait1 r1, r1^, u0.w0, u0.w1
    FMA.f32 r2, r3^, r0, 0x0.neg
    FMA.f32.wait2 r2, r2^, u1.w0, u1.w1
    FMA.f32 r3, r4^, r0, 0x0.neg
    FMA.f32 r3, r3^, u2.w0, u2.w1
    MOV.i32 r4, r1^
    MOV.i32 r5, r2^
    MOV.i32 r6, r3^
    MOV.i32 r7, r0^
    AND_IMM.i32 r0, shader_output.w0, #0x1
    BRANCH.not.reconverge r0^, offset:5
    LEA_BUF_IMM.slot0 @r0:r1, r59^, table:13, index:0
    NOP.wait0
    STORE.i128.istream.slot1 @r4:r5:r6:r7, [r0^:r1^], offset:0
    NOP.wait1
    NOP.reconverge
    NOP.end

    """

  static let triangleFragment = """
    MOV.i32 r0, 0x3F800000
    IADD_IMM.i32 r1, 0x0, #0x3F000000
    MOV.i32 r2, 0x0
    MOV.i32 r3, 0x3F800000
    NOP.wait0126
    ATEST @r60, r60, r3, atest_datum.w0
    NOP.wait
    BLEND.f32.slot0.end @r0:r1:r2:r3, blend_descriptor_0, r60, skip:0

    """

  @Test func theTrianglesListingsAreTheOnesTheBoardRuns() throws {
    #expect(try compileGraphicsText(Corpus.triangleVertex).listing == Self.triangleVertex)
    #expect(try compileGraphicsText(Corpus.triangleFragment).listing == Self.triangleFragment)
  }
}

@Suite struct VertexRunTests {
  /// Window-space corners of the board triangle (graphics/mali's TriangleCheck) in a 64 x 64 target, as the
  /// hand-assembled shader's table holds them: x, y, z and the reciprocal of w.
  static let corners: [(Float, Float)] = [(8, 6), (58, 20), (20, 56)]

  @Test func theCompiledPositionShaderStoresWhatTheHandAssembledOneDid() throws {
    // The hand-assembled shader copies window-space records from a table (FAU slot 0).
    let table: UInt64 = 0x1000_0000
    var windowTable: [UInt32] = []
    for (x, y) in Self.corners { windowTable += [bits(x), bits(y), bits(0.5), bits(1)] }
    while windowTable.count < 64 { windowTable.append(0) }
    let hand = try TriangleShaders.positionWords.map { try isa.decode($0, arch: 12, aliases: true) }
    let handRun = try HostRun.vertex(
      instructions: hand, fau: [UInt32(truncatingIfNeeded: table), UInt32(table >> 32)], varyingBytes: 0,
      memory: [(table, bytesOf(windowTable))])

    // The compiled shader reads clip-space records through the root pointer and transforms them itself.
    let c = try compileGraphicsText(Corpus.triangleVertex)
    let vs = try #require(c.vertex)
    let clip: UInt64 = 0x2000_0000
    var clipTable: [UInt32] = []
    for (x, y) in Self.corners { clipTable += [bits((x - 32) / 32), bits((y - 32) / 32), bits(0.5), bits(1)] }
    while clipTable.count < 64 { clipTable.append(0) }
    var push = [UInt32](repeating: 0, count: 2)
    push[0] = UInt32(truncatingIfNeeded: clip)
    push[1] = UInt32(clip >> 32)
    let block = vs.layout.block(viewport: ViewportTransform(width: 64, height: 64), push: push)
    var fau: [UInt32] = []
    for w in block { fau += [UInt32(truncatingIfNeeded: w), UInt32(w >> 32)] }
    let run = try HostRun.vertex(instructions: c.instructions, fau: fau, varyingBytes: 0, memory: [(clip, bytesOf(clipTable))])
    for v in 0..<3 {
      #expect(run.positions[v] == handRun.positions[v], "vertex \(v): \(run.positions[v]) against \(handRun.positions[v])")
    }
    #expect(handRun.positions[0] == [bits(8), bits(6), bits(0.5), bits(1)])
  }

  @Test func aVaryingIsStoredAtItsLocation() throws {
    let c = try compileGraphicsText(Corpus.varyingVertex)
    let vs = try #require(c.vertex)
    // Vertices of 32 bytes: a position (x, y) at 0 and a colour at 16.
    let base: UInt64 = 0x2000_0000
    var table: [UInt32] = []
    for n in 0..<16 {
      let f = Float(n)
      table += [bits(f / 16 - 0.5), bits(0.25), 0, 0, bits(f), bits(f + 1), bits(f + 2), bits(0.75)]
    }
    let block = vs.layout.block(viewport: ViewportTransform(width: 64, height: 32), push: [UInt32(truncatingIfNeeded: base), UInt32(base >> 32)])
    var fau: [UInt32] = []
    for w in block { fau += [UInt32(truncatingIfNeeded: w), UInt32(w >> 32)] }
    let run = try HostRun.vertex(instructions: c.instructions, fau: fau, varyingBytes: Int(vs.varyingBytes), memory: [(base, bytesOf(table))])
    for n in 0..<16 {
      let f = Float(n)
      #expect(run.varyings[n] == [bits(f), bits(f + 1), bits(f + 2), bits(0.75)], "vertex \(n): \(run.varyings[n])")
      // x = (ndc x * 32) + 32, y = (0.25 * 16) + 16, z = 0, w' = 1.
      #expect(run.positions[n] == [bits((f / 16 - 0.5) * 32 + 32), bits(0.25 * 16 + 16), bits(0), bits(1)], "vertex \(n)")
    }
  }

  /// The varying shader with the colour's alpha as the position's w.
  static let withW = Corpus.varyingVertex.replacingOccurrences(
    of: "%pos = OpCompositeConstruct %v4float %x %y %f0 %f1",
    with: "%cw = OpCompositeExtract %float %c 3\n%pos = OpCompositeConstruct %v4float %x %y %f0 %cw")

  @Test func aNoPerspectiveVaryingIsTimesW() throws {
    let base: UInt64 = 0x2000_0000
    var table: [UInt32] = []
    // w = 0.5, so the reciprocal is exactly 2.
    for n in 0..<16 { table += [0, 0, 0, 0, bits(Float(n)), bits(2), bits(3), bits(0.5)] }
    func run(_ c: CompiledGraphicsShader, mask: UInt32 = 0) throws -> VertexResult {
      let vs = try #require(c.vertex)
      let b = vs.layout.block(viewport: ViewportTransform(width: 8, height: 8), nonPerspectiveMask: mask, push: [UInt32(truncatingIfNeeded: base), UInt32(base >> 32)])
      var fau: [UInt32] = []
      for w in b { fau += [UInt32(truncatingIfNeeded: w), UInt32(w >> 32)] }
      return try HostRun.vertex(instructions: c.instructions, fau: fau, varyingBytes: Int(vs.varyingBytes), memory: [(base, bytesOf(table))])
    }
    // A smooth varying is stored as it is, a no-perspective one times the reciprocal of w.
    let smooth = try run(try compileGraphicsText(Self.withW))
    #expect(smooth.varyings[3] == [bits(3), bits(2), bits(3), bits(0.5)])
    #expect(smooth.positions[3][3] == bits(2))
    let known = try run(try compileGraphicsText(Self.withW, options: BackendOptions(nonPerspectiveMask: 1)))
    #expect(known.varyings[3] == [bits(6), bits(4), bits(6), bits(1)])
    // The mask read at run time: bit 0 set multiplies, clear leaves the value.
    let rt = try compileGraphicsText(Self.withW, options: BackendOptions(nonPerspectiveMask: nil))
    #expect(try run(rt, mask: 1).varyings[5] == [bits(10), bits(4), bits(6), bits(1)])
    #expect(try run(rt, mask: 0).varyings[5] == [bits(5), bits(2), bits(3), bits(0.5)])
  }
}

// MARK: the tree's own shaders

private func treeWords(_ rel: String, file: String = #filePath) -> [UInt32]? {
  var resolved = file
  if let r = realpath(file, nil) {
    resolved = String(cString: r)
    free(r)
  }
  var parts = resolved.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
  parts.removeLast(6)
  guard let f = fopen(parts.joined(separator: "/") + "/" + rel, "rb") else { return nil }
  defer { fclose(f) }
  var out: [UInt32] = []
  var word: UInt32 = 0
  var n = 0
  var byte: UInt8 = 0
  while fread(&byte, 1, 1, f) == 1 {
    word |= UInt32(byte) << UInt32(8 * n)
    n += 1
    if n == 4 {
      out.append(word)
      word = 0
      n = 0
    }
  }
  return out
}

@Suite struct TreeGraphicsShaderTests {
  @Test func theTreesVertexAndFragmentShadersCompile() throws {
    for path in [
      "graphics/loinnir/tests/shaders/triangle.vert.spv", "graphics/loinnir/tests/shaders/triangle.frag.spv",
      "graphics/loinnir/tests/shaders/textured.vert.spv", "services/radharc/shaders/compose.vert.spv",
    ] {
      let w = try #require(treeWords(path), "\(path)")
      let c = try ValhallBackend.compileGraphics(spirv: w)
      #expect(c.vertex != nil || c.fragment != nil, "\(path)")
      #expect(!c.instructions.isEmpty, "\(path)")
    }
  }

  @Test func loinnirsTriangleVertexShaderRunsOnTheInterpreter() throws {
    let w = try #require(treeWords("graphics/loinnir/tests/shaders/triangle.vert.spv"))
    let c = try ValhallBackend.compileGraphics(spirv: w)
    let vs = try #require(c.vertex)
    #expect(vs.outputLocations == [0] && vs.varyingBytes == 16)
    let base: UInt64 = 0x2000_0000
    var table: [UInt32] = []
    for n in 0..<16 {
      let f = Float(n)
      table += [bits(f / 16 - 0.5), bits(0.25), 0, 0, bits(f), bits(f + 1), bits(f + 2), bits(0.75)]
    }
    let block = vs.layout.block(viewport: ViewportTransform(width: 64, height: 32), push: [UInt32(truncatingIfNeeded: base), UInt32(base >> 32)])
    var fau: [UInt32] = []
    for x in block { fau += [UInt32(truncatingIfNeeded: x), UInt32(x >> 32)] }
    let run = try HostRun.vertex(instructions: c.instructions, fau: fau, varyingBytes: Int(vs.varyingBytes), memory: [(base, bytesOf(table))])
    for n in 0..<16 {
      let f = Float(n)
      #expect(run.varyings[n] == [bits(f), bits(f + 1), bits(f + 2), bits(0.75)], "vertex \(n)")
      #expect(run.positions[n] == [bits((f / 16 - 0.5) * 32 + 32), bits(0.25 * 16 + 16), bits(0), bits(1)], "vertex \(n)")
    }
  }
}
