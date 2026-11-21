// SPDX-License-Identifier: BSD-3-Clause

// Selection for the vertex and fragment stages (valhall 12c and 14; the ABI the backend chose is in
// graphics/mali/lib/GraphicsShader.swift). What the stages add to the compute selector:
//
//  - inputs: a vertex shader's attributes (LD_ATTR_IMM, table 0) and a fragment shader's varyings
//    (LD_VAR_BUF_IMM) are loaded once, in the entry block, each into a block of registers whose words the
//    shader's reads name (`Loc.part`);
//  - outputs: each `stageOut` copies its value into the output's block of four registers; every return (and
//    every OpKill) branches to one epilogue that does what the stage's outputs need:
//      vertex   - the three groups of `shader_output` (12c.4.2): the position record (bit 0), then the generic
//                 varyings (bit 2), each behind a test of its bit, the whole shader running in both IDVS passes;
//      fragment - ATEST, then one BLEND for each colour output (12c.6.4), the waits the table names.

#if canImport(MaliCore)
  import MaliCore
#endif
#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif
#if canImport(ValhallISA)
  import ValhallISA
#endif

extension Selector {
  var isVertex: Bool { m.executionModel == 0 }

  /// The block layout of the FAU and the limits of the stage (before selection: the push constants' place is needed).
  mutating func scanGraphics() throws(BackendError) {
    guard fau.bindings.isEmpty else {
      throw BackendError.unsupported("a descriptor-bound buffer in a vertex or fragment shader (the root pointer is the binding)")
    }
    gfau = GraphicsFauLayout()
    var word = 0
    if isVertex {
      gfau.viewportWord = 0
      word = 6
      var hasVarying = false
      for o in m.outputs where o.location >= 0 { hasVarying = true }
      needsNonPerspectiveWord = hasVarying && opts.nonPerspectiveMask == nil
      if needsNonPerspectiveWord {
        gfau.nonPerspectiveWord = word
        word += 1
      }
      word = (word + 1) / 2 * 2
      for v in m.inputs where v.location >= 16 {
        throw BackendError.unsupported("vertex attribute location \(v.location) (table 0 holds sixteen)")
      }
    }
    for v in m.inputs where !isVertex && v.location >= VaryingLayout.maxLocations {
      throw BackendError.unsupported("varying location \(v.location)")
    }
    for v in m.outputs where isVertex && v.location >= VaryingLayout.maxLocations {
      throw BackendError.unsupported("varying location \(v.location)")
    }
    for v in m.outputs where !isVertex {
      guard v.location >= 0 && v.location < 8 else { throw BackendError.unsupported("a colour output at location \(v.location)") }
      guard v.type.scalarKind == .f32 else { throw BackendError.unsupported("an integer colour output") }
    }
    // The heap handles of the images and samplers the shader names, from word 0 of a fragment shader's block
    // (graphics/mali/lib/GraphicsShader.swift), then the dummy sampler a fetch of a plain image names.
    var keys: [UInt64] = []
    var needsDummy = false
    for b in layout {
      for id in f.blocks[b].insts where f.insts[id].op == .tex {
        let t = f.insts[id]
        if isVertex { throw BackendError.unsupported("a texture access in a vertex shader") }
        for p in t.payload where p != UInt64.max && !keys.contains(p) { keys.append(p) }
        if t.imm & TexFlags.noSampler != 0 { needsDummy = true }
      }
    }
    keys.sort()
    for k in keys {
      gfau.imageBindings.append(ImageBinding(set: Int(k >> 32), binding: Int(k & 0xFFFF_FFFF), word: word))
      imageWord.append((key: k, word: word))
      word += 1
    }
    if needsDummy {
      gfau.dummySamplerWord = word
      dummySamplerWord = word
      word += 1
    }
    gfau.pushWord = word
    fau.pushWord = word
    outputReg = [Int](repeating: -1, count: m.outputs.count)
    inputReg = [Int](repeating: -1, count: m.inputs.count)
    epilogue = layout.count
  }

  // MARK: inputs

  func vectorSize(_ comps: Int) -> String { ["scalar", "v2", "v3", "v4"][comps - 1] }

  /// The loads of the stage's inputs, at the top of the entry block.
  mutating func graphicsPrologue() throws(BackendError) {
    var fragmentWord = -1
    for (n, v) in m.inputs.enumerated() where inputUse[n] > 0 {
      let comps = inputUse[n]
      let block = newReg(comps)
      inputReg[n] = block
      if isVertex {
        guard v.builtin < 0 else { continue }
        var i = op("LD_ATTR_IMM")
        i.put("table", 0)
        i.put("index", v.location)
        i.put("vsz", vectorSize(comps))
        i.put("fmt", v.type.scalarKind == .f32 ? "f32" : "auto32")
        var mi = MInst(i, .message)
        mi.src[0] = .reg(preload(60), 0)
        mi.src[1] = .reg(preload(61), 0)
        mi.stageWrite = .reg(block, 0)
        add(mi)
      } else {
        let flat = v.flat || v.type.scalarKind != .f32
        var i = op("LD_VAR_BUF_IMM", "f32")
        i.put("offset", VaryingLayout.offset(location: v.location))
        i.put("vsz", vectorSize(comps))
        i.put("vfmt", flat ? "src_flat32" : "src_f32")
        i.put("spos", !flat && v.centroid ? "centroid" : "center")
        i.put("upd", flat ? "retrieve" : "store")
        var mi = MInst(i, .message)
        mi.src[0] = !flat && v.centroid ? .reg(preload(61), 0) : .const(0)
        mi.stageWrite = .reg(block, 0)
        mi.hidden = !flat
        add(mi)
        if v.noPerspective && !flat {
          // 12c.5.6: a no-perspective varying is the interpolated one times the fragment's w.
          if fragmentWord < 0 {
            fragmentWord = newReg()
            addSpecialLoad("frag_w", into: fragmentWord, hidden: true)
          }
          for k in 0..<comps {
            alu("FMA", "f32", dst: .reg(block, k), .reg(block, k), .reg(fragmentWord, 0), .const(0), set: [("neg2", 1)])
          }
        }
      }
    }
  }

  /// `LD_VAR_SPECIAL.f32.<name>.center` into a register (12c.5.4).
  mutating func addSpecialLoad(_ name: String, into r: Int, hidden: Bool) {
    var i = op("LD_VAR_SPECIAL")
    i.put("name", name)
    i.put("fmt", "f32")
    i.put("vsz", "scalar")
    i.put("spos", "center")
    var mi = MInst(i, .message)
    mi.src[0] = .const(0)
    mi.stageWrite = .reg(r, 0)
    mi.hidden = hidden
    add(mi)
  }

  mutating func selectStageIn(_ i: Inst) throws(BackendError) {
    guard i.imm < inputReg.count, inputReg[i.imm] >= 0 else {
      if isVertex && m.inputs[i.imm].builtin >= 0 { throw BackendError.unsupported("a builtin vertex input") }
      throw BackendError.invalidIR("a stage input that was not loaded")
    }
    loc[i.result] = .part(inputReg[i.imm], max(i.imm2, 0))
  }

  /// The fragment builtins that are not preloads as they are: the pixel position as a float, the facing.
  mutating func selectFragmentBuiltin(_ i: Inst) throws(BackendError) {
    let c = max(i.imm2, 0)
    if i.imm == IRBuiltin.frontFacing {
      // Bit 0 of the primitive flags is 0 for front facing (14.4.1).
      let r58 = preload(58)
      let t = newReg()
      alu("AND_IMM", "i32", dst: .reg(t, 0), .reg(r58, 0), set: [("imm", 1)])
      alu("ICMP_OR", "u32", dst: def32(i), .reg(t, 0), .const(0), .const(0), named: [("cmp", "eq"), ("rtype", "m1")])
      return
    }
    switch c {
    case 0, 1:
      // The pixel's integer coordinates, plus a half (14.4.4).
      let r59 = preload(59)
      let u = newReg()
      alu("U16_TO_U32", "", dst: .reg(u, 0), .reg(r59, 0), set: [("wd0", c)])
      let f = newReg()
      alu("U32_TO_F32", "", dst: .reg(f, 0), .reg(u, 0))
      let half: Opd = smallConstant(0x3F00_0000).map { Opd.const($0) } ?? materialize(0x3F00_0000)
      alu("FADD", "f32", dst: def32(i), .reg(f, 0), half)
    default:
      let r = newReg()
      loc[i.result] = .reg(r)
      addSpecialLoad(c == 2 ? "frag_z" : "frag_w", into: r, hidden: c == 3)
    }
  }

  // MARK: outputs

  mutating func selectStageOut(_ i: Inst) throws(BackendError) {
    let n = i.imm
    // PointSize is accepted and not stored (the position record's basic format has no room for it).
    if isVertex && m.outputs[n].builtin == Int(BuiltInId.pointSize) { return }
    if outputReg[n] < 0 { outputReg[n] = newReg(4) }
    let d: Opd = .reg(outputReg[n], max(i.imm2, 0))
    if case .const(let bits) = loc[i.args[0]], smallConstant(UInt32(truncatingIfNeeded: bits)) == nil {
      alu("IADD_IMM", "i32", dst: d, .const(0), set: [("imm", Int(UInt32(truncatingIfNeeded: bits)))])
      return
    }
    alu("MOV", "i32", dst: d, opd(i.args[0]))
  }

  mutating func branchIfBlock(_ c: Opd, to block: Int, not: Bool) {
    var inst = op("BRANCH")
    if not { inst.put("not", 1) }
    var mi = MInst(inst, .branch)
    mi.src[0] = c
    mi.target = block
    add(mi)
  }

  mutating func newBlock() -> Int {
    mf.blocks.append(MBlock())
    return mf.blocks.count - 1
  }

  mutating func graphicsEpilogue() throws(BackendError) {
    if isVertex { try vertexEpilogue() } else { try fragmentEpilogue() }
  }

  // MARK: the vertex epilogue

  mutating func vertexEpilogue() throws(BackendError) {
    var pos = -1
    for (n, o) in m.outputs.enumerated() where o.builtin == Int(BuiltInId.position) { pos = n }
    guard pos >= 0 else { throw BackendError.invalidIR("a vertex shader without a position") }
    if outputReg[pos] < 0 { outputReg[pos] = newReg(4) }
    var varyings: [Int] = []
    for (n, o) in m.outputs.enumerated() where o.location >= 0 { varyings.append(n) }
    varyings.sort { m.outputs[$0].location < m.outputs[$1].location }
    // Groups, as shader_output's bits name them (12c.4.2): position (bit 0), generic varyings (bit 2).
    // The attribute group (bit 1: point size, layer, primitive id) has no store here: PointSize is accepted and not stored.
    var bits = [0]
    if !varyings.isEmpty { bits.append(2) }
    let base = epilogue
    precondition(base == mf.blocks.count, "the epilogue follows the entry's blocks")
    for _ in 0..<(2 * bits.count + 1) { _ = newBlock() }
    let end = base + 2 * bits.count
    for (g, bit) in bits.enumerated() {
      let head = base + 2 * g
      let body = head + 1
      let next = head + 2
      cur = head
      let t = newReg()
      if bit == 2 && opts.varyingProbe != .tested {
        alu("IADD_IMM", "i32", dst: .reg(t, 0), .const(0), set: [("imm", 1 << bit)])
      } else {
        alu("AND_IMM", "i32", dst: .reg(t, 0), .special(3, 4, 0), set: [("imm", 1 << bit)])
      }
      branchIfBlock(.reg(t, 0), to: next, not: true)
      mf.blocks[head].succs = [next, body]
      cur = body
      let a = newReg(2)
      message(
        "LEA_BUF_IMM", "", address: .reg(preload(59), 0), offset: 0, write: .reg(a, 0), memory: 0,
        set: [("table", 13), ("index", bit == 0 ? 0 : 1)])
      if bit == 0 {
        message("STORE", "i128", address: .reg(a, 0), offset: 0, read: .reg(outputReg[pos], 0), memory: 2, named: [("access", "istream")])
      } else {
        if opts.varyingProbe == .shaderOutput, let first = varyings.first(where: { outputReg[$0] >= 0 }) {
          let b = newReg()
          alu("AND_IMM", "i32", dst: .reg(b, 0), .special(3, 4, 0), set: [("imm", 255)])
          let fl = newReg()
          alu("U32_TO_F32", "", dst: .reg(fl, 0), .reg(b, 0))
          let scale = materialize(0x3B80_8081)
          alu("FMA", "f32", dst: .reg(outputReg[first], 0), .reg(fl, 0), scale, .const(0), set: [("neg2", 1)])
        }
        for n in varyings {
          let o = m.outputs[n]
          guard outputReg[n] >= 0 else { continue }
          let comps = o.type.lanes
          if o.type.scalarKind == .f32 { try nonPerspective(o, outputReg[n], comps, wReg: outputReg[pos]) }
          let width = ["i32", "i64", "i96", "i128"][comps - 1]
          message(
            "STORE", width, address: .reg(a, 0), offset: VaryingLayout.offset(location: o.location), read: .reg(outputReg[n], 0),
            memory: 2, named: [("access", "estream")])
        }
      }
      mf.blocks[body].succs = [next]
    }
    cur = end
    add(MInst(op("NOP"), .end))
  }

  /// The varying times the position's reciprocal w, when the fragment shader declares it NoPerspective (14.3.6): by the
  /// compile-time mask, or by the bit of the FAU word the driver fills.
  mutating func nonPerspective(_ o: StageVariable, _ reg: Int, _ comps: Int, wReg: Int) throws(BackendError) {
    let bit = UInt32(1) << UInt32(o.location & 31)
    var factor: Opd
    if let mask = opts.nonPerspectiveMask {
      if mask & bit == 0 || o.location >= 32 { return }
      factor = .reg(wReg, 3)
    } else {
      guard o.location < 32, gfau.nonPerspectiveWord >= 0 else { return }
      let w = gfau.nonPerspectiveWord
      let t = newReg()
      alu("AND_IMM", "i32", dst: .reg(t, 0), .user(w / 2, w % 2), set: [("imm", Int(bit))])
      let f = newReg()
      let one: Opd = smallConstant(0x3F80_0000).map { Opd.const($0) } ?? materialize(0x3F80_0000)
      alu("CSEL", "u32", dst: .reg(f, 0), .reg(t, 0), .const(0), .reg(wReg, 3), one, named: [("cmp", "ne")])
      factor = .reg(f, 0)
    }
    for k in 0..<comps { alu("FMA", "f32", dst: .reg(reg, k), .reg(reg, k), factor, .const(0), set: [("neg2", 1)]) }
  }

  // MARK: the fragment epilogue

  mutating func fragmentEpilogue() throws(BackendError) {
    precondition(epilogue == mf.blocks.count, "the epilogue follows the entry's blocks")
    cur = newBlock()
    mf.blocks[cur].succs = []
    let v60 = preload(60)
    let one: Opd = smallConstant(0x3F80_0000).map { Opd.const($0) } ?? materialize(0x3F80_0000)
    var targets: [(rt: Int, reg: Int)] = []
    for (n, o) in m.outputs.enumerated() where o.location >= 0 {
      if outputReg[n] < 0 { outputReg[n] = newReg(4) }
      let comps = o.type.lanes
      var k = comps
      while k < 4 {
        alu("MOV", "i32", dst: .reg(outputReg[n], k), k == 3 ? one : .const(0))
        k += 1
      }
      targets.append((o.location, outputReg[n]))
    }
    targets.sort { $0.rt < $1.rt }
    // 12c.6.4: wait0126, ATEST (slot 0), then `wait` before each BLEND.
    waitFlow(.wait0126)
    var alpha = one
    for t in targets where t.rt == 0 { alpha = .reg(t.reg, 3) }
    var atest = MInst(op("ATEST"), .message)
    atest.src[0] = .reg(v60, 0)
    atest.src[1] = alpha
    atest.src[2] = .special(0, 5, 0)
    atest.stageWrite = .reg(v60, 0)
    atest.fixedSlot = 0
    add(atest)
    if targets.isEmpty { waitFlow(.wait) }
    for t in targets {
      waitFlow(.wait)
      var b = op("BLEND")
      b.put("fmt", "f32")
      var mi = MInst(b, .message)
      mi.src[0] = .special(0, 8 + t.rt, 0)
      mi.src[2] = .reg(v60, 0)
      mi.stageRead = .reg(t.reg, 0)
      add(mi)
    }
    add(MInst(op("NOP"), .end))
  }

  mutating func waitFlow(_ f: Flow) {
    var i = op("NOP")
    i.flow = f
    add(MInst(i, .waitFlow))
  }
}
