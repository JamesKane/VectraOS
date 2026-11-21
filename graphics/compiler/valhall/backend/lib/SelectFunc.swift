// SPDX-License-Identifier: BSD-3-Clause

// The selection driver: what the shader uses (so the FAU layout is known), the
// phis, the blocks, and how each block ends (13.4, 13.5).

import ShaderCompiler
import ValhallISA

extension Selector {
  var fusedCmp: [Bool] {
    get { fused }
    set { fused = newValue }
  }

  mutating func run() throws(BackendError) -> MFunc {
    let nv = f.values.count
    loc = [Loc](repeating: .none, count: nv)
    zeroHigh = [Bool](repeating: false, count: nv)
    fused = [Bool](repeating: false, count: nv)
    foldedShift = [Int](repeating: -1, count: nv)
    foldedBase = [ValueID](repeating: -1, count: nv)
    layout = Prep.layout(f)
    blockOf = [Int](repeating: -1, count: f.blocks.count)
    for (n, b) in layout.enumerated() { blockOf[b] = n }
    uses = [Int](repeating: 0, count: nv)
    for b in layout {
      for id in f.blocks[b].insts {
        for a in f.insts[id].args { uses[a] += 1 }
      }
    }
    for v in 0..<nv {
      switch f.values[v].kind {
      case .constant(let bits):
        loc[v] = .const(bits)
        if f.values[v].type == .i64 && bits >> 32 == 0 { zeroHigh[v] = true }
      case .undef: loc[v] = .const(0)
      default: break
      }
    }
    try scan()
    // Memory the IR names: workgroup and private variables.
    var wg = 0
    var priv = 0
    wgOffset = [Int](repeating: 0, count: m.globals.count)
    privOffset = [Int](repeating: 0, count: m.globals.count)
    for (n, g) in m.globals.enumerated() {
      let al = max(g.align, 4)
      if g.space == .workgroup {
        wg = (wg + al - 1) / al * al
        wgOffset[n] = wg
        wg += g.size
      } else {
        priv = (priv + al - 1) / al * al
        privOffset[n] = priv
        priv += g.size
      }
    }
    workgroupBytes = (wg + 3) / 4 * 4
    mf.usesWorkgroupMemory = wg > 0
    mf.stackBytes = priv
    for v in 0..<nv {
      switch f.values[v].kind {
      case .resource(let set, let binding):
        var slot = -1
        for b in fau.bindings where b.set == set && b.binding == binding { slot = b.slot }
        loc[v] = .ptr(PtrVal(base: .binding(slot), offset: 0))
      case .global(let g):
        if m.globals[g].space == .workgroup {
          loc[v] = .ptr(PtrVal(base: .workgroup, offset: wgOffset[g]))
        } else {
          loc[v] = .ptr(PtrVal(base: .stack, offset: privOffset[g]))
        }
      case .pushConstants: loc[v] = .ptr(PtrVal(base: .push, offset: 0))
      default: break
      }
    }
    // MIR blocks.
    for b in layout {
      var mb = MBlock()
      mb.ir = b
      mf.blocks.append(mb)
    }
    // Phi results get registers up front: their copies come from the predecessors.
    for b in layout {
      for id in f.blocks[b].insts where f.insts[id].op == .phi {
        let i = f.insts[id]
        guard case .scalar(let s) = i.type, s == .i32 || s == .f32 || s == .bool || s == .i64 else {
          if case .ptr(let sp) = i.type, sp == .global {
            loc[i.result] = .reg(newReg(2))
            continue
          }
          throw BackendError.unsupported("a phi of " + i.type.name)
        }
        loc[i.result] = .reg(newReg(s == .i64 ? 2 : 1))
      }
    }
    for (n, b) in layout.enumerated() {
      cur = n
      if n == 0 { prologue(usedBuiltins) }
      try selectBlock(b, next: n + 1 < layout.count ? layout[n + 1] : -1)
    }
    for n in 0..<layout.count {
      var s: [Int] = []
      for t in f.successors(layout[n]) where !s.contains(blockOf[t]) { s.append(blockOf[t]) }
      mf.blocks[n].succs = s
    }
    return mf
  }

  /// What the shader uses, from the IR: the buffers (so the FAU layout), builtins, folds and fusions.
  mutating func scan() throws(BackendError) {
    var keys: [Int] = []
    var sized: [Int] = []
    var usesNumWG = false
    usedBuiltins = [Bool](repeating: false, count: 9)
    for b in layout {
      for id in f.blocks[b].insts {
        let i = f.insts[id]
        for a in i.args {
          if case .resource(let set, let binding) = f.values[a].kind {
            let k = set << 16 | binding
            if !keys.contains(k) { keys.append(k) }
          }
        }
        if i.op == .arraylen {
          var v = i.args[0]
          while let pi = placedInst(v), pi.op == .ptradd { v = pi.args[0] }
          if case .resource(let set, let binding) = f.values[v].kind {
            let k = set << 16 | binding
            if !keys.contains(k) { keys.append(k) }
            if !sized.contains(k) { sized.append(k) }
          }
        }
        if i.op == .builtin {
          usedBuiltins[i.imm] = true
          if i.imm == IRBuiltin.localInvocationId { usedLid[max(i.imm2, 0)] = true }
          if i.imm == IRBuiltin.numWorkgroups { usesNumWG = true }
        }
        // A power-of-two multiply whose every use is a pointer offset folds into the address (SHADD).
        if (i.op == .imul || i.op == .shl) && i.type == .i32 {
          var k = -1
          var x = -1
          if i.op == .imul, case .constant(let c) = f.values[i.args[1]].kind, c > 0, c <= 128, c & (c - 1) == 0 {
            k = 0
            while (UInt64(1) << UInt64(k)) < c { k += 1 }
            x = i.args[0]
          } else if i.op == .shl, case .constant(let c) = f.values[i.args[1]].kind, c <= 7 {
            k = Int(c)
            x = i.args[0]
          }
          if k >= 0 {
            foldedShift[i.result] = k
            foldedBase[i.result] = x
          }
        }
      }
    }
    // A fold stands only if every use of the product is a ptradd's offset.
    for b in layout {
      for id in f.blocks[b].insts {
        let i = f.insts[id]
        for (n, a) in i.args.enumerated() where foldedShift[a] >= 0 {
          if !(i.op == .ptradd && n == 1 && f.values[i.args[0]].type != .ptr(.global)) { foldedShift[a] = -1 }
        }
      }
    }
    // A compare used once, by a select in its own block, is the select's condition.
    for b in layout {
      for id in f.blocks[b].insts where f.insts[id].op == .select {
        let c = f.insts[id].args[0]
        if uses[c] == 1, let ci = placedInst(c), ci.op == .icmp || ci.op == .fcmp, ci.imm != FCmpPred.ord, ci.imm != FCmpPred.uno,
          case .scalar(let s) = f.values[ci.args[0]].type, s == .i32 || s == .f32, sameBlock(c, b),
          case .scalar(let ts) = f.insts[id].type, ts != .i64
        {
          fused[c] = true
        }
      }
    }
    // The FAU layout, in the order of Contract.swift.
    keys.sort()
    var slot = 0
    for k in keys {
      fau.bindings.append(FauLayout.Binding(set: k >> 16, binding: k & 0xFFFF, slot: slot, sizeWord: -1))
      slot += 1
    }
    var word = slot * 2
    if usesNumWG {
      fau.numWorkgroupsWord = word
      word += 4
    }
    for k in keys where sized.contains(k) {
      for n in 0..<fau.bindings.count where fau.bindings[n].set == k >> 16 && fau.bindings[n].binding == k & 0xFFFF {
        fau.bindings[n].sizeWord = word
        word += 1
      }
    }
    word = (word + 1) / 2 * 2
    fau.pushWord = word
    if word / 2 > 128 { throw BackendError.fauOverflow }
  }

  func sameBlock(_ v: ValueID, _ b: Int) -> Bool {
    guard let d = f.definition(v) else { return false }
    return f.blocks[b].insts.contains(d)
  }

  // MARK: blocks

  mutating func selectBlock(_ b: Int, next: Int) throws(BackendError) {
    let blk = f.blocks[b]
    for id in blk.insts {
      let i = f.insts[id]
      switch i.op {
      case .phi: break
      case .br, .condbr, .switch_, .ret, .unreachable: try terminate(b, i, next: next)
      case .iadd, .isub, .imul, .ineg, .and, .or, .xor, .not, .shl, .lshr, .ashr, .smin, .smax, .umin, .umax, .udiv, .sdiv,
        .urem, .srem:
        if foldedShift[max(i.result, 0)] >= 0 && i.result >= 0 { continue }
        try selectInteger(i)
      case .fadd, .fsub, .fmul, .fdiv, .fneg, .fabs, .fmin, .fmax, .fma, .ffloor, .fceil, .ftrunc, .fround, .fsqrt, .frsq,
        .fexp2, .flog2, .fsin, .fcos:
        try selectFloat(i)
      case .icmp, .fcmp: try selectCompare(i)
      case .select: try selectSelect(i)
      case .zext, .sext, .trunc, .fptosi, .fptoui, .sitofp, .uitofp, .bitcast: try selectConvert(i)
      case .load: try selectLoad(i)
      case .store: try selectStore(i)
      case .ptradd: try selectPtrAdd(i)
      case .alloca:
        let al = max(i.imm2, 4)
        mf.stackBytes = (mf.stackBytes + al - 1) / al * al
        loc[i.result] = .ptr(PtrVal(base: .stack, offset: mf.stackBytes))
        mf.stackBytes += i.imm
      case .atomic: try selectAtomic(i)
      case .barrier, .membar: selectBarrier(i)
      case .builtin: try selectBuiltin(i)
      case .arraylen: try selectArrayLen(i)
      default: throw BackendError.unsupported("operation " + i.op.rawValue)
      }
    }
  }

  /// The copies that set a successor's phis, from this block.
  mutating func phiCopies(from b: Int, to s: Int) {
    var dsts: [Int] = []
    var srcs: [ValueID] = []
    for id in f.blocks[s].insts where f.insts[id].op == .phi {
      let i = f.insts[id]
      guard let k = i.blocks.firstIndex(of: b), case .reg(let d) = loc[i.result] else { continue }
      dsts.append(d)
      srcs.append(i.args[k])
    }
    // A source that is another phi's register of this group would be overwritten first: read all sources into
    // temporaries then.
    var hazard = false
    for v in srcs {
      if case .reg(let r) = loc[v] { if dsts.contains(r) { hazard = true } }
    }
    var staged: [Loc] = []
    for v in srcs {
      if hazard, case .reg(let r) = loc[v] {
        let t = newReg(mf.vregs[r].size)
        copyWords(.reg(t), .reg(r), size: mf.vregs[r].size)
        staged.append(.reg(t))
      } else {
        staged.append(loc[v])
      }
    }
    for (n, d) in dsts.enumerated() { copyWords(.reg(d), staged[n], size: mf.vregs[d].size) }
  }

  mutating func copyWords(_ d: Loc, _ s: Loc, size: Int) {
    guard case .reg(let dv) = d else { return }
    for w in 0..<size {
      var o: Opd = .const(0)
      switch s {
      case .reg(let r): o = .reg(r, w)
      case .const(let bits):
        let b = UInt32(truncatingIfNeeded: bits >> UInt64(32 * w))
        if let c = smallConstant(b) {
          o = .const(c)
        } else {
          alu("IADD_IMM", "i32", dst: .reg(dv, w), .const(0), set: [("imm", Int(b))])
          continue
        }
      case .fau(let word): o = .user(word / 2, word % 2)
      default: break
      }
      if o == .reg(dv, w) { continue }
      alu("MOV", "i32", dst: .reg(dv, w), o)
    }
  }

  mutating func terminate(_ b: Int, _ i: Inst, next: Int) throws(BackendError) {
    switch i.op {
    case .ret, .unreachable:
      add(MInst(op("NOP"), .end))
    case .br:
      let t = i.blocks[0]
      phiCopies(from: b, to: t)
      if t != next { branchAlways(t) }
    case .condbr:
      let t = i.blocks[0]
      let e = i.blocks[1]
      if t == e {
        phiCopies(from: b, to: t)
        if t != next { branchAlways(t) }
        return
      }
      let c = opd(i.args[0])
      if e == next {
        branchIf(c, to: t, not: false)
      } else if t == next {
        branchIf(c, to: e, not: true)
      } else {
        branchIf(c, to: t, not: false)
        branchAlways(e)
      }
    case .switch_:
      // A compare and a branch for each case, then the default.
      let sel = opd(i.args[0])
      var k = 0
      while k < i.payload.count {
        let target = i.blocks[k + 1]
        let t = newReg()
        let cv = UInt32(truncatingIfNeeded: i.payload[k])
        let cOpd: Opd = smallConstant(cv).map { Opd.const($0) } ?? materialize(cv)
        alu("ICMP_OR", "u32", dst: .reg(t, 0), sel, cOpd, .const(0), named: [("cmp", "eq"), ("rtype", "m1")])
        branchIf(.reg(t, 0), to: target, not: false)
        k += 1
      }
      let d = i.blocks[0]
      if d != next { branchAlways(d) }
    default: break
    }
  }

  mutating func branchAlways(_ target: Int) {
    var inst = op("BRANCH")
    inst.put("not", 1)
    var m = MInst(inst, .branch)
    m.src[0] = .const(0)
    m.target = blockOf[target]
    add(m)
  }

  mutating func branchIf(_ c: Opd, to target: Int, not: Bool) {
    var inst = op("BRANCH")
    if not { inst.put("not", 1) }
    var m = MInst(inst, .branch)
    m.src[0] = c
    m.target = blockOf[target]
    add(m)
  }
}
