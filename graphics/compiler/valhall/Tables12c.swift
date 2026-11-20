// SPDX-License-Identifier: BSD-3-Clause

// Transcribed from valhall 12c: vertex attributes, varyings, fragment output
// and tile-buffer access. `table` holds the folded table code of 12c.2.2
// (0 to 11 name tables 0 to 11, 12 to 15 name tables 60 to 63).

extension ISATable {
  static let table12c = """
    # 12c.3 vertex attribute loads
    S attrtail fmt@26:24/e.fmt=* vsz@29:28/e.vsz slot@32:30/e.slot=* sc@35:33/c!fmtcount sr@45:40/r
    S ldattrimm src0@7:0/s src1@15:8/s table@19:16/n index@23:20/n @attrtail
    S ldattr src0@7:0/s src1@15:8/s src2@23:16/s @attrtail
    S leaattrimm src0@7:0/s src1@15:8/s table@19:16/n index@23:20/n slot@32:30/e.slot=* sc@35:33/c!const=3 sr@45:40/r
    S leaattr src0@7:0/s src1@15:8/s src2@23:16/s slot@32:30/e.slot=* sc@35:33/c!const=3 sr@45:40/r
    I LD_ATTR_IMM - S2 msg 10-14 0066800000000000 ldattrimm stage=w
    I LD_ATTR - S3 msg 10-14 0076800000000000 ldattr stage=w
    I LEA_ATTR_IMM - S2 msg 10-14 0067800600000000 leaattrimm stage=w
    I LEA_ATTR - S3 msg 10-14 0077800600000000 leaattr stage=w

    # 12c.5 interpolated and flat varyings
    S vartail fmt@26:24/e.fmt=* vsz@29:28/e.vsz slot@32:30/e.slot=* sc@35:33/c!fmtcount upd@37:36/e.upd=* spos@39:38/e.spos=* sr@45:40/r
    S ldvarimm src0@7:0/s table@11:8/n index@19:12/n @vartail
    S ldvar src0@7:0/s src1@15:8/s @vartail
    I LD_VAR_IMM - S1 msg 10-14 0054800000000000 ldvarimm stage=w
    I LD_VAR - S2 msg 10-14 0064800000000000 ldvar stage=w
    S flattail fmt@26:24/e.fmt=* vsz@29:28/e.vsz slot@32:30/e.slot=* sc@35:33/c!fmtcount sr@45:40/r
    S ldflatimm table@11:8/n index@19:12/n @flattail
    S ldflat src0@7:0/s @flattail
    I LD_VAR_FLAT_IMM - S0 msg 10-14 0041800000000000 ldflatimm stage=w
    I LD_VAR_FLAT - S1 msg 10-14 0055800000000000 ldflat stage=w
    F vfmt src_flat32=0 src_flat16=1 src_f32=2 src_f16=3
    S bufmid vfmt@25:24/e.vfmt=* vsz@29:28/e.vsz slot@32:30/e.slot=*
    S ldbufimm32 src0@7:0/s offset@18:8/n @bufmid sc@35:33/c!var32 upd@37:36/e.upd=* spos@39:38/e.spos=* sr@45:40/r
    S ldbufimm16 src0@7:0/s offset@18:8/n @bufmid sc@35:33/c!var16 upd@37:36/e.upd=* spos@39:38/e.spos=* sr@45:40/r
    S ldbufimm32a src0@7:0/s offset@23:16/n @bufmid sc@35:33/c!var32 upd@37:36/e.upd=* spos@39:38/e.spos=* sr@45:40/r
    S ldbufimm16a src0@7:0/s offset@23:16/n @bufmid sc@35:33/c!var16 upd@37:36/e.upd=* spos@39:38/e.spos=* sr@45:40/r
    S ldbuf32 src0@7:0/s src1@15:8/s @bufmid sc@35:33/c!var32 upd@37:36/e.upd=* spos@39:38/e.spos=* sr@45:40/r
    S ldbuf16 src0@7:0/s src1@15:8/s @bufmid sc@35:33/c!var16 upd@37:36/e.upd=* spos@39:38/e.spos=* sr@45:40/r
    I LD_VAR_BUF_IMM f32 S1 msg 11-14 005C800000000000 ldbufimm32 stage=w
    I LD_VAR_BUF_IMM f16 S1 msg 11-14 005D800000000000 ldbufimm16 stage=w
    I LD_VAR_BUF_IMM f32 S1 msg 10-10 005C800000000000 ldbufimm32a stage=w
    I LD_VAR_BUF_IMM f16 S1 msg 10-10 005D800000000000 ldbufimm16a stage=w
    I LD_VAR_BUF f32 S2 msg 10-14 006C800000000000 ldbuf32 stage=w
    I LD_VAR_BUF f16 S2 msg 10-14 006D800000000000 ldbuf16 stage=w
    # OPEN QUESTION (12c.5.4): the spec writes the varying name both as a suffix and as an operand (`point`), and the
    # arch 10 to 13 update mode (clobber) as a modifier; the update mode is a field defaulting to clobber, and
    # `point` is accepted either way.
    S ldspecial src0@7:0/s name@14:12/e.{point=0,frag_w=2,frag_z=3}=* fmt@26:24/e.fmt=f32 vsz@29:28/e.vsz slot@32:30/e.slot=* sc@35:33/c!speccount upd@37:36/e.upd=clobber spos@39:38/e.spos sr@45:40/r
    I LD_VAR_SPECIAL - S1 msg 10-13 0056803002000000 ldspecial stage=w

    # 12c.6 fragment output
    S atest @s3 wd1@27:26/e.wF sc@35:33/c!const=1 sr@45:40/r
    S zsemit @s3 stencil@24/b z@25/b sc@35:33/c!const=1 sr@45:40/r
    S blend src0@7:0/S target@15:8/n src2@23:16/s fmt@26:24/e.fmt=* slot@32:30/e.slot=* sc@35:33/c!blendcount sr@45:40/r
    I ATEST - S3 msg 10-14 007D800200000000 atest stage=w
    I ZS_EMIT - S3 msg 10-14 007E800200000000 zsemit stage=w
    I BLEND - S3 msg 10-14 007F400030000000 blend stage=r

    # 12c.7 tile-buffer access
    S ldtile @s3 fmt@26:24/e.fmt=* vsz@29:28/e.vsz slot@32:30/e.slot=* sc@35:33/c!fmtcount z_stencil@36/b last_read@39/b sr@45:40/r
    S sttile @s3 fmt@26:24/e.fmt=* vsz@29:28/e.vsz slot@32:30/e.slot=* sc@35:33/c!fmtcount sr@45:40/r
    I LD_TILE - S3 msg 10-14 0078800000000000 ldtile stage=w
    I ST_TILE - S3 msg 10-14 0079400000000000 sttile stage=r
    """
}
