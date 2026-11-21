// SPDX-License-Identifier: BSD-3-Clause

// The two shaders of a triangle, written by hand for the board before the
// compiler's graphics path exists (D174 step 2), each instruction derived from
// valhall's encoding tables (10, 11b, 12a, 12c, 13) field by field; the
// graphics/mali tests assemble the same text with ValhallISA, decode every
// word and run the validator over both shaders. Neither is a general shader:
// the position shader stores a window-space position per vertex out of a table
// in memory, and the fragment shader writes one constant colour.
//
// The position shader (arch 12: one program for both IDVS passes, which tests
// `shader_output` bit 0, 12c.4.2, 14.3.5). It has no varyings, so it does
// nothing in the varying pass.
//
//   r59  internal vertex id (preloaded: bit 11), the vertex's slot in the hardware vertex buffer
//   r60  vertex id (preloaded: bit 12), the table index
//   u0   FAU slot 0: the address of the table of 16-byte positions (x, y, z, 1/w as floats, window space, 14.3.3)
//
//    0  AND_IMM.i32 r2, shader_output.w0, #1          ; r2 = bit 0: does this pass write the position
//    1  BRANCH.not r2, offset:5                       ; if clear, go to the end (instruction 7)
//    2  SHADD.u64 [r0:r1], u0, [r60:r61].w0, shift:4  ; r0:r1 = table + vertex id * 16
//    3  LOAD.i128.slot0 @r4:r5:r6:r7, [r0:r1]         ; the position
//    4  LEA_BUF_IMM.slot0 @r8:r9, r59, index:0, table:13   ; address of the position section's slot for r59 (12c.4.1)
//    5  NOP.wait0                                     ; both slot 0 results
//    6  STORE.i128.istream.slot0.end @r4:r5:r6:r7, [r8:r9], offset:0
//    7  NOP.end
//
// The fragment shader (12c.6.4's epilogue for one render target, the colour in r0 to r3 as four f32):
//
//    0 to 2  MOV_IMM.i32 r0..r2, #colour
//    3  MOV_IMM.i32.wait0126 r3, #colour                       ; a wait acts after its carrier: slots 0, 1, 2 and 6 for ATEST
//    4  ATEST @r60, r60, 0x3F800000, atest_datum.w0            ; alpha 1.0
//    5  NOP.wait                                              ; slot 0 (ATEST's r60) and 6 and 7 for BLEND
//    6  BLEND.f32.slot0.end @r0:r1:r2:r3, blend_descriptor_0.w0, r60, skip:0
//
// Both are register class 64 for the first board run: the spec's two statements about a class 32 shader and
// r60 are reconciled (04 4.3 and 14.1.2) but the class 64 shader the compute check ran is the one known to run.

public enum TriangleShaders {
  // MARK: Instruction composers (10 section 10.2.1's word, one function per instruction of 10 section 10.15)

  /// AND_IMM.i32 (11b section 11b.3.7): class R1I 17, opcode 1 = 8, destination width 3, the immediate in `[39:8]`,
  /// src0 in `[7:0]`. `page` is the instruction's FAU page (3 for the special entries of page 3).
  public static func andImm(dst: Int, src0: UInt64, page: UInt64 = 0, immediate: UInt32) -> UInt64 {
    BringUpShader.word(page: page, class: 17, opcode1: 8, control: 3, register: UInt64(dst),
                       low: UInt64(immediate) << 8 | src0)
  }

  /// MOV_IMM.i32 (11b section 11b.3.7): IADD_IMM.i32 (opcode 1 = 0) with the zero constant (`0xC0`) as src0.
  public static func movImm(dst: Int, immediate: UInt32, flow: UInt64 = 0) -> UInt64 {
    BringUpShader.word(flow: flow, class: 17, opcode1: 0, control: 3, register: UInt64(dst), low: UInt64(immediate) << 8 | 0xC0)
  }

  /// BRANCH (13 section 13.4.1): class N1 1, opcode 1 = 15, `[47:46]` = 3, src0 `[7:0]`, the signed 27-bit offset
  /// in 8-byte instructions from the next instruction `[34:8]`, `not` `[36]`.
  public static func branch(src0: UInt64, offset: Int, not: Bool, flow: UInt64 = 0) -> UInt64 {
    BringUpShader.word(flow: flow, class: 1, opcode1: 15, control: 3, register: 0,
                       low: (not ? 1 << 36 : 0) | (UInt64(bitPattern: Int64(offset)) & 0x7FF_FFFF) << 8 | src0)
  }

  /// NOP (13 section 13.6.1): class N0 0, `[47:46]` = 3, carrying a flow value.
  public static func nop(flow: UInt64 = 0) -> UInt64 { BringUpShader.word(flow: flow, class: 0, opcode1: 0, control: 3, register: 0, low: 0) }

  /// LOAD.i128 (12a section 12a.3): class S2 6, opcode 1 = 0, control `write` (2), the first register of the
  /// block in `[45:40]`; extend `[39]` set and lane `d0` (7) in `[38:36]` as the table gives for the wide widths,
  /// staging count 4 `[35:33]`, slot `[32:30]`, width i128 (7) `[29:27]`, offset `[23:8]`, the address pair src0.
  public static func loadI128(dst: Int, address: UInt64, offset: Int16 = 0, slot: Int = 0, flow: UInt64 = 0) -> UInt64 {
    BringUpShader.word(flow: flow, class: 6, opcode1: 0, control: 2, register: UInt64(dst),
                       low: 1 << 39 | 7 << 36 | 4 << 33 | UInt64(slot & 7) << 30 | 7 << 27
                         | UInt64(UInt16(bitPattern: offset)) << 8 | address)
  }

  /// STORE.i128 with an access hint (12a section 12a.4, 12a section 12a.1.2): class S2 6, opcode 1 = 1, control
  /// `read` (1), width 7, staging count 4, the access in `[26:24]` (`istream` is 1).
  public static func storeI128(data: Int, address: UInt64, access: UInt64, offset: Int16 = 0, slot: Int = 0, flow: UInt64 = 0)
    -> UInt64
  {
    BringUpShader.word(flow: flow, class: 6, opcode1: 1, control: 1, register: UInt64(data),
                       low: 4 << 33 | UInt64(slot & 7) << 30 | 7 << 27 | access << 24
                         | UInt64(UInt16(bitPattern: offset)) << 8 | address)
  }

  /// LEA_BUF_IMM (12a section 12a.5.2): class S1 5, opcode 1 = 14, control `write`, staging count 2, the first
  /// register of the address pair in `[45:40]`, the table code `[11:8]` and buffer index `[19:12]`, the element
  /// index src0.
  public static func leaBufImm(dst: Int, element: UInt64, tableCode: UInt64, index: UInt64, slot: Int = 0) -> UInt64 {
    BringUpShader.word(class: 5, opcode1: 14, control: 2, register: UInt64(dst),
                       low: 2 << 33 | UInt64(slot & 7) << 30 | index << 12 | tableCode << 8 | element)
  }

  /// ATEST (12c section 12c.6.1): class S3 7, opcode 1 = 13, control `write`, the destination r60, staging count 1,
  /// slot 0; src0 the input coverage, src1 the alpha, src2 the alpha-test datum.
  public static func atest(src0: UInt64, src1: UInt64, src2: UInt64, flow: UInt64 = 0) -> UInt64 {
    BringUpShader.word(flow: flow, class: 7, opcode1: 13, control: 2, register: 60,
                       low: 1 << 33 | src2 << 16 | src1 << 8 | src0)
  }

  /// BLEND.f32 (12c section 12c.6.3): class S3 7, opcode 1 = 15, control `read`, the first register of the colour
  /// block in `[45:40]`, register format f32 (2) `[26:24]`, vector size v4 (3) `[29:28]`, staging count 4,
  /// src0 the 64-bit blend operand, src2 the coverage (r60), skip `[15:8]` in 8-byte instructions.
  public static func blendF32(colour: Int, descriptor: UInt64, coverage: UInt64, skip: Int = 0, slot: Int = 0, flow: UInt64 = 0)
    -> UInt64
  {
    BringUpShader.word(flow: flow, class: 7, opcode1: 15, control: 1, register: UInt64(colour),
                       low: 4 << 33 | UInt64(slot & 7) << 30 | 3 << 28 | 2 << 24 | coverage << 16
                         | UInt64(skip & 0xFF) << 8 | descriptor)
  }

  // MARK: Flow values (10 section 10.9.2)

  public static let flowWait0: UInt64 = 1
  public static let flowWait0126: UInt64 = 8
  public static let flowWait: UInt64 = 9

  // MARK: Source bytes (10 section 10.5)

  /// A special FAU word: `0xE0 | entry << 1 | word` (10.5.3); the page is the instruction's FAU page field.
  public static func special(entry: Int, word: Int = 0) -> UInt64 { 0xE0 | UInt64(entry & 15) << 1 | UInt64(word & 1) }
  /// `shader_output`: page 3 entry 4 (arch 12 and later).
  public static let shaderOutput: UInt64 = special(entry: 4)
  /// `atest_datum`: page 0 entry 5. `blend_descriptor_0`: page 0 entry 8 (a 64-bit slot, bit 0 clear).
  public static let atestDatum: UInt64 = special(entry: 5)
  public static let blendDescriptor0: UInt64 = special(entry: 8)
  /// The small constants (10.5.2): index `0xC0 | n`; 16 is the float 1.0.
  public static let constantOne: UInt64 = 0xC0 | 16
  /// r60: the fragment's cumulative coverage.
  public static let coverage: UInt64 = BringUpShader.registerSource(60)

  // MARK: The position shader

  /// The preload mask: r59 (internal vertex id, bit 11) and r60 (vertex id, bit 12) of a vertex shader (14.1.3).
  public static let positionPreloadMask: UInt16 = 1 << 11 | 1 << 12
  /// The table the position shader reads: 16 positions of 16 bytes. Lanes the hardware starts beyond the draw's
  /// vertices read zeros there (a warp is 16 lanes, 10.1).
  public static let positionTableEntries = 16
  public static let positionBytes = 16

  /// The eight instructions above.
  public static var positionWords: [UInt64] {
    [
      andImm(dst: 2, src0: shaderOutput, page: 3, immediate: 1),
      branch(src0: BringUpShader.registerSource(2), offset: 5, not: true),
      BringUpShader.shadd64(dst: 0, src0: BringUpShader.fauSource(slot: 0), src1: BringUpShader.registerSource(60),
                            widenW0: true, shift: 4),
      loadI128(dst: 4, address: BringUpShader.registerSource(0)),
      leaBufImm(dst: 8, element: BringUpShader.registerSource(59), tableCode: 13, index: 0),
      nop(flow: flowWait0),
      storeI128(data: 4, address: BringUpShader.registerSource(8), access: 1, flow: BringUpShader.flowEnd),
      nop(flow: BringUpShader.flowEnd),
    ]
  }

  // MARK: The fragment shader

  /// The preload mask: r60, the cumulative coverage (bit 12), which ATEST and BLEND read (14.4.3).
  public static let fragmentPreloadMask: UInt16 = 1 << 12

  /// The seven instructions above, the colour four f32 bit patterns (R, G, B, A).
  public static func fragmentWords(colour: [UInt32]) -> [UInt64] {
    [
      movImm(dst: 0, immediate: colour[0]), movImm(dst: 1, immediate: colour[1]),
      movImm(dst: 2, immediate: colour[2]), movImm(dst: 3, immediate: colour[3], flow: flowWait0126),
      atest(src0: coverage, src1: constantOne, src2: atestDatum),
      nop(flow: flowWait),
      blendF32(colour: 0, descriptor: blendDescriptor0, coverage: coverage, flow: BringUpShader.flowEnd),
    ]
  }
}
