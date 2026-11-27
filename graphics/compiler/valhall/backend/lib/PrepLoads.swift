// SPDX-License-Identifier: BSD-3-Clause

// Neighbouring 32-bit loads of global memory as one message: up to four words at consecutive offsets from one base,
// in one block and close together, are one `LOAD.i64`, `i96` or `i128` (valhall 12a: a global access needs no
// alignment up to 128 bits, 12a.1.6). A matrix's column from a uniform block, a vertex input's components: a fourth of
// the messages, and the load-store unit's queue is what a vertex shader full of them waits on.
//
// The IR is scalar here; the merged load is the one vector load the selector takes (SelectMem.swift), each word an
// `extract` of it.

#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif

extension Prep {
  /// How far apart, in instructions, the loads one message replaces may be: the message's words are live from the first.
  static let combineWindow = 24

  /// Combine the loads of each block. Only when nothing in the function writes memory other than its own stack (so
  /// moving a load up past other instructions cannot reorder it with a store).
  static func combineLoads(_ f: inout Function) {
    for b in f.blocks {
      for id in b.insts {
        switch f.insts[id].op {
        case .store:
          if case .ptr(.function) = f.values[f.insts[id].args[0]].type { continue }
          return
        case .atomic, .imgstore, .call: return
        default: break
        }
      }
    }
    for b in 0..<f.blocks.count { combine(&f, block: b) }
  }

  private struct Candidate {
    var position: Int
    var inst: Int
    var base: ValueID
    var offset: Int
  }

  private static func combine(_ f: inout Function, block b: Int) {
    // The loads: a 32-bit scalar of a global pointer that is a base or a base plus a constant.
    var cands: [Candidate] = []
    for (k, id) in f.blocks[b].insts.enumerated() {
      let i = f.insts[id]
      guard i.op == .load, i.imm2 & 1 == 0, i.type == .scalar(.i32) || i.type == .scalar(.f32),
        f.values[i.args[0]].type == .ptr(.global)
      else { continue }
      var base = i.args[0]
      var offset = 0
      // Through every constant step: a matrix column is a step from the matrix, which is one from the block.
      while case .inst(let d) = f.values[base].kind, f.insts[d].op == .ptradd, let c = f.constantBits(f.insts[d].args[1]) {
        base = f.insts[d].args[0]
        offset += Int(Int64(bitPattern: c))
      }
      cands.append(Candidate(position: k, inst: id, base: base, offset: offset))
    }
    guard cands.count >= 2 else { return }
    var used = [Bool](repeating: false, count: cands.count)
    // (first position, the new load and its pointer, the members: candidate index and lane)
    var groups: [(position: Int, members: [(Int, Int)], base: ValueID, offset: Int)] = []
    for a in 0..<cands.count where !used[a] {
      // The lowest offset of a run that starts here: look for the words after it.
      let first = cands[a]
      var members: [(Int, Int)] = [(a, 0)]
      var lanes = 1
      var next = a + 1
      while lanes < 4 && next < cands.count {
        let c = cands[next]
        if c.position - first.position > combineWindow { break }
        if !used[next] && c.base == first.base && c.offset == first.offset + 4 * lanes {
          members.append((next, lanes))
          lanes += 1
          next = a + 1
          continue
        }
        next += 1
      }
      guard members.count >= 2 else { continue }
      for (m, _) in members { used[m] = true }
      groups.append((first.position, members, first.base, first.offset))
    }
    guard !groups.isEmpty else { return }
    // Build the new loads and extracts; insert from the last position back so earlier positions stay right.
    var insertions: [(position: Int, late: Bool, insts: [Int])] = []
    for g in groups {
      let lanes = g.members.count
      let space = f.values[g.base].type
      var made: [Int] = []
      var ptr = g.base
      if g.offset != 0 {
        let p = f.makeInst(Inst(.ptradd, space, [g.base, f.constant(.i64, UInt64(bitPattern: Int64(g.offset)))]))
        made.append(p)
        ptr = f.insts[p].result
      }
      let v = f.makeInst(Inst(.load, .vector(.i32, lanes), [ptr], imm: 4, imm2: 0))
      made.append(v)
      let vec = f.insts[v].result
      insertions.append((g.position, false, made))
      // Each member becomes an extract (and a bitcast for a float) where it was.
      for (m, lane) in g.members {
        let id = cands[m].inst
        let result = f.insts[id].result
        if f.insts[id].type == .scalar(.i32) {
          f.insts[id] = Inst(.extract, .scalar(.i32), [vec], imm: lane)
          f.insts[id].result = result
        } else {
          let e = f.makeInst(Inst(.extract, .scalar(.i32), [vec], imm: lane))
          f.insts[id] = Inst(.bitcast, .scalar(.f32), [f.insts[e].result])
          f.insts[id].result = result
          insertions.append((cands[m].position, true, [e]))
        }
      }
    }
    // At one position the new load goes before an extract of it: inserted last.
    insertions.sort { $0.position != $1.position ? $0.position > $1.position : $0.late && !$1.late }
    for ins in insertions { f.blocks[b].insts.insert(contentsOf: ins.insts, at: ins.position) }
  }
}
