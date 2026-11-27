// SPDX-License-Identifier: BSD-3-Clause

// A vertex shader's work divided between the two IDVS passes (valhall 14.3.2, 14.3.5). On arch 12 one program runs in
// both, the position pass and the varying pass, and `shader_output` says which groups of outputs the pass writes; a
// shader that computed everything in both would do its varyings' work for every vertex the tiler sees and its position's
// again for every vertex of a kept primitive. Here the instructions only the position needs run behind bit 0 of
// `shader_output`, with the position's stores, and those only the varyings need behind bit 2, with theirs; what both
// need runs first, in both passes.
//
// Only a shader of one block is divided (no control flow: glmark2's, and most), of one view, whose varyings are all
// perspective-correct (a non-perspective one needs the position's w in the varying pass), with no memory writes.

#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif

/// Where a divided vertex shader's output groups are stored: at the end of IR block `block`, the groups `bits` of
/// `shader_output` (0 the position, 1 the attributes, 2 the generic varyings).
struct GroupStores {
  var block: Int
  var bits: [Int]
}

extension Prep {
  /// Divide the vertex shader's one block between the passes; nil when it isn't divided (the epilogue stores every group).
  static func divideVertexPasses(_ f: inout Function, _ m: IRModule, _ opts: BackendOptions) -> [GroupStores]? {
    guard m.executionModel == 0, opts.viewMask == 0, opts.varyingProbe == .tested, opts.nonPerspectiveMask == 0,
      f.blocks.count == 1, let last = f.blocks[0].insts.last, f.insts[last].op == .ret
    else { return nil }
    let list = f.blocks[0].insts
    var hasVarying = false
    var hasAttributes = false
    for id in list {
      let i = f.insts[id]
      switch i.op {
      case .store, .atomic, .imgstore, .barrier, .membar, .call, .kill, .demote, .phi, .alloca: return nil
      case .stageOut:
        let o = m.outputs[i.imm]
        if o.location >= 0 { hasVarying = true }
        if o.builtin == Int(BuiltInId.layer) || o.builtin == Int(BuiltInId.viewportIndex) { hasAttributes = true }
      default: break
      }
    }
    guard hasVarying else { return nil }
    // What each group needs, from its stores back through the operands.
    var forPosition = [Bool](repeating: false, count: f.insts.count)
    var forVaryings = [Bool](repeating: false, count: f.insts.count)
    for id in list.reversed() {
      let i = f.insts[id]
      if i.op == .stageOut {
        if m.outputs[i.imm].location >= 0 { forVaryings[id] = true } else { forPosition[id] = true }
      }
      guard forPosition[id] || forVaryings[id] else { continue }
      for a in i.args {
        guard case .inst(let d) = f.values[a].kind else { continue }
        if forPosition[id] { forPosition[d] = true }
        if forVaryings[id] { forVaryings[d] = true }
      }
    }
    var shared: [Int] = []
    var position: [Int] = []
    var varyings: [Int] = []
    for id in list.dropLast() {
      if forPosition[id] && !forVaryings[id] {
        position.append(id)
      } else if forVaryings[id] && !forPosition[id] {
        varyings.append(id)
      } else {
        shared.append(id)
      }
    }
    // The tests cost a few instructions in each pass: not worth it for a shader that is nearly all shared.
    guard position.count + varyings.count >= 8 else { return nil }
    let bP = f.addBlock()
    let bJ = f.addBlock()
    let bV = f.addBlock()
    let bE = f.addBlock()
    func test(_ bit: UInt64, _ s: ValueID, in b: Int) -> ValueID {
      let t = f.append(Inst(.and, .scalar(.i32), [s, f.constant(.i32, bit)]), to: b)
      return f.append(Inst(.icmp, .scalar(.bool), [t, f.constant(.i32, 0)], imm: ICmpPred.ne), to: b)
    }
    f.blocks[0].insts = shared
    let so = f.append(Inst(.builtin, .scalar(.i32), [], imm: IRBuiltin.shaderOutput, imm2: -1), to: 0)
    let c0 = test(1, so, in: 0)
    f.append(Inst(.condbr, .void, [c0], blocks: [bP, bJ]), to: 0)
    f.blocks[0].kind = .selection
    f.blocks[0].merge = bJ
    f.blocks[bP].insts = position
    f.append(Inst(.br, .void, [], blocks: [bJ]), to: bP)
    let c2 = test(4, so, in: bJ)
    f.append(Inst(.condbr, .void, [c2], blocks: [bV, bE]), to: bJ)
    f.blocks[bJ].kind = .selection
    f.blocks[bJ].merge = bE
    f.blocks[bV].insts = varyings
    f.append(Inst(.br, .void, [], blocks: [bE]), to: bV)
    f.blocks[bE].insts = [last]
    return [GroupStores(block: bP, bits: hasAttributes ? [0, 1] : [0]), GroupStores(block: bV, bits: [2])]
  }
}
