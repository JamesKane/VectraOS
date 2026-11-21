// SPDX-License-Identifier: BSD-3-Clause

// What the backend does to the IR before it selects instructions: calls are
// inlined (valhall 14 has no calling convention for compute: JUMP_EX is
// "not to be emitted", 13.4.3), edges that would need a copy for a phi are
// split, and the blocks are put in the order the selector walks them.

#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif

enum Prep {
  /// Inline every call in the entry function. Recursion is refused.
  static func inlineCalls(_ m: inout IRModule) throws(BackendError) {
    var rounds = 0
    while true {
      var found = false
      var bi = 0
      var ki = 0
      let f = m.functions[m.entry]
      search: for b in 0..<f.blocks.count {
        for k in 0..<f.blocks[b].insts.count where f.insts[f.blocks[b].insts[k]].op == .call {
          bi = b
          ki = k
          found = true
          break search
        }
      }
      if !found { return }
      rounds += 1
      if rounds > 4096 { throw BackendError.unsupported("recursive calls") }
      inline(&m, block: bi, at: ki)
    }
  }

  private static func inline(_ m: inout IRModule, block bi: Int, at k: Int) {
    var f = m.functions[m.entry]
    let callId = f.blocks[bi].insts[k]
    let call = f.insts[callId]
    let callee = m.functions[call.imm]

    // Split the block at the call: the tail takes the rest, the terminator and what it heads.
    let tail = f.addBlock()
    f.blocks[tail].insts = Array(f.blocks[bi].insts[(k + 1)...])
    f.blocks[bi].insts = Array(f.blocks[bi].insts[..<k])
    f.blocks[tail].kind = f.blocks[bi].kind
    f.blocks[tail].merge = f.blocks[bi].merge
    f.blocks[tail].continueTarget = f.blocks[bi].continueTarget
    f.blocks[bi].kind = .plain
    f.blocks[bi].merge = -1
    f.blocks[bi].continueTarget = -1
    for s in f.successors(tail) {
      for id in f.blocks[s].insts where f.insts[id].op == .phi {
        for n in 0..<f.insts[id].blocks.count where f.insts[id].blocks[n] == bi { f.insts[id].blocks[n] = tail }
      }
    }

    // Clone the callee's blocks and instructions.
    var blockMap = [Int](repeating: -1, count: callee.blocks.count)
    for b in 0..<callee.blocks.count { blockMap[b] = f.addBlock() }
    var valMap = [ValueID](repeating: -1, count: callee.values.count)
    for p in 0..<callee.params.count { valMap[p] = call.args[p] }
    var newInsts: [Int] = []
    for b in 0..<callee.blocks.count {
      for id in callee.blocks[b].insts {
        let nid = f.makeInst(callee.insts[id])
        f.blocks[blockMap[b]].insts.append(nid)
        newInsts.append(nid)
        if callee.insts[id].result >= 0 { valMap[callee.insts[id].result] = f.insts[nid].result }
      }
      f.blocks[blockMap[b]].kind = callee.blocks[b].kind
      f.blocks[blockMap[b]].merge = callee.blocks[b].merge >= 0 ? blockMap[callee.blocks[b].merge] : -1
      f.blocks[blockMap[b]].continueTarget =
        callee.blocks[b].continueTarget >= 0 ? blockMap[callee.blocks[b].continueTarget] : -1
    }
    func map(_ v: ValueID) -> ValueID {
      if valMap[v] >= 0 { return valMap[v] }
      let val = callee.values[v]
      var r = -1
      switch val.kind {
      case .constant(let bits):
        if case .scalar(let s) = val.type { r = f.constant(s, bits) }
      case .constVec(let es):
        var mapped: [ValueID] = []
        for e in es { mapped.append(map(e)) }
        r = f.constVector(mapped)
      case .undef: r = f.undef(val.type)
      case .global(let g):
        if case .ptr(let sp) = val.type { r = f.global(g, space: sp) }
      case .resource(let set, let binding):
        if case .ptr(let sp) = val.type { r = f.resource(set: set, binding: binding, space: sp) }
      case .pushConstants: r = f.pushConstants()
      case .inst, .param: break
      }
      valMap[v] = r
      return r
    }
    var retValues: [ValueID] = []
    var retBlocks: [Int] = []
    for nid in newInsts {
      var inst = f.insts[nid]
      var args: [ValueID] = []
      for a in inst.args { args.append(map(a)) }
      inst.args = args
      var bl: [Int] = []
      for b in inst.blocks { bl.append(blockMap[b]) }
      inst.blocks = bl
      if inst.op == .ret {
        // The block holding the ret is the one whose instruction list has this id.
        for b in 0..<callee.blocks.count where f.blocks[blockMap[b]].insts.contains(nid) {
          retBlocks.append(blockMap[b])
        }
        if let v = args.first { retValues.append(v) }
        inst = Inst(.br, .void, [], blocks: [tail])
      }
      f.insts[nid] = inst
    }
    f.append(Inst(.br, .void, [], blocks: [blockMap[0]]), to: bi)

    // The call's result.
    if call.result >= 0 {
      var repl = retValues.count > 0 ? retValues[0] : f.undef(call.type)
      if retValues.count > 1 {
        let phi = Inst(.phi, call.type, retValues, blocks: retBlocks)
        repl = f.insert(phi, in: tail, at: 0)
      }
      for b in 0..<f.blocks.count {
        for id in f.blocks[b].insts {
          for n in 0..<f.insts[id].args.count where f.insts[id].args[n] == call.result { f.insts[id].args[n] = repl }
        }
      }
    }
    m.functions[m.entry] = f
  }

  /// Split every edge from a block of several successors into a block with phis, so a phi's copy has a block to
  /// live in. The new block holds one `br`.
  static func splitCriticalEdges(_ f: inout Function) {
    var b = 0
    let count = f.blocks.count
    while b < count {
      let succ = f.successors(b)
      if succ.count > 1 {
        var done: [Int] = []
        for s in succ where !done.contains(s) {
          done.append(s)
          var hasPhi = false
          for id in f.blocks[s].insts where f.insts[id].op == .phi { hasPhi = true }
          if !hasPhi { continue }
          let n = f.addBlock()
          f.append(Inst(.br, .void, [], blocks: [s]), to: n)
          let t = f.blocks[b].insts[f.blocks[b].insts.count - 1]
          for k in 0..<f.insts[t].blocks.count where f.insts[t].blocks[k] == s { f.insts[t].blocks[k] = n }
          for id in f.blocks[s].insts where f.insts[id].op == .phi {
            for k in 0..<f.insts[id].blocks.count where f.insts[id].blocks[k] == b { f.insts[id].blocks[k] = n }
          }
        }
      }
      b += 1
    }
  }

  /// The reachable blocks in reverse postorder, visiting the later successor first so a branch's then-arm follows it.
  static func layout(_ f: Function) -> [Int] {
    var visited = [Bool](repeating: false, count: f.blocks.count)
    var post: [Int] = []
    var stack: [(Int, Int)] = [(0, 0)]
    visited[0] = true
    while !stack.isEmpty {
      let (b, k) = stack[stack.count - 1]
      let succ = f.successors(b)
      if k < succ.count {
        stack[stack.count - 1].1 += 1
        let s = succ[succ.count - 1 - k]
        if !visited[s] {
          visited[s] = true
          stack.append((s, 0))
        }
      } else {
        post.append(b)
        stack.removeLast()
      }
    }
    var out: [Int] = []
    var i = post.count - 1
    while i >= 0 {
      out.append(post[i])
      i -= 1
    }
    return out
  }
}
