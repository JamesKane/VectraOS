// SPDX-License-Identifier: BSD-3-Clause

// Transcribed from valhall 11a: floating-point arithmetic. Each `I` line is
// a row of a variant table (mnemonic, variant, class, unit, arch range, base
// word); each `S` is that entry's field table. An alias names the
// instruction it is built on and drops the fields it fixes.

extension ISATable {
  static let table11a = """
    # 11a.3 FADD, FADD_IMM, FADD_LSCALE, FABS, FNEG
    S fadd32 @s2 wd1@27:26/e.wF wd0@29:28/e.wF round@31:30/e.rnd clamp@33:32/e.clamp sticky@34/b @m1 @m0 @dn
    S fadd16 @s2 wd1@27:26/e.swH=2 wd0@29:28/e.swH=2 round@31:30/e.rnd clamp@33:32/e.clamp sticky@34/b @m1 @m0 @d1
    S faddimm src0@7:0/s imm@39:8/u @d1
    S fabs32 @fadd32 -src1 -wd1 -round -sticky -neg1 -abs1 -neg0 -abs0
    S fabs16 @fadd16 -src1 -wd1 -round -sticky -neg1 -abs1 -neg0 -abs0
    I FADD f32 R2 fma 10-14 00A4000000000000 fadd32
    I FADD v2f16 R2 fma 10-14 00A5000000000000 fadd16
    I FADD_LSCALE f32 R2 fma 10-14 00A4000000090000 fadd32
    I FADD_IMM f32 R1I fma 10-14 0114000000000000 faddimm
    I FADD_IMM v2f16 R1I fma 10-14 0115000000000000 faddimm
    I FABS f32 R2 fma 10-14 00A400900000C000 fabs32 alias=FADD.f32
    I FABS v2f16 R2 fma 10-14 00A500900800C000 fabs16 alias=FADD.v2f16
    I FNEG f32 R2 fma 10-14 00A400500000C000 fabs32 alias=FADD.f32
    I FNEG v2f16 R2 fma 10-14 00A500500800C000 fabs16 alias=FADD.v2f16

    # 11a.4 FMA, FMUL
    S fma32 @s3 wd2@25:24/e.wF wd1@27:26/e.wF wd0@29:28/e.wF round@31:30/e.rnd clamp@33:32/e.clamp @m2 @m1 @m0 @dn
    S fma16 @s3 wd2@25:24/e.swH=2 wd1@27:26/e.swH=2 wd0@29:28/e.swH=2 round@31:30/e.rnd clamp@33:32/e.clamp @m2 @m1 @m0 @d1
    S fmul32 @fma32 -src2 -wd2 -abs2 neg2@34/b!fmul
    S fmul16 @fma16 -src2 -wd2 -abs2 neg2@34/b!fmul
    I FMA f32 R3 fma 10-14 00B2000000000000 fma32
    I FMA v2f16 R3 fma 10-14 00B3000000000000 fma16
    I FMUL f32 R3 fma 10-14 00B2000000C00000 fmul32 alias=FMA.f32
    I FMUL v2f16 R3 fma 10-14 00B3000002C00000 fmul16 alias=FMA.v2f16

    # 11a.5 FMA_RSCALE, FADD_RSCALE, FMUL_RSCALE
    S fmar @s3 src3@31:24/s clamp@33:32/e.clamp @m2 @m1 @m0 @d1 special@49:48/e.{none=0,n=1,left=2,n_add=3} round@50/e.{none=0,round_zero=1}
    S faddr @fmar -src1 -neg1 -abs1
    S fmulr @fmar -src2 -neg2 -abs2
    I FMA_RSCALE f32 R4_FMAR fma 10-14 0160000000000000 fmar
    I FADD_RSCALE f32 R4_FMAR fma 10-14 016000000000D000 faddr alias=FMA_RSCALE.f32
    I FMUL_RSCALE f32 R4_FMAR fma 10-14 0160000400C00000 fmulr alias=FMA_RSCALE.f32

    # 11a.6 FMIN, FMAX
    S fmin32 @s2 wd1@27:26/e.wF wd0@29:28/e.wF nan@31:30/e.{nan_suppress=0,nan_propagate=1} clamp@33:32/e.clamp @m1 @m0 @d1
    S fmin16 @s2 wd1@27:26/e.swH=2 wd0@29:28/e.swH=2 nan@31:30/e.{nan_suppress=0,nan_propagate=1} clamp@33:32/e.clamp @m1 @m0 @d1
    I FMIN f32 R2 cvt 10-14 00A4000000020000 fmin32
    I FMIN v2f16 R2 cvt 10-14 00A5000000020000 fmin16
    I FMAX f32 R2 cvt 10-14 00A4000000030000 fmin32
    I FMAX v2f16 R2 cvt 10-14 00A5000000030000 fmin16

    # 11a.7 FCMP_OR, FCMP_AND, FCMP
    S fcmp32 @s3 wd1@27:26/e.wF wd0@29:28/e.wF rtype@31:30/e.rtype cmp@34:32/e.cmp=* @m1 @m0 @d1
    S fcmp16 @s3 wd1@27:26/e.swH=2 wd0@29:28/e.swH=2 rtype@31:30/e.rtype cmp@34:32/e.cmp=* @m1 @m0 @d1
    S fcmpa32 @fcmp32 -src2
    S fcmpa16 @fcmp16 -src2
    I FCMP_OR f32 R3_CMP cvt 10-14 00F4000000000000 fcmp32
    I FCMP_OR v2f16 R3_CMP cvt 10-14 00F5000000000000 fcmp16
    I FCMP_AND f32 R3_CMP cvt 10-14 00F4000001000000 fcmp32
    I FCMP_AND v2f16 R3_CMP cvt 10-14 00F5000001000000 fcmp16
    I FCMP f32 R3_CMP cvt 10-14 00F4000000C00000 fcmpa32 alias=FCMP_OR.f32
    I FCMP v2f16 R3_CMP cvt 10-14 00F5000000C00000 fcmpa16 alias=FCMP_OR.v2f16

    # 11a.8 CSEL (all compare types)
    S csel @s4 cmp@34:32/e.cmp=* @d1
    I CSEL f32 R4_CSEL cvt 10-14 0154000000000000 csel
    I CSEL v2f16 R4_CSEL cvt 10-14 0155000000000000 csel
    I CSEL u32 R4_CSEL cvt 10-14 0150000000000000 csel
    I CSEL s32 R4_CSEL cvt 10-14 0158000000000000 csel
    I CSEL v2u16 R4_CSEL cvt 10-14 0151000000000000 csel
    I CSEL v2s16 R4_CSEL cvt 10-14 0159000000000000 csel

    # 11a.10 FLUSH
    S flush32 src0@7:0/s nanmode@9:8/e.{none=0,flush_nan=1,quiet_nan=2} ftz@10/b flush_inf@11/b wd0@29:28/e.wF @m0 @d1
    S flush16 src0@7:0/s nanmode@9:8/e.{none=0,flush_nan=1,quiet_nan=2} ftz@10/b flush_inf@11/b wd0@29:28/e.swH=2 @m0 @d1
    I FLUSH f32 R1 cvt 10-14 0098000000000000 flush32
    I FLUSH v2f16 R1 cvt 10-14 0098000000010000 flush16

    # 11a.11 FROUND: arch 10 has the widen and destination width free and a v2f16 form
    S fround src0@7:0/s round@32:30/e.rnd3 @m0 dst@45:40/r
    S fround10 src0@7:0/s wd0@29:28/e.wF round@32:30/e.rnd3 @m0 @d1
    S fround10h src0@7:0/s wd0@29:28/e.swH=2 round@32:30/e.rnd3 @m0 @d1
    I FROUND f32 R1 fma 11-14 0090C000000D0000 fround
    I FROUND f32 R1 cvt 10-10 00900000000D0000 fround10
    I FROUND v2f16 R1 cvt 10-10 00900000000F0000 fround10h

    # 11a.12 LDEXP
    S ldexp @s2 inf@29:28/e.{none=0,inf=1,inf0=2} round@32:30/e.rnd3 neg0@38/b abs0@39/b @d1
    I LDEXP f32 R2 fma 10-14 00A4000000060000 ldexp
    I LDEXP v2f16 R2 fma 10-14 00A5000000060000 ldexp

    # 11a.13 FMUL_SLICE, FMUL_CSLICE
    S fslice @s2 @d1
    S fcslice @s2 wd0@28/e.l16 @m0 @d1
    I FMUL_SLICE f32 R2 fma 10-14 00A40000000A0000 fslice
    I FMUL_CSLICE - R2 fma 10-14 00A50000000A0000 fcslice

    # 11a.14 cube-map helpers
    S cubeface @s3 wd2@25:24/e.wF wd1@27:26/e.wF wd0@29:28/e.wF @m2 @m1 @m0 @d1
    S cubesel @s3 wd1@27:26/e.wF wd0@29:28/e.wF @m1 @m0 @d1
    I CUBEFACE1 - R3A cvt 10-14 00C0000000000000 cubeface
    I CUBEFACE2 - R3A cvt 10-14 00C1000000000000 cubeface
    I CUBE_SSEL - R3 sfu 10-14 00BC000000000000 cubesel
    I CUBE_TSEL - R3 sfu 10-14 00BC000001000000 cubesel

    # 11a.15 MMUL: class M3 fixes the destination width and the FAU page
    S mmul @s3 dst@45:40/r
    S mmulh @s3 wd1@27:26/e.{f0=0,f1=1} wd0@29:28/e.{f0=0,f1=1} dst@45:40/r
    I MMUL f32 M3 fma 11-14 0102C00000000000 mmul
    I MMUL v2f16 M3 fma 11-14 0103C00000000000 mmulh
    I MMUL v4s8 M3 fma 11-13 0100C00000000000 mmul
    I MMUL v4u8 M3 fma 11-13 0101C00000000000 mmul
    """
}
