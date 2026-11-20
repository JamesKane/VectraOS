// SPDX-License-Identifier: BSD-3-Clause

// Dead-code elimination (mark and sweep from the instructions with effects)
// and common-subexpression elimination within a block.

extension Function {
  /// Remove instructions whose results nothing live uses. Phi cycles that
  /// only feed themselves go too. Returns whether anything was removed.
  @discardableResult
  public mutating func eliminateDeadCode() -> Bool {
    var live = [Bool](repeating: false, count: insts.count)
    var work: [Int] = []
    for b in blocks {
      for id in b.insts {
        let i = insts[id]
        let volatileLoad = i.op == .load && i.imm2 & 1 != 0
        if !i.op.isRemovable || volatileLoad {
          live[id] = true
          work.append(id)
        }
      }
    }
    while let id = work.popLast() {
      for a in insts[id].args {
        if case .inst(let d) = values[a].kind, !live[d] {
          live[d] = true
          work.append(d)
        }
      }
    }
    var removed = false
    for bi in 0..<blocks.count {
      var kept: [Int] = []
      for id in blocks[bi].insts {
        if live[id] { kept.append(id) } else { removed = true }
      }
      blocks[bi].insts = kept
    }
    return removed
  }

  /// Merge equal pure instructions within a block: the later one's uses go
  /// to the earlier. Commutative operations match in either operand order.
  @discardableResult
  public mutating func eliminateCommonSubexpressions() -> Bool {
    var repl = [ValueID](repeating: -1, count: values.count)
    var changed = false
    for bi in 0..<blocks.count {
      var table = HashTable()
      var seen: [Int] = []  // instruction ids, by the table's ids
      var kept: [Int] = []
      for id in blocks[bi].insts {
        var i = insts[id]
        for k in 0..<i.args.count { i.args[k] = resolve(i.args[k], repl) }
        insts[id].args = i.args
        guard i.op.isPure, i.result >= 0 else {
          kept.append(id)
          continue
        }
        var args = i.args
        if commutative(i), args.count == 2, args[0] > args[1] { args.swapAt(0, 1) }
        var h = i.type.key
        for c in i.op.rawValue.utf8 { h = hashMix(h, UInt64(c)) }
        h = hashMix(h, UInt64(bitPattern: Int64(i.imm)))
        h = hashMix(h, UInt64(bitPattern: Int64(i.imm2)))
        for a in args { h = hashMix(h, UInt64(a)) }
        for p in i.payload { h = hashMix(h, p) }
        var found: Int? = nil
        if let s = table.find(h, { n in
          let o = self.insts[seen[n]]
          return o.op == i.op && o.type == i.type && o.imm == i.imm && o.imm2 == i.imm2 && o.payload == i.payload
            && self.sortedArgs(o) == args
        }) {
          found = seen[s]
        }
        if let e = found {
          repl[i.result] = insts[e].result
          changed = true
        } else {
          table.insert(h, seen.count)
          seen.append(id)
          kept.append(id)
        }
      }
      blocks[bi].insts = kept
    }
    if changed { apply(repl) }
    return changed
  }

  private func commutative(_ i: Inst) -> Bool {
    switch i.op {
    case .iadd, .imul, .and, .or, .xor, .fadd, .fmul, .smin, .smax, .umin, .umax: return true
    case .icmp: return i.imm == ICmpPred.eq || i.imm == ICmpPred.ne
    case .fcmp: return i.imm == FCmpPred.oeq || i.imm == FCmpPred.one || i.imm == FCmpPred.ueq || i.imm == FCmpPred.une
    default: return false
    }
  }

  private func sortedArgs(_ i: Inst) -> [ValueID] {
    var a = i.args
    if commutative(i), a.count == 2, a[0] > a[1] { a.swapAt(0, 1) }
    return a
  }
}
