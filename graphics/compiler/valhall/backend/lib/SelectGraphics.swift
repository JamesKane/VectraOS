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
    if !isVertex && opts.blendShaders {
      // 09 section 9.9.5: the blend constants are the first four words (slots 0 and 1) of a fragment shader's FAU.
      gfau.blendConstantWord = 0
      word = 4
    }
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
      if usedBuiltins[IRBuiltin.baseVertex] {
        gfau.baseVertexWord = word
        word += 1
      }
      if usedBuiltins[IRBuiltin.baseInstance] || usedBuiltins[IRBuiltin.instanceIndex] {
        gfau.baseInstanceWord = word
        word += 1
      }
      word = (word + 1) / 2 * 2
      // The draw's viewports, for a shader that writes ViewportIndex (Prep.viewportTransform): a 64-bit address in a slot of its own.
      if usedBuiltins[IRBuiltin.viewportTable] {
        gfau.viewportTableWord = word
        word += 2
      }
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
    for v in m.outputs where !isVertex && v.builtin < 0 {
      guard v.location >= 0 && v.location < 8 else { throw BackendError.unsupported("a colour output at location \(v.location)") }
    }
    // The heap handles of the images and samplers the shader names (a vertex shader's after its own words), from word 0 of a fragment shader's block
    // (graphics/mali/lib/GraphicsShader.swift), then the dummy sampler a fetch of a plain image names.
    var keys: [UInt64] = []
    var needsDummy = false
    for b in layout {
      for id in f.blocks[b].insts where f.insts[id].op == .imgload || f.insts[id].op == .imgstore || f.insts[id].op == .imgaddr
        || f.insts[id].op == .descword
      {
        if isVertex { throw BackendError.unsupported("a storage image access in a vertex shader") }
        let k = f.insts[id].payload[0]
        if !keys.contains(k) { keys.append(k) }
      }
      for id in f.blocks[b].insts where f.insts[id].op == .tex {
        let t = f.insts[id]
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
    // The sample position the hidden interpolation register holds weights for (12c.2.4): a later load at the same one
    // retrieves them instead of computing them again, and waits only for the load that stored them (12c.5.5).
    var storedCentroid: Bool? = nil
    if !isVertex && usedBuiltins[IRBuiltin.helperInvocation] {
      var demotes = false
      for b in layout { for id in f.blocks[b].insts where f.insts[id].op == .demote { demotes = true } }
      if demotes {
        demotedReg = newReg()
        alu("MOV", "i32", dst: .reg(demotedReg, 0), .const(0))
      }
    }
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
        let retrieve = !flat && storedCentroid == v.centroid
        i.put("spos", !flat && !retrieve && v.centroid ? "centroid" : "center")
        i.put("upd", flat || retrieve ? "retrieve" : "store")
        var mi = MInst(i, .message)
        mi.src[0] = !flat && !retrieve && v.centroid ? .reg(preload(61), 0) : .const(0)
        mi.stageWrite = .reg(block, 0)
        mi.hidden = !flat
        mi.hiddenRetrieve = retrieve
        add(mi)
        if !flat { storedCentroid = v.centroid }
        if v.noPerspective && !flat {
          // 12c.5.6: a no-perspective varying is the interpolated one times the fragment's w.
          if fragmentWord < 0 {
            fragmentWord = newReg()
            addSpecialLoad("frag_w", into: fragmentWord, hidden: true)
            storedCentroid = nil
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

  /// The vertex shader's outputs by view and the groups of `shader_output` it stores, found once.
  mutating func vertexGroups() throws(BackendError) -> VertexGroups {
    if let g = vgroups { return g }
    // The views the shader was replicated for (Prep.replicateViews): one, view 0, unless the draw is multiview.
    var g = VertexGroups()
    for o in m.outputs where !g.views.contains(o.view) { g.views.append(o.view) }
    g.views.sort()
    for v in g.views {
      var pos = -1
      for (n, o) in m.outputs.enumerated() where o.view == v && o.builtin == Int(BuiltInId.position) { pos = n }
      guard pos >= 0 else { throw BackendError.invalidIR("a vertex shader without a position") }
      g.posOf.append(pos)
      var varyings: [Int] = []
      for (n, o) in m.outputs.enumerated() where o.view == v && o.location >= 0 { varyings.append(n) }
      varyings.sort { m.outputs[$0].location < m.outputs[$1].location }
      g.varyingsOf.append(varyings)
      var layerOut = -1
      for (n, o) in m.outputs.enumerated() where o.view == v && (o.builtin == Int(BuiltInId.layer) || o.builtin == Int(BuiltInId.viewportIndex)) {
        if layerOut >= 0 { throw BackendError.unsupported("a layer and a viewport index together: they share one field (valhall 14.3.7)") }
        layerOut = n
        storesViewportIndex = o.builtin == Int(BuiltInId.viewportIndex)
      }
      g.layerOf.append(layerOut)
    }
    // Groups, as shader_output's bits name them (12c.4.2): position (bit 0), generic varyings (bit 2).
    // The attribute group (bit 1: point size, layer, primitive id) has no store here: PointSize is accepted and not stored.
    g.bits = [0]
    if g.layerOf[0] >= 0 {
      g.bits.append(1)
      storesAttributes = true
    }
    if !g.varyingsOf[0].isEmpty { g.bits.append(2) }
    vgroups = g
    return g
  }

  mutating func vertexEpilogue() throws(BackendError) {
    let g = try vertexGroups()
    let base = epilogue
    precondition(base == mf.blocks.count, "the epilogue follows the entry's blocks")
    if !groupStores.isEmpty {
      // Divided: each group was stored behind its test where its outputs were made.
      _ = newBlock()
      cur = base
      add(MInst(op("NOP"), .end))
      return
    }
    for _ in 0..<(2 * g.bits.count + 1) { _ = newBlock() }
    let end = base + 2 * g.bits.count
    for (k, bit) in g.bits.enumerated() {
      let head = base + 2 * k
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
      try storeGroup(bit)
      mf.blocks[body].succs = [next]
    }
    cur = end
    add(MInst(op("NOP"), .end))
  }

  /// The stores of one group of `shader_output` (0 the position record, 1 the attributes, 2 the generic varyings) for each
  /// view, at the end of the current block.
  mutating func storeGroup(_ bit: Int) throws(BackendError) {
    let g = try vertexGroups()
    // A view's slots (12c.4.1): its bit position times 8 with the extended record, else 4, for the position and the attributes
    // (which are 4 further); times 4 for the generic varyings.
    let positionStride = storesAttributes ? 8 : 4
    for (k, view) in g.views.enumerated() {
      let pos = g.posOf[k]
      if outputReg[pos] < 0 { outputReg[pos] = newReg(4) }
      let layerOut = g.layerOf[k]
      let a = newReg(2)
      var slot: Opd = .reg(preload(59), 0)
      let index = (bit == 2 ? 4 : positionStride) * view + (bit == 1 ? 4 : 0)
      if index != 0 {
        let s = newReg()
        alu("IADD_IMM", "i32", dst: .reg(s, 0), slot, set: [("imm", index)])
        slot = .reg(s, 0)
      }
      message(
        "LEA_BUF_IMM", "", address: slot, offset: 0, write: .reg(a, 0), memory: 0,
        set: [("table", 13), ("index", bit == 2 ? 1 : 0)])
      if bit == 1 {
        // The layer or viewport index: a u8 at byte 2 of the attributes (06 6.6.1).
        if layerOut >= 0 && outputReg[layerOut] >= 0 {
          message("STORE", "i8", address: .reg(a, 0), offset: 2, read: .reg(outputReg[layerOut], 0), memory: 2, named: [("access", "istream")])
        }
      } else if bit == 0 {
        message("STORE", "i128", address: .reg(a, 0), offset: 0, read: .reg(outputReg[pos], 0), memory: 2, named: [("access", "istream")])
      } else {
        let varyings = g.varyingsOf[k]
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
    }
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
    var targets: [(rt: Int, reg: Int, float: Bool)] = []
    var second: (rt: Int, reg: Int)?
    for (n, o) in m.outputs.enumerated() where o.location >= 0 {
      if outputReg[n] < 0 { outputReg[n] = newReg(4) }
      let comps = o.type.lanes
      var k = comps
      while k < 4 {
        if k == 3 && o.type.scalarKind != .f32 {
          alu("IADD_IMM", "i32", dst: .reg(outputReg[n], k), .const(0), set: [("imm", 1)])
        } else {
          alu("MOV", "i32", dst: .reg(outputReg[n], k), k == 3 ? one : .const(0))
        }
        k += 1
      }
      if o.index == 1 {
        // The second source of dual-source blending (09 section 9.9.2): a blend shader finds it in r4 to r7.
        second = (o.location, outputReg[n])
      } else {
        targets.append((o.location, outputReg[n], o.type.scalarKind == .f32))
      }
    }
    targets.sort { $0.rt < $1.rt }
    if opts.blendShaders {
      for t in targets { mf.vregs[t.reg].callSafe = true }
      if let s = second { mf.vregs[s.reg].callSafe = true }
    }
    // 12c.6.4 step 1: a sample mask the shader wrote is ANDed into the coverage in r60 before ATEST.
    var depthReg = -1
    var stencilReg = -1
    for (n, o) in m.outputs.enumerated() where o.builtin >= 0 && outputReg[n] >= 0 {
      if o.builtin == Int(BuiltInId.sampleMask), let (amt, lane) = shiftAmount(0) {
        alu("LSHIFT_AND", "i32", dst: .reg(v60, 0), .reg(v60, 0), amt, .reg(outputReg[n], 0), set: [("wd1", lane)])
      }
      if o.builtin == Int(BuiltInId.fragDepth) { depthReg = outputReg[n] }
      if o.builtin == Int(BuiltInId.fragStencilRef) { stencilReg = outputReg[n] }
    }
    // 12c.6.4: wait0126, ATEST (slot 0), then `wait` before each BLEND.
    waitFlow(.wait0126)
    var alpha = one
    for t in targets where t.rt == 0 && t.float { alpha = .reg(t.reg, 3) }
    var atest = MInst(op("ATEST"), .message)
    atest.src[0] = .reg(v60, 0)
    atest.src[1] = alpha
    atest.src[2] = .special(0, 5, 0)
    atest.stageWrite = .reg(v60, 0)
    atest.fixedSlot = 0
    add(atest)
    if depthReg >= 0 || stencilReg >= 0 {
      // ZS_EMIT after the ATEST's wait (12c.6.2): the depth and the stencil the shader wrote, the coverage in r60.
      waitFlow(.wait0126)
      var zi = op("ZS_EMIT")
      if depthReg >= 0 { zi.put("z", 1) }
      if stencilReg >= 0 { zi.put("stencil", 1) }
      var zs = MInst(zi, .message)
      zs.src[0] = depthReg >= 0 ? .reg(depthReg, 0) : .const(0)
      zs.src[1] = stencilReg >= 0 ? .reg(stencilReg, 0) : .const(0)
      zs.src[2] = .reg(v60, 0)
      zs.stageWrite = .reg(v60, 0)
      zs.fixedSlot = 0
      add(zs)
    }
    if targets.isEmpty { waitFlow(.wait) }
    let calls = opts.blendShaders
    for (k, t) in targets.enumerated() {
      waitFlow(.wait)
      let last = k == targets.count - 1
      var b = op("BLEND")
      // An integer output goes in the render target's own format (auto32): the alpha test is skipped for it (12c.6.1).
      b.put("fmt", t.float ? "f32" : "auto32")
      var staged: Opd = .reg(t.reg, 0)
      var keep: [Int] = []
      if calls {
        // 09 section 9.9.2: a blend shader finds the colour in r0 to r3, and clobbers r0 to r15 and r48. The colour is copied there,
        // and the other targets' colours stay out of the registers a blend shader may use (`callSafe`).
        let s = mf.newReg(size: 4, fixed: 0)
        for c in 0..<4 { alu("MOV", "i32", dst: .reg(s, c), .reg(t.reg, c)) }
        staged = .reg(s, 0)
        if let d = second, d.rt == t.rt {
          let s2 = mf.newReg(size: 4, fixed: 4)
          for c in 0..<4 { alu("MOV", "i32", dst: .reg(s2, c), .reg(d.reg, c)) }
          keep.append(s2)
        }
        keep.append(s)
        // 9.8.2: the instruction skips the call sequence (16 bytes) in the modes that write; a shader that ends here has `end` on the
        // BLEND itself, and the sequence then returns to address 0 (9.9.1).
        if last { b.flow = .end } else { b.put("skip", 16) }
      }
      var mi = MInst(b, .message)
      mi.src[0] = .special(0, 8 + t.rt, 0)
      mi.src[2] = .reg(v60, 0)
      mi.stageRead = staged
      add(mi)
      if calls {
        // The call sequence, exactly two instructions (9.9.1): the return address in r48 (the program counter, which reads as the
        // address of the following instruction, plus 8; zero for a shader that ends), then the jump to the blend shader's address,
        // the high word of the descriptor's operand (an unconditional jump: not, on the constant zero; 13.4.2).
        let link = mf.newReg(size: 1, fixed: 48)
        if last {
          alu("MOV", "i32", dst: .reg(link, 0), .const(0))
        } else {
          alu("ADR", "", dst: .reg(link, 0), set: [("imm", 8)])
        }
        alu("JUMP", "", .const(0), .special(0, 8 + t.rt, 1), set: [("not", 1)])
        // What the blend shader reads (the colour in r0 to r3, the second source in r4 to r7) stays put until the jump.
        mf.blocks[cur].insts[mf.blocks[cur].insts.count - 1].keepAlive = keep
      }
    }
    if !calls || targets.isEmpty { add(MInst(op("NOP"), .end)) }
  }

  mutating func waitFlow(_ f: Flow) {
    var i = op("NOP")
    i.flow = f
    add(MInst(i, .waitFlow))
  }
}
