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
      if !found {
        // Nothing calls anything now: the callees go, so no pass has to take their vector parameters and returns.
        m.functions = [m.functions[m.entry]]
        m.entry = 0
        return
      }
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

  // MARK: texture handles (valhall 12b.2.1, 15 Q16)

  /// Whether a value is the same in every lane of a warp: what a constant, a push constant, or arithmetic on such is. A
  /// flat varying, an instance or vertex index, a window position, a loaded or phi'd value is not (a fragment warp
  /// mixes primitives and instances).
  static func isUniform(_ f: Function, _ v: ValueID, depth: Int = 0) -> Bool {
    if depth > 24 { return false }
    switch f.values[v].kind {
    case .constant, .constVec, .undef, .global, .resource, .pushConstants: return true
    case .param: return false
    case .inst(let id):
      let i = f.insts[id]
      switch i.op {
      case .lane: return true
      case .load:
        // A load at an address every lane has gives every lane the same value: push constants, uniform and storage
        // buffers, global memory through a root pointer (private and function memory are each lane's own).
        guard let p = i.args.first, case .ptr(let sp) = f.values[p].type,
          sp == .pushConstant || sp == .uniform || sp == .storage || sp == .global
        else { return false }
        return isUniform(f, p, depth: depth + 1)
      case .iadd, .isub, .imul, .udiv, .sdiv, .urem, .srem, .ineg, .and, .or, .xor, .not, .shl, .lshr, .ashr, .smin, .smax,
        .umin, .umax, .fadd, .fsub, .fmul, .fdiv, .fneg, .fabs, .fmin, .fmax, .fma, .ffloor, .fceil, .ftrunc, .fround,
        .fsqrt, .frsq, .fexp2, .flog2, .fsin, .fcos, .icmp, .fcmp, .select, .zext, .sext, .trunc, .fptosi, .fptoui,
        .sitofp, .uitofp, .fpext, .fptrunc, .bitcast, .ptrtoint, .inttoptr, .vecbuild, .extract, .insert, .shuffle,
        .ptradd:
        for a in i.args where !isUniform(f, a, depth: depth + 1) { return false }
        return true
      default: return false
      }
    }
  }

  /// Makes every texture access whose handle (the image's element index, or the sampler's) is not uniform a loop over
  /// the distinct values, as the hardware needs (12b.2.1: a handle is one value per warp): until every lane has been
  /// served, the lowest waiting lane's handle is broadcast, the lanes that have it do the access and are done.
  ///
  ///   pre:   ...; br head
  ///   head:  pending, count, result phis; mask = ballot(pending); handle = broadcast(index, lowest set bit of mask);
  ///          match = pending && index == handle; condbr match, access, next
  ///   access: the texture accesses with the uniform handle; br next
  ///   next:  result phis, pending = pending && !match, count + 1; condbr (ballot(pending) != 0 && count < 16), head, post
  ///   post:  the rest of the block, the results from the phis
  ///
  /// The count bounds the loop at the warp's 16 lanes: a handle loop that could not finish ends rather than hangs.
  static func uniformTextureHandles(_ f: inout Function) {
    var rounds = 0
    var changed = true
    while changed && rounds < 256 {
      changed = false
      rounds += 1
      search: for b in 0..<f.blocks.count {
        for (pos, id) in f.blocks[b].insts.enumerated() {
          let t = f.insts[id]
          guard t.op == .tex else { continue }
          var needTexture = !isUniform(f, t.args[0])
          let hasSampler = t.payload.count > 1 && t.payload[1] != UInt64.max && t.args.count > 1
          let needSampler = hasSampler && !isUniform(f, t.args[1])
          if !needTexture && !needSampler { continue }
          if !needTexture { needTexture = false }
          expand(&f, block: b, at: pos, texture: needTexture, sampler: needSampler)
          changed = true
          break search
        }
      }
    }
  }

  private static func expand(_ f: inout Function, block b: Int, at pos: Int, texture: Bool, sampler: Bool) {
    let first = f.insts[f.blocks[b].insts[pos]]
    // The access: this instruction and the others of the block with the same operands (its other components).
    var group: [Int] = []
    var rest: [Int] = []
    for (k, id) in f.blocks[b].insts.enumerated() where k >= pos {
      let t = f.insts[id]
      if t.op == .tex && t.imm == first.imm && t.args == first.args && t.payload == first.payload {
        group.append(id)
      } else {
        rest.append(id)
      }
    }
    let i32 = IRType.scalar(.i32), bool = IRType.scalar(.bool)
    let pre = b
    let head = f.addBlock(), access = f.addBlock(), next = f.addBlock(), post = f.addBlock()
    f.blocks[post].insts = rest
    f.blocks[post].kind = f.blocks[pre].kind
    f.blocks[post].merge = f.blocks[pre].merge
    f.blocks[post].continueTarget = f.blocks[pre].continueTarget
    f.blocks[pre].insts = Array(f.blocks[pre].insts[..<pos])
    f.blocks[pre].kind = .plain
    f.blocks[pre].merge = -1
    f.blocks[pre].continueTarget = -1
    for s in f.successors(post) {
      for id in f.blocks[s].insts where f.insts[id].op == .phi {
        for n in 0..<f.insts[id].blocks.count where f.insts[id].blocks[n] == pre { f.insts[id].blocks[n] = post }
      }
    }
    f.append(Inst(.br, .void, [], blocks: [head]), to: pre)

    let yes = f.constant(.bool, 1), no = f.constant(.bool, 0)
    let zero = f.constant(.i32, 0), one = f.constant(.i32, 1)
    // head's phis, their loop-back operands patched once next has made them.
    let pending = f.append(Inst(.phi, bool, [yes, no], blocks: [pre, next]), to: head)
    let count = f.append(Inst(.phi, i32, [zero, zero], blocks: [pre, next]), to: head)
    var results: [ValueID] = []
    for id in group {
      let u = f.undef(f.insts[id].type)
      results.append(f.append(Inst(.phi, f.insts[id].type, [u, u], blocks: [pre, next]), to: head))
    }
    // The lowest waiting lane: the mask's lowest set bit, as the exponent of its float (exact for a power of two).
    let mask = f.append(Inst(.lane, i32, [pending], imm: 0), to: head)
    let negated = f.append(Inst(.ineg, i32, [mask]), to: head)
    let lowest = f.append(Inst(.and, i32, [mask, negated]), to: head)
    let asFloat = f.append(Inst(.uitofp, .scalar(.f32), [lowest]), to: head)
    let bits = f.append(Inst(.bitcast, i32, [asFloat]), to: head)
    let shifted = f.append(Inst(.lshr, i32, [bits, f.constant(.i32, 23)]), to: head)
    let laneIndex = f.append(Inst(.isub, i32, [shifted, f.constant(.i32, 127)]), to: head)
    var match = pending
    var handles = first.args
    if texture {
      let h = f.append(Inst(.lane, i32, [first.args[0], laneIndex], imm: 1), to: head)
      let eq = f.append(Inst(.icmp, bool, [first.args[0], h], imm: ICmpPred.eq), to: head)
      match = f.append(Inst(.and, bool, [match, eq]), to: head)
      handles[0] = h
    }
    if sampler {
      let h = f.append(Inst(.lane, i32, [first.args[1], laneIndex], imm: 1), to: head)
      let eq = f.append(Inst(.icmp, bool, [first.args[1], h], imm: ICmpPred.eq), to: head)
      match = f.append(Inst(.and, bool, [match, eq]), to: head)
      handles[1] = h
    }
    f.append(Inst(.condbr, .void, [match], blocks: [access, next]), to: head)

    // The access, with the handle every lane here has.
    var accessed: [ValueID] = []
    for id in group {
      var t = f.insts[id]
      t.args = handles
      t.result = -1
      accessed.append(f.append(t, to: access))
    }
    f.append(Inst(.br, .void, [], blocks: [next]), to: access)

    // next: what is done, what waits, whether to go round again.
    var merged: [ValueID] = []
    for (k, id) in group.enumerated() {
      merged.append(f.append(Inst(.phi, f.insts[id].type, [results[k], accessed[k]], blocks: [head, access]), to: next))
    }
    let still = f.append(Inst(.phi, bool, [pending, no], blocks: [head, access]), to: next)
    let count2 = f.append(Inst(.iadd, i32, [count, one]), to: next)
    let remaining = f.append(Inst(.lane, i32, [still], imm: 0), to: next)
    let any = f.append(Inst(.icmp, bool, [remaining, zero], imm: ICmpPred.ne), to: next)
    let room = f.append(Inst(.icmp, bool, [count2, f.constant(.i32, 16)], imm: ICmpPred.ult), to: next)
    let go = f.append(Inst(.and, bool, [any, room]), to: next)
    f.append(Inst(.condbr, .void, [go], blocks: [head, post]), to: next)

    // The loop-back operands of head's phis.
    func patch(_ v: ValueID, _ from: ValueID) {
      guard case .inst(let id) = f.values[v].kind else { return }
      f.insts[id].args[1] = from
    }
    patch(pending, still)
    patch(count, count2)
    for (k, r) in results.enumerated() { patch(r, merged[k]) }

    // The rest of the shader reads the loop's results.
    for (k, id) in group.enumerated() {
      let old = f.insts[id].result
      for blk in 0..<f.blocks.count where blk != head && blk != access && blk != next {
        for use in f.blocks[blk].insts {
          for n in 0..<f.insts[use].args.count where f.insts[use].args[n] == old { f.insts[use].args[n] = merged[k] }
        }
      }
    }
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
