// SPDX-License-Identifier: BSD-3-Clause

// Texel buffer stores and atomics are guarded against an element past the buffer's end (valhall 12b.10.5, 12a.5.2).
//
// An out-of-bounds coordinate gives `LEA_TEX` an address that faults when a store or an atomic uses it, and `LEA_BUF` is no better
// (what it returns past the end is open). So a store (`imgstore`) or an atomic's address (`imgaddr`, with the atomics on it) of a
// texel buffer goes into a block that only an element inside the buffer reaches: the buffer has `size / stride` elements, from the
// descriptor's words 1 and 4 (12b.14.1), read as the size query reads them, and the test is `(element + 1) * stride <= size` in 64 bits
// with a stride that is not zero (a null descriptor has none). An atomic that has a result gives 0 past the end. Loads are not guarded.
//
//   pre:    ...; size, stride; ok = stride != 0 && (zext(element) + 1) * zext(stride) <= zext(size); condbr ok, access, post
//   access: the store, or the address and the atomics on it; br post
//   post:   phis for the atomics' results (0 from pre), the rest of the block

#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif

extension Prep {
  static func guardTexelBuffers(_ f: inout Function) {
    var rounds = 0
    var changed = true
    while changed && rounds < 256 {
      changed = false
      rounds += 1
      search: for b in 0..<f.blocks.count {
        for (pos, id) in f.blocks[b].insts.enumerated() {
          let t = f.insts[id]
          guard t.op == .imgstore || t.op == .imgaddr, ImgFlags.isBuffer(t.imm), !ImgFlags.isGuarded(t.imm) else { continue }
          var users: [Int] = []
          if t.op == .imgaddr {
            guard let found = addressUsers(f, block: b, at: pos) else { continue }
            users = found
          }
          guardAccess(&f, block: b, at: pos, users: users)
          changed = true
          break search
        }
      }
    }
  }

  /// The atomics of the block that use the address, when nothing else does.
  private static func addressUsers(_ f: Function, block b: Int, at pos: Int) -> [Int]? {
    let address = f.insts[f.blocks[b].insts[pos]].result
    var users: [Int] = []
    for blk in 0..<f.blocks.count {
      for (k, id) in f.blocks[blk].insts.enumerated() where f.insts[id].args.contains(address) {
        guard blk == b, k > pos, f.insts[id].op == .atomic, f.insts[id].args[0] == address else { return nil }
        users.append(id)
      }
    }
    return users
  }

  private static func guardAccess(_ f: inout Function, block b: Int, at pos: Int, users: [Int]) {
    let accessId = f.blocks[b].insts[pos]
    let first = f.insts[accessId]
    let rest = Array(f.blocks[b].insts[(pos + 1)...]).filter { !users.contains($0) }
    let i32 = IRType.scalar(.i32), i64 = IRType.scalar(.i64), bool = IRType.scalar(.bool)
    let pre = b
    let access = f.addBlock(), post = f.addBlock()
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

    // The buffer's size and stride, the element, and whether the element is inside.
    let size = f.append(Inst(.descword, i32, [first.args[0]], imm: 1, payload: first.payload), to: pre)
    let stride = f.append(Inst(.descword, i32, [first.args[0]], imm: 4, payload: first.payload), to: pre)
    let element = first.args[1]
    let element64 = f.append(Inst(.zext, i64, [element]), to: pre)
    let stride64 = f.append(Inst(.zext, i64, [stride]), to: pre)
    let size64 = f.append(Inst(.zext, i64, [size]), to: pre)
    let through = f.append(Inst(.iadd, i64, [element64, f.constant(.i64, 1)]), to: pre)
    let end = f.append(Inst(.imul, i64, [through, stride64]), to: pre)
    let fits = f.append(Inst(.icmp, bool, [end, size64], imm: ICmpPred.ule), to: pre)
    let present = f.append(Inst(.icmp, bool, [stride, f.constant(.i32, 0)], imm: ICmpPred.ne), to: pre)
    let inside = f.append(Inst(.and, bool, [fits, present]), to: pre)
    f.append(Inst(.condbr, .void, [inside], blocks: [access, post]), to: pre)

    // The access, as it was, marked as guarded.
    var a = first
    a.imm |= ImgFlags.guarded
    let oldAddress = a.result
    a.result = -1
    let moved = f.append(a, to: access)
    var accessed: [ValueID] = []
    for id in users {
      var t = f.insts[id]
      t.args[0] = moved
      t.result = -1
      accessed.append(f.append(t, to: access))
    }
    _ = oldAddress
    f.append(Inst(.br, .void, [], blocks: [post]), to: access)

    // An atomic's result is 0 where the access did not happen.
    for (k, id) in users.enumerated() {
      let old = f.insts[id].result
      if old < 0 { continue }
      let type = f.insts[id].type
      let zero = f.constant(type.scalarKind ?? .i32, 0)
      let merged = f.append(Inst(.phi, type, [zero, accessed[k]], blocks: [pre, access]), to: post)
      for blk in 0..<f.blocks.count where blk != access {
        for use in f.blocks[blk].insts {
          for n in 0..<f.insts[use].args.count where f.insts[use].args[n] == old { f.insts[use].args[n] = merged }
        }
      }
    }
  }
}
