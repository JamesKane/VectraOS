// SPDX-License-Identifier: BSD-3-Clause

// Integer division and remainder for a GPU with no divide instruction (Valhall's has none: valhall 11b.1 lists
// "divide and remainder" among the instructions that do not exist). The pass rewrites `udiv`, `sdiv`, `urem` and
// `srem` of 32 and 64 bits into operations every backend has; what is left is the IR's other operations.
//
// The result is defined where SPIR-V leaves it undefined, so a shader never hangs or faults on it:
//
//   a divisor of zero gives what the reference sequences give (valhall 11b.8.1.6): the remainder is N, the quotient is
//   2 for N = 0 and N + 1 (N - 1 for a negative signed N) at 32 bits and all ones at 64 bits (1 for a negative signed
//   N); a constant zero divisor gives 0 (11b.8.1.5);
//   INT_MIN / -1 is INT_MIN (the wrapped result) and INT_MIN % -1 is 0.
//
// A constant divisor of 32 bits is the multiply-high method (11b.8.1.5). The float estimate below keeps its own margin: the
// reciprocal is taken 2^-20 low, so the first quotient is below the true one whether FRCP errs low or high by an ulp
// (the reference's fixed-point sequence is exact only for a low FRCP).
//
// 32 bits, branch free (the unsigned core; signed values go through their magnitudes):
//
//   t  = (1 / float(d)) * (1 - 2^-20)            a reciprocal a little low
//   q0 = trunc(float(a) * t)                      at most the true quotient, and at most about 6000 below it
//   r0 = a - q0 * d                               exact: 0 <= r0 < 2^32
//   e  = trunc(float(r0) * t)                     the missing part, at most one below r0 / d
//   q  = q0 + e,  r = r0 - e * d                  0 <= r < 2 * d
//   two steps of: if r >= d { q += 1, r -= d }    one is enough; the second is margin for a reciprocal that is a
//                                                 unit in the last place worse than the spec's bound
//
// The float estimates have relative error below 6 * 2^-24 (conversion of a, of d, the reciprocal, two products), the
// margin is 2^-20, so the estimate never exceeds the quotient and the first step leaves r0 / d below 6000, where the
// second step's margin (2^-20 of 6000) is far below 1.
//
// 64 bits: when both operands are below 2^32, the 32-bit sequence; otherwise 64 steps of restoring division, a loop of
// uniform trip count (the shifted remainder's top bit is tested before the shift drops it).

extension IRModule {
  /// Rewrite the integer divisions of every function. Vectors and widths other than 32 and 64 stay as they are.
  @discardableResult
  public mutating func expandIntegerDivision() -> Bool {
    var any = false
    for k in 0..<functions.count where functions[k].expandIntegerDivision() { any = true }
    return any
  }
}

extension Function {
  @discardableResult
  public mutating func expandIntegerDivision() -> Bool {
    var any = false
    while let (b, k) = firstDivision() {
      expandDivision(b, k)
      any = true
    }
    if any { eliminateDeadCode() }
    return any
  }

  private func firstDivision() -> (Int, Int)? {
    for b in 0..<blocks.count {
      for (k, id) in blocks[b].insts.enumerated() {
        let i = insts[id]
        switch i.op {
        case .udiv, .sdiv, .urem, .srem:
          if case .scalar(let s) = i.type, s == .i32 || s == .i64 { return (b, k) }
        default: break
        }
      }
    }
    return nil
  }

  mutating func em(_ b: BlockID, _ op: IROp, _ t: IRType, _ args: [ValueID], imm: Int = 0) -> ValueID {
    append(Inst(op, t, args, imm: imm), to: b)
  }

  /// The unsigned quotient and remainder of 32-bit `a` by `d`, with `d` not zero.
  private mutating func unsignedDivRem32(_ b: BlockID, _ a: ValueID, _ d: ValueID) -> (q: ValueID, r: ValueID) {
    let i32 = IRType.i32, f32 = IRType.f32, bool = IRType.bool
    if let c = constantBits(d) { return unsignedDivRemConstant32(b, a, d, UInt32(truncatingIfNeeded: c)) }
    let one = constant(.f32, UInt64(Float(1).bitPattern))
    let low = constant(.f32, UInt64((Float(1) - Float(1) / Float(1 << 20)).bitPattern))
    let fd = em(b, .uitofp, f32, [d])
    let rcp = em(b, .fdiv, f32, [one, fd])
    let t = em(b, .fmul, f32, [rcp, low])
    let fa = em(b, .uitofp, f32, [a])
    let q0f = em(b, .fmul, f32, [fa, t])
    let q0 = em(b, .fptoui, i32, [q0f])
    let m0 = em(b, .imul, i32, [q0, d])
    let r0 = em(b, .isub, i32, [a, m0])
    let fr = em(b, .uitofp, f32, [r0])
    let ef = em(b, .fmul, f32, [fr, t])
    let e = em(b, .fptoui, i32, [ef])
    let m1 = em(b, .imul, i32, [e, d])
    var r = em(b, .isub, i32, [r0, m1])
    var q = em(b, .iadd, i32, [q0, e])
    let one32 = constant(.i32, 1)
    for _ in 0..<2 {
      let c = em(b, .icmp, bool, [r, d], imm: ICmpPred.uge)
      let q1 = em(b, .iadd, i32, [q, one32])
      let r1 = em(b, .isub, i32, [r, d])
      q = em(b, .select, i32, [c, q1, q])
      r = em(b, .select, i32, [c, r1, r])
    }
    return (q, r)
  }

  /// The unsigned quotient and remainder of 32-bit `a` by the constant `c`, not zero or a power of two (valhall 11b.8.1.5):
  /// a divisor from 2^31 up gives 1 when `a >= c`; any other is the multiply-high method of Granlund and Montgomery
  /// (1994, figure 4.1): m = floor(2^32 (2^l - c) / c) + 1 with l = ceil(log2 c), t = umulhi(m, a),
  /// q = (t + ((a - t) >> 1)) >> (l - 1), exact for every a. The remainder is a - q * c.
  private mutating func unsignedDivRemConstant32(_ b: BlockID, _ a: ValueID, _ d: ValueID, _ c: UInt32) -> (q: ValueID, r: ValueID) {
    let i32 = IRType.i32, bool = IRType.bool
    var q: ValueID
    if c & (c - 1) == 0 {
      q = em(b, .lshr, i32, [a, constant(.i32, UInt64(c.trailingZeroBitCount))])
    } else if c >= 0x8000_0000 {
      let ge = em(b, .icmp, bool, [a, d], imm: ICmpPred.uge)
      q = em(b, .select, i32, [ge, constant(.i32, 1), constant(.i32, 0)])
    } else {
      let l = 32 - (c - 1).leadingZeroBitCount
      let m = (UInt64(1) << 32) * ((UInt64(1) << UInt64(l)) - UInt64(c)) / UInt64(c) + 1
      let wide = em(b, .zext, .i64, [a])
      let product = em(b, .imul, .i64, [wide, constant(.i64, m)])
      let t = em(b, .trunc, i32, [em(b, .lshr, .i64, [product, constant(.i64, 32)])])
      let half = em(b, .lshr, i32, [em(b, .isub, i32, [a, t]), constant(.i32, 1)])
      q = em(b, .lshr, i32, [em(b, .iadd, i32, [t, half]), constant(.i32, UInt64(l - 1))])
    }
    let r = em(b, .isub, i32, [a, em(b, .imul, i32, [q, d])])
    return (q, r)
  }

  private mutating func expandDivision(_ b: BlockID, _ k: Int) {
    let id = blocks[b].insts[k]
    let inst = insts[id]
    guard case .scalar(let s) = inst.type else { return }
    let ty = inst.type
    let bool = IRType.bool
    let signed = inst.op == .sdiv || inst.op == .srem
    let wantQuotient = inst.op == .udiv || inst.op == .sdiv
    let a = inst.args[0]
    let d = inst.args[1]
    let zero = constant(s, 0)
    let tail = Array(blocks[b].insts[(k + 1)...])
    blocks[b].insts = Array(blocks[b].insts[..<k])

    // A constant zero divisor folds to 0 for every form (valhall 11b.8.1.5).
    if let c = constantBits(d), c == 0 {
      blocks[b].insts += tail
      replace(inst.result, with: zero)
      return
    }

    // An unsigned division by a power of two (a constant one) is a shift or a mask.
    if !signed, let c = constantBits(d), c != 0, c & (c - 1) == 0 {
      let r: ValueID
      if wantQuotient {
        r = em(b, .lshr, ty, [a, constant(s, UInt64(c.trailingZeroBitCount))])
      } else {
        r = em(b, .and, ty, [a, constant(s, c - 1)])
      }
      blocks[b].insts += tail
      replace(inst.result, with: r)
      return
    }

    // The divisor is known not to be zero when it is a nonzero constant.
    let known = (constantBits(d) ?? 0) != 0
    let bz = known ? -1 : em(b, .icmp, bool, [d, zero], imm: ICmpPred.eq)
    var sa = -1
    var sb = -1
    var ua = a
    var ub = d
    if signed {
      sa = em(b, .icmp, bool, [a, zero], imm: ICmpPred.slt)
      ua = em(b, .select, ty, [sa, em(b, .ineg, ty, [a]), a])
      if let c = constantBits(d) {
        // The divisor's sign and magnitude are known.
        let negative = c >> UInt64(s.bits - 1) & 1 == 1
        // (A bool constant is 1, and a backend's bool is all ones: the compare makes the real one.)
        sb = em(b, .icmp, bool, [constant(s, negative ? 1 : 0), constant(s, 0)], imm: ICmpPred.ne)
        ub = constant(s, negative ? 0 &- c : c)
      } else {
        sb = em(b, .icmp, bool, [d, zero], imm: ICmpPred.slt)
        ub = em(b, .select, ty, [sb, em(b, .ineg, ty, [d]), d])
      }
    }
    let oneS = constant(s, 1)
    let divisor = known ? ub : em(b, .select, ty, [bz, oneS, ub])

    var join = b
    var quotient: ValueID
    var remainder: ValueID
    if s == .i32 {
      (quotient, remainder) = unsignedDivRem32(b, ua, divisor)
    } else {
      // pre (this block), sm (both below 2^32), head (the loop), done, join (the rest of the block).
      let sm = addBlock(), head = addBlock(), done = addBlock(), j = addBlock()
      join = j
      blocks[j].kind = blocks[b].kind
      blocks[j].merge = blocks[b].merge
      blocks[j].continueTarget = blocks[b].continueTarget
      blocks[b].kind = .selection
      blocks[b].merge = j
      blocks[b].continueTarget = -1
      for succ in insts[tail[tail.count - 1]].blocks {
        for pid in blocks[succ].insts where insts[pid].op == .phi {
          for n in 0..<insts[pid].blocks.count where insts[pid].blocks[n] == b { insts[pid].blocks[n] = j }
        }
      }
      let both = em(b, .or, ty, [ua, divisor])
      let small = em(b, .icmp, bool, [both, constant(.i64, 1 << 32)], imm: ICmpPred.ult)
      em0(b, Inst(.condbr, .void, [small], blocks: [sm, head]))

      // sm
      let a32 = em(sm, .trunc, .i32, [ua])
      let d32 = em(sm, .trunc, .i32, [divisor])
      let (q32, r32) = unsignedDivRem32(sm, a32, d32)
      let qz = em(sm, .zext, ty, [q32])
      let rz = em(sm, .zext, ty, [r32])
      em0(sm, Inst(.br, .void, [], blocks: [j]))

      // head: shift the next bit of the dividend into the remainder, subtract the divisor when it fits.
      let zero32 = constant(.i32, 0)
      let i = em(head, .phi, .i32, [zero32, zero32])
      let r = em(head, .phi, ty, [zero, zero])
      let n = em(head, .phi, ty, [ua, ua])
      let q = em(head, .phi, ty, [zero, zero])
      let top = em(head, .icmp, bool, [r, zero], imm: ICmpPred.slt)
      let bit = em(head, .lshr, ty, [n, constant(.i64, 63)])
      let rs = em(head, .shl, ty, [r, oneS])
      let r1 = em(head, .or, ty, [rs, bit])
      let n1 = em(head, .shl, ty, [n, oneS])
      let fits = em(head, .icmp, bool, [r1, divisor], imm: ICmpPred.uge)
      let ge = em(head, .or, bool, [top, fits])
      let rsub = em(head, .isub, ty, [r1, divisor])
      let r2 = em(head, .select, ty, [ge, rsub, r1])
      let qs = em(head, .shl, ty, [q, oneS])
      let qb = em(head, .select, ty, [ge, oneS, zero])
      let q1 = em(head, .or, ty, [qs, qb])
      let i1 = em(head, .iadd, .i32, [i, constant(.i32, 1)])
      let go = em(head, .icmp, bool, [i1, constant(.i32, 64)], imm: ICmpPred.ult)
      em0(head, Inst(.condbr, .void, [go], blocks: [head, done]))
      blocks[head].kind = .loop
      blocks[head].merge = done
      blocks[head].continueTarget = head
      func patch(_ phi: ValueID, _ pre: ValueID, _ back: ValueID, _ f: inout Function) {
        guard case .inst(let pid) = f.values[phi].kind else { return }
        f.insts[pid].args = [pre, back]
        f.insts[pid].blocks = [b, head]
      }
      patch(i, zero32, i1, &self)
      patch(r, zero, r2, &self)
      patch(n, ua, n1, &self)
      patch(q, zero, q1, &self)
      em0(done, Inst(.br, .void, [], blocks: [j]))

      // join
      quotient = em(j, .phi, ty, [qz, q1])
      remainder = em(j, .phi, ty, [rz, r2])
      setPhiBlocks(quotient, [sm, done])
      setPhiBlocks(remainder, [sm, done])
    }

    // The result, with the signs put back and a zero divisor giving zero.
    var result: ValueID
    if wantQuotient {
      result = quotient
      if signed {
        let negate = em(join, .xor, bool, [sa, sb])
        result = em(join, .select, ty, [negate, em(join, .ineg, ty, [quotient]), quotient])
      }
    } else {
      result = remainder
      if signed { result = em(join, .select, ty, [sa, em(join, .ineg, ty, [remainder]), remainder]) }
    }
    if !known {
      // A zero divisor gives what the reference sequences give (valhall 11b.8.1.6): the remainder is N; the quotient is
      // 2 for N = 0 and N + 1 (N - 1 for a negative signed N) at 32 bits, all ones at 64 bits (1 for a negative signed N).
      var zres = a
      if wantQuotient {
        if s == .i32 {
          let plus = em(join, .iadd, ty, [a, constant(s, 1)])
          var step = plus
          if signed {
            let minus = em(join, .isub, ty, [a, constant(s, 1)])
            step = em(join, .select, ty, [sa, minus, plus])
          }
          let isZero = em(join, .icmp, bool, [a, zero], imm: ICmpPred.eq)
          zres = em(join, .select, ty, [isZero, constant(s, 2), step])
        } else {
          let ones = constant(s, ~0)
          zres = signed ? em(join, .select, ty, [sa, constant(s, 1), ones]) : ones
        }
      }
      result = em(join, .select, ty, [bz, zres, result])
    }
    blocks[join].insts += tail
    replace(inst.result, with: result)
  }

  private mutating func em0(_ b: BlockID, _ inst: Inst) { append(inst, to: b) }

  private mutating func setPhiBlocks(_ v: ValueID, _ bl: [BlockID]) {
    guard case .inst(let id) = values[v].kind else { return }
    insts[id].blocks = bl
  }

  mutating func replace(_ old: ValueID, with new: ValueID) {
    var table = [ValueID](repeating: -1, count: values.count)
    table[old] = new
    apply(table)
  }
}
