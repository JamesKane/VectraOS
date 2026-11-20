// SPDX-License-Identifier: BSD-3-Clause

// Promotion of Function-storage variables to SSA values.
//
// Two steps. First an alloca used only through loads, stores and `ptradd`s
// of constant offsets is split into one alloca for each distinct accessed
// slot (offset and type), if no two slots overlap. Then each such slot alloca
// whose uses are all direct loads and stores is promoted: phis go at the
// iterated dominance frontier of its stores, and a walk of the dominator tree
// replaces loads with the value reaching them (Cytron et al.). A slot read
// before any store reads `undef`.

private struct Access {
  var inst: Int  // the load or store
  var offset: Int
  var type: IRType
  var isStore: Bool
}

extension Function {
  /// Promote what can be promoted. Returns whether anything changed.
  @discardableResult
  public mutating func promoteAllocas() -> Bool {
    var changed = splitAllocas()
    if promoteSlots() { changed = true }
    return changed
  }

  // MARK: step 1: split

  /// The accesses of an alloca through constant `ptradd`s; nil if it escapes
  /// or has a volatile access.
  private func collect(_ root: ValueID, users: [[Int]]) -> (accesses: [Access], pointerInsts: [Int])? {
    var accesses: [Access] = []
    var pointerInsts: [Int] = []
    var work: [(ValueID, Int)] = [(root, 0)]
    while let (p, off) = work.popLast() {
      for id in users[p] {
        let i = insts[id]
        switch i.op {
        case .load where i.args[0] == p:
          if i.imm2 & 1 != 0 { return nil }
          accesses.append(Access(inst: id, offset: off, type: i.type, isStore: false))
        case .store where i.args[0] == p && i.args[1] != p:
          if i.imm2 & 1 != 0 { return nil }
          accesses.append(Access(inst: id, offset: off, type: values[i.args[1]].type, isStore: true))
        case .ptradd where i.args[0] == p:
          guard let c = constantBits(i.args[1]) else { return nil }
          pointerInsts.append(id)
          work.append((i.result, off + Int(Int32(truncatingIfNeeded: c))))
        default: return nil
        }
      }
    }
    return (accesses, pointerInsts)
  }

  private func users() -> [[Int]] {
    var u = [[Int]](repeating: [], count: values.count)
    for b in blocks {
      for id in b.insts {
        for a in insts[id].args where u[a].last != id { u[a].append(id) }
      }
    }
    return u
  }

  private func sizeOf(_ t: IRType) -> Int { max(1, (t.totalBits + 7) / 8) }

  private mutating func splitAllocas() -> Bool {
    var changed = false
    var u = users()
    var entry = blocks[0].insts
    var k = 0
    while k < entry.count {
      let id = entry[k]
      k += 1
      let a = insts[id]
      guard a.op == .alloca, let (accesses, pointerInsts) = collect(a.result, users: u), !accesses.isEmpty else { continue }
      // A plain access of the alloca's own address needs no split.
      if pointerInsts.isEmpty { continue }
      // Slots must not overlap partially.
      var slots: [(offset: Int, type: IRType)] = []
      var ok = true
      for x in accesses {
        var found = false
        for s in slots where s.offset == x.offset {
          if s.type != x.type { ok = false }
          found = true
        }
        if !found { slots.append((x.offset, x.type)) }
      }
      if !ok { continue }
      for s in slots {
        for t in slots where t.offset != s.offset && t.offset < s.offset + sizeOf(s.type) && s.offset < t.offset + sizeOf(t.type) {
          ok = false
        }
      }
      if !ok { continue }
      // One alloca a slot, in the entry block before the original.
      var newPtr: [ValueID] = []
      for s in slots {
        let al = Inst(.alloca, .ptr(.function), [], imm: sizeOf(s.type), imm2: max(1, min(sizeOf(s.type.element), 16)))
        let v = insert(al, in: 0, at: entry.firstIndex(of: id) ?? 0)
        entry = blocks[0].insts
        newPtr.append(v)
      }
      for x in accesses {
        var si = 0
        for (n, s) in slots.enumerated() where s.offset == x.offset { si = n }
        insts[x.inst].args[0] = newPtr[si]
      }
      changed = true
      k = 0
      u = users()
    }
    return changed
  }

  // MARK: step 2: promote

  private mutating func promoteSlots() -> Bool {
    let cfg = CFG(self)
    let u = users()
    // Candidates: allocas with only direct, non-volatile, same-typed loads and stores.
    var slotValue: [ValueID] = []
    var slotType: [IRType] = []
    var slotAccesses: [[Access]] = []
    for id in blocks[0].insts {
      let a = insts[id]
      guard a.op == .alloca, let (acc, ptrs) = collect(a.result, users: u), ptrs.isEmpty else { continue }
      guard let first = acc.first else { continue }  // unused: dead code removes it
      var ok = true
      for x in acc where x.type != first.type || x.offset != 0 { ok = false }
      if !ok { continue }
      slotValue.append(a.result)
      slotType.append(first.type)
      slotAccesses.append(acc)
    }
    if slotValue.isEmpty { return false }
    let n = slotValue.count
    var slotOf = [Int](repeating: -1, count: values.count)
    for s in 0..<n { slotOf[slotValue[s]] = s }

    // Phi placement.
    let df = cfg.frontiers()
    var phiAt = [[Int]](repeating: [Int](repeating: -1, count: n), count: blocks.count)  // inst id
    var blockOfInst = [Int](repeating: -1, count: insts.count)
    for (b, blk) in blocks.enumerated() { for id in blk.insts { blockOfInst[id] = b } }
    for s in 0..<n {
      var work: [Int] = []
      var hasDef = [Bool](repeating: false, count: blocks.count)
      for x in slotAccesses[s] where x.isStore {
        let b = blockOfInst[x.inst]
        if cfg.reachable(b) && !hasDef[b] {
          hasDef[b] = true
          work.append(b)
        }
      }
      while let b = work.popLast() {
        for d in df[b] where phiAt[d][s] < 0 {
          let pid = makeInst(Inst(.phi, slotType[s], []))
          phiAt[d][s] = pid
          if !hasDef[d] {
            hasDef[d] = true
            work.append(d)
          }
        }
      }
    }
    for b in 0..<blocks.count {
      var front: [Int] = []
      for s in 0..<n where phiAt[b][s] >= 0 { front.append(phiAt[b][s]) }
      blocks[b].insts = front + blocks[b].insts
    }

    // Rename along the dominator tree.
    let children = cfg.domChildren()
    var repl = [ValueID](repeating: -1, count: values.count + 8)
    var dead = [Bool](repeating: false, count: insts.count + n * blocks.count + 8)
    var undefs: [ValueID] = []
    for s in 0..<n { undefs.append(undef(slotType[s])) }
    var phiArgs: [[(ValueID, BlockID)]] = [[(ValueID, BlockID)]](repeating: [], count: insts.count)

    // Iterative DFS with the current values copied down the tree.
    var stack: [(block: Int, cur: [ValueID])] = [(0, undefs)]
    while let (b, incoming) = stack.popLast() {
      var cur = incoming
      for s in 0..<n where phiAt[b][s] >= 0 { cur[s] = insts[phiAt[b][s]].result }
      for id in blocks[b].insts {
        let i = insts[id]
        switch i.op {
        case .load:
          let s = slotOf[i.args[0]]
          if s >= 0 {
            if i.result >= repl.count { repl += [ValueID](repeating: -1, count: i.result - repl.count + 8) }
            repl[i.result] = cur[s]
            dead[id] = true
          }
        case .store:
          let s = slotOf[i.args[0]]
          if s >= 0 {
            cur[s] = resolve(i.args[1], repl)
            dead[id] = true
          }
        default: break
        }
      }
      for sb in cfg.succs[b] {
        for s in 0..<n where phiAt[sb][s] >= 0 {
          let pid = phiAt[sb][s]
          if !phiArgs[pid].contains(where: { $0.1 == b }) { phiArgs[pid].append((cur[s], b)) }
        }
      }
      for c in children[b].reversed() { stack.append((c, cur)) }
    }
    // Unreachable predecessors contribute undef.
    for b in 0..<blocks.count {
      for s in 0..<n where phiAt[b][s] >= 0 {
        let pid = phiAt[b][s]
        for p in cfg.preds[b] where !phiArgs[pid].contains(where: { $0.1 == p }) { phiArgs[pid].append((undefs[s], p)) }
        insts[pid].args = phiArgs[pid].map { $0.0 }
        insts[pid].blocks = phiArgs[pid].map { $0.1 }
      }
    }
    // Remove the promoted loads and stores; the allocas are now unused.
    for b in 0..<blocks.count {
      blocks[b].insts = blocks[b].insts.filter { $0 >= dead.count || !dead[$0] }
    }
    apply(repl)
    // Phi arguments were resolved at the time of the walk; resolve again for
    // loads replaced after their phi was filled.
    for b in blocks { for id in b.insts where insts[id].op == .phi {
      for k in 0..<insts[id].args.count { insts[id].args[k] = resolve(insts[id].args[k], repl) }
    } }
    eliminateDeadCode()
    return true
  }
}
