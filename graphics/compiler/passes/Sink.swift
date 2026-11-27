// SPDX-License-Identifier: BSD-3-Clause

// Loads of memory nothing writes move down to their first use in their block, with the address arithmetic only they
// use. A front end may load early on purpose (GLSL's uniforms, loaded once at the entry's start, glsl(2)), and a
// vertex shader's inputs are all loaded before anything else runs (vulkanlowering(2)); with many of them the values
// are live together across the whole shader and spill. Near its use a load's value lives for a few instructions; the
// latency is hidden by the other warps a smaller register class leaves room for.

extension Function {
  /// How many instructions a sunk load stays ahead of its first use.
  static let loadLead = 8
}

extension Function {
  /// Whether nothing in the function can write global or storage memory: no store through such a pointer, no atomic,
  /// no image store, no call.
  func writesNoSharedMemory() -> Bool {
    for b in blocks {
      for id in b.insts {
        let i = insts[id]
        switch i.op {
        case .store:
          switch values[i.args[0]].type {
          case .ptr(.function), .ptr(.private_): break
          default: return false
          }
        case .atomic, .imgstore, .call: return false
        default: break
        }
      }
    }
    return true
  }

  /// Move each load of read-only memory, and the address arithmetic used only by such loads, to just before its first
  /// use in its block. A value used in another block, or by a phi, stays. Returns whether anything moved.
  @discardableResult
  public mutating func sinkLoadsToUses() -> Bool {
    let globalReadOnly = writesNoSharedMemory()
    var users = [[Int]](repeating: [], count: values.count)
    for b in blocks {
      for id in b.insts {
        for a in insts[id].args where users[a].last != id { users[a].append(id) }
      }
    }
    func readOnlyLoad(_ i: Inst) -> Bool {
      guard i.op == .load, i.imm2 & 1 == 0 else { return false }
      switch values[i.args[0]].type {
      case .ptr(.uniform), .ptr(.pushConstant): return true
      case .ptr(.global), .ptr(.storage): return globalReadOnly
      default: return false
      }
    }
    var block = [Int](repeating: -1, count: insts.count)
    for (b, bl) in blocks.enumerated() { for id in bl.insts { block[id] = b } }
    var movable = [Bool](repeating: false, count: insts.count)
    var changed = false
    for b in 0..<blocks.count {
      var list = blocks[b].insts
      guard list.count > 2 else { continue }
      var k = list.count - 2
      while k >= 0 {
        let id = list[k]
        let i = insts[id]
        k -= 1
        var ok = readOnlyLoad(i)
        if !ok && i.result >= 0 {
          switch i.op {
          case .ptradd, .inttoptr, .iadd, .zext, .bitcast:
            // Address arithmetic: every use is a load or more of it that moves.
            ok = !users[i.result].isEmpty && users[i.result].allSatisfy { movable[$0] }
          default: break
          }
        }
        guard ok, i.result >= 0 else { continue }
        var first = Int.max
        var local = true
        for u in users[i.result] {
          if block[u] != b || insts[u].op == .phi { local = false; break }
          if let p = list.firstIndex(of: u), p < first { first = p }
        }
        guard local, first != Int.max else { continue }
        movable[id] = true
        let at = k + 1
        // A load keeps a few instructions ahead of its use, so its latency overlaps them; its address goes just before it.
        let target = readOnlyLoad(i) ? first - Function.loadLead : first
        if target > at + 1 {
          list.remove(at: at)
          list.insert(id, at: target - 1)
          changed = true
        }
      }
      blocks[b].insts = list
    }
    return changed
  }
}
