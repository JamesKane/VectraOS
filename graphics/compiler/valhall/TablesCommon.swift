// SPDX-License-Identifier: BSD-3-Clause

// Transcribed from valhall 10.6, 10.10 and the shared definitions of 11 to
// 13: the enumerations and the field sets that recur across instructions.
// Notation: TableParser.swift.

extension ISATable {
  /// Every table text, in the order they are read.
  static let allTableSources: [String] = [
    commonTable, table11a, table11b, table11c, table12a, table12b, table12c, table13,
  ]

  static let commonTable = """
    # widen of a float source (10.6.2)
    F wF none=0 h0=1 h1=2
    # swizzle of two 16-bit lanes
    F swH h00=0 h10=1 h01=2 h11=3
    # widen of an integer source
    F wI none=0 h0=2 h1=3 b0=4 b1=5 b2=6 b3=7 w0=8 w1=9
    # swizzle of two 16-bit lanes of integer data
    F swI h00=0 h10=1 h01=2 h11=3 b00=4 b20=5 b02=6 b22=7 b11=8 b31=9 b13=10 b33=11 b01=12 b23=13
    # swizzle of four byte lanes
    F swB b0123=0 b3210=1 b0101=2 b2323=3 b0000=4 b1111=5 b2222=6 b3333=7 b2301=8 b1032=9 b0011=10 b2233=11
    # byte-to-half expansion
    F b2h b00=0 b10=1 b20=2 b30=3 b01=4 b11=5 b21=6 b31=7 b02=8 b12=9 b22=10 b32=11 b03=12 b13=13 b23=14 b33=15
    F l16 h0=0 h1=1
    F l8 b0=0 b1=1 b2=2 b3=3
    # shift lanes, 32-bit and 16-bit (11b.5.1, 10.6.2). OPEN QUESTION (11b.5.1 reserves every value but 4 to 7 for
    # 32-bit lanes): the spec words of LROT and RSHIFT_OR (11b.5.5) carry 0 where no lane is written, so 0 is named
    # `none` and is the default; a compiler writes `.b0` (4) explicitly.
    # shift lanes of the 32-bit family, then the 16-bit family
    F lsh4 none=0 b0=4 b1=5 b2=6 b3=7
    F lsh2 b02=0 b00=4 b11=5 b22=6 b33=7 b01=10 b23=11
    # destination width: plain, and narrow/replicate
    F dw h0=1 h1=2 none=3
    F dwh h01=0 h0=1 h1=2
    F dwn h01=0 h0=1 h1=2 none=3
    F rnd none=0 round_up=1 round_down=2 round_zero=3
    F rnd3 none=0 round_up=1 round_down=2 round_zero=3 round_na=4
    F clamp none=0 clamp_0_inf=1 clamp_m1_1=2 clamp_0_1=3
    F cmp eq=0 gt=1 ge=2 ne=3 lt=4 le=5 gtlt=6 total=7
    F rtype i1=0 f1=1 m1=2 c=3
    F acc none=0 istream=1 estream=2 force=3
    F fmt auto32=0 f32=2 f16=3 s32=4 s16=5 u32=6 u16=7
    F vsz scalar=0 v2=1 v3=2 v4=3
    F slot slot0=0 slot1=1 slot2=2 slot7=7
    F ext sext=0 zext=1
    F sg subgroup2=0 subgroup4=1 subgroup8=2 subgroup16=3
    # varying interpolation: update mode and sample position
    F upd store=0 retrieve=1 clobber=3
    F spos center=0 centroid=1 sample=2 explicit=3
    F dim tex1d=0 tex2d=1 tex3d=2 cube=3
    F lodm none=0 computed=1 computed_force_delta=3 explicit=4 computed_bias=5 grdesc=6 computed_bias_force_delta=7
    F gcomp gather4_r=0 gather4_g=1 gather4_b=2 gather4_a=3
    F cmode float_coordinates=0 integer_coordinates=1
    F tw dst16=0 dst32=1
    F wmask r=1 g=2 rg=3 b=4 rb=5 gb=6 rgb=7 a=8 ra=9 ga=10 rga=11 ba=12 rba=13 gba=14 rgba=15
    F aop aaddu=0 aadds=1 aadd=2 asmin=8 asmax=9 aumin=10 aumax=11 aand=12 aor=13 axor=14 axchg=15
    F a1op ainc=0 adec=1 aumax1=2 asmax1=3 aor1=4
    F lane8 b0=0 b1=1 b2=2 b3=3 h0=4 h1=5 w0=6 d0=7
    F lane16 h0=0 h1=1 w0=2 d0=3
    F lane32 none=0 d0=1
    # sources: two, three, four
    S s2 src0@7:0/s src1@15:8/s
    S s3 @s2 src2@23:16/s
    S s4 @s3 src3@31:24/s
    # negate and absolute value of source 0, 1, 2
    S m0 neg0@38/b abs0@39/b
    S m1 neg1@36/b abs1@37/b
    S m2 neg2@34/b abs2@35/b
    # a destination with its width: plain, narrow; a 64-bit destination
    S d1 dst@45:40/r dw@47:46/e.dw=3
    S dn dst@45:40/r dw@47:46/e.dwn=3
    S d64 dst@45:40/R
    """
}
