// SPDX-License-Identifier: BSD-3-Clause

// Encoded examples the spec gives in running text rather than in a table
// (valhall 11a.5, 11a.11, 11b.3.3 to 11b.7.2, 12a.9, 13.4.2, 13.6.3, 13.8,
// 13.9.2 and 13.11).

let specWordsExtra: [SpecWord] = [
  SpecWord(
    section: "11a.5", asm: "FMA_RSCALE.f32.left.wait0126 r0, r1^, r2^, 0x0.neg, r0^", word: 0x4162_C004_40C0_4241,
    arch: 12),
  SpecWord(section: "11a.11", asm: "FROUND.v2f16.round_down r0.h0, r0", word: 0x0090_4000_A00F_0000, arch: 10),
  SpecWord(section: "11b.3.3", asm: "HADD.v4s8.round_up r0, r1^, r0^", word: 0x00AA_C000_400B_4041, arch: 10),
  SpecWord(section: "11b.3.5", asm: "SHADD.u64 [r0:r1], u1, [r60:r61].w0, shift:2", word: 0x01A3_C000_2027_3C82, arch: 12),
  SpecWord(section: "11b.3.8", asm: "IDPADD.v4u8.saturate r0, r1, r2, r3", word: 0x00C2_C000_4103_0201, arch: 12),
  SpecWord(section: "11b.4.1", asm: "IABS.s32 r1, r2.b2", word: 0x0091_C160_0008_0002, arch: 12),
  SpecWord(
    section: "11b.4.3", asm: "ICMP_MULTI.u32.gt.m1 r2, r5^, r7^, r2^", word: 0x00F0_C201_8242_4745, arch: 12),
  SpecWord(
    section: "11b.4.3", asm: "ICMP_MULTI.u32.gt.c r2, r4^, r6^, 0x0", word: 0x00F0_C201_C2C0_4644, arch: 12),
  SpecWord(section: "11b.6.1", asm: "CLZ.u32 r12, r11", word: 0x0091_CC00_0004_000B, arch: 12),
  SpecWord(section: "11b.6.1", asm: "CLZ.v2u16.mask r0, r1.h10", word: 0x0091_C000_5005_0001, arch: 12),
  SpecWord(section: "11b.6.2", asm: "POPCOUNT.i32 r62, r10^", word: 0x0091_FE00_000C_004A, arch: 12),
  SpecWord(section: "11b.6.3", asm: "BITREV.i32 r0, r1", word: 0x0091_C000_000D_0001, arch: 12),
  SpecWord(section: "11b.7.1", asm: "MOV.i32 r1, r2", word: 0x0091_C100_0000_0002, arch: 12),
  SpecWord(section: "11b.7.2", asm: "SWZ.v2i16 r0, r1.h10", word: 0x00A1_C010_0800_C001, arch: 12),
  SpecWord(section: "12a.9", asm: "BARRIER.slot7.wait", word: 0x4845_C001_C000_0000, arch: 12),
  SpecWord(
    section: "13.4.2", asm: "JUMP.not.absolute.wait0 0x0, blend_descriptor_0.w1", word: 0x082F_C110_0000_F1C0,
    arch: 12),
  SpecWord(section: "13.6.3", asm: "DISCARD.f32.ne r2, 0x0", word: 0x0020_C003_0000_C002, arch: 12),
  SpecWord(section: "13.9.2", asm: "WMASK.subgroup16 r1, r2", word: 0x0095_C130_0000_0002, arch: 12),
  SpecWord(section: "13.11", asm: "LD_GCLK.slot0.cycle_counter @r4:r5", word: 0x0044_8404_0000_0006, arch: 12),
]

/// Every example: the tables' and the running text's.
let allSpecWords: [SpecWord] = specWords + specWordsExtra
