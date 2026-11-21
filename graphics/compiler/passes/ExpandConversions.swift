// SPDX-License-Identifier: BSD-3-Clause

// Conversions between 64-bit integers and binary32, for a GPU with no such instruction (valhall 11c.13.1.1; the sequences
// there are a method, and this follows it with operations every backend has).
//
// 64-bit integer to float, rounding to nearest even: the magnitude x, e the index of its highest set bit, d = max(e - 23, 0)
// the bits that do not fit, m = x >> d rounded up when the dropped bits are above half or at half with m odd, and the result
// float(m) * 2^d (exact, since m is at most 2^24). The index of the highest bit of a word is the exponent of its float with
// the low byte cleared (a word of at most 24 significant bits converts exactly).
//
// Float to 64-bit integer, truncating: t = trunc(v), the high word is trunc(|t| * 2^-32) and the low word |t| minus that
// times 2^32 (both exact), negated for a negative signed result. A negative float gives 0 as unsigned. Out-of-range
// values are undefined in Vulkan; they are clamped below 2^64 here so no backend sees a value its conversion cannot take.

extension IRModule {
  @discardableResult
  public mutating func expandLongConversions() -> Bool {
    var any = false
    for k in 0..<functions.count where functions[k].expandLongConversions() { any = true }
    return any
  }
}

extension Function {
  @discardableResult
  public mutating func expandLongConversions() -> Bool {
    var any = false
    search: while true {
      for b in 0..<blocks.count {
        for (k, id) in blocks[b].insts.enumerated() {
          let i = insts[id]
          switch i.op {
          case .sitofp, .uitofp:
            if i.type == .f32, values[i.args[0]].type == .i64 {
              expandToFloat(b, k)
              any = true
              continue search
            }
          case .fptosi, .fptoui:
            if i.type == .i64, values[i.args[0]].type == .f32 {
              expandFromFloat(b, k)
              any = true
              continue search
            }
          default: break
          }
        }
      }
      break
    }
    if any { eliminateDeadCode() }
    return any
  }

  /// The index of the highest set bit of a word, -1 for zero.
  private mutating func highestBit(_ b: BlockID, _ w: ValueID) -> ValueID {
    let i32 = IRType.i32, bool = IRType.bool
    let big = em(b, .icmp, bool, [w, constant(.i32, 256)], imm: ICmpPred.uge)
    let cleared = em(b, .select, i32, [big, em(b, .and, i32, [w, constant(.i32, 0xFFFF_FF00)]), w])
    let bits = em(b, .bitcast, i32, [em(b, .uitofp, .f32, [cleared])])
    let e = em(b, .isub, i32, [em(b, .lshr, i32, [bits, constant(.i32, 23)]), constant(.i32, 127)])
    let isZero = em(b, .icmp, bool, [w, constant(.i32, 0)], imm: ICmpPred.eq)
    return em(b, .select, i32, [isZero, constant(.i32, UInt64(UInt32.max)), e])
  }

  private mutating func expandToFloat(_ b: BlockID, _ k: Int) {
    let id = blocks[b].insts[k]
    let inst = insts[id]
    let signed = inst.op == .sitofp
    let i32 = IRType.i32, i64 = IRType.i64, f32 = IRType.f32, bool = IRType.bool
    let tail = Array(blocks[b].insts[(k + 1)...])
    blocks[b].insts = Array(blocks[b].insts[..<k])
    var x = inst.args[0]
    var negative = -1
    if signed {
      negative = em(b, .icmp, bool, [x, constant(.i64, 0)], imm: ICmpPred.slt)
      x = em(b, .select, i64, [negative, em(b, .ineg, i64, [x]), x])
    }
    let lo = em(b, .trunc, i32, [x])
    let hi = em(b, .trunc, i32, [em(b, .lshr, i64, [x, constant(.i64, 32)])])
    let eLo = highestBit(b, lo)
    let eHi = em(b, .iadd, i32, [highestBit(b, hi), constant(.i32, 32)])
    let e = em(b, .select, i32, [em(b, .icmp, bool, [hi, constant(.i32, 0)], imm: ICmpPred.ne), eHi, eLo])
    let d = em(b, .smax, i32, [em(b, .isub, i32, [e, constant(.i32, 23)]), constant(.i32, 0)])
    let d64 = em(b, .zext, i64, [d])
    let one = constant(.i64, 1)
    let m0 = em(b, .lshr, i64, [x, d64])
    let bit = em(b, .shl, i64, [one, d64])
    let rem = em(b, .and, i64, [x, em(b, .isub, i64, [bit, one])])
    let half = em(b, .lshr, i64, [bit, one])
    let above = em(b, .icmp, bool, [rem, half], imm: ICmpPred.ugt)
    let atHalf = em(b, .icmp, bool, [rem, half], imm: ICmpPred.eq)
    let shifted = em(b, .icmp, bool, [d, constant(.i32, 0)], imm: ICmpPred.ne)
    let odd = em(b, .icmp, bool, [em(b, .and, i64, [m0, one]), constant(.i64, 0)], imm: ICmpPred.ne)
    let tie = em(b, .and, bool, [em(b, .and, bool, [atHalf, shifted]), odd])
    let up = em(b, .or, bool, [above, tie])
    let m = em(b, .select, i64, [up, em(b, .iadd, i64, [m0, one]), m0])
    // 2^d as a float: the exponent field d + 127 (d is at most 41).
    let field = em(b, .shl, i32, [em(b, .iadd, i32, [d, constant(.i32, 127)]), constant(.i32, 23)])
    let scale = em(b, .bitcast, f32, [field])
    var r = em(b, .fmul, f32, [em(b, .uitofp, f32, [em(b, .trunc, i32, [m])]), scale])
    if signed { r = em(b, .select, f32, [negative, em(b, .fneg, f32, [r]), r]) }
    blocks[b].insts += tail
    replace(inst.result, with: r)
  }

  private mutating func expandFromFloat(_ b: BlockID, _ k: Int) {
    let id = blocks[b].insts[k]
    let inst = insts[id]
    let signed = inst.op == .fptosi
    let i32 = IRType.i32, i64 = IRType.i64, f32 = IRType.f32, bool = IRType.bool
    let tail = Array(blocks[b].insts[(k + 1)...])
    blocks[b].insts = Array(blocks[b].insts[..<k])
    let zero = constant(.f32, 0)
    let t = em(b, .ftrunc, f32, [inst.args[0]])
    let negative = em(b, .fcmp, bool, [t, zero], imm: FCmpPred.olt)
    // The magnitude (0 for a negative float and an unsigned result), below 2^64.
    let magnitude = signed ? em(b, .fabs, f32, [t]) : em(b, .fmax, f32, [t, zero])
    let top = constant(.f32, UInt64(Float(18_446_742_974_197_923_840).bitPattern))
    let ta = em(b, .fmin, f32, [magnitude, top])
    let inverse = constant(.f32, UInt64(Float(2.3283064365386963e-10).bitPattern))
    let hif = em(b, .ftrunc, f32, [em(b, .fmul, f32, [ta, inverse])])
    let lof = em(b, .fma, f32, [hif, constant(.f32, UInt64((-Float(4_294_967_296)).bitPattern)), ta])
    let hi = em(b, .fptoui, i32, [hif])
    let lo = em(b, .fptoui, i32, [lof])
    let high = em(b, .shl, i64, [em(b, .zext, i64, [hi]), constant(.i64, 32)])
    var r = em(b, .or, i64, [high, em(b, .zext, i64, [lo])])
    if signed { r = em(b, .select, i64, [negative, em(b, .ineg, i64, [r]), r]) }
    blocks[b].insts += tail
    replace(inst.result, with: r)
  }
}
