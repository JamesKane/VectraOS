// SPDX-License-Identifier: BSD-3-Clause

// Cheaper forms of 32-bit float arithmetic and of addresses, an instruction at a time:
//   - `x / c` for a constant power of two c is `x * (1 / c)`, which is exact;
//   - `x / y` otherwise is `x * (1 / y)`, so that the reciprocals of one y (a perspective divide's w) are one value
//     common-subexpression elimination keeps;
//   - `fma(a, 1, c)` is `a + c`;
//   - `inttoptr(x + c)` is `inttoptr(x) + c` as a pointer, so a load takes c in its offset field (the vertex inputs'
//     components, vulkanlowering(2)).

extension Function {
  /// Rewrite what has a cheaper form. Returns whether anything changed.
  @discardableResult
  public mutating func reduceStrength() -> Bool {
    let one = UInt64(Float(1).bitPattern)
    var changed = false
    for b in 0..<blocks.count {
      var k = 0
      while k < blocks[b].insts.count {
        let id = blocks[b].insts[k]
        let i = insts[id]
        k += 1
        switch i.op {
        case .fdiv where i.type == .f32:
          if let c = constantBits(i.args[1]) {
            let d = Float(bitPattern: UInt32(truncatingIfNeeded: c))
            let r = 1 / d
            // Exact only for a power of two; the backend multiplies by any other constant's reciprocal itself.
            guard d.isFinite, d != 0, d.significandBitPattern == 0, r.isNormal else { continue }
            insts[id] = Inst(.fmul, .f32, [i.args[0], constant(.f32, UInt64(r.bitPattern))])
            insts[id].result = i.result
            changed = true
          } else if constantBits(i.args[0]) != one {
            let rcp = insert(Inst(.fdiv, .f32, [constant(.f32, one), i.args[1]]), in: b, at: k - 1)
            k += 1
            insts[id] = Inst(.fmul, .f32, [i.args[0], rcp])
            insts[id].result = i.result
            changed = true
          }
        case .fma where i.type == .f32:
          var other = -1
          if constantBits(i.args[1]) == one { other = i.args[0] } else if constantBits(i.args[0]) == one { other = i.args[1] }
          guard other >= 0 else { continue }
          insts[id] = Inst(.fadd, .f32, [other, i.args[2]])
          insts[id].result = i.result
          changed = true
        case .inttoptr:
          guard case .inst(let d) = values[i.args[0]].kind, insts[d].op == .iadd, values[insts[d].args[0]].type == .scalar(.i64),
            let c = constantBits(insts[d].args[1]), Int64(bitPattern: c) >= -32768, Int64(bitPattern: c) <= 32767 else { continue }
          let base = insert(Inst(.inttoptr, i.type, [insts[d].args[0]]), in: b, at: k - 1)
          k += 1
          insts[id] = Inst(.ptradd, i.type, [base, insts[d].args[1]])
          insts[id].result = i.result
          changed = true
        default: break
        }
      }
    }
    if changed { eliminateDeadCode() }
    return changed
  }
}
