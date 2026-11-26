// SPDX-License-Identifier: BSD-3-Clause

// Selection of texture accesses (valhall 12b, 13.10.3; D174 step 3): the IR's four `tex` instructions of one access
// become one `TEX_SINGLE` or `TEX_FETCH`.
//
//  - The handle source `H` is a register pair in the wide form (12b.2.1: word 0 the sampler's handle, word 1 the
//    texture's). Each half is the FAU word of the binding (the driver puts the heap handle of element 0 there:
//    graphics/mali/lib/GraphicsShader.swift) plus the element index, computed at run time, so an array of textures
//    indexed non-uniformly needs no more than a constant index does. A fetch of a plain image has no sampler: it names
//    the dummy sampler the driver supplies.
//  - The staging read block is the operands in 12b.5.1's order, one register each: the coordinates, the layer, the
//    offset word, the level word (a fetch's level is byte 3 of its offset word, 12b.5.2). The wide form has no
//    narrow word, so everything is staged.
//  - The result block holds the channels the shader reads, compactly, 32 bits each (12b.4). Its register type field
//    (`[27:26]`) comes from the texel's kind, as the reference assembler writes it.
//  - `skip` is left clear: a computed level needs the helper lanes' coordinates (13.10.3), and a result a helper
//    lane skipped is zero. The shaders carry no `discard` flow, so the helpers stay alive to the end (13.6.4).
//  - The wait before a consumer of the result is the scheduler's, on the instruction before the consumer (a wait
//    takes effect after its carrier, docs/gpu/valhall-board-findings.md).

#if canImport(MaliCore)
  import MaliCore
#endif
#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif
#if canImport(ValhallISA)
  import ValhallISA
#endif

/// One texture message already selected: its IR identity and where its result block is.
struct TexGroup {
  var block: Int
  var args: [ValueID]
  var imm: Int
  var payload: [UInt64]
  var reg: Int
  var mask: Int
}

extension Selector {
  static let writeMasks = [
    "", "r", "g", "rg", "b", "rb", "gb", "rgb", "a", "ra", "ga", "rga", "ba", "rba", "gba", "rgba",
  ]

  /// The FAU operand of a binding's heap handle.
  func bindingWord(_ key: UInt64) -> Opd {
    for b in imageWord where b.key == key { return .user(b.word / 2, b.word % 2) }
    return .const(0)
  }

  /// The position of a component in a result block holding the components of `mask` in order.
  func texPosition(_ mask: Int, _ c: Int) -> Int {
    var n = 0
    for k in 0..<c where mask & (1 << k) != 0 { n += 1 }
    return n
  }

  /// A 32-bit value into a register of a staging block.
  mutating func stage(_ v: ValueID, into d: Opd) {
    if case .const(let bits) = loc[v], smallConstant(UInt32(truncatingIfNeeded: bits)) == nil {
      alu("IADD_IMM", "i32", dst: d, .const(0), set: [("imm", Int(UInt32(truncatingIfNeeded: bits)))])
      return
    }
    alu("MOV", "i32", dst: d, opd(v))
  }

  /// One half of `H`: the binding's word plus the element index.
  mutating func heapHandle(into d: Opd, key: UInt64, index: ValueID) {
    let base = bindingWord(key)
    if let c = f.constantBits(index), c == 0 {
      alu("MOV", "i32", dst: d, base)
    } else {
      alu("IADD", "u32", dst: d, opd(index), base)
    }
  }

  mutating func selectTexture(_ i: Inst) throws(BackendError) {
    // A vertex shader samples as a fragment shader does, from the same heap, but has no derivatives: an implicit level is the
    // base level (12b: LOD mode none), and a bias has nothing to bias.
    if isVertex && TexFlags.kind(i.imm) == TexFlags.bias { throw BackendError.unsupported("a biased texture access in a vertex shader") }
    for g in texGroups where g.block == cur && g.imm == i.imm && g.args == i.args && g.payload == i.payload {
      loc[i.result] = .part(g.reg, texPosition(g.mask, i.imm2))
      return
    }
    // The first of an access: the channels the block's other components of it read.
    var mask = 0
    for id in f.blocks[layout[cur]].insts {
      let t = f.insts[id]
      if t.op == .tex && t.imm == i.imm && t.args == i.args && t.payload == i.payload { mask |= 1 << t.imm2 }
    }
    let kind = TexFlags.kind(i.imm)
    let dims = TexFlags.dims(i.imm)
    let cube = TexFlags.isCube(i.imm)
    let gradient = i.imm & TexFlags.gradient != 0
    let query = i.imm & TexFlags.lodQuery != 0
    let gather = i.imm & TexFlags.gather != 0
    let h = newReg(2)
    heapHandle(into: .reg(h, 1), key: i.payload[0], index: i.args[0])
    if i.payload[1] == UInt64.max {
      guard dummySamplerWord >= 0 else { throw BackendError.invalidIR("a fetch of a plain image with no dummy sampler") }
      alu("MOV", "i32", dst: .reg(h, 0), .user(dummySamplerWord / 2, dummySamplerWord % 2))
    } else {
      heapHandle(into: .reg(h, 0), key: i.payload[1], index: i.args[1])
    }
    let derivatives = gradient ? 2 * dims : 0
    let count = TexFlags.argumentCount(i.imm) - 2 - derivatives
    guard count >= 1 && count <= 8 else { throw BackendError.unsupported("a texture access of \(count) staging words") }
    let sr = newReg(count)
    for k in 0..<count { stage(i.args[2 + k], into: .reg(sr, k)) }
    var results = 0
    for k in 0..<4 where mask & (1 << k) != 0 { results += 1 }
    let sw = newReg(results)
    let rtype = query ? "s" : ["f", "u", "s"][min(TexFlags.texel(i.imm), 2)]
    let dim = cube ? "cube" : ["tex1d", "tex2d", "tex3d"][dims - 1]

    // Explicit gradients (12b.5.6): a TEX_GRADIENT of the derivatives, interleaved per axis, makes the descriptor the
    // sample reads as its last two words. The reference sets both disables, so the sampler's bias and clamps apply when
    // the descriptor is consumed.
    var descriptor = -1
    if gradient {
      let g = newReg(derivatives)
      for axis in 0..<dims {
        stage(i.args[2 + count + axis], into: .reg(g, 2 * axis))
        stage(i.args[2 + count + dims + axis], into: .reg(g, 2 * axis + 1))
      }
      descriptor = newReg(2)
      var gi = op("TEX_GRADIENT")
      gi.put("wide", 1)
      gi.put("dim", dim)
      gi.put("derivative", 1)
      gi.put("lod_bias_disable", 1)
      gi.put("lod_clamp_disable", 1)
      gi.put("mask", "rg")
      gi.put("rtype", "f")
      gi.put("width", "dst32")
      var gm = MInst(gi, .message)
      gm.src[0] = .reg(h, 0)
      gm.stageRead = .reg(g, 0)
      gm.stageWrite = .reg(descriptor, 0)
      add(gm)
    }
    let sample = gradient ? newReg(count + 2) : sr
    if gradient {
      for k in 0..<count { alu("MOV", "i32", dst: .reg(sample, k), .reg(sr, k)) }
      alu("MOV", "i32", dst: .reg(sample, count), .reg(descriptor, 0))
      alu("MOV", "i32", dst: .reg(sample, count + 1), .reg(descriptor, 1))
    }

    var inst: Instruction
    if query {
      inst = op("TEX_GRADIENT")
      inst.put("lod_clamp_disable", 1)
    } else if gather {
      inst = op("TEX_GATHER")
      inst.put("gcomp", TexFlags.gatherComponent(i.imm))
    } else {
      inst = op(kind == TexFlags.fetch ? "TEX_FETCH" : "TEX_SINGLE")
    }
    inst.put("wide", 1)
    inst.put("dim", dim)
    if cube && kind != TexFlags.fetch { inst.put("project", 1) }
    if TexFlags.isArrayed(i.imm) { inst.put("array", 1) }
    if i.imm & TexFlags.hasOffset != 0 { inst.put("texel_offset", 1) }
    if i.imm & TexFlags.compare != 0 { inst.put("compare", 1) }
    if kind != TexFlags.fetch && !gather && !query {
      if gradient {
        inst.put("lod", "grdesc")
      } else {
        switch kind {
        case TexFlags.implicit: inst.put("lod", isVertex ? "none" : "computed")
        case TexFlags.bias: inst.put("lod", "computed_bias")
        default: inst.put("lod", i.imm & TexFlags.hasLevel != 0 ? "explicit" : "none")
        }
      }
    }
    inst.put("mask", Selector.writeMasks[mask])
    inst.put("rtype", rtype)
    inst.put("width", "dst32")
    var mi = MInst(inst, .message)
    mi.src[0] = .reg(h, 0)
    mi.stageRead = .reg(sample, 0)
    mi.stageWrite = .reg(sw, 0)
    add(mi)
    texGroups.append(TexGroup(block: cur, args: i.args, imm: i.imm, payload: i.payload, reg: sw, mask: mask))
    loc[i.result] = .part(sw, texPosition(mask, i.imm2))
  }

  /// The subgroup operations of the handle loop (IROp.lane): WMASK and CLPER over the warp's 16 lanes (13.9).
  mutating func selectLane(_ i: Inst) {
    let d = newReg()
    if i.imm == 0 {
      // The one place a ballot is made (valhall 13.9.4, whether WMASK counts the lanes executing it or every lane launched is
      // open): WMASK, or sixteen permutes, which give zero for a lane that is not executing whatever WMASK reports.
      ballot(reg32(i.args[0]), into: d)
    } else {
      alu("CLPER", "", dst: .reg(d, 0), reg32(i.args[0]), reg32(i.args[1]))
    }
    loc[i.result] = .reg(d)
  }

  /// OpDemoteToHelperInvocation: flag the lane discarded and keep going (13.6.3: a discarded lane keeps executing and
  /// still takes part in its quad's derivatives; its stores and its BLEND are suppressed).
  mutating func selectDemote() {
    alu("DISCARD", "f32", .const(0), .const(0), named: [("cmp", "eq")])
    // A demoted lane is a helper invocation from here on (Vulkan's IsHelperInvocation).
    if demotedReg >= 0 { alu("MOV", "i32", dst: .reg(demotedReg, 0), .const(1)) }
    usesKill = true
  }
}
