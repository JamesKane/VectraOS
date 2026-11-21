// SPDX-License-Identifier: BSD-3-Clause

// The atomics the hardware does not have, built from the ones it does (valhall 12a.8.8: the instruction set works on 32 and 64-bit
// integer locations only; the compare-exchange on the containing aligned 32-bit word is the building block the spec names).
//
//  - A float add, minimum or maximum on a binary32 or binary16 location, and any read-modify-write on an 8 or 16-bit location, is
//    a loop: read the word, compute the new word (from the float value of the old one, or by replacing the lane inside it), and
//    retry while the compare-exchange returns something other than the word read. The exchange compares bit patterns, so a float
//    negative zero and a positive zero are different words and a NaN equals itself.
//  - A float exchange is the integer exchange on the bit pattern.
//  - An 8 or 16-bit atomic load or store is a plain load or store of that width (naturally aligned, so single-copy atomic), with
//    the barriers the memory semantics ask for.
//
// The pass runs before the narrow integers are legalised (it makes i8, i16 and f16 operations) and after the passes (so
// pointers are `ptradd` chains over a base).

/// The compare-exchange loops' bound: rounds of one word before the loop gives up.
public enum ExpandAtomicsLimits {
  public static let casBound: UInt64 = 1 << 20
}

extension IRModule {
  @discardableResult
  public mutating func expandAtomics() -> Bool {
    var any = false
    for k in 0..<functions.count where functions[k].expandAtomics() { any = true }
    return any
  }
}

extension Function {
  private func atomicElement(_ i: Inst) -> Scalar? {
    let t = i.type == .void ? values[i.args[1]].type : i.type
    if case .scalar(let s) = t { return s }
    return nil
  }

  private func needsExpansion(_ i: Inst) -> Bool {
    guard i.op == .atomic, let s = atomicElement(i) else { return false }
    switch s {
    case .i8, .i16, .f16: return true
    case .f32: return i.imm == AtomicKind.fadd || i.imm == AtomicKind.fmin || i.imm == AtomicKind.fmax || i.imm == AtomicKind.xchg
    default: return false
    }
  }

  @discardableResult
  public mutating func expandAtomics() -> Bool {
    var any = false
    search: while true {
      for b in 0..<blocks.count {
        for (k, id) in blocks[b].insts.enumerated() where needsExpansion(insts[id]) {
          expandAtomic(b, k)
          any = true
          continue search
        }
      }
      break
    }
    if any { eliminateDeadCode() }
    return any
  }

  /// A `membar` for the ordering a SPIR-V scope and semantics ask for: release before, acquire after; none at invocation scope.
  private func needsRelease(_ imm2: Int) -> Bool { (imm2 >> 32) != 4 && imm2 & 0x1C != 0 }
  private func needsAcquire(_ imm2: Int) -> Bool { (imm2 >> 32) != 4 && imm2 & 0x1A != 0 }

  private mutating func expandAtomic(_ b: BlockID, _ k: Int) {
    let id = blocks[b].insts[k]
    let inst = insts[id]
    let tail = Array(blocks[b].insts[(k + 1)...])
    blocks[b].insts = Array(blocks[b].insts[..<k])
    let kind = inst.imm
    let s = atomicElement(inst)!
    let i32 = IRType.i32
    let bool = IRType.bool
    let p = inst.args[0]

    // A narrow load or store: a plain access between the barriers.
    if kind == AtomicKind.load || kind == AtomicKind.store {
      if needsRelease(inst.imm2) && kind == AtomicKind.store { append(Inst(.membar, .void, [], imm2: inst.imm2), to: b) }
      if kind == AtomicKind.load {
        let v = em(b, .load, inst.type, [p])
        if needsAcquire(inst.imm2) { append(Inst(.membar, .void, [], imm2: inst.imm2), to: b) }
        blocks[b].insts += tail
        replace(inst.result, with: v)
      } else {
        append(Inst(.store, .void, [p, inst.args[1]]), to: b)
        blocks[b].insts += tail
      }
      return
    }

    // A float exchange: the integer exchange on the bits.
    if s == .f32 && kind == AtomicKind.xchg {
      let bits = em(b, .bitcast, i32, [inst.args[1]])
      let old = append(Inst(.atomic, i32, [p, bits], imm: AtomicKind.xchg, imm2: inst.imm2), to: b)
      let r = em(b, .bitcast, .f32, [old])
      blocks[b].insts += tail
      replace(inst.result, with: r)
      return
    }

    // The containing word: the pointer's base and its byte offset, rounded down to 4.
    var wordPtr = p
    var shift = constant(.i32, 0)
    if s.bits < 32 {
      var root = p
      var offsets: [ValueID] = []
      while let d = definition(root), insts[d].op == .ptradd {
        offsets.append(insts[d].args[1])
        root = insts[d].args[0]
      }
      guard case .ptr(let space) = values[root].type else { return }
      let ot = space.offsetType
      var off = constant(ot, 0)
      for o in offsets.reversed() { off = em(b, .iadd, .scalar(ot), [off, o]) }
      let aligned = em(b, .and, .scalar(ot), [off, constant(ot, ot == .i64 ? 0xFFFF_FFFF_FFFF_FFFC : 0xFFFF_FFFC)])
      wordPtr = em(b, .ptradd, .ptr(space), [root, aligned])
      let low = em(b, .and, .scalar(ot), [off, constant(ot, 3)])
      let low32 = ot == .i64 ? em(b, .trunc, i32, [low]) : low
      shift = em(b, .shl, i32, [low32, constant(.i32, 3)])
    }

    let head = addBlock()
    let j = addBlock()
    blocks[j].kind = blocks[b].kind
    blocks[j].merge = blocks[b].merge
    blocks[j].continueTarget = blocks[b].continueTarget
    blocks[b].kind = .plain
    blocks[b].merge = -1
    blocks[b].continueTarget = -1
    for succ in insts[tail[tail.count - 1]].blocks {
      for pid in blocks[succ].insts where insts[pid].op == .phi {
        for n in 0..<insts[pid].blocks.count where insts[pid].blocks[n] == b { insts[pid].blocks[n] = j }
      }
    }
    if needsRelease(inst.imm2) { append(Inst(.membar, .void, [], imm2: inst.imm2), to: b) }
    let old0 = em(b, .atomic, i32, [wordPtr], imm: AtomicKind.load)
    append(Inst(.br, .void, [], blocks: [head]), to: b)

    // head: the old word, the lane's value, the new value, the exchange.
    let old = append(Inst(.phi, i32, [old0, old0], blocks: [b, head]), to: head)
    // The loop is bounded (12a.8.8.2: no forward progress is stated across warps): after `casBound` rounds it ends without the
    // update and gives the last word it read.
    let rounds = append(Inst(.phi, i32, [constant(.i32, 0), constant(.i32, 0)], blocks: [b, head]), to: head)
    let elementType = IRType.scalar(s)
    let intType = IRType.scalar(s == .f16 ? .i16 : s == .f32 ? .i32 : s)
    var cur: ValueID
    if s.bits == 32 {
      cur = s == .f32 ? em(head, .bitcast, elementType, [old]) : old
    } else {
      let moved = em(head, .lshr, i32, [old, shift])
      let narrow = em(head, .trunc, intType, [moved])
      cur = s == .f16 ? em(head, .bitcast, elementType, [narrow]) : narrow
    }
    var newv: ValueID
    let operand = inst.args.count > 1 ? inst.args[1] : -1
    switch kind {
    case AtomicKind.xchg: newv = operand
    case AtomicKind.add: newv = em(head, .iadd, elementType, [cur, operand])
    case AtomicKind.sub: newv = em(head, .isub, elementType, [cur, operand])
    case AtomicKind.and: newv = em(head, .and, elementType, [cur, operand])
    case AtomicKind.or: newv = em(head, .or, elementType, [cur, operand])
    case AtomicKind.xor: newv = em(head, .xor, elementType, [cur, operand])
    case AtomicKind.smin: newv = em(head, .smin, elementType, [cur, operand])
    case AtomicKind.smax: newv = em(head, .smax, elementType, [cur, operand])
    case AtomicKind.umin: newv = em(head, .umin, elementType, [cur, operand])
    case AtomicKind.umax: newv = em(head, .umax, elementType, [cur, operand])
    case AtomicKind.fadd: newv = em(head, .fadd, elementType, [cur, operand])
    case AtomicKind.fmin: newv = em(head, .fmin, elementType, [cur, operand])
    case AtomicKind.fmax: newv = em(head, .fmax, elementType, [cur, operand])
    default:
      // compare-exchange: [pointer, compare, new]
      let same = em(head, .icmp, bool, [cur, inst.args[1]], imm: ICmpPred.eq)
      newv = em(head, .select, elementType, [same, inst.args[2], cur])
    }
    var newWord: ValueID
    if s.bits == 32 {
      newWord = s == .f32 ? em(head, .bitcast, i32, [newv]) : newv
    } else {
      let bits = s == .f16 ? em(head, .bitcast, intType, [newv]) : newv
      let wide = em(head, .zext, i32, [bits])
      let laneMask = constant(.i32, s.bits == 8 ? 0xFF : 0xFFFF)
      let mask = em(head, .shl, i32, [laneMask, shift])
      let keep = em(head, .and, i32, [old, em(head, .not, i32, [mask])])
      newWord = em(head, .or, i32, [keep, em(head, .shl, i32, [wide, shift])])
    }
    let seen = em(head, .atomic, i32, [wordPtr, old, newWord], imm: AtomicKind.cmpxchg)
    insts[definition(seen)!].imm2 = inst.imm2
    let ok = em(head, .icmp, bool, [seen, old], imm: ICmpPred.eq)
    let next = em(head, .iadd, i32, [rounds, constant(.i32, 1)])
    let spent = em(head, .icmp, bool, [next, constant(.i32, ExpandAtomicsLimits.casBound)], imm: ICmpPred.uge)
    let finished = em(head, .or, bool, [ok, spent])
    append(Inst(.condbr, .void, [finished], blocks: [j, head]), to: head)
    blocks[head].kind = .loop
    blocks[head].merge = j
    blocks[head].continueTarget = head
    if case .inst(let pid) = values[old].kind {
      insts[pid].args = [old0, seen]
      insts[pid].blocks = [b, head]
    }
    if case .inst(let rid) = values[rounds].kind {
      insts[rid].args = [constant(.i32, 0), next]
      insts[rid].blocks = [b, head]
    }
    blocks[j].insts += tail
    if needsAcquire(inst.imm2) { blocks[j].insts.insert(makeInst(Inst(.membar, .void, [], imm2: inst.imm2)), at: 0) }
    if inst.result >= 0 { replace(inst.result, with: cur) }
  }
}
