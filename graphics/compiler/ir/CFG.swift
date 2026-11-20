// SPDX-License-Identifier: BSD-3-Clause

// A function's control-flow graph: reachability, reverse postorder and the
// dominator tree (Cooper, Harvey and Kennedy's iterative algorithm).

struct CFG {
  var count: Int
  var preds: [[BlockID]]
  var succs: [[BlockID]]
  /// Reachable blocks in reverse postorder.
  var rpo: [BlockID] = []
  /// Position in `rpo`, or -1 when unreachable.
  var order: [Int]
  /// Immediate dominator; the entry's is itself; -1 when unreachable.
  var idom: [Int]

  init(_ f: Function) {
    count = f.blocks.count
    succs = []
    for b in 0..<count { succs.append(f.successors(b)) }
    preds = [[BlockID]](repeating: [], count: count)
    for b in 0..<count {
      for s in succs[b] where s >= 0 && s < count { preds[s].append(b) }
    }
    order = [Int](repeating: -1, count: count)
    idom = [Int](repeating: -1, count: count)
    guard count > 0 else { return }
    // Postorder by an explicit stack.
    var visited = [Bool](repeating: false, count: count)
    var post: [BlockID] = []
    var stack: [(BlockID, Int)] = [(0, 0)]
    visited[0] = true
    while !stack.isEmpty {
      let (b, k) = stack[stack.count - 1]
      if k < succs[b].count {
        stack[stack.count - 1].1 += 1
        let s = succs[b][k]
        if s >= 0 && s < count && !visited[s] {
          visited[s] = true
          stack.append((s, 0))
        }
      } else {
        post.append(b)
        stack.removeLast()
      }
    }
    rpo = post.reversed()
    for (n, b) in rpo.enumerated() { order[b] = n }
    idom[0] = 0
    var changed = true
    while changed {
      changed = false
      for b in rpo where b != 0 {
        var new = -1
        for p in preds[b] where idom[p] >= 0 {
          new = new < 0 ? p : intersect(p, new)
        }
        if new != idom[b] {
          idom[b] = new
          changed = true
        }
      }
    }
  }

  private func intersect(_ a: Int, _ b: Int) -> Int {
    var x = a
    var y = b
    while x != y {
      while order[x] > order[y] { x = idom[x] }
      while order[y] > order[x] { y = idom[y] }
    }
    return x
  }

  func reachable(_ b: BlockID) -> Bool { order[b] >= 0 }

  /// Whether a dominates b (a block dominates itself); both reachable.
  func dominates(_ a: BlockID, _ b: BlockID) -> Bool {
    var x = b
    while true {
      if x == a { return true }
      if x == 0 || idom[x] < 0 { return false }
      x = idom[x]
    }
  }

  /// The dominance frontier of every block.
  func frontiers() -> [[BlockID]] {
    var df = [[BlockID]](repeating: [], count: count)
    for b in rpo where preds[b].count >= 2 {
      for p in preds[b] where reachable(p) {
        var runner = p
        while runner != idom[b] {
          if !df[runner].contains(b) { df[runner].append(b) }
          runner = idom[runner]
        }
      }
    }
    return df
  }

  /// Children in the dominator tree.
  func domChildren() -> [[BlockID]] {
    var c = [[BlockID]](repeating: [], count: count)
    for b in rpo where b != 0 { c[idom[b]].append(b) }
    return c
  }
}
