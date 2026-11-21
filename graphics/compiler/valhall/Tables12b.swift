// SPDX-License-Identifier: BSD-3-Clause

// Transcribed from valhall 12b: texture and image instructions. A texture
// instruction (class S2RW) reads the block `sr` of `sc` registers and writes
// the block `sw` of `swc` registers; the fused varying-and-texture forms
// (S3A) only write, `sc` at [38:36] being their write count. `rtype` is the
// register type of [27:26] (12b.4): the hardware does not read it, the
// reference assembler always writes it (f 1, u 2, s 3; 0 is invalid), so
// the assembler writes it too; it defaults to f and is named when it is not.

extension ISATable {
  static let table12b = """
    # 12b.6 to 12b.8 the texture forms. TEX_GRADIENT's read count is (c << derivative) + projection with c = 1, 2, 3
    # and 2 for a cube (12b.5.6; 5 and 7 are not encodable). TEX_DUAL's write count is Rp + Rs, the primary block's
    # registers and the secondary's, and holds the stored value + 1 (12b.8.3).
    F sel center_store=0 centroid_store=1 sample_store=2 explicit_store=3 center_clobber=4 sample_clobber=6 retrieve=7
    S texhead src0@7:0/S wide@8/b
    S texfoot sw@21:16/r mask@25:22/e.wmask=rgba rtype@27:26/e.treg=f dim@29:28/e.dim=*
    S texpost skip@39/b sr@45:40/r width@46/e.tw=* slot@32:30/e.slot=*
    S tex_single @texhead project@9/b array@10/b texel_offset@11/b compare@12/b lod@15:13/e.lodm=* @texfoot sc@35:33/c8!texsingle swc@38:36/c1!texwrite @texpost
    S tex_fetch @texhead array@10/b texel_offset@11/b @texfoot sc@35:33/c8!texfetch swc@38:36/c1!texwrite @texpost
    S tex_gather @texhead project@9/b array@10/b texel_offset@11/b compare@12/b cmode@13/e.cmode gcomp@15:14/e.gcomp=* @texfoot sc@35:33/c8!texgather swc@38:36/c1!texwrite @texpost
    S tex_gradient @texhead project@9/b force_delta@12/b lod_bias_disable@13/b lod_clamp_disable@14/b derivative@15/b @texfoot sc@35:33/c8!texgrad swc@38:36/c1!texwrite @texpost
    S tex_dual @texhead project@9/b array@10/b texel_offset@11/b compare@12/b lod@15:13/e.lodm=* @texfoot sc@35:33/c8!texsingle swc@38:36/c1!texdual skip@39/b sr@45:40/r width@46/e.tw=* swidth@47/e.tw=* slot@32:30/e.slot=*
    I TEX_FETCH - S2RW msg 10-14 0125000000000000 tex_fetch stage=rw
    I TEX_SINGLE - S2RW msg 10-14 0128000000000000 tex_single stage=rw
    I TEX_GATHER - S2RW msg 10-14 0129000000000000 tex_gather stage=rw
    I TEX_GRADIENT - S2RW msg 10-14 012A000000000000 tex_gradient stage=rw
    I TEX_DUAL - S2RW msg 10-14 012F000000000000 tex_dual stage=rw

    # 12b.9 the fused varying-and-texture forms
    S vthead src0@7:0/S wide@8/b project@9/b src2@23:16/s rtype@27:26/e.treg=f dim@29:28/e.dim=* sel@35:33/e.sel=* sc@38:36/c1 skip@39/b sr@45:40/r
    S vt_single @vthead array@10/b compare@12/b lod@15:13/e.lodm=* width@24/e.tw=* slot@32:30/e.slot=*
    S vt_gather @vthead array@10/b compare@12/b gcomp@15:14/e.gcomp=* width@24/e.tw=* slot@32:30/e.slot=*
    S vt_gradient @vthead lod_bias_disable@13/b lod_clamp_disable@14/b width@24/e.tw=* slot@32:30/e.slot=*
    S vt_dual @vthead array@10/b compare@12/b lod@15:13/e.lodm=* width@24/e.tw=* swidth@25/e.tw=* sc@38:36/c1!vtdual slot@32:30/e.slot=*
    S vtb_single @vt_single vfmt@11/e.{src_f32=0,src_f16=1}
    S vtb_gather @vt_gather vfmt@11/e.{src_f32=0,src_f16=1}
    S vtb_gradient @vt_gradient vfmt@11/e.{src_f32=0,src_f16=1}
    S vtb_dual @vt_dual vfmt@11/e.{src_f32=0,src_f16=1}
    I VAR_TEX_BUF_SINGLE - S3A msg 10-14 0130800000000000 vtb_single stage=w
    I VAR_TEX_BUF_GATHER - S3A msg 10-14 0131800000000000 vtb_gather stage=w
    I VAR_TEX_BUF_GRADIENT - S3A msg 10-14 0132800000000000 vtb_gradient stage=w
    I VAR_TEX_BUF_DUAL - S3A msg 10-14 0137800000000000 vtb_dual stage=w
    I VAR_TEX_SINGLE - S3A msg 10-14 0138800000000000 vt_single stage=w
    I VAR_TEX_GATHER - S3A msg 10-14 0139800000000000 vt_gather stage=w
    I VAR_TEX_GRADIENT - S3A msg 10-14 013A800000000000 vt_gradient stage=w
    I VAR_TEX_DUAL - S3A msg 10-14 013F800000000000 vt_dual stage=w

    # 12b.10 image access: the attribute opcodes with descriptor type 1
    S ldtex src0@7:0/s src1@15:8/s src2@23:16/s fmt@26:24/e.fmt=* vsz@29:28/e.vsz slot@32:30/e.slot=* sc@35:33/c!fmtcount sr@45:40/r
    S ldteximm src0@7:0/s src1@15:8/s table@19:16/n index@23:20/n fmt@26:24/e.fmt=* vsz@29:28/e.vsz slot@32:30/e.slot=* sc@35:33/c!fmtcount sr@45:40/r
    S leatex src0@7:0/s src1@15:8/s src2@23:16/s slot@32:30/e.slot=* sc@35:33/c!const=3 sr@45:40/r
    S leateximm src0@7:0/s src1@15:8/s table@19:16/n index@23:20/n slot@32:30/e.slot=* sc@35:33/c!const=3 sr@45:40/r
    I LD_TEX - S3 msg 10-14 0076802000000000 ldtex stage=w
    I LD_TEX_IMM - S2 msg 10-14 0066802000000000 ldteximm stage=w
    I LEA_TEX - S3 msg 10-14 0077802600000000 leatex stage=w
    I LEA_TEX_IMM - S2 msg 10-14 0067802600000000 leateximm stage=w
    """
}
