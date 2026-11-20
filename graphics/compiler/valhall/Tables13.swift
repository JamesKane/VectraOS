// SPDX-License-Identifier: BSD-3-Clause

// Transcribed from valhall 13: control flow, waiting, barriers and subgroup
// operations. The flow field itself (the waits, reconverge, discard, end)
// is part of every instruction (Flow); a NOP carries one when no other
// instruction can.

extension ISATable {
  static let table13 = """
    # 13.6.1, 13.6.2 NOP and the N0 messages
    S nofields
    I NOP - N0 cvt 10-14 0000C00000000000 nofields
    I DOORBELL - N0 msg 10-14 0004C00000000000 nofields
    I EUREKA - N0 msg 10-14 0005C00000000000 nofields
    I KABOOM - N0 msg 10-14 0006C00000000000 nofields

    # 13.4 branches and jumps
    F combine none=0 h0=1 h1=2 and=3 lowbits=4
    S branch src0@7:0/s offset@34:8/m conservative@35/b not@36/b wd0@39:37/e.combine
    S jump src0@7:0/s src1@15:8/s conservative@35/b not@36/b wd0@39:37/e.combine
    S jump10 @jump mode@40/e.{relative=0,absolute=1}=absolute
    S jumpex src0@7:0/s src1@15:8/s src2@23:16/s diverge@32/b stack@34:33/e.{return=0,call=1,none=2,replace=3}=none conservative@35/b not@36/b wd0@39:37/e.combine
    I BRANCH - N1 cvt 10-14 001FC00000000000 branch
    I JUMP - N2 cvt 10-14 002FC00000000000 jump10
    I JUMP_EX - N3 cvt 10-14 003FC00000000000 jumpex

    # 13.6.3 DISCARD
    S discard @s2 wd1@27:26/e.wF wd0@29:28/e.wF cmp@34:32/e.cmp=* @m1 @m0
    I DISCARD f32 N2 cvt 10-14 0020C00000000000 discard

    # 13.8 BARRIER, 13.11 LD_GCLK
    I BARRIER - S0 msg 10-14 0045C001C0000000 nofields
    S gclk source@2:0/e.{cycle_counter=6,system_timestamp=7}=* slot@32:30/e.slot=* sc@35:33/c!const=2 sr@45:40/r
    I LD_GCLK - S0 msg 10-14 0044800400000000 gclk stage=w

    # 13.9 subgroup operations
    S wmask src0@7:0/s subgroup@39:36/e.sg=subgroup16 @d1
    I WMASK - R1 cvt 10-14 0095000000000000 wmask
    F inactive zero=0 umax=1 i1=2 v2i1=3 smin=4 smax=5 v2smin=6 v2smax=7 v4smin=8 v4smax=9 f1=10 v2f1=11 infn=12 inf=13 v2infn=14 v2inf=15
    S clper @s2 inactive@25:22/e.inactive wd1@29:26/e.lsh4=b0 lane_op@35:32/e.{none=0,xor=1,accumulate=2,shift=3,rotate=4} subgroup@39:36/e.sg=subgroup16 @d1
    # the spec calls the CLPER variant i32 in its table and writes none in its examples; there is none here
    I CLPER - R2 cvt 10-14 00A00000000F0000 clper
    """
}
