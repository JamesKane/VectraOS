// SPDX-License-Identifier: BSD-3-Clause

// Transcribed from valhall 11c: conversions and special functions (the
// arch 10 only forms are kept; FROUND, LDEXP, FLUSH and FADD_LSCALE are in
// 11a).

extension ISATable {
  static let table11c = """
    # 11c.3 integer widening: byte and half lanes, and the byte pair
    S cvt8 src0@7:0/s wd0@29:28/e.l8 @d1
    S cvt16 src0@7:0/s wd0@28/e.l16 @d1
    S cvtb2h src0@7:0/s wd0@39:36/e.b2h=8 @d1
    I S8_TO_S32 - R1 cvt 10-14 0090000000000000 cvt8
    I U8_TO_U32 - R1 cvt 10-14 0090000000100000 cvt8
    I S16_TO_S32 - R1 cvt 10-14 0090000000040000 cvt16
    I U16_TO_U32 - R1 cvt 10-14 0090000000140000 cvt16
    I V2S8_TO_V2S16 - R1 cvt 10-14 0090000000020000 cvtb2h
    I V2U8_TO_V2U16 - R1 cvt 10-14 0090000000120000 cvtb2h

    # 11c.4 integer to float
    S i2f src0@7:0/s round@32:30/e.rnd3 wd0@39:36/e.wI @d1
    I S32_TO_F32 - R1 cvt 10-14 0090000000090000 i2f
    I U32_TO_F32 - R1 cvt 10-14 0090000000190000 i2f
    I S8_TO_F32 - R1 cvt 10-10 0090000000010000 cvt8
    I U8_TO_F32 - R1 cvt 10-10 0090000000110000 cvt8
    I S16_TO_F32 - R1 cvt 10-10 0090000000050000 cvt16
    I U16_TO_F32 - R1 cvt 10-10 0090000000150000 cvt16
    I V2S8_TO_V2F16 - R1 cvt 10-10 0090000000030000 cvtb2h
    I V2U8_TO_V2F16 - R1 cvt 10-10 0090000000130000 cvtb2h
    S i16tof src0@7:0/s round@32:30/e.rnd3 wd0@39:36/e.swI=2 @d1
    I V2S16_TO_V2F16 - R1 cvt 10-10 0090000000070000 i16tof
    I V2U16_TO_V2F16 - R1 cvt 10-10 0090000000170000 i16tof

    # 11c.5 float to integer
    S f2i src0@7:0/s wd0@29:28/e.wF round@32:30/e.rnd3 @m0 @d1
    S f162i src0@7:0/s wd0@28/e.l16 round@32:30/e.rnd3 @m0 @d1
    S f2h2i src0@7:0/s wd0@29:28/e.swH=2 round@32:30/e.rnd3 @m0 @d1
    I F32_TO_S32 - R1 cvt 10-14 00900000000C0000 f2i
    I F32_TO_U32 - R1 cvt 10-14 00900000001C0000 f2i
    I F16_TO_S32 - R1 cvt 10-10 00900000000A0000 f162i
    I F16_TO_U32 - R1 cvt 10-10 00900000001A0000 f162i
    I V2F16_TO_V2S16 - R1 cvt 10-10 00900000000E0000 f2h2i
    I V2F16_TO_V2U16 - R1 cvt 10-10 00900000001E0000 f2h2i

    # 11c.6 float to float
    S f16tof32 src0@7:0/s wd0@28/e.l16 @m0 @d1
    I F16_TO_F32 - R1 cvt 10-14 00900000000B0000 f16tof32
    S f2h src0@7:0/s round@31:30/e.rnd clamp@33:32/e.clamp neg1@36/b!f2h @m0 dst@45:40/r dw@47:46/e.dwh=*
    I F32_TO_F16 - R2 fma 11-14 00A400000000C000 f2h alias=FADD.f32
    S f2f16 @s2 round@31:30/e.rnd clamp@33:32/e.clamp @m1 @m0 @d1
    I V2F32_TO_V2F16 - R2 cvt 10-10 00A5000000040000 f2f16

    # 11c.7 FREXPM, FREXPE, ILOGB, LOGB
    S frexpm src0@7:0/s mode@25:24/e.{none=0,sqrt=1,log=2} wd0@29:28/e.wF @m0 @d1
    S frexpmh src0@7:0/s mode@25:24/e.{none=0,sqrt=1,log=2} wd0@29:28/e.swH=2 @m0 @d1
    S frexpe src0@7:0/s mode@25:24/e.{none=0,sqrt=1,log=2} wd0@29:28/e.wF neg_result@30/b @d1
    S frexpeh src0@7:0/s mode@25:24/e.{none=0,sqrt=1,log=2} wd0@29:28/e.swH=2 neg_result@30/b @d1
    I FREXPM f32 R1 cvt 10-14 0099000000000000 frexpm
    I FREXPM v2f16 R1 cvt 10-10 0099000000010000 frexpmh
    I FREXPE f32 R1 cvt 10-14 0099000000020000 frexpe
    I FREXPE v2f16 R1 cvt 10-10 0099000000030000 frexpeh
    S logb src0@7:0/s wd0@29:28/e.wF @d1
    S logbh src0@7:0/s wd0@29:28/e.swH=2 @d1
    I ILOGB f32 R1 cvt 10-10 0098000000040000 logb
    I ILOGB v2f16 R1 cvt 10-10 0098000000050000 logbh
    I LOGB f32 R1 cvt 10-10 0098000000060000 logb
    I LOGB v2f16 R1 cvt 10-10 0098000000070000 logbh

    # 11c.8 reciprocal, reciprocal square root, cube-root helpers
    S sfu32 src0@7:0/s wd0@29:28/e.wF @m0 @d1
    S sfu16 src0@7:0/s wd0@28/e.l16 @m0 @dn
    S sfu32nomod src0@7:0/s @d1
    I FRCP f32 R1 sfu 10-14 009C000000000000 sfu32
    I FRCP f16 R1 sfu 10-14 009C000000010000 sfu16
    I FRSQ f32 R1 sfu 10-14 009C000000020000 sfu32
    I FRSQ f16 R1 sfu 10-14 009C000000030000 sfu16
    I FRCP_APPROX f32 R1 sfu 10-14 009C0000000E0000 sfu32
    I FRSQ_APPROX f32 R1 sfu 10-14 009C0000000F0000 sfu32
    I FRCBRT_APPROX_A f32 R1 sfu 10-14 009E000000000000 sfu32
    I FRCBRT_APPROX_B f32 R1 sfu 10-14 009E000000010000 sfu32nomod
    I FRCBRT_APPROX_C f32 R1 sfu 10-14 009E000000020000 sfu32nomod

    # 11c.9 logarithms
    I FLOGD f32 R1 sfu 10-14 009C000000080000 sfu32
    I FLOG f16 R1 sfu 12-14 009C000000090000 sfu16
    S flogtab src0@7:0/s wd0@29:28/e.wF mode@32:31/e.{red=0,base2=1,natural=2}=* precision@34:33/e.{none=0,high=1,low=2} @m0 @d1
    I FLOG_TABLE f32 R1 sfu 10-14 009C0000000C0000 flogtab

    # 11c.10 exponentials and powers
    S fexp32 @s2 wd1@27:26/e.wF @m1 @d1
    I FEXP f32 R2 sfu 10-14 00A4000000080000 fexp32
    S fpow16 @s2 wd1@26/e.l16 wd0@28/e.l16 @m1 @m0 @dn
    S fexp16 @fpow16 -src0 -wd0 -neg0 -abs0
    I FPOW f16 R2 sfu 12-14 00A60000030D0000 fpow16
    I FEXP f16 R2 sfu 12-14 00A60000130D00DC fexp16 alias=FPOW.f16
    S fexptab src0@7:0/s adjust@32:31/e.{none=0,low=2} @d1
    I FEXP_TABLE u4 R1 sfu 10-14 009C0000000D0000 fexptab
    S fpowdet @s2 function@21:20/e.{pow=0,powr=1}=* @d1
    S fpowapply @s2 @d1
    I FPOW_SC_DET f32 R2 sfu 10-14 00A40000000D0000 fpowdet
    I FPOW_SC_APPLY - R2 sfu 10-14 00A40000010D0000 fpowapply

    # 11c.11 trigonometric tables
    S sintab src0@7:0/s offset@30/b @d1
    S sincosoff src0@7:0/s scale@30/b @d1
    I FSIN_TABLE u6 R1 sfu 10-14 009C000000040000 sintab
    I FCOS_TABLE u6 R1 sfu 10-14 009C000000050000 sintab
    I FSINCOS_OFFSET u6 R1 sfu 10-14 009C000000060000 sincosoff

    # 11c.12 classification and arctangent helpers
    S fpclass32 src0@7:0/s @m0 @d1
    S fpclass16 src0@7:0/s wd0@28/e.l16 @m0 @d1
    I FPCLASS f32 R1 sfu 10-14 009C0000000A0000 fpclass32
    I FPCLASS f16 R1 sfu 10-14 009C0000000B0000 fpclass16
    S fatan @s2 @d1
    I FATAN_ASSIST f32 R2 sfu 10-14 00A40000000E0000 fatan
    I FATAN_TABLE f32 R2 sfu 10-14 00A40000010E0000 fatan
    """
}
