// SPDX-License-Identifier: BSD-3-Clause

// What the passes share: replacing values and counting uses.

extension Function {
  /// The final replacement of a value in a replacement table (chains are
  /// followed; -1 or out of range means itself).
  func resolve(_ v: ValueID, _ repl: [ValueID]) -> ValueID {
    var x = v
    var steps = 0
    while x < repl.count && repl[x] >= 0 && repl[x] != x {
      x = repl[x]
      steps += 1
      if steps > repl.count { break }
    }
    return x
  }

  /// Rewrite every operand of every placed instruction through a table.
  mutating func apply(_ repl: [ValueID]) {
    for b in blocks {
      for id in b.insts {
        for k in 0..<insts[id].args.count { insts[id].args[k] = resolve(insts[id].args[k], repl) }
      }
    }
  }

  /// How many placed instructions use each value.
  func useCounts() -> [Int] {
    var n = [Int](repeating: 0, count: values.count)
    for b in blocks {
      for id in b.insts {
        for a in insts[id].args { n[a] += 1 }
      }
    }
    return n
  }

  /// The instruction defining `v`, if it is a placed one.
  func def(_ v: ValueID) -> Inst? {
    if case .inst(let id) = values[v].kind { return insts[id] }
    return nil
  }
}

/// The element lanes of a constant value as bits.
func constantLanes(_ f: Function, _ v: ValueID) -> [UInt64]? {
  switch f.values[v].kind {
  case .constant(let b): return [b]
  case .constVec(let es):
    var r: [UInt64] = []
    for e in es {
      guard let b = f.constantBits(e) else { return nil }
      r.append(b)
    }
    return r
  default: return nil
  }
}
