// SPDX-License-Identifier: BSD-3-Clause

// The two hand-assembled shaders of a triangle (TriangleShaders) checked three
// ways: the composer against every literal word the spec prints for the same
// instruction; each word against ValhallISA's assembler (the text in
// RenderShaders.swift's header) and decoder; and both programs through ValhallISA's validator
// for their stage. MaliCore itself does not depend on the compiler: only this
// test target does.

import MaliCore
import Testing
import ValhallISA

private let isa = ISATable.shared

// MARK: The composer against the spec's printed words

@Test func theComposersReproduceTheWordsTheSpecPrints() {
  typealias S = TriangleShaders
  // 11b section 11b.3.7.
  #expect(S.movImm(dst: 5, immediate: 0x1234_5678) == 0x0110_C512_3456_78C0)
  #expect(S.andImm(dst: 0, src0: BringUpShader.registerSource(1), immediate: 0xFF) == 0x0118_C000_0000_FF01)
  // 13 section 13.4.1: the conditional branch with reconverge and the unconditional backward one; 13.6.1's NOPs.
  #expect(S.branch(src0: BringUpShader.registerSource(1, lastUse: true), offset: 3, not: false, flow: 10)
    == 0x501F_C000_0000_0341)
  #expect(S.branch(src0: 0xC0, offset: -8, not: true) == 0x001F_C017_FFFF_F8C0)
  #expect(S.nop() == 0x0000_C000_0000_0000 && S.nop(flow: S.flowWait0126) == 0x4000_C000_0000_0000)
  #expect(S.nop(flow: S.flowWait) == 0x4800_C000_0000_0000 && S.nop(flow: BringUpShader.flowEnd) == 0x7800_C000_0000_0000)
  // 12a sections 12a.3.1 and 12a.4.2.
  #expect(S.loadI128(dst: 4, address: BringUpShader.fauSource(slot: 0)) == 0x0060_84F8_3800_0080)
  #expect(S.storeI128(data: 8, address: BringUpShader.registerSource(4, lastUse: true), access: 1,
                      flow: BringUpShader.flowEnd) == 0x7861_4808_3900_0044)
  // 12c section 12c.10.
  #expect(S.atest(src0: S.coverage, src1: 0xD0, src2: S.atestDatum, flow: 13) == 0x687D_BC02_00EA_D03C)
  #expect(S.blendF32(colour: 0, descriptor: S.blendDescriptor0, coverage: S.coverage, flow: BringUpShader.flowEnd)
    == 0x787F_4008_323C_00F0)
  #expect(S.blendF32(colour: 0, descriptor: 0xF2, coverage: S.coverage) == 0x007F_4008_323C_00F2)
  // The source bytes of 10 section 10.5: shader_output (page 3 entry 4), atest_datum (page 0 entry 5), blend_descriptor_0.
  #expect(S.shaderOutput == 0xE8 && S.atestDatum == 0xEA && S.blendDescriptor0 == 0xF0 && S.constantOne == 0xD0)
}

// MARK: The assembler's text against the words

private let positionText = [
  "AND_IMM.i32 r2, shader_output.w0, #1",
  "BRANCH.not r2, offset:5",
  "SHADD.u64 r0:r1, u0, r60:r61.w0, shift:4",
  "LOAD.i128.slot0 @r4:r5:r6:r7, [r0:r1], offset:0",
  "LEA_BUF_IMM.slot0 @r8:r9, r59, index:0, table:13",
  "NOP.wait0",
  "STORE.i128.istream.slot0.end @r4:r5:r6:r7, [r8:r9], offset:0",
  "NOP.end",
]

private let fragmentText = [
  "MOV_IMM.i32 r0, #0x3F800000",
  "MOV_IMM.i32 r1, #0x3F000000",
  "MOV_IMM.i32 r2, #0x0",
  "MOV_IMM.i32.wait0126 r3, #0x3F800000",
  "ATEST @r60, r60, 0x3F800000, atest_datum.w0",
  "NOP.wait",
  "BLEND.f32.slot0.end @r0:r1:r2:r3, blend_descriptor_0.w0, r60, skip:0",
]

private let colour: [UInt32] = [0x3F80_0000, 0x3F00_0000, 0, 0x3F80_0000]

private func decoded(_ words: [UInt64]) throws -> [ValhallISA.Instruction] {
  try words.map { try isa.decode($0, arch: 12, aliases: true) }
}

@Test func thePositionShaderIsTheEightInstructionsOfItsHeader() throws {
  let words = TriangleShaders.positionWords
  #expect(words == [
    0x0718_C200_0000_01E8, 0x001F_C010_0000_0502, 0x01A3_C000_2047_3C80, 0x0060_84F8_3800_0000,
    0x005E_8804_0000_0D3B, 0x0800_C000_0000_0000, 0x7861_4408_3900_0008, 0x7800_C000_0000_0000,
  ])
  #expect(words.count == positionText.count)
  for (i, line) in positionText.enumerated() {
    let assembled = try isa.assemble(line)
    #expect(try isa.encode(assembled) == words[i], "instruction \(i): \(line)")
    #expect(try isa.decode(words[i], arch: 12, aliases: true) == assembled, "instruction \(i) decodes to \(line)")
  }
}

@Test func theFragmentShaderIsTheSevenInstructionsOfItsHeader() throws {
  let words = TriangleShaders.fragmentWords(colour: colour)
  #expect(words == [
    0x0110_C03F_8000_00C0, 0x0110_C13F_0000_00C0, 0x0110_C200_0000_00C0, 0x4110_C33F_8000_00C0,
    0x007D_BC02_00EA_D03C, 0x4800_C000_0000_0000, 0x787F_4008_323C_00F0,
  ])
  for (i, line) in fragmentText.enumerated() {
    let assembled = try isa.assemble(line)
    #expect(try isa.encode(assembled) == words[i], "instruction \(i): \(line)")
    #expect(try isa.decode(words[i], arch: 12, aliases: true) == assembled, "instruction \(i) decodes to \(line)")
  }
}

@Test func theDecoderNamesTheInstructionsAndTheFlowBits() throws {
  let v = try decoded(TriangleShaders.positionWords).map { isa.disassemble($0) }
  #expect(v.count == 8)
  #expect(v[0].hasPrefix("AND_IMM") && v[1].hasPrefix("BRANCH") && v[2].hasPrefix("SHADD") && v[3].hasPrefix("LOAD"))
  #expect(v[4].hasPrefix("LEA_BUF_IMM") && v[5].hasPrefix("NOP") && v[6].hasPrefix("STORE") && v[7] == "NOP.end")
  #expect(v[6].contains("istream") && v[6].contains("end"))
  let f = try decoded(TriangleShaders.fragmentWords(colour: colour)).map { isa.disassemble($0) }
  #expect(f[3].contains("wait0126") && f[5] == "NOP.wait" && f[6].hasPrefix("BLEND") && f[6].contains("end"))
}

// MARK: The validator

private func violations(_ words: [UInt64], stage: ShaderStage) throws -> [String] {
  isa.validate(try decoded(words), options: ValidatorOptions(arch: 12, stage: stage, registerClass: .class64))
    .map { "\($0.rule) at \($0.instruction): \($0.message)" }
}

@Test func theValidatorAcceptsBothShaders() throws {
  #expect(try violations(TriangleShaders.positionWords, stage: .vertex) == [])
  #expect(try violations(TriangleShaders.fragmentWords(colour: colour), stage: .fragment) == [])
}

@Test func theValidatorRefusesTheEpilogueWithItsWaitsLeftOut() throws {
  // ATEST without slot 6, and BLEND without slots 6 and 7 (10.9.2): a missed wait is a test failure, not a hang.
  var words = TriangleShaders.fragmentWords(colour: colour)
  words[3] = TriangleShaders.movImm(dst: 3, immediate: colour[3])  // the wait for ATEST rides on the instruction before it
  words[4] = TriangleShaders.atest(src0: TriangleShaders.coverage, src1: TriangleShaders.constantOne,
                                   src2: TriangleShaders.atestDatum)
  words[5] = TriangleShaders.nop()
  #expect(try !violations(words, stage: .fragment).isEmpty)
}

@Test func theShadersUseOnlyRegistersTheirStageHasAndTheClassAllows() throws {
  // Class 64 names r0 to r63; the position shader reads r59 and r60 (the preload mask names both) and the
  // fragment shader r60 (its mask names it).
  #expect(TriangleShaders.positionPreloadMask == 0x1800 && TriangleShaders.fragmentPreloadMask == 0x1000)
  func registers(_ words: [UInt64]) throws -> Set<Int> {
    var used = Set<Int>()
    for i in try decoded(words) {
      for s in i.sources where s.kind == .register { used.insert(s.register) }
    }
    return used
  }
  let v = try registers(TriangleShaders.positionWords)
  #expect(v.contains(59) && v.contains(60) && v.max()! <= 63)
  let f = try registers(TriangleShaders.fragmentWords(colour: colour))
  #expect(f.contains(60) && f.max()! <= 63)
}
