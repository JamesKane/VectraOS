// SPDX-License-Identifier: BSD-3-Clause

// Transcribed from valhall 12a: memory and atomics. A load names the first
// register of the block it writes (`sr`), a store the block it reads; the
// count is the width in registers, or derived from the lane (valhall
// 12a.1.3). The widths with a fixed lane and count (`i24`, `i48` and up)
// carry them in their base words; their count is still a field, held at
// its one value.

extension ISATable {
  static let table12a = """
    # 12a.3 LOAD: i8, i16, i32 take a lane and an extension; the wider forms have none
    S ldhead src0@7:0/A offset@23:8/m access@26:24/e.acc slot@32:30/e.slot=*
    S ld8 @ldhead sc@35:33/c!ldcount lane@38:36/e.lane8 ext@39/e.ext=1 sr@45:40/r
    S ld16 @ldhead sc@35:33/c!ldcount lane@37:36/e.lane16 ext@39/e.ext=1 sr@45:40/r
    S ld32 @ldhead sc@35:33/c!ldcount lane@36/e.lane32 ext@39/e.ext=1 sr@45:40/r
    S ldc1 @ldhead sc@35:33/c!const=1 sr@45:40/r
    S ldc2 @ldhead sc@35:33/c!const=2 sr@45:40/r
    S ldc3 @ldhead sc@35:33/c!const=3 sr@45:40/r
    S ldc4 @ldhead sc@35:33/c!const=4 sr@45:40/r
    I LOAD i8 S2 msg 10-14 0060800000000000 ld8 stage=w
    I LOAD i16 S2 msg 10-14 0060800008000000 ld16 stage=w
    I LOAD i24 S2 msg 10-14 0060808210000000 ldc1 stage=w
    I LOAD i32 S2 msg 10-14 0060800018000000 ld32 stage=w
    I LOAD i48 S2 msg 10-14 006080C420000000 ldc2 stage=w
    I LOAD i64 S2 msg 10-14 006080F428000000 ldc2 stage=w
    I LOAD i96 S2 msg 10-14 006080E630000000 ldc3 stage=w
    I LOAD i128 S2 msg 10-14 006080F838000000 ldc4 stage=w

    # 12a.4 STORE: i8 and i16 name the lane stored
    S sthead src0@7:0/A offset@23:8/m access@26:24/e.acc slot@32:30/e.slot=*
    S st8 @sthead sc@35:33/c!const=1 lane@37:36/e.l8 sr@45:40/r
    S st16 @sthead sc@35:33/c!const=1 lane@36/e.l16 sr@45:40/r
    S stc1 @sthead sc@35:33/c!const=1 sr@45:40/r
    S stc2 @sthead sc@35:33/c!const=2 sr@45:40/r
    S stc3 @sthead sc@35:33/c!const=3 sr@45:40/r
    S stc4 @sthead sc@35:33/c!const=4 sr@45:40/r
    I STORE i8 S2 msg 10-14 0061400200000000 st8 stage=r
    I STORE i16 S2 msg 10-14 0061400208000000 st16 stage=r
    I STORE i24 S2 msg 10-14 0061400210000000 stc1 stage=r
    I STORE i32 S2 msg 10-14 0061400218000000 stc1 stage=r
    I STORE i48 S2 msg 10-14 0061400420000000 stc2 stage=r
    I STORE i64 S2 msg 10-14 0061400428000000 stc2 stage=r
    I STORE i96 S2 msg 10-14 0061400630000000 stc3 stage=r
    I STORE i128 S2 msg 10-14 0061400838000000 stc4 stage=r

    # 12a.5 LD_PKA, LEA_PKA through a buffer descriptor; LEA_BUF, LEA_BUF_IMM
    S pkahead src0@7:0/s src1@15:8/s access@26:24/e.acc slot@32:30/e.slot=*
    S pka8 @pkahead sc@35:33/c!ldcount lane@38:36/e.lane8 ext@39/e.ext=1 sr@45:40/r
    S pka16 @pkahead sc@35:33/c!ldcount lane@37:36/e.lane16 ext@39/e.ext=1 sr@45:40/r
    S pka32 @pkahead sc@35:33/c!ldcount lane@36/e.lane32 ext@39/e.ext=1 sr@45:40/r
    S pkac1 @pkahead sc@35:33/c!const=1 sr@45:40/r
    S pkac2 @pkahead sc@35:33/c!const=2 sr@45:40/r
    S pkac3 @pkahead sc@35:33/c!const=3 sr@45:40/r
    S pkac4 @pkahead sc@35:33/c!const=4 sr@45:40/r
    I LD_PKA i8 S2 msg 10-14 006A800000000000 pka8 stage=w
    I LD_PKA i16 S2 msg 10-14 006A800008000000 pka16 stage=w
    I LD_PKA i24 S2 msg 10-14 006A808210000000 pkac1 stage=w
    I LD_PKA i32 S2 msg 10-14 006A800018000000 pka32 stage=w
    I LD_PKA i48 S2 msg 10-14 006A80C420000000 pkac2 stage=w
    I LD_PKA i64 S2 msg 10-14 006A80F428000000 pkac2 stage=w
    I LD_PKA i96 S2 msg 10-14 006A80E630000000 pkac3 stage=w
    I LD_PKA i128 S2 msg 10-14 006A80F838000000 pkac4 stage=w
    I LEA_PKA - S2 msg 10-14 006B800400000000 pkac2 stage=w
    S leabuf src0@7:0/s src1@15:8/s slot@32:30/e.slot=* sc@35:33/c!const=2 sr@45:40/r
    S leabufimm src0@7:0/s table@11:8/n index@19:12/n slot@32:30/e.slot=* sc@35:33/c!const=2 sr@45:40/r
    I LEA_BUF - S2 msg 10-14 006E800400000000 leabuf stage=w
    I LEA_BUF_IMM - S1 msg 10-14 005E800400000000 leabufimm stage=w

    # 12a.6 checked loads and stores (arch 12 and later)
    S chk src0@7:0/A src1@15:8/s src2@23:16/s access@26:24/e.acc slot@32:30/e.slot=*
    S chkimm src0@7:0/A offset@15:8+39:36/u src2@23:16/s access@26:24/e.acc slot@32:30/e.slot=*
    S chk1 @chk sc@35:33/c!const=1 sr@45:40/r
    S chk2 @chk sc@35:33/c!const=2 sr@45:40/r
    S chk3 @chk sc@35:33/c!const=3 sr@45:40/r
    S chk4 @chk sc@35:33/c!const=4 sr@45:40/r
    S chki1 @chkimm sc@35:33/c!const=1 sr@45:40/r
    S chki2 @chkimm sc@35:33/c!const=2 sr@45:40/r
    S chki3 @chkimm sc@35:33/c!const=3 sr@45:40/r
    S chki4 @chkimm sc@35:33/c!const=4 sr@45:40/r
    I LD_CHECKED i8 S4 msg 12-14 0172800200000000 chk1 stage=w
    I LD_CHECKED i16 S4 msg 12-14 0172800208000000 chk1 stage=w
    I LD_CHECKED i24 S4 msg 12-14 0172800210000000 chk1 stage=w
    I LD_CHECKED i32 S4 msg 12-14 0172800218000000 chk1 stage=w
    I LD_CHECKED i48 S4 msg 12-14 0172800420000000 chk2 stage=w
    I LD_CHECKED i64 S4 msg 12-14 0172800428000000 chk2 stage=w
    I LD_CHECKED i96 S4 msg 12-14 0172800630000000 chk3 stage=w
    I LD_CHECKED i128 S4 msg 12-14 0172800838000000 chk4 stage=w
    I ST_CHECKED i8 S4 msg 12-14 0173400200000000 chk1 stage=r
    I ST_CHECKED i16 S4 msg 12-14 0173400208000000 chk1 stage=r
    I ST_CHECKED i24 S4 msg 12-14 0173400210000000 chk1 stage=r
    I ST_CHECKED i32 S4 msg 12-14 0173400218000000 chk1 stage=r
    I ST_CHECKED i48 S4 msg 12-14 0173400420000000 chk2 stage=r
    I ST_CHECKED i64 S4 msg 12-14 0173400428000000 chk2 stage=r
    I ST_CHECKED i96 S4 msg 12-14 0173400630000000 chk3 stage=r
    I ST_CHECKED i128 S4 msg 12-14 0173400838000000 chk4 stage=r
    I LD_CHECKED_IMM i8 S3 msg 12-14 0072800200000000 chki1 stage=w
    I LD_CHECKED_IMM i16 S3 msg 12-14 0072800208000000 chki1 stage=w
    I LD_CHECKED_IMM i24 S3 msg 12-14 0072800210000000 chki1 stage=w
    I LD_CHECKED_IMM i32 S3 msg 12-14 0072800218000000 chki1 stage=w
    I LD_CHECKED_IMM i48 S3 msg 12-14 0072800420000000 chki2 stage=w
    I LD_CHECKED_IMM i64 S3 msg 12-14 0072800428000000 chki2 stage=w
    I LD_CHECKED_IMM i96 S3 msg 12-14 0072800630000000 chki3 stage=w
    I LD_CHECKED_IMM i128 S3 msg 12-14 0072800838000000 chki4 stage=w
    I ST_CHECKED_IMM i8 S3 msg 12-14 0073400200000000 chki1 stage=r
    I ST_CHECKED_IMM i16 S3 msg 12-14 0073400208000000 chki1 stage=r
    I ST_CHECKED_IMM i24 S3 msg 12-14 0073400210000000 chki1 stage=r
    I ST_CHECKED_IMM i32 S3 msg 12-14 0073400218000000 chki1 stage=r
    I ST_CHECKED_IMM i48 S3 msg 12-14 0073400420000000 chki2 stage=r
    I ST_CHECKED_IMM i64 S3 msg 12-14 0073400428000000 chki2 stage=r
    I ST_CHECKED_IMM i96 S3 msg 12-14 0073400630000000 chki3 stage=r
    I ST_CHECKED_IMM i128 S3 msg 12-14 0073400838000000 chki4 stage=r

    # 12a.7 LD_CVT, ST_CVT
    S cvtmem src0@7:0/A offset@15:8/n src2@23:16/s fmt@26:24/e.fmt=* vsz@29:28/e.vsz slot@32:30/e.slot=* sc@35:33/c!fmtcount access@39:37/e.acc sr@45:40/r
    I LD_CVT - S3 msg 10-14 0070800000000000 cvtmem stage=w
    I ST_CVT - S3 msg 10-14 0071400000000000 cvtmem stage=r

    # 12a.8 atomics
    S atomhead src0@7:0/A offset@15:8/n
    S atom32 @atomhead op@25:22/e.aop=* slot@32:30/e.slot=* sc@35:33/c!const=1 sr@45:40/r
    S atom64 @atomhead op@25:22/e.aop=* slot@32:30/e.slot=* sc@35:33/c!atomcount sr@45:40/r
    I ATOM i32 S2 msg 10-14 0068400218000000 atom32 stage=r
    I ATOM i64 S2 msg 10-14 0068400028000000 atom64 stage=r
    S atom1 @atomhead op@24:22/e.a1op=* slot@32:30/e.slot=*
    S atom1r32 @atom1 sc@35:33/c!const=1 sr@45:40/r
    S atom1r64 @atom1 sc@35:33/c!const=2 sr@45:40/r
    I ATOM1 i32 S2 msg 10-14 0069400018000000 atom1
    I ATOM1 i64 S2 msg 10-14 0069400028000000 atom1
    I ATOM1_RETURN i32 S2 msg 10-14 0069800218000000 atom1r32 stage=w
    I ATOM1_RETURN i64 S2 msg 10-14 0069800428000000 atom1r64 stage=w
    S atomrw32 @atomhead sw@21:16/r op@25:22/e.aop=* slot@32:30/e.slot=* sc@35:33/c!const=1 swc@38:36/c1!const=1 sr@45:40/r
    S atomrw64 @atomhead sw@21:16/r op@25:22/e.aop=* slot@32:30/e.slot=* sc@35:33/c!atomcount swc@38:36/c1!const=2 sr@45:40/r
    S axchg32 @atomrw32 -op
    S axchg64 @atomrw64 -op
    S acmp32 @atomhead sw@21:16/r slot@32:30/e.slot=* sc@35:33/c!const=2 swc@38:36/c1!const=1 sr@45:40/r
    S acmp64 @atomhead sw@21:16/r slot@32:30/e.slot=* sc@35:33/c!const=4 swc@38:36/c1!const=2 sr@45:40/r
    I ATOM_RETURN i32 S2RW msg 10-14 0120C00218000000 atomrw32 stage=rw
    I ATOM_RETURN i64 S2RW msg 10-14 0120C01028000000 atomrw64 stage=rw
    I AXCHG i32 S2RW msg 10-14 0120C0021BC00000 axchg32 stage=rw alias=ATOM_RETURN.i32
    I AXCHG i64 S2RW msg 10-14 0120C0142BC00000 axchg64 stage=rw alias=ATOM_RETURN.i64
    I ACMPXCHG i32 S2RW msg 10-14 0120C0041FC00000 acmp32 stage=rw
    I ACMPXCHG i64 S2RW msg 10-14 0120C0182FC00000 acmp64 stage=rw
    """
}
