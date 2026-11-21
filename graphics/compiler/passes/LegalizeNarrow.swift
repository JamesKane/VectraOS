// SPDX-License-Identifier: BSD-3-Clause

// 8 and 16-bit integers for a GPU whose integer registers are 32 bits and whose integer ALU is 32 bits wide (valhall 11b: the
// 32-bit forms; the byte and half conversions of 11c.3 widen a lane in one instruction).
//
// Every i8 and i16 value becomes an i32 whose upper bits are not defined: an operation that wraps (add, subtract, multiply,
// negate, the bitwise ones, shift left, select, phi) needs no fix, and one that looks at the value's upper bits first widens
// the operand by the type's own signedness: a `trunc` to the narrow type and a `sext` or `zext` back, which the backend selects
// as one conversion (S8_TO_S32, U16_TO_U32, ...). Those are the comparisons, min and max, division and remainder, right shifts,
// the conversions to wider integers and to float. Only memory keeps the narrow type: a load gives the narrow value (the
// backend's LOAD of 8 or 16 bits, zero extended into the register) that a `zext` widens, and a store takes a `trunc`.
//
// The pass runs on scalarised IR, before the division expansion (which then sees only 32-bit operands: INT_MIN / -1 in 16
// bits is 32768, whose low 16 bits are the right answer).

extension IRModule {
  /// Whether any function had narrow integers to legalise.
  @discardableResult
  public mutating func legalizeNarrowIntegers() -> Bool {
    var any = false
    for k in 0..<functions.count where functions[k].legalizeNarrowIntegers() { any = true }
    return any
  }
}

extension Function {
  private func isNarrowInt(_ t: IRType) -> Bool {
    if case .scalar(let s) = t { return s == .i8 || s == .i16 }
    return false
  }

  /// The IR is scalarised, so a narrow vector cannot occur; the pass leaves such a function alone.
  @discardableResult
  public mutating func legalizeNarrowIntegers() -> Bool {
    var any = false
    for v in values where isNarrowInt(v.type) { any = true }
    for i in insts where isNarrowInt(i.type) { any = true }
    guard any else { return false }
    let orig = values.map { $0.type }
    func narrow(_ v: ValueID) -> Scalar? {
      if v >= 0, v < orig.count, case .scalar(let s) = orig[v], s == .i8 || s == .i16 { return s }
      return nil
    }
    for v in 0..<values.count where narrow(v) != nil { values[v].type = .i32 }
    for n in 0..<insts.count where isNarrowInt(insts[n].type) { insts[n].type = .i32 }
    var repl = [ValueID](repeating: -1, count: values.count)

    for b in 0..<blocks.count {
      var out: [Int] = []
      /// Emit an instruction into the rebuilt block; returns its result.
      func emit(_ f: inout Function, _ op: IROp, _ t: IRType, _ args: [ValueID], imm: Int = 0) -> ValueID {
        let id = f.makeInst(Inst(op, t, args, imm: imm))
        out.append(id)
        return f.insts[id].result
      }
      /// The value `v` widened to a defined 32-bit integer by its own type's signedness.
      func widen(_ f: inout Function, _ v: ValueID, signed: Bool) -> ValueID {
        guard let s = narrow(v) else { return v }
        if case .constant(let bits) = f.values[v].kind {
          let m: UInt64 = s == .i8 ? 0xFF : 0xFFFF
          var x = bits & m
          if signed && x & (m == 0xFF ? 0x80 : 0x8000) != 0 { x |= ~m }
          return f.constant(.i32, x & 0xFFFF_FFFF)
        }
        let t = emit(&f, .trunc, .scalar(s), [v])
        return emit(&f, signed ? .sext : .zext, .i32, [t])
      }
      for id in blocks[b].insts {
        let i = insts[id]
        switch i.op {
        case .load:
          if let s = narrowType(orig, i.result) {
            // The load keeps its narrow type; a `zext` gives the old result.
            let nv = values.count
            values.append(Value(type: .scalar(s), kind: .inst(id)))
            insts[id].type = .scalar(s)
            insts[id].result = nv
            out.append(id)
            let w = emit(&self, .zext, .i32, [nv])
            repl[i.result] = w
          } else {
            out.append(id)
          }
        case .store:
          if let s = narrow(i.args[1]) {
            let t = emit(&self, .trunc, .scalar(s), [i.args[1]])
            insts[id].args[1] = t
          }
          out.append(id)
        case .icmp:
          let signed = [ICmpPred.slt, ICmpPred.sle, ICmpPred.sgt, ICmpPred.sge].contains(i.imm)
          if narrow(i.args[0]) != nil {
            let w0 = widen(&self, i.args[0], signed: signed)
            let w1 = widen(&self, i.args[1], signed: signed)
            insts[id].args[0] = w0
            insts[id].args[1] = w1
          }
          out.append(id)
        case .smin, .smax, .umin, .umax, .sdiv, .srem, .udiv, .urem:
          let signed = i.op == .smin || i.op == .smax || i.op == .sdiv || i.op == .srem
          if narrow(i.args[0]) != nil {
            let w0 = widen(&self, i.args[0], signed: signed)
            let w1 = widen(&self, i.args[1], signed: signed)
            insts[id].args[0] = w0
            insts[id].args[1] = w1
          }
          out.append(id)
        case .lshr, .ashr:
          if narrow(i.args[0]) != nil {
            let w0 = widen(&self, i.args[0], signed: i.op == .ashr)
            insts[id].args[0] = w0
          }
          out.append(id)
        case .sitofp, .uitofp:
          if narrow(i.args[0]) != nil {
            let w0 = widen(&self, i.args[0], signed: i.op == .sitofp)
            insts[id].args[0] = w0
          }
          out.append(id)
        case .sext, .zext:
          if let s = narrow(i.args[0]) {
            let signed = i.op == .sext
            let t = emit(&self, .trunc, .scalar(s), [i.args[0]])
            let w = emit(&self, i.op, .i32, [t])
            if orig[i.result] == .i64 {
              repl[i.result] = emit(&self, i.op, .i64, [w])
            } else {
              repl[i.result] = w
            }
            _ = signed
          } else {
            out.append(id)
          }
        case .trunc:
          if narrow(i.result) != nil {
            // To a narrow type: the low bits are all that matter.
            if orig[i.args[0]] == .i64 {
              repl[i.result] = emit(&self, .trunc, .i32, [i.args[0]])
            } else {
              repl[i.result] = i.args[0]
            }
          } else {
            out.append(id)
          }
        case .bitcast:
          let fromN = narrow(i.args[0])
          let toN = narrow(i.result)
          if let s = fromN, toN == nil {
            let t = emit(&self, .trunc, .scalar(s), [i.args[0]])
            repl[i.result] = emit(&self, .bitcast, i.type, [t])
          } else if fromN == nil, let s = toN {
            let t = emit(&self, .bitcast, .scalar(s), [i.args[0]])
            repl[i.result] = emit(&self, .zext, .i32, [t])
          } else if fromN != nil, toN != nil {
            repl[i.result] = i.args[0]
          } else {
            out.append(id)
          }
        default:
          out.append(id)
        }
      }
      blocks[b].insts = out
    }
    while repl.count < values.count { repl.append(-1) }
    apply(repl.enumerated().map { $1 < 0 ? $0 : $1 })
    eliminateDeadCode()
    return true
  }

  /// The narrow type of a load's original result, when the load read an i8 or i16.
  private func narrowType(_ orig: [IRType], _ v: ValueID) -> Scalar? {
    if v >= 0, v < orig.count, case .scalar(let s) = orig[v], s == .i8 || s == .i16 { return s }
    return nil
  }
}

// float16 operations that have no half-precision instruction in the sequences the backend uses (division, square root, the
// special functions, rounding to an integer) are computed in binary32 on the widened operands and rounded to binary16: the
// binary32 results are far inside binary16's precision, so the rounding is the only error that remains.

extension IRModule {
  @discardableResult
  public mutating func promoteHalfMath() -> Bool {
    var any = false
    for k in 0..<functions.count where functions[k].promoteHalfMath() { any = true }
    return any
  }
}

extension Function {
  @discardableResult
  public mutating func promoteHalfMath() -> Bool {
    var any = false
    var repl = [ValueID](repeating: -1, count: values.count)
    for b in 0..<blocks.count {
      var out: [Int] = []
      for id in blocks[b].insts {
        let i = insts[id]
        switch i.op {
        case .fdiv, .fsqrt, .frsq, .fexp2, .flog2, .fsin, .fcos, .ffloor, .fceil, .ftrunc, .fround:
          guard i.type == .scalar(.f16) else {
            out.append(id)
            continue
          }
          any = true
          var args: [ValueID] = []
          for a in i.args {
            let n = makeInst(Inst(.fpext, .f32, [a]))
            out.append(n)
            args.append(insts[n].result)
          }
          let r = makeInst(Inst(i.op, .f32, args))
          out.append(r)
          let t = makeInst(Inst(.fptrunc, .scalar(.f16), [insts[r].result]))
          out.append(t)
          repl[i.result] = insts[t].result
        default:
          out.append(id)
        }
      }
      blocks[b].insts = out
    }
    if any {
      while repl.count < values.count { repl.append(-1) }
      apply(repl.enumerated().map { $1 < 0 ? $0 : $1 })
    }
    return any
  }
}
