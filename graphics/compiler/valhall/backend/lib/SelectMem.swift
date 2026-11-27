// SPDX-License-Identifier: BSD-3-Clause

// Selection of memory: loads, stores and atomics (12a), pointer arithmetic,
// workgroup and stack memory (14.9), builtins (14.2) and barriers (13.8).

#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif
#if canImport(ValhallISA)
  import ValhallISA
#endif

extension Selector {
  func placedInst(_ v: ValueID) -> Inst? {
    if case .inst(let id) = f.values[v].kind { return f.insts[id] }
    return nil
  }

  /// Make a register that is the low word of a pair usable as `.w0` of a 64-bit source: even.
  mutating func evenReg(_ o: Opd) -> Opd {
    guard case .reg(let v, let off) = o else { return copyToReg(o) }
    if off == 0 && mf.vregs[v].size == 1 && (mf.vregs[v].fixed < 0 || mf.vregs[v].fixed % 2 == 0) {
      mf.vregs[v].align = 2
      return o
    }
    if off == 0 && mf.vregs[v].size >= 2 { return o }
    let r = newReg()
    mf.vregs[r].align = 2
    alu("MOV", "i32", dst: .reg(r, 0), o)
    return .reg(r, 0)
  }

  func baseOpd(_ p: PtrVal) -> Opd {
    switch p.base {
    case .binding(let s): return .user(s, 0)
    case .workgroup: return .special(1, 3, 0)
    case .stack: return .special(1, 1, 0)
    case .reg(let r): return .reg(r, 0)
    case .push: return .const(0)
    }
  }

  /// The address operand and constant offset of an access. `wide`: the offset field is the signed 16 bits of LOAD
  /// and STORE; else the unsigned 8 bits, multiple of 4, of the atomics.
  mutating func address(_ p: PtrVal, wide: Bool) -> (Opd, Int) {
    var base = baseOpd(p)
    var imm = p.offset
    if p.dyn >= 0 {
      let d = evenReg(.reg(p.dyn, 0))
      let t = newReg(2)
      alu("SHADD", "u64", dst: .reg(t, 0), base, d, set: [("shift", p.shift)], named: [("wd1", "w0")])
      base = .reg(t, 0)
    }
    let fits = wide ? (imm >= -32768 && imm <= 32767) : (imm >= 0 && imm <= 252 && imm % 4 == 0)
    if !fits {
      let c = pairConstant(UInt64(bitPattern: Int64(imm)))
      let t = newReg(2)
      alu("IADD", "u64", dst: .reg(t, 0), base, c)
      base = .reg(t, 0)
      imm = 0
    }
    return (base, imm)
  }

  func accessFor(_ p: PtrVal) -> String {
    if case .stack = p.base { return "force" }
    return "none"
  }

  mutating func selectPtrAdd(_ i: Inst) throws(BackendError) {
    var p = ptr(i.args[0])
    let o = i.args[1]
    if case .const(let bits) = loc[o] {
      let signed = f.values[o].type == .i64 ? Int(Int64(bitPattern: bits)) : Int(Int32(truncatingIfNeeded: bits))
      p.offset += signed
    } else if foldedShift[o] >= 0 && p.dyn < 0 {
      let base = foldedBase[o]
      p.dyn = copyToRegV(opd(base))
      p.shift = foldedShift[o]
    } else {
      // A run-time offset: a 32-bit value (a 64-bit one is its low word).
      let off = opd(o)
      if case .reg(let b) = p.base, mf.vregs[b].size == 2, f.values[o].type == .i64 {
        // A global pointer plus a 64-bit offset.
        let (lo, hi) = words64(o)
        _ = hi
        _ = lo
        let t = newReg(2)
        alu("IADD", "u64", dst: .reg(t, 0), .reg(b, 0), opd64(o))
        p = PtrVal(base: .reg(t), offset: p.offset)
      } else {
        if p.dyn >= 0 {
          // Two run-time offsets: add them in a register.
          var cur: Opd = .reg(p.dyn, 0)
          if p.shift != 0 {
            let t = newReg()
            alu("LSHIFT_OR", "i32", dst: .reg(t, 0), cur, shiftAmount(p.shift)!.0, .const(0), set: [("wd1", shiftAmount(p.shift)!.1)])
            cur = .reg(t, 0)
          }
          let t = newReg()
          alu("IADD", "u32", dst: .reg(t, 0), cur, off)
          p.dyn = t
          p.shift = 0
        } else {
          p.dyn = copyToRegV(off)
          p.shift = 0
        }
      }
    }
    loc[i.result] = .ptr(p)
  }

  mutating func copyToRegV(_ o: Opd) -> Int {
    if case .reg(let v, 0) = o, mf.vregs[v].size == 1 { return v }
    let r = newReg()
    alu("MOV", "i32", dst: .reg(r, 0), o)
    return r
  }

  // MARK: loads and stores

  mutating func selectLoad(_ i: Inst) throws(BackendError) {
    let p = ptr(i.args[0])
    let kind: Scalar
    if case .scalar(let x) = i.type {
      kind = x
    } else if i.type == .ptr(.global) {
      kind = .i64
    } else if case .vector(.i32, let n) = i.type, n >= 2 && n <= 4 {
      // Words at consecutive addresses, one message (Prep.combineLoads); each word is an `extract` of it.
      switch p.base {
      case .push, .stack: throw BackendError.unsupported("a vector load of the stack or the push constants")
      default: break
      }
      let r = newReg(n)
      loc[i.result] = .reg(r)
      let (a, imm) = address(p, wide: true)
      message("LOAD", ["i64", "i96", "i128"][n - 2], address: a, offset: imm, write: .reg(r, 0), memory: 1,
              named: [("access", accessFor(p))])
      return
    } else {
      throw BackendError.unsupported("a vector load")
    }
    let s = kind
    if s == .i8 || s == .i16 || s == .f16 { try selectNarrowLoad(i, s, p); return }
    if case .push = p.base {
      guard p.dyn < 0 else { throw BackendError.unsupported("a push constant read at a run-time offset") }
      let w = p.offset / 4
      if s == .i64 {
        noteFAU(push: w + 1)
        let r = newReg(2)
        alu("MOV", "i32", dst: .reg(r, 0), .user((fau.pushWord + w) / 2, (fau.pushWord + w) % 2))
        alu("MOV", "i32", dst: .reg(r, 1), .user((fau.pushWord + w + 1) / 2, (fau.pushWord + w + 1) % 2))
        loc[i.result] = .reg(r)
      } else {
        guard s == .i32 || s == .f32 else { throw BackendError.unsupported("a push constant of " + s.name) }
        noteFAU(push: w)
        loc[i.result] = .fau(fau.pushWord + w)
      }
      return
    }
    if case .stack = p.base, s == .i64 {
      let d = def64(i)
      guard case .reg(let dv, _) = d else { return }
      for k in 0..<2 {
        var q = p
        q.offset += 4 * k
        let (a, imm) = address(q, wide: true)
        message("LOAD", "i32", address: a, offset: imm, write: .reg(dv, k), memory: 1, named: [("access", "force")])
      }
      return
    }
    let (a, imm) = address(p, wide: true)
    switch s {
    case .i32, .f32, .bool:
      let d = def32(i)
      message("LOAD", "i32", address: a, offset: imm, write: d, memory: 1, named: [("access", accessFor(p))])
    case .i64:
      let d = def64(i)
      message("LOAD", "i64", address: a, offset: imm, write: d, memory: 1, named: [("access", accessFor(p))])
    case .i8, .i16, .f16: try selectNarrowLoad(i, s, p)
    default: throw BackendError.unsupported("a load of " + s.name)
    }
  }

  mutating func selectStore(_ i: Inst) throws(BackendError) {
    let p = ptr(i.args[0])
    let v = i.args[1]
    guard case .scalar(let s) = f.values[v].type else { throw BackendError.unsupported("a vector store") }
    if case .stack = p.base, s == .i64 {
      let (lo, hi) = words64(v)
      let words = [copyToReg(lo), copyToReg(hi)]
      for k in 0..<2 {
        var q = p
        q.offset += 4 * k
        let (a, imm) = address(q, wide: true)
        message("STORE", "i32", address: a, offset: imm, read: words[k], memory: 2, named: [("access", "force")])
      }
      return
    }
    switch s {
    case .i32, .f32, .bool:
      let d = reg32(v)
      let (a, imm) = address(p, wide: true)
      message("STORE", "i32", address: a, offset: imm, read: d, memory: 2, named: [("access", accessFor(p))])
    case .i64:
      var d = opd64(v)
      if case .reg = d {} else { d = pairConstantRegs(v) }
      let (a, imm) = address(p, wide: true)
      message("STORE", "i64", address: a, offset: imm, read: d, memory: 2, named: [("access", accessFor(p))])
    case .i8, .i16, .f16: try selectNarrowStore(p, v, s)
    default: throw BackendError.unsupported("a store of " + s.name)
    }
  }

  mutating func pairConstantRegs(_ v: ValueID) -> Opd {
    if case .const(let bits) = loc[v] { return pairConstant(bits) }
    return .const(0)
  }

  // MARK: atomics

  mutating func selectAtomic(_ i: Inst) throws(BackendError) {
    let p = ptr(i.args[0])
    let kind = i.imm
    if kind == AtomicKind.load || kind == AtomicKind.store {
      let t = kind == AtomicKind.load ? i.type : f.values[i.args[1]].type
      if t != .i32 && t != .f32 { throw BackendError.unsupported("an atomic load or store of " + t.name) }
    }
    if kind == AtomicKind.load {
      let (a, imm) = address(p, wide: true)
      let d = def32(i)
      message("LOAD", "i32", address: a, offset: imm, write: d, memory: 1, named: [("access", accessFor(p))])
      return
    }
    if kind == AtomicKind.store {
      let d = reg32(i.args[1])
      let (a, imm) = address(p, wide: true)
      message("STORE", "i32", address: a, offset: imm, read: d, memory: 2, named: [("access", accessFor(p))])
      return
    }
    if i.type == .i64 { try selectAtomic64(i, p); return }
    guard i.type == .i32 || i.type == .void else { throw BackendError.unsupported("an atomic of " + i.type.name) }
    let (a, imm) = address(p, wide: false)
    let used = i.result >= 0 && uses[i.result] > 0
    if kind == AtomicKind.cmpxchg {
      let blk = newReg(2)
      alu("MOV", "i32", dst: .reg(blk, 0), opd(i.args[2]))
      alu("MOV", "i32", dst: .reg(blk, 1), opd(i.args[1]))
      let d = def32(i)
      message("ACMPXCHG", "i32", address: a, offset: imm, read: .reg(blk, 0), write: d, memory: 2)
      return
    }
    // add of 1 with no result: ATOM1 (12a.8.1).
    if (kind == AtomicKind.add || kind == AtomicKind.sub), !used, case .const(let c) = loc[i.args[1]], c == 1 {
      message("ATOM1", "i32", address: a, offset: imm, memory: 2, named: [("op", kind == AtomicKind.add ? "ainc" : "adec")])
      return
    }
    var data = opd(i.args[1])
    var op = "aadd"
    switch kind {
    case AtomicKind.add: op = "aadd"
    case AtomicKind.sub:
      let t = newReg()
      alu("ISUB", "u32", dst: .reg(t, 0), .const(0), data)
      data = .reg(t, 0)
    case AtomicKind.xchg: op = "axchg"
    case AtomicKind.and: op = "aand"
    case AtomicKind.or: op = "aor"
    case AtomicKind.xor: op = "axor"
    case AtomicKind.smin: op = "asmin"
    case AtomicKind.smax: op = "asmax"
    case AtomicKind.umin: op = "aumin"
    case AtomicKind.umax: op = "aumax"
    default: throw BackendError.unsupported("atomic kind")
    }
    let dreg = copyToReg(data)
    if used || kind == AtomicKind.xchg {
      let d = i.result >= 0 ? def32(i) : Opd.reg(newReg(), 0)
      message("ATOM_RETURN", "i32", address: a, offset: imm, read: dreg, write: d, memory: 2, named: [("op", op)])
    } else {
      message("ATOM", "i32", address: a, offset: imm, read: dreg, memory: 2, named: [("op", op)])
    }
  }

  /// A 64-bit atomic: the same instructions with 64-bit data (12a.8): a pair for the operand, and for a compare-exchange a block
  /// of the new value's pair and the compared value's.
  mutating func selectAtomic64(_ i: Inst, _ p: PtrVal) throws(BackendError) {
    let (a, imm) = address(p, wide: false)
    let used = i.result >= 0 && uses[i.result] > 0
    let kind = i.imm
    if kind == AtomicKind.cmpxchg {
      let blk = newReg(4)
      let (nl, nh) = words64(i.args[2])
      let (cl, ch) = words64(i.args[1])
      alu("MOV", "i32", dst: .reg(blk, 0), nl)
      alu("MOV", "i32", dst: .reg(blk, 1), nh)
      alu("MOV", "i32", dst: .reg(blk, 2), cl)
      alu("MOV", "i32", dst: .reg(blk, 3), ch)
      let d = def64(i)
      message("ACMPXCHG", "i64", address: a, offset: imm, read: .reg(blk, 0), write: d, memory: 2)
      return
    }
    var op = "aadd"
    switch kind {
    case AtomicKind.add, AtomicKind.sub: op = "aadd"
    case AtomicKind.xchg: op = "axchg"
    case AtomicKind.and: op = "aand"
    case AtomicKind.or: op = "aor"
    case AtomicKind.xor: op = "axor"
    case AtomicKind.smin: op = "asmin"
    case AtomicKind.smax: op = "asmax"
    case AtomicKind.umin: op = "aumin"
    case AtomicKind.umax: op = "aumax"
    default: throw BackendError.unsupported("atomic kind")
    }
    let pair = newReg(2)
    let (dl, dh) = words64(i.args[1])
    if kind == AtomicKind.sub {
      // 0 - x as a 64-bit subtract.
      let y = opd64(i.args[1])
      alu("ISUB", "u64", dst: .reg(pair, 0), .const(0), y)
    } else {
      alu("MOV", "i32", dst: .reg(pair, 0), dl)
      alu("MOV", "i32", dst: .reg(pair, 1), dh)
    }
    if used || kind == AtomicKind.xchg {
      let d = def64(i)
      message("ATOM_RETURN", "i64", address: a, offset: imm, read: .reg(pair, 0), write: d, memory: 2, named: [("op", op)])
    } else {
      message("ATOM", "i64", address: a, offset: imm, read: .reg(pair, 0), memory: 2, named: [("op", op)])
    }
  }

  // MARK: builtins, barriers, array length

  mutating func noteFAU(push w: Int) { if w > maxPushWord { maxPushWord = w } }

  mutating func selectBuiltin(_ i: Inst) throws(BackendError) {
    let b = i.imm
    let c = i.imm2
    let comp = c >= 0 ? c : 0
    guard c >= 0 || !IRBuiltin.isVec3(b) else { throw BackendError.unsupported("a whole vector builtin") }
    switch b {
    case IRBuiltin.globalInvocationId: loc[i.result] = .reg(preload(60 + comp))
    case IRBuiltin.workgroupId: loc[i.result] = .reg(preload(57 + comp))
    case IRBuiltin.numWorkgroups: loc[i.result] = .fau(fau.numWorkgroupsWord + comp)
    case IRBuiltin.localInvocationId, IRBuiltin.localInvocationIndex, IRBuiltin.subgroupId:
      loc[i.result] = .reg(builtinReg[b][comp])
    case IRBuiltin.subgroupSize: loc[i.result] = .const(16)
    case IRBuiltin.numSubgroups:
      let n = Int(m.localSize.x) * Int(m.localSize.y) * Int(m.localSize.z)
      loc[i.result] = .const(UInt64((n + 15) / 16))
    case IRBuiltin.subgroupLocalId:
      mf.usesLaneID = true
      let d = def32(i)
      alu("MOV", "i32", dst: d, .special(3, 1, 0))
    case IRBuiltin.vertexIndex: loc[i.result] = .reg(preload(60))
    case IRBuiltin.instanceIndex: try selectInstanceIndex(i)
    case IRBuiltin.viewportScale: loc[i.result] = .fau(gfau.viewportWord + 2 * comp)
    case IRBuiltin.viewportOffset: loc[i.result] = .fau(gfau.viewportWord + 2 * comp + 1)
    case IRBuiltin.viewportTable:
      guard gfau.viewportTableWord >= 0 else { throw BackendError.invalidIR("the viewport table with no FAU slot") }
      loc[i.result] = .ptr(PtrVal(base: .binding(gfau.viewportTableWord / 2), offset: 0))
    case IRBuiltin.shaderOutput: alu("MOV", "i32", dst: def32(i), .special(3, 4, 0))
    case IRBuiltin.fragCoord, IRBuiltin.frontFacing: try selectFragmentBuiltin(i)
    default: try selectStageBuiltin(i)
    }
  }

  mutating func preload(_ r: Int) -> Int {
    if preloadReg[r - 48] < 0 { preloadReg[r - 48] = mf.newReg(size: 1, fixed: r) }
    mf.preload |= UInt16(1) << UInt16(r - 48)
    return preloadReg[r - 48]
  }

  /// The values that come from packed or computed preloads, made once at the start of the entry block.
  mutating func prologue(_ used: [Bool]) {
    func has(_ b: Int) -> Bool { used[b] }
    let lx = has(IRBuiltin.localInvocationId) || has(IRBuiltin.localInvocationIndex) || has(IRBuiltin.subgroupId)
    if !lx { return }
    var parts = [-1, -1, -1]
    let sx = Int(m.localSize.x)
    let sy = Int(m.localSize.y)
    let sz = Int(m.localSize.z)
    let needIndex = has(IRBuiltin.localInvocationIndex) || has(IRBuiltin.subgroupId)
    if usedLid[0] || needIndex {
      let r55 = preload(55)
      parts[0] = newReg()
      alu("U16_TO_U32", "", dst: .reg(parts[0], 0), .reg(r55, 0), set: [("wd0", 0)])
    }
    if usedLid[1] || (needIndex && sy > 1) {
      let r55 = preload(55)
      parts[1] = newReg()
      alu("U16_TO_U32", "", dst: .reg(parts[1], 0), .reg(r55, 0), set: [("wd0", 1)])
    }
    if usedLid[2] || (needIndex && sz > 1) {
      let r56 = preload(56)
      parts[2] = newReg()
      alu("U16_TO_U32", "", dst: .reg(parts[2], 0), .reg(r56, 0), set: [("wd0", 0)])
    }
    builtinReg[IRBuiltin.localInvocationId] = parts
    if needIndex {
      var idx = parts[0]
      if sy > 1 || sz > 1 {
        // x + sx * (y + sy * z)
        var acc: Opd = .reg(parts[1] >= 0 ? parts[1] : parts[0], 0)
        if parts[1] < 0 { acc = .const(0) }
        if sz > 1 && parts[2] >= 0 {
          let t = newReg()
          alu("IMUL", "u32", dst: .reg(t, 0), .reg(parts[2], 0), materialize(UInt32(sy)))
          let u = newReg()
          alu("IADD", "u32", dst: .reg(u, 0), .reg(t, 0), acc)
          acc = .reg(u, 0)
        }
        let t = newReg()
        alu("IMUL", "u32", dst: .reg(t, 0), acc, materialize(UInt32(sx)))
        let u = newReg()
        alu("IADD", "u32", dst: .reg(u, 0), .reg(t, 0), .reg(parts[0], 0))
        idx = u
      }
      builtinReg[IRBuiltin.localInvocationIndex] = [idx, -1, -1]
      if has(IRBuiltin.subgroupId) {
        mf.usesLaneID = true
        let sg = newReg()
        let (amt, lane) = shiftAmount(4)!
        alu("RSHIFT_OR", "i32", dst: .reg(sg, 0), .reg(idx, 0), amt, .const(0), set: [("wd1", lane)])
        builtinReg[IRBuiltin.subgroupId] = [sg, -1, -1]
      }
    }
  }

  mutating func selectBarrier(_ i: Inst) {
    if i.op == .barrier && (i.imm == 3 || i.imm == 4) {
      // Subgroup or invocation execution scope: no instruction (12a.9); the memory semantics' waits remain.
      let (release, acquire) = Selector.orderingOf(i.imm2)
      if release || acquire { add(MInst(op("NOP"), .fence)) }
    } else if i.op == .barrier {
      mf.usesBarrier = true
      add(MInst(op("BARRIER"), .barrier))
    } else {
      add(MInst(op("NOP"), .fence))
    }
  }

  mutating func selectArrayLen(_ i: Inst) throws(BackendError) {
    var v = i.args[0]
    while let pi = placedInst(v), pi.op == .ptradd { v = pi.args[0] }
    guard case .resource(let set, let binding) = f.values[v].kind else { throw BackendError.unsupported("arraylen of this pointer") }
    var word = -1
    for b in fau.bindings where b.set == set && b.binding == binding { word = b.sizeWord }
    guard word >= 0, i.imm2 > 0, i.imm2 & (i.imm2 - 1) == 0 else { throw BackendError.unsupported("arraylen with this stride") }
    var k = 0
    while (1 << k) < i.imm2 { k += 1 }
    let size: Opd = .user(word / 2, word % 2)
    var cur = size
    if i.imm != 0 {
      let t = newReg()
      alu("IADD_IMM", "i32", dst: .reg(t, 0), size, set: [("imm", Int(0 &- UInt32(i.imm)))])
      cur = .reg(t, 0)
    }
    if k == 0 {
      alu("MOV", "i32", dst: def32(i), cur)
    } else {
      let (amt, lane) = shiftAmount(k)!
      alu("RSHIFT_OR", "i32", dst: def32(i), cur, amt, .const(0), set: [("wd1", lane)])
    }
  }
}
