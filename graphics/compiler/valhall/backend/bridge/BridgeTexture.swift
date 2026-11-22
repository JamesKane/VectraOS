// SPDX-License-Identifier: BSD-3-Clause

// Host only: the texture and the fragment-stage instructions into the interpreter's fields (TextureOps.swift,
// FragmentOps.swift), and the heap handles a test gives its textures and samplers.

import ValhallISA
import ValhallInterp

extension ValhallISA.Instruction {
  /// The fields of TEX_SINGLE, TEX_FETCH, TEX_GATHER and TEX_GRADIENT (12b.4 to 12b.8).
  func fillTexture(_ i: inout Instr) throws {
    func v(_ n: String) -> UInt64 { value(n) ?? 0 }
    var t = TexFields()
    t.wide = v("wide") != 0
    t.project = v("project") != 0
    t.array = v("array") != 0
    t.texelOffset = v("texel_offset") != 0
    t.compare = v("compare") != 0
    t.lod = UInt8(v("lod"))
    t.dim = UInt8(v("dim"))
    t.mask = UInt8(v("mask"))
    t.gatherComponent = UInt8(v("gcomp"))
    t.integerCoordinates = v("cmode") != 0
    t.derivative = v("derivative") != 0
    t.forceDelta = v("force_delta") != 0
    t.biasDisable = v("lod_bias_disable") != 0
    t.clampDisable = v("lod_clamp_disable") != 0
    t.skip = v("skip") != 0
    t.dst32 = v("width") != 0
    i.tex = t
    i.slot = UInt8(v("slot"))
  }

  /// The fields of LD_VAR_BUF_IMM, LD_VAR_SPECIAL, ATEST, ZS_EMIT and BLEND (12c.5, 12c.6).
  func fillFragment(_ i: inout Instr) throws {
    func v(_ n: String) -> UInt64 { value(n) ?? 0 }
    i.slot = UInt8(v("slot"))
    switch mnemonic {
    case "LD_VAR_BUF_IMM":
      i.offset = Int32(v("offset"))
      i.imm = UInt32(v("vsz")) + 1
      i.access = v("vfmt") == 0 || v("vfmt") == 1 ? 1 : 0
      i.special = UInt8(v("spos"))
    case "LD_VAR_SPECIAL":
      i.imm = UInt32(v("name"))
      i.lane = UInt8(v("vsz")) + 1
      i.special = UInt8(v("spos"))
    case "ZS_EMIT":
      i.imm = (v("z") != 0 ? 1 : 0) | (v("stencil") != 0 ? 2 : 0)
      i.slot = 0
    case "ATEST":
      i.slot = 0
    case "BLEND":
      i.special = UInt8(v("fmt"))
      i.offset = Int32(v("skip") / 8)
    case "LD_TILE":
      i.special = UInt8(v("fmt"))
      i.imm = UInt32(v("vsz")) + 1
    default: break
    }
  }
}
