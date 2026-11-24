// SPDX-License-Identifier: BSD-3-Clause

// The Valhall backend for the vertex and fragment stages (D174 section 3, step 2): SPIR-V or an IR module to a
// `VertexShader` or a `FragmentShader`, the data MaliCore builds a draw from. The ABI the code follows (preloads,
// the FAU block, where varyings sit, the epilogues) is in graphics/mali/lib/GraphicsShader.swift; selection is
// SelectGraphics.swift. The order of the work is the compute path's (Backend.swift), with one pass added for a
// vertex shader: its position is divided by w and put through the viewport transform (14.3.3, the shader's job on
// this hardware), reading the viewport's scale and offset from the FAU.

#if canImport(MaliCore)
  import MaliCore
#endif
#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif
#if canImport(ValhallISA)
  import ValhallISA
#endif

/// A vertex or fragment shader the backend made.
public struct CompiledGraphicsShader: Sendable {
  public var vertex: VertexShader?
  public var fragment: FragmentShader?
  /// The instructions the words encode, for tests and listings.
  public var instructions: [Instruction]
  public var registersUsed: Int
  public var spillSlots: Int

  /// The listing, one instruction a line (valhall 10.14).
  public var listing: String {
    var s = ""
    for i in instructions { s += ISATable.shared.disassemble(i) + "\n" }
    return s
  }

  /// The code words of whichever stage this is.
  public var code: [UInt64] { vertex?.code ?? fragment?.code ?? [] }
}

extension ValhallBackend {
  /// Compile the vertex or fragment entry point of SPIR-V words (the first non-compute one, or `entryPoint`).
  public static func compileGraphics(
    spirv words: [UInt32], entryPoint: String? = nil, specialization: [(id: UInt32, bits: UInt64)] = [],
    options: BackendOptions = BackendOptions()
  ) throws(BackendError) -> CompiledGraphicsShader {
    var ir: IRModule
    do {
      let s = try SPIRVModule.parse(words: words)
      ir = try IRModule.lower(s, entryPoint: entryPoint, specialization: specialization)
    } catch {
      throw BackendError.frontEnd(error.message)
    }
    return try compileGraphics(ir, options: options)
  }

  public static func compileGraphics(_ module: IRModule, options: BackendOptions = BackendOptions()) throws(BackendError)
    -> CompiledGraphicsShader
  {
    guard module.executionModel == 0 || module.executionModel == 4 else {
      throw BackendError.unsupported("a shader that is not a vertex or fragment shader")
    }
    let vertex = module.executionModel == 0
    var m = module
    try Prep.inlineCalls(&m)
    // A vertex shader is replicated for each view of a multiview draw (valhall 07 section 7.8.2), and ViewIndex is each copy's view.
    if vertex {
      var views: [Int] = []
      for v in 0..<32 where options.viewMask >> UInt32(v) & 1 == 1 { views.append(v) }
      Prep.replicateViews(&m, views: views.isEmpty ? [0] : views)
    }
    do {
      try m.optimize()
      try m.verify(scalar: true)
      let expanded = m.expandIntegerDivision()
      if m.expandLongConversions() || expanded { try m.verify(scalar: true) }
    } catch {
      throw BackendError.frontEnd(error.message)
    }
    try Prep.refuseDoubles(m)
    if vertex {
      try Prep.viewportTransform(&m)
      do { try m.verify(scalar: true) } catch { throw BackendError.frontEnd(error.message) }
    }
    var f = m.functions[m.entry]
    if !vertex { Prep.guardTexelBuffers(&f) }
    // A handle that differs between lanes is made uniform by a loop (a fragment warp mixes instances).
    if !vertex && options.uniformTextureHandles {
      Prep.uniformImageAtomics(&f)
      Prep.uniformTextureHandles(&f)
    }
    Prep.splitCriticalEdges(&f)
    var o = options
    // Class 64 for both stages: the class the board ran the hand-written shaders in (valhall 14.1.2).
    o.preferClass32 = false
    var sel = Selector(m, f, o)
    var mf = try sel.run()
    mf.legalize()
    var alloc = try mf.allocate(o)
    if alloc.highest < 0 { alloc.highest = 0 }

    var blocks = mf.physical(alloc)
    for b in 0..<blocks.count {
      blocks[b] = Schedule.waits(blocks[b])
      blocks[b] = mergeEnd(blocks[b])
    }
    let instructions = try link(blocks)

    if options.validate {
      let vo = ValidatorOptions(arch: options.arch, stage: vertex ? .vertex : .fragment, registerClass: .class64)
      let v = ISATable.shared.validate(instructions, options: vo)
      if let first = v.first {
        throw BackendError.invalidOutput(first.rule + " at " + String(first.instruction) + ": " + first.message)
      }
    }
    var code: [UInt64] = []
    for i in instructions {
      do {
        code.append(try ISATable.shared.encode(i))
      } catch {
        throw BackendError.invalidOutput(error.description)
      }
    }

    var layout = sel.gfau
    layout.pushWords = sel.maxPushWord + 1
    var words = layout.pushWord + layout.pushWords
    if layout.pushWords == 0 {
      words = layout.pushWord
      if layout.nonPerspectiveWord >= 0 { words = max(words, layout.nonPerspectiveWord + 1) }
    }
    layout.words = (words + 1) / 2 * 2
    if layout.words > 256 { throw BackendError.fauOverflow }

    var result = CompiledGraphicsShader(
      vertex: nil, fragment: nil, instructions: instructions, registersUsed: alloc.highest + 1, spillSlots: mf.spillSlots)
    let stack = UInt32((mf.stackBytes + 7) / 8 * 8)
    if vertex {
      var outs: [Int] = []
      for o in m.outputs where o.location >= 0 && !outs.contains(o.location) { outs.append(o.location) }
      outs.sort()
      var attrs: [Int] = []
      for v in m.inputs where v.location >= 0 { attrs.append(v.location) }
      attrs.sort()
      let vary = outs.isEmpty ? 0 : VaryingLayout.offset(location: outs[outs.count - 1]) + VaryingLayout.slotBytes
      result.vertex = VertexShader(
        code: code, registerClass: .r64, preloadMask: mf.preload, layout: layout, varyingBytes: UInt32(vary),
        outputLocations: outs, attributeLocations: attrs, storesPointSize: false, stackBytes: stack)
      result.vertex?.readsDrawIndex = sel.usedBuiltins[IRBuiltin.drawIndex]
      result.vertex?.extendedRecord = sel.storesAttributes
      result.vertex?.storesViewportIndex = sel.storesViewportIndex
      result.vertex?.writesLayer = m.outputs.contains { $0.builtin == Int(BuiltInId.layer) }
    } else {
      var targets: [Int] = []
      for o in m.outputs where o.location >= 0 && o.index == 0 { targets.append(o.location) }
      targets.sort()
      var ins: [Int] = []
      var np: UInt32 = 0
      for v in m.inputs where v.location >= 0 {
        ins.append(v.location)
        if v.noPerspective && !v.flat && v.type.scalarKind == .f32 && v.location < 32 { np |= 1 << UInt32(v.location) }
      }
      ins.sort()
      result.fragment = FragmentShader(
        code: code, registerClass: .r64, preloadMask: mf.preload, layout: layout, colourTargets: targets, inputLocations: ins,
        nonPerspectiveMask: np, discards: sel.usesKill, earlyFragmentTests: m.earlyFragmentTests, stackBytes: stack)
      result.fragment?.writesSecondOutput = m.outputs.contains { $0.location >= 0 && $0.index == 1 }
      result.fragment?.writesDepth = m.outputs.contains { $0.builtin == Int(BuiltInId.fragDepth) }
      result.fragment?.writesStencil = m.outputs.contains { $0.builtin == Int(BuiltInId.fragStencilRef) }
      result.fragment?.writesSampleMask = m.outputs.contains { $0.builtin == Int(BuiltInId.sampleMask) }
      result.fragment?.perSampleShading = sel.perSampleShading
      result.fragment?.readsSamplePositions = sel.usesSamplePositions
    }
    return result
  }
}

extension Prep {
  /// The position's transform (14.3.3), in the IR: `r = clamp(1 / w, -2^15, 2^15)`, `x' = x * r * scale + offset` for
  /// x, y and z, and `w' = r`; the scale and offset are the viewport builtins the selector reads from the FAU.
  /// Every block that publishes the position gets it.
  static func viewportTransform(_ m: inout IRModule) throws(BackendError) {
    var positions: [Int] = []
    for (n, o) in m.outputs.enumerated() where o.builtin == Int(BuiltInId.position) { positions.append(n) }
    guard !positions.isEmpty else { throw BackendError.invalidIR("a vertex shader without a position") }
    var f = m.functions[m.entry]
    // Each view's position (a multiview shader has one a view).
    for position in positions {
    // A shader that writes ViewportIndex takes the transform of the viewport it names (14 section 14.3.7): from the draw's table
    // (`IRBuiltin.viewportTable`), entry `index & 15`, so no index reads past it.
    var viewportOut = -1
    for (n, o) in m.outputs.enumerated() where o.builtin == Int(BuiltInId.viewportIndex) && o.view == m.outputs[position].view {
      viewportOut = n
    }
    for b in 0..<f.blocks.count {
      var comp = [Int](repeating: -1, count: 4)
      var last = -1
      var index = -1
      for (k, id) in f.blocks[b].insts.enumerated() where f.insts[id].op == .stageOut && f.insts[id].imm == position {
        let c = f.insts[id].imm2
        guard c >= 0 && c < 4 else { throw BackendError.invalidIR("a position output that is not scalar") }
        comp[c] = id
        last = k
      }
      if last < 0 { continue }
      for c in 0..<4 where comp[c] < 0 { throw BackendError.invalidIR("a position component is not published") }
      if viewportOut >= 0 {
        for (k, id) in f.blocks[b].insts.enumerated() where f.insts[id].op == .stageOut && f.insts[id].imm == viewportOut {
          index = f.insts[id].args[0]
          last = max(last, k)
        }
        guard index >= 0 else {
          throw BackendError.unsupported("a ViewportIndex not written where the position is (the transform needs both)")
        }
      }
      // The new instructions and the four stores go where the last store was, so every operand is defined by then.
      var made: [Int] = []
      func emit(_ i: Inst) -> ValueID {
        let id = f.makeInst(i)
        made.append(id)
        return f.insts[id].result
      }
      let one = f.constant(.f32, 0x3F80_0000)
      let big = f.constant(.f32, 0x4700_0000)
      let nbig = f.constant(.f32, 0xC700_0000)
      let w = f.insts[comp[3]].args[0]
      let rw = emit(Inst(.fdiv, .f32, [one, w]))
      let low = emit(Inst(.fmax, .f32, [rw, nbig]))
      let r = emit(Inst(.fmin, .f32, [low, big]))
      var entry = -1
      if index >= 0 {
        let table = emit(Inst(.builtin, .ptr(.global), [], imm: IRBuiltin.viewportTable, imm2: -1))
        let masked = emit(Inst(.and, .i32, [index, f.constant(.i32, 15)]))
        let scaled = emit(Inst(.shl, .i32, [masked, f.constant(.i32, 5)]))
        let wide = emit(Inst(.zext, .i64, [scaled]))
        entry = emit(Inst(.ptradd, .ptr(.global), [table, wide]))
      }
      var moved: [ValueID] = []
      for c in 0..<3 {
        let v = f.insts[comp[c]].args[0]
        let t = emit(Inst(.fmul, .f32, [v, r]))
        let scale: ValueID
        let offset: ValueID
        if entry >= 0 {
          let ps = emit(Inst(.ptradd, .ptr(.global), [entry, f.constant(.i64, UInt64(4 * c))]))
          scale = emit(Inst(.load, .f32, [ps], imm: 4))
          let po = emit(Inst(.ptradd, .ptr(.global), [entry, f.constant(.i64, UInt64(16 + 4 * c))]))
          offset = emit(Inst(.load, .f32, [po], imm: 4))
        } else {
          scale = emit(Inst(.builtin, .f32, [], imm: IRBuiltin.viewportScale, imm2: c))
          offset = emit(Inst(.builtin, .f32, [], imm: IRBuiltin.viewportOffset, imm2: c))
        }
        moved.append(emit(Inst(.fma, .f32, [t, scale, offset])))
      }
      for c in 0..<3 { f.insts[comp[c]].args[0] = moved[c] }
      f.insts[comp[3]].args[0] = r
      // The new instructions and the position's stores go where the last of the stores (and the index's) was.
      var list: [Int] = []
      for (k, id) in f.blocks[b].insts.enumerated() {
        if comp.contains(id) {
          if k == last {
            list.append(contentsOf: made)
            list.append(contentsOf: comp)
          }
          continue
        }
        list.append(id)
        if k == last {
          list.append(contentsOf: made)
          list.append(contentsOf: comp)
        }
      }
      f.blocks[b].insts = list
    }
    }
    m.functions[m.entry] = f
  }
}
