// SPDX-License-Identifier: BSD-3-Clause

// An atomic on a storage image whose element index differs between lanes (valhall 12b.2.1, 12b.11).
//
// An image atomic is `imgaddr` (the texel's address, from the image's descriptor, which the hardware reads one of for a warp) and
// an ordinary global atomic at that address. When the index is not the same in every lane, the address and the atomics on it are
// done in the loop over the distinct handles that texture accesses get (Prep.uniformTextureHandles): the lowest waiting lane's index
// is broadcast, the lanes that have it do the address and its atomics and are done, and the loop ends when no lane waits.
//
//   pre:    ...; br head
//   head:   pending, count, result phis; handle = broadcast of the lowest waiting lane's index; match = pending && index == handle;
//           condbr match, access, next
//   access: the `imgaddr` with the uniform handle and the atomics on its address; br next
//   next:   result phis, pending && !match, count + 1; condbr (ballot(pending) != 0 && count < 16), head, post
//   post:   the rest of the block, the atomics' results from the phis

#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif

extension Prep {
  static func uniformImageAtomics(_ f: inout Function) {
    var rounds = 0
    var changed = true
    while changed && rounds < 256 {
      changed = false
      rounds += 1
      search: for b in 0..<f.blocks.count {
        for (pos, id) in f.blocks[b].insts.enumerated() {
          let t = f.insts[id]
          guard t.op == .imgaddr, !isUniform(f, t.args[0]) else { continue }
          guard let users = atomicUsers(f, block: b, at: pos) else { continue }
          expandAtomic(&f, block: b, at: pos, users: users)
          changed = true
          break search
        }
      }
    }
  }

  /// The atomics of the block that use the address, when nothing else does.
  private static func atomicUsers(_ f: Function, block b: Int, at pos: Int) -> [Int]? {
    let address = f.insts[f.blocks[b].insts[pos]].result
    var users: [Int] = []
    for blk in 0..<f.blocks.count {
      for (k, id) in f.blocks[blk].insts.enumerated() where f.insts[id].args.contains(address) {
        guard blk == b, k > pos, f.insts[id].op == .atomic, f.insts[id].args[0] == address else { return nil }
        users.append(id)
      }
    }
    return users.isEmpty ? nil : users
  }

  private static func expandAtomic(_ f: inout Function, block b: Int, at pos: Int, users: [Int]) {
    let addressId = f.blocks[b].insts[pos]
    let first = f.insts[addressId]
    let group = [addressId] + users
    let rest = Array(f.blocks[b].insts[(pos + 1)...]).filter { !users.contains($0) }
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
    let pending = f.append(Inst(.phi, bool, [yes, no], blocks: [pre, next]), to: head)
    let count = f.append(Inst(.phi, i32, [zero, zero], blocks: [pre, next]), to: head)
    // The atomics' results: a phi each in head, a merge in next.
    var results: [ValueID] = []
    for id in users {
      if f.insts[id].result < 0 {
        results.append(-1)
        continue
      }
      let u = f.undef(f.insts[id].type)
      results.append(f.append(Inst(.phi, f.insts[id].type, [u, u], blocks: [pre, next]), to: head))
    }
    let mask = f.append(Inst(.lane, i32, [pending], imm: 0), to: head)
    let negated = f.append(Inst(.ineg, i32, [mask]), to: head)
    let lowest = f.append(Inst(.and, i32, [mask, negated]), to: head)
    let asFloat = f.append(Inst(.uitofp, .scalar(.f32), [lowest]), to: head)
    let bits = f.append(Inst(.bitcast, i32, [asFloat]), to: head)
    let shifted = f.append(Inst(.lshr, i32, [bits, f.constant(.i32, 23)]), to: head)
    let laneIndex = f.append(Inst(.isub, i32, [shifted, f.constant(.i32, 127)]), to: head)
    let h = f.append(Inst(.lane, i32, [first.args[0], laneIndex], imm: 1), to: head)
    let eq = f.append(Inst(.icmp, bool, [first.args[0], h], imm: ICmpPred.eq), to: head)
    let match = f.append(Inst(.and, bool, [pending, eq]), to: head)
    f.append(Inst(.condbr, .void, [match], blocks: [access, next]), to: head)

    // The address with the handle every lane here has, and the atomics on it.
    var handles = first.args
    handles[0] = h
    var a = first
    a.args = handles
    a.result = -1
    let newAddress = f.append(a, to: access)
    var accessed: [ValueID] = []
    for id in users {
      var t = f.insts[id]
      t.args[0] = newAddress
      t.result = -1
      accessed.append(f.append(t, to: access))
    }
    f.append(Inst(.br, .void, [], blocks: [next]), to: access)

    var merged: [ValueID] = []
    for (k, id) in users.enumerated() {
      if results[k] < 0 {
        merged.append(-1)
        continue
      }
      merged.append(f.append(Inst(.phi, f.insts[id].type, [results[k], accessed[k]], blocks: [head, access]), to: next))
    }
    let still = f.append(Inst(.phi, bool, [pending, no], blocks: [head, access]), to: next)
    let count2 = f.append(Inst(.iadd, i32, [count, one]), to: next)
    let remaining = f.append(Inst(.lane, i32, [still], imm: 0), to: next)
    let any = f.append(Inst(.icmp, bool, [remaining, zero], imm: ICmpPred.ne), to: next)
    let room = f.append(Inst(.icmp, bool, [count2, f.constant(.i32, 16)], imm: ICmpPred.ult), to: next)
    let go = f.append(Inst(.and, bool, [any, room]), to: next)
    f.append(Inst(.condbr, .void, [go], blocks: [head, post]), to: next)

    func patch(_ v: ValueID, _ from: ValueID) {
      guard case .inst(let id) = f.values[v].kind else { return }
      f.insts[id].args[1] = from
    }
    patch(pending, still)
    patch(count, count2)
    for (k, r) in results.enumerated() where r >= 0 { patch(r, merged[k]) }

    for (k, id) in users.enumerated() {
      let old = f.insts[id].result
      if old < 0 { continue }
      for blk in 0..<f.blocks.count where blk != head && blk != access && blk != next {
        for use in f.blocks[blk].insts {
          for n in 0..<f.insts[use].args.count where f.insts[use].args[n] == old { f.insts[use].args[n] = merged[k] }
        }
      }
    }
    _ = group
  }
}
