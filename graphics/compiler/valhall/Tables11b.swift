// SPDX-License-Identifier: BSD-3-Clause

// Transcribed from valhall 11b: integer, bitwise, shift and bitfield
// arithmetic. The fifteen shift-and-logic mnemonics and their nine aliases
// (11b.5) are four variants each; their rows are built from the family base
// words of 11b.5.1 and the alias table of 11b.5.3 below.

extension ISATable {
  static let table11b: String = table11bFixed + shiftFamilyRows

  static let table11bFixed = """
    # 11b.3.1 IADD, ISUB: 32-bit forms, 16-bit lanes, byte lanes (arch 10), 64-bit
    S iadd32 @s2 wd1@29:26/e.wI saturate@30/b wd0@39:36/e.wI @d1
    S iadd16 @s2 wd1@29:26/e.swI=2 saturate@30/b wd0@39:36/e.swI=2 @d1
    S iadd8 @s2 wd1@29:26/e.swB saturate@30/b wd0@39:36/e.swB @d1
    S iadd64 src0@7:0/S src1@15:8/S wd1@29:26/e.wI saturate@30/b wd0@39:36/e.wI @d64
    I IADD u32 R2 cvt 10-14 00A0000000000000 iadd32
    I IADD s32 R2 cvt 10-14 00A8000000000000 iadd32
    I IADD v2u16 R2 cvt 10-14 00A1000000000000 iadd16
    I IADD v2s16 R2 cvt 10-14 00A9000000000000 iadd16
    I IADD v4u8 R2 cvt 10-10 00A2000000000000 iadd8
    I IADD v4s8 R2 cvt 10-10 00AA000000000000 iadd8
    I IADD u64 D2 cvt 10-14 01A3C00000000000 iadd64
    I IADD s64 D2 cvt 10-14 01ABC00000000000 iadd64
    I ISUB u32 R2 cvt 10-14 00A0000000010000 iadd32
    I ISUB s32 R2 cvt 10-14 00A8000000010000 iadd32
    I ISUB v2u16 R2 cvt 10-14 00A1000000010000 iadd16
    I ISUB v2s16 R2 cvt 10-14 00A9000000010000 iadd16
    I ISUB v4u8 R2 cvt 10-10 00A2000000010000 iadd8
    I ISUB v4s8 R2 cvt 10-10 00AA000000010000 iadd8
    I ISUB u64 D2 cvt 10-14 01A3C00000010000 iadd64
    I ISUB s64 D2 cvt 10-14 01ABC00000010000 iadd64

    # 11b.3.2 IMUL: the 64-bit forms take a required widen, no saturate
    S imul64 src0@7:0/S src1@15:8/S wd1@29:26/e.wI=* wd0@39:36/e.wI=* @d64
    I IMUL u32 R2 sfu 10-14 00A00000000A0000 iadd32
    I IMUL s32 R2 sfu 10-14 00A80000000A0000 iadd32
    I IMUL v2u16 R2 sfu 10-14 00A10000000A0000 iadd16
    I IMUL v2s16 R2 sfu 10-14 00A90000000A0000 iadd16
    I IMUL v4u8 R2 sfu 10-14 00A20000000A0000 iadd8
    I IMUL v4s8 R2 sfu 10-14 00AA0000000A0000 iadd8
    I IMUL u64 D2 sfu 10-14 01A3C000000A0000 imul64
    I IMUL s64 D2 sfu 10-14 01ABC000000A0000 imul64

    # 11b.3.3 HADD (arch 10 only): the IADD forms with a rounding bit for saturate
    S hadd32 @s2 wd1@29:26/e.wI round@30/e.{round_down=0,round_up=1} wd0@39:36/e.wI @d1
    S hadd16 @s2 wd1@29:26/e.swI=2 round@30/e.{round_down=0,round_up=1} wd0@39:36/e.swI=2 @d1
    S hadd8 @s2 wd1@29:26/e.swB round@30/e.{round_down=0,round_up=1} wd0@39:36/e.swB @d1
    I HADD u32 R2 cvt 10-10 00A00000000B0000 hadd32
    I HADD s32 R2 cvt 10-10 00A80000000B0000 hadd32
    I HADD v2u16 R2 cvt 10-10 00A10000000B0000 hadd16
    I HADD v2s16 R2 cvt 10-10 00A90000000B0000 hadd16
    I HADD v4u8 R2 cvt 10-10 00A20000000B0000 hadd8
    I HADD v4s8 R2 cvt 10-10 00AA0000000B0000 hadd8

    # 11b.3.4 IADDC, ISUBB
    S iaddc @s3 carry@30/e.{none=0,c=1} @d1
    I IADDC u32 R3 cvt 10-14 00B0000000000000 iaddc
    I ISUBB u32 R3 cvt 10-14 00B0000001000000 iaddc

    # 11b.3.5 SHADD, 11b.3.6 SEG_ADD and SEG_SUB
    S shadd src0@7:0/S src1@15:8/S shift@22:20/n wd1@29:26/e.wI @d64
    I SHADD u64 D2 cvt 10-14 01A3C00000070000 shadd
    I SHADD s64 D2 cvt 10-14 01ABC00000070000 shadd
    S segadd src0@7:0/S src1@15:8/S wd1@29:26/e.wI preserve_null@39/b @d64
    I SEG_ADD u64 D2 cvt 10-14 01A3C00000060000 segadd
    I SEG_SUB u64 D2 cvt 10-14 01A3C04000060000 segadd

    # 11b.3.7 the immediate forms
    S imm32 src0@7:0/s imm@39:8/u @d1
    S immalias imm@39:8/u @d1
    I IADD_IMM i32 R1I cvt 10-14 0110000000000000 imm32
    I IADD_IMM v2i16 R1I cvt 10-14 0111000000000000 imm32
    I IADD_IMM v4i8 R1I cvt 10-10 0112000000000000 imm32
    I MOV_IMM i32 R1I cvt 10-14 01100000000000C0 immalias alias=IADD_IMM.i32
    I MOV_IMM v2i16 R1I cvt 10-14 01110000000000C0 immalias alias=IADD_IMM.v2i16
    I MOV_IMM v4i8 R1I cvt 10-10 01120000000000C0 immalias alias=IADD_IMM.v4i8
    S adr imm@39:8/i dst@45:40/r
    I ADR - R1I cvt 10-14 0710C000000000FE adr alias=IADD_IMM.i32
    I AND_IMM i32 R1I cvt 11-14 0118000000000000 imm32
    I OR_IMM i32 R1I cvt 11-14 0119000000000000 imm32
    I XOR_IMM i32 R1I cvt 11-14 011A000000000000 imm32

    # 11b.3.8 IDPADD
    S idpadd @s3 saturate@30/b @d1
    I IDPADD v4s8 R3A fma 10-14 00C2000000000000 idpadd
    I IDPADD v4u8 R3A fma 10-14 00C2000001000000 idpadd

    # 11b.4.1 IABS
    S iabs32 src0@7:0/s wd0@39:36/e.wI @d1
    S iabs16 src0@7:0/s wd0@39:36/e.swI=2 @d1
    S iabs8 src0@7:0/s wd0@39:36/e.swB @d1
    I IABS s32 R1 cvt 10-14 0091000000080000 iabs32
    I IABS v2s16 R1 cvt 10-14 0091000000090000 iabs16
    I IABS v4s8 R1 cvt 10-10 00910000000A0000 iabs8

    # 11b.4.2 ICMP_OR, ICMP_AND, ICMP; 11b.4.3 ICMP_MULTI
    S icmp32 @s3 wd1@29:26/e.wI rtype@31:30/e.rtype cmp@34:32/e.cmp=* wd0@39:36/e.wI @d1
    S icmp16 @s3 wd1@29:26/e.swI=2 rtype@31:30/e.rtype cmp@34:32/e.cmp=* wd0@39:36/e.swI=2 @d1
    S icmp8 @s3 wd1@29:26/e.swB rtype@31:30/e.rtype cmp@34:32/e.cmp=* wd0@39:36/e.swB @d1
    S icmpa32 @icmp32 -src2
    S icmpa16 @icmp16 -src2
    S icmpa8 @icmp8 -src2
    I ICMP_OR u32 R3_CMP cvt 10-14 00F0000000000000 icmp32
    I ICMP_OR s32 R3_CMP cvt 10-14 00F8000000000000 icmp32
    I ICMP_OR v2u16 R3_CMP cvt 10-14 00F1000000000000 icmp16
    I ICMP_OR v2s16 R3_CMP cvt 10-14 00F9000000000000 icmp16
    I ICMP_OR v4u8 R3_CMP cvt 10-10 00F2000000000000 icmp8
    I ICMP_OR v4s8 R3_CMP cvt 10-10 00FA000000000000 icmp8
    I ICMP_AND u32 R3_CMP cvt 10-14 00F0000001000000 icmp32
    I ICMP_AND s32 R3_CMP cvt 10-14 00F8000001000000 icmp32
    I ICMP_AND v2u16 R3_CMP cvt 10-14 00F1000001000000 icmp16
    I ICMP_AND v2s16 R3_CMP cvt 10-14 00F9000001000000 icmp16
    I ICMP_AND v4u8 R3_CMP cvt 10-10 00F2000001000000 icmp8
    I ICMP_AND v4s8 R3_CMP cvt 10-10 00FA000001000000 icmp8
    I ICMP u32 R3_CMP cvt 10-14 00F0000000C00000 icmpa32 alias=ICMP_OR.u32
    I ICMP s32 R3_CMP cvt 10-14 00F8000000C00000 icmpa32 alias=ICMP_OR.s32
    I ICMP v2u16 R3_CMP cvt 10-14 00F1000000C00000 icmpa16 alias=ICMP_OR.v2u16
    I ICMP v2s16 R3_CMP cvt 10-14 00F9000000C00000 icmpa16 alias=ICMP_OR.v2s16
    I ICMP v4u8 R3_CMP cvt 10-10 00F2000000C00000 icmpa8 alias=ICMP_OR.v4u8
    I ICMP v4s8 R3_CMP cvt 10-10 00FA000000C00000 icmpa8 alias=ICMP_OR.v4s8
    I ICMP_MULTI u32 R3_CMP cvt 10-14 00F0000002000000 icmp32
    I ICMP_MULTI s32 R3_CMP cvt 10-14 00F8000002000000 icmp32

    # 11b.4.5 MUX
    S mux32 @s3 cond@33:32/e.{neg=0,int_zero=1,fp_zero=2,bit=3}=int_zero @d1
    S mux16 @s3 wd2@25:24/e.swH=2 wd1@27:26/e.swH=2 wd0@29:28/e.swH=2 cond@33:32/e.{neg=0,int_zero=1,fp_zero=2,bit=3}=int_zero @d1
    I MUX i32 R3 sfu 10-14 00B8000000000000 mux32
    I MUX v2i16 R3 sfu 10-14 00B9000000000000 mux16
    I MUX v4i8 R3 sfu 10-14 00BA000000000000 mux32

    # 11b.5.4 NOT_OLD
    S notold src0@7:0/s @d1
    S notold64 src0@7:0/S @d64
    I NOT_OLD i32 R1 sfu 10-13 00910000000E0000 notold
    I NOT_OLD i64 D1 sfu 10-13 0191C000000E0000 notold64

    # 11b.6 CLZ, POPCOUNT, BITREV; 11b.7 MOV, SWZ, MKVEC
    S clz32 src0@7:0/s mask@30/b @d1
    S clz16 src0@7:0/s wd0@29:28/e.swH=2 mask@30/b @d1
    S un src0@7:0/s @d1
    I CLZ u32 R1 sfu 10-14 0091000000040000 clz32
    I CLZ v2u16 R1 sfu 10-14 0091000000050000 clz16
    I CLZ v4u8 R1 sfu 10-14 0091000000060000 clz32
    I POPCOUNT i32 R1 sfu 10-14 00910000000C0000 un
    I BITREV i32 R1 sfu 10-14 00910000000D0000 un
    I MOV i32 R1 cvt 10-14 0091000000000000 un
    S swz16 @iadd16 -src1 -wd1 -saturate
    S swz8 @iadd8 -src1 -wd1 -saturate
    I SWZ v2i16 R2 cvt 10-14 00A100000800C000 swz16 alias=IADD.v2u16
    I SWZ v4i8 R2 cvt 10-10 00A200000000C000 swz8 alias=IADD.v4u8
    S mkvec16 @s2 wd1@26/e.l16 wd0@28/e.l16 @d1
    S mkvec8 @s3 wd1@37:36/e.l8 wd0@39:38/e.l8 @d1
    I MKVEC v2i16 R2 cvt 10-14 00A1000000050000 mkvec16
    I MKVEC v2i8 R3 cvt 10-14 00BD000000000000 mkvec8
    """

  /// The shift-and-logic family (11b.5.1): `<shift>_<combine>` for five
  /// shifts and three combines, in four variants, and the nine aliases of
  /// 11b.5.3 with the words the spec gives.
  static let shiftFamilyRows: String = {
    // variant, class, family base word (high half), lane family, source-0 selector
    let variants: [(name: String, cls: String, high: UInt64, lane: String, sel: String)] = [
      ("i32", "R3", 0x00B4_0000, "lsh4=b0", "wI"),
      ("v2i16", "R3", 0x00B5_0000, "lsh2=0", "swI=2"),
      ("v4i8", "R3", 0x00B6_0000, "swB", "swB"),
      ("i64", "D3", 0x01B7_C000, "lsh4=b0", "wI"),
    ]
    let shifts = ["RSHIFT", "LSHIFT", "RROT", "LROT", "ARSHIFT"]
    let combines = ["AND", "OR", "XOR"]
    func word(_ v: UInt64) -> String {
      let hex = String(v, radix: 16, uppercase: true)
      return String(repeating: "0", count: 16 - hex.utf8.count) + hex
    }
    var out = "\n# 11b.5.1 the shift-and-logic family\n"
    for v in variants {
      let wide = v.name.sym == "i64"
      let srcs = wide ? "src0@7:0/S src1@15:8/S src2@23:16/S" : "src0@7:0/s src1@15:8/s src2@23:16/s"
      let base = "wd1@29:26/e." + v.lane + " not_result@30/b not2@35/b wd0@39:36/e." + v.sel
      let dst = wide ? " @d64" : " @d1"
      out += "S shift_" + v.name + " " + srcs + " " + base + dst + "\n"
      out += "S alias1_" + v.name + " @shift_" + v.name + " -src1 -wd1\n"
      out += "S alias2_" + v.name + " @shift_" + v.name + " -src2 -not2\n"
      out += "S alias3_" + v.name + " @shift_" + v.name + " -src1 -src2 -wd1 -not2 -not_result\n"
    }
    for v in variants {
      for (si, s) in shifts.enumerated() {
        for (ci, c) in combines.enumerated() {
          let w = v.high << 32 | UInt64(si) << 32 | UInt64(ci) << 24
          let unit = v.name.sym == "i32" && s.sym != "RROT" && s.sym != "LROT" ? "cvt" : "sfu"
          out += "I " + s + "_" + c + " " + v.name + " " + v.cls + " " + unit + " 10-14 " + word(w) + " shift_"
            + v.name + "\n"
        }
      }
    }
    // 11b.5.3: AND, OR, XOR, NOT, the shifts and rotates, with the spec's words (i32, v2i16, v4i8, i64)
    let aliases: [(String, String, Int, [UInt64])] = [
      (
        "AND", "LSHIFT_AND", 1,
        [0x00B4_0001_1000_C000, 0x00B5_0001_0000_C000, 0x00B6_0001_0000_C000, 0x01B7_C001_1000_C000]
      ),
      (
        "OR", "LSHIFT_OR", 1,
        [0x00B4_0001_1100_C000, 0x00B5_0001_0100_C000, 0x00B6_0001_0100_C000, 0x01B7_C001_1100_C000]
      ),
      (
        "XOR", "LSHIFT_XOR", 1,
        [0x00B4_0001_1200_C000, 0x00B5_0001_0200_C000, 0x00B6_0001_0200_C000, 0x01B7_C001_1200_C000]
      ),
      (
        "NOT", "LSHIFT_XOR", 3,
        [0x00B4_0009_12C0_C000, 0x00B5_0009_02C0_C000, 0x00B6_0009_02C0_C000, 0x01B7_C009_12C0_C000]
      ),
      (
        "LSHIFT", "LSHIFT_OR", 2,
        [0x00B4_0001_11C0_0000, 0x00B5_0001_01C0_0000, 0x00B6_0001_01C0_0000, 0x01B7_C001_11C0_0000]
      ),
      (
        "RSHIFT", "RSHIFT_OR", 2,
        [0x00B4_0000_11C0_0000, 0x00B5_0000_01C0_0000, 0x00B6_0000_01C0_0000, 0x01B7_C000_11C0_0000]
      ),
      (
        "ARSHIFT", "ARSHIFT_OR", 2,
        [0x00B4_0004_11C0_0000, 0x00B5_0004_01C0_0000, 0x00B6_0004_01C0_0000, 0x01B7_C004_11C0_0000]
      ),
      (
        "LROT", "LROT_OR", 2,
        [0x00B4_0003_11C0_0000, 0x00B5_0003_01C0_0000, 0x00B6_0003_01C0_0000, 0x01B7_C003_11C0_0000]
      ),
      (
        "RROT", "RROT_OR", 2,
        [0x00B4_0002_11C0_0000, 0x00B5_0002_01C0_0000, 0x00B6_0002_01C0_0000, 0x01B7_C002_11C0_0000]
      ),
    ]
    for (name, under, kind, words) in aliases {
      for (i, v) in variants.enumerated() {
        let unit = v.name.sym == "i32" && name.sym != "RROT" && name.sym != "LROT" ? "cvt" : "sfu"
        out += "I " + name + " " + v.name + " " + v.cls + " " + unit + " 10-14 " + word(words[i]) + " alias"
        out += String(kind) + "_" + v.name + " alias=" + under + "." + v.name + "\n"
      }
    }
    return out
  }()
}
