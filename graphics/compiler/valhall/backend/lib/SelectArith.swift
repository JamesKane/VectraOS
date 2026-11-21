// SPDX-License-Identifier: BSD-3-Clause

// Selection of the arithmetic: integers (11b), floats (11a), conversions and
// the special-function sequences of 11c.13.

#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif
#if canImport(ValhallISA)
  import ValhallISA
#endif

extension Selector {
  // MARK: shared pieces

  mutating func def32(_ i: Inst) -> Opd {
    let r = newReg()
    loc[i.result] = .reg(r)
    return .reg(r, 0)
  }

  mutating func def64(_ i: Inst) -> Opd {
    let r = newReg(2)
    loc[i.result] = .reg(r)
    return .reg(r, 0)
  }

  /// A mask of all ones, from a bool in a register: the complement.
  mutating func complementMask(_ d: Opd, _ a: Opd) {
    alu("LSHIFT_XOR", "i32", dst: d, a, .const(0), .const(1), named: [("wd1", "b0")])
  }

  /// `D = A op B` of the shift family (and, or, xor), 32-bit.
  mutating func logic32(_ mn: String, _ d: Opd, _ a: Opd, _ b: Opd) {
    alu(mn, "i32", dst: d, a, .const(0), b, named: [("wd1", "b0")])
  }

  /// A source that is an immediate the 32-bit R1I forms take, when the value is a constant not in the table.
  func immOf(_ v: ValueID) -> UInt32? {
    if case .const(let bits) = loc[v] {
      let b = UInt32(truncatingIfNeeded: bits)
      if smallConstant(b) == nil { return b }
    }
    return nil
  }

  func isConst(_ v: ValueID) -> Bool {
    if case .const = loc[v] { return true }
    return false
  }

  // MARK: integers

  mutating func selectInteger(_ i: Inst) throws(BackendError) {
    let t = i.type
    guard case .scalar(let s) = t else { throw BackendError.unsupported("integer operation on " + t.name) }
    if s == .i64 { try selectInteger64(i); return }
    guard s == .i32 || s == .bool else { throw BackendError.unsupported("integer operation on " + t.name) }
    var a = i.args.count > 0 ? i.args[0] : -1
    var b = i.args.count > 1 ? i.args[1] : -1
    switch i.op {
    case .iadd, .and, .or, .xor:
      if b >= 0 && isConst(a) && !isConst(b) { swap(&a, &b) }
    default: break
    }
    switch i.op {
    case .iadd:
      if let imm = immOf(b) {
        let x = opd(a)
        alu("IADD_IMM", "i32", dst: def32(i), x, set: [("imm", Int(imm))])
      } else {
        let x = opd(a)
        let y = opd(b)
        alu("IADD", "u32", dst: def32(i), x, y)
      }
    case .isub:
      if let imm = immOf(b) {
        let x = opd(a)
        alu("IADD_IMM", "i32", dst: def32(i), x, set: [("imm", Int(0 &- imm))])
      } else {
        let x = opd(a)
        let y = opd(b)
        alu("ISUB", "u32", dst: def32(i), x, y)
      }
    case .imul:
      let x = opd(a)
      let y = opd(b)
      alu("IMUL", "u32", dst: def32(i), x, y)
    case .ineg:
      let x = opd(a)
      alu("ISUB", "u32", dst: def32(i), .const(0), x)
    case .and, .or, .xor:
      let name = i.op == .and ? "AND" : i.op == .or ? "OR" : "XOR"
      if let imm = immOf(b), s == .i32 {
        let x = opd(a)
        alu(name + "_IMM", "i32", dst: def32(i), x, set: [("imm", Int(imm))])
      } else {
        let x = opd(a)
        let y = opd(b)
        logic32("LSHIFT_" + name, def32(i), x, y)
      }
    case .not:
      let x = opd(a)
      complementMask(def32(i), x)
    case .shl, .lshr, .ashr:
      let mn = i.op == .shl ? "LSHIFT_OR" : i.op == .lshr ? "RSHIFT_OR" : "ARSHIFT_OR"
      let x = opd(a)
      if case .const(let n) = loc[b], let (amt, lane) = shiftAmount(Int(n & 31)) {
        alu(mn, "i32", dst: def32(i), x, amt, .const(0), set: [("wd1", lane)])
      } else {
        let y = opd(b)
        alu(mn, "i32", dst: def32(i), x, y, .const(0), named: [("wd1", "b0")])
      }
    case .smin, .smax, .umin, .umax:
      let x = opd(a)
      let y = opd(b)
      let signed = i.op == .smin || i.op == .smax
      let lt = i.op == .smin || i.op == .umin
      alu("CSEL", signed ? "s32" : "u32", dst: def32(i), x, y, x, y, named: [("cmp", lt ? "lt" : "gt")])
    case .udiv, .sdiv, .urem, .srem:
      throw BackendError.unsupported("integer division")
    default: throw BackendError.unsupported("integer operation " + i.op.rawValue)
    }
  }

  mutating func selectInteger64(_ i: Inst) throws(BackendError) {
    let a = i.args.count > 0 ? i.args[0] : -1
    let b = i.args.count > 1 ? i.args[1] : -1
    switch i.op {
    case .iadd, .isub:
      let x = opd64(a)
      let y = opd64(b)
      alu(i.op == .iadd ? "IADD" : "ISUB", "u64", dst: def64(i), x, y)
    case .ineg:
      let y = opd64(a)
      alu("ISUB", "u64", dst: def64(i), .const(0), y)
    case .imul:
      let d = def64(i)
      guard case .reg(let dv, _) = d else { return }
      let (alo, ahi) = words64(a)
      let (blo, bhi) = words64(b)
      alu("IMUL", "u64", dst: d, alo64(a, alo), alo64(b, blo), named: [("wd1", "w0"), ("wd0", "w0")])
      let ahz = zeroHigh[a] || isZeroConst(ahi)
      let bhz = zeroHigh[b] || isZeroConst(bhi)
      if !bhz {
        let t = newReg()
        alu("IMUL", "u32", dst: .reg(t, 0), alo, bhi)
        alu("IADD", "u32", dst: .reg(dv, 1), .reg(dv, 1), .reg(t, 0))
      }
      if !ahz {
        let t = newReg()
        alu("IMUL", "u32", dst: .reg(t, 0), ahi, blo)
        alu("IADD", "u32", dst: .reg(dv, 1), .reg(dv, 1), .reg(t, 0))
      }
    case .and, .or, .xor:
      let name = i.op == .and ? "AND" : i.op == .or ? "OR" : "XOR"
      let x = opd64(a)
      let y = opd64(b)
      alu("LSHIFT_" + name, "i64", dst: def64(i), x, .const(0), y, named: [("wd1", "b0")])
    case .not:
      let x = opd64(a)
      alu("LSHIFT_XOR", "i64", dst: def64(i), x, .const(0), .const(1), named: [("wd1", "b0")])
    case .shl, .lshr, .ashr:
      let mn = i.op == .shl ? "LSHIFT_OR" : i.op == .lshr ? "RSHIFT_OR" : "ARSHIFT_OR"
      let x = opd64(a)
      if case .const(let n) = loc[b], let (amt, lane) = shiftAmount(Int(n & 63)) {
        alu(mn, "i64", dst: def64(i), x, amt, .const(0), set: [("wd1", lane)])
      } else {
        // The amount's low word, as the low word of a pair.
        let (lo, _) = words64(b)
        let r = newReg(2)
        alu("MOV", "i32", dst: .reg(r, 0), lo)
        alu(mn, "i64", dst: def64(i), x, .reg(r, 0), .const(0), named: [("wd1", "b0")])
      }
    default: throw BackendError.unsupported("64-bit integer operation " + i.op.rawValue)
    }
  }

  func isZeroConst(_ o: Opd) -> Bool { o == .const(0) }

  /// A 32-bit operand as the low word of a 64-bit source: its pair when it is one, else a register pair holding it.
  mutating func alo64(_ v: ValueID, _ lo: Opd) -> Opd {
    if case .reg(let r) = loc[v], mf.vregs[r].size == 2 { return .reg(r, 0) }
    if case .const(let bits) = loc[v], bits >> 32 == 0, let c = smallConstant(UInt32(bits)) { return .const(c) }
    let r = newReg(2)
    alu("MOV", "i32", dst: .reg(r, 0), lo)
    return .reg(r, 0)
  }

  // MARK: compares

  /// The compare an `icmp` or `fcmp` makes: the instruction's variant, the comparison, whether the result is the
  /// complement of the comparison.
  func compareOf(_ i: Inst) -> (float: Bool, variant: String, cmp: String, negate: Bool)? {
    if i.op == .icmp {
      switch i.imm {
      case ICmpPred.eq: return (false, "u32", "eq", false)
      case ICmpPred.ne: return (false, "u32", "ne", false)
      case ICmpPred.ult: return (false, "u32", "lt", false)
      case ICmpPred.ule: return (false, "u32", "le", false)
      case ICmpPred.ugt: return (false, "u32", "gt", false)
      case ICmpPred.uge: return (false, "u32", "ge", false)
      case ICmpPred.slt: return (false, "s32", "lt", false)
      case ICmpPred.sle: return (false, "s32", "le", false)
      case ICmpPred.sgt: return (false, "s32", "gt", false)
      case ICmpPred.sge: return (false, "s32", "ge", false)
      default: return nil
      }
    }
    switch i.imm {
    case FCmpPred.oeq: return (true, "f32", "eq", false)
    case FCmpPred.one: return (true, "f32", "gtlt", false)
    case FCmpPred.olt: return (true, "f32", "lt", false)
    case FCmpPred.ole: return (true, "f32", "le", false)
    case FCmpPred.ogt: return (true, "f32", "gt", false)
    case FCmpPred.oge: return (true, "f32", "ge", false)
    case FCmpPred.une: return (true, "f32", "ne", false)
    case FCmpPred.ueq: return (true, "f32", "gtlt", true)
    case FCmpPred.ult: return (true, "f32", "ge", true)
    case FCmpPred.ule: return (true, "f32", "gt", true)
    case FCmpPred.ugt: return (true, "f32", "le", true)
    case FCmpPred.uge: return (true, "f32", "lt", true)
    default: return nil
    }
  }

  mutating func selectCompare(_ i: Inst) throws(BackendError) {
    let a = i.args[0]
    let b = i.args[1]
    guard case .scalar(let s) = f.values[a].type else { throw BackendError.unsupported("a vector compare") }
    if s == .i64 { try compare64(i); return }
    guard s == .i32 || s == .f32 || s == .bool else { throw BackendError.unsupported("compare of " + s.name) }
    if fusedCmp[i.result] { return }
    if i.op == .fcmp && (i.imm == FCmpPred.ord || i.imm == FCmpPred.uno) {
      let x = opd(a)
      let y = opd(b)
      let t = newReg()
      alu("FCMP_OR", "f32", dst: .reg(t, 0), y, y, .const(0), named: [("cmp", "eq"), ("rtype", "m1")])
      if i.imm == FCmpPred.ord {
        alu("FCMP_AND", "f32", dst: def32(i), x, x, .reg(t, 0), named: [("cmp", "eq"), ("rtype", "m1")])
      } else {
        let o = newReg()
        alu("FCMP_AND", "f32", dst: .reg(o, 0), x, x, .reg(t, 0), named: [("cmp", "eq"), ("rtype", "m1")])
        complementMask(def32(i), .reg(o, 0))
      }
      return
    }
    guard let c = compareOf(i) else { throw BackendError.unsupported("compare predicate") }
    let x = opd(a)
    let y = opd(b)
    let d = def32(i)
    let mn = c.float ? "FCMP_OR" : "ICMP_OR"
    if c.negate {
      let t = newReg()
      alu(mn, c.variant, dst: .reg(t, 0), x, y, .const(0), named: [("cmp", c.cmp), ("rtype", "m1")])
      complementMask(d, .reg(t, 0))
    } else {
      alu(mn, c.variant, dst: d, x, y, .const(0), named: [("cmp", c.cmp), ("rtype", "m1")])
    }
  }

  /// 64-bit compare: the low words give an ordering, the high words refine it (11b.4.3).
  mutating func compare64(_ i: Inst) throws(BackendError) {
    guard let c = compareOf(i) else { throw BackendError.unsupported("compare predicate") }
    let (alo, ahi) = words64(i.args[0])
    let (blo, bhi) = words64(i.args[1])
    let t = newReg()
    alu("ICMP_MULTI", "u32", dst: .reg(t, 0), alo, blo, .const(0), named: [("cmp", c.cmp), ("rtype", "c")])
    alu("ICMP_MULTI", c.variant, dst: def32(i), ahi, bhi, .reg(t, 0), named: [("cmp", c.cmp), ("rtype", "m1")])
  }

  mutating func selectSelect(_ i: Inst) throws(BackendError) {
    guard case .scalar(let s) = i.type else { throw BackendError.unsupported("a vector select") }
    let c = i.args[0]
    // A single-use compare in this block selects in one instruction (CSEL, 11a.8).
    if s != .i64, fusedCmp[c], let ci = placedInst(c), let cmp = compareOf(ci) {
      let x = opd(ci.args[0])
      let y = opd(ci.args[1])
      let t = opd(cmp.negate ? i.args[2] : i.args[1])
      let e = opd(cmp.negate ? i.args[1] : i.args[2])
      alu("CSEL", cmp.variant, dst: def32(i), x, y, t, e, named: [("cmp", cmp.cmp)])
      return
    }
    let cond = opd(c)
    if s == .i64 {
      let (alo, ahi) = words64(i.args[1])
      let (blo, bhi) = words64(i.args[2])
      let d = def64(i)
      guard case .reg(let dv, _) = d else { return }
      alu("CSEL", "u32", dst: .reg(dv, 0), cond, .const(0), alo, blo, named: [("cmp", "ne")])
      alu("CSEL", "u32", dst: .reg(dv, 1), cond, .const(0), ahi, bhi, named: [("cmp", "ne")])
    } else {
      let x = opd(i.args[1])
      let y = opd(i.args[2])
      alu("CSEL", "u32", dst: def32(i), cond, .const(0), x, y, named: [("cmp", "ne")])
    }
  }

  // MARK: floats

  mutating func selectFloat(_ i: Inst) throws(BackendError) {
    guard i.type == .f32 else { throw BackendError.unsupported("float operation on " + i.type.name) }
    let a = i.args.count > 0 ? i.args[0] : -1
    let b = i.args.count > 1 ? i.args[1] : -1
    switch i.op {
    case .fadd, .fsub:
      let x = opd(a)
      let y = opd(b)
      alu("FADD", "f32", dst: def32(i), x, y, set: i.op == .fsub ? [("neg1", 1)] : [])
    case .fmul:
      let x = opd(a)
      let y = opd(b)
      alu("FMA", "f32", dst: def32(i), x, y, .const(0), set: [("neg2", 1)])
    case .fma:
      let x = opd(a)
      let y = opd(b)
      let z = opd(i.args[2])
      alu("FMA", "f32", dst: def32(i), x, y, z)
    case .fneg:
      let x = opd(a)
      alu("FADD", "f32", dst: def32(i), x, .const(0), set: [("neg0", 1), ("neg1", 1)])
    case .fabs:
      let x = opd(a)
      alu("FADD", "f32", dst: def32(i), x, .const(0), set: [("abs0", 1), ("neg1", 1)])
    case .fmin, .fmax:
      let x = opd(a)
      let y = opd(b)
      alu(i.op == .fmin ? "FMIN" : "FMAX", "f32", dst: def32(i), x, y)
    case .fdiv:
      let x = opd(a)
      let y = opd(b)
      let r = newReg()
      alu("FRCP", "f32", dst: .reg(r, 0), y)
      alu("FMA", "f32", dst: def32(i), x, .reg(r, 0), .const(0), set: [("neg2", 1)])
    case .ffloor, .fceil, .ftrunc, .fround:
      let x = opd(a)
      let mode = i.op == .ffloor ? "round_down" : i.op == .fceil ? "round_up" : i.op == .ftrunc ? "round_zero" : "none"
      alu("FROUND", "f32", dst: def32(i), x, named: [("round", mode)])
    case .frsq:
      let x = opd(a)
      alu("FRSQ", "f32", dst: def32(i), x)
    case .fsqrt:
      let x = opd(a)
      let r = newReg()
      alu("FRSQ", "f32", dst: .reg(r, 0), x)
      alu("FRCP", "f32", dst: def32(i), .reg(r, 0))
    case .fexp2:
      let x = opd(a)
      // 11c.13.6: S = x * 1.0 * 2^24, I = S to a signed integer, D = FEXP(I, S).
      let k = materialize(24)
      let s = newReg()
      alu("FMA_RSCALE", "f32", dst: .reg(s, 0), x, .const(16), .const(0), k, set: [("neg2", 1)])
      let n = newReg()
      alu("F32_TO_S32", "", dst: .reg(n, 0), .reg(s, 0))
      alu("FEXP", "f32", dst: def32(i), .reg(n, 0), .reg(s, 0))
    case .flog2:
      let x = opd(a)
      // 11c.13.7: D = FLOGD(x) * (LSCALE(-1.0, x)) + float(FREXPE.log(x)).
      let e = newReg()
      alu("FREXPE", "f32", dst: .reg(e, 0), x, named: [("mode", "log")])
      let ef = newReg()
      alu("S32_TO_F32", "", dst: .reg(ef, 0), .reg(e, 0))
      let fl = newReg()
      alu("FLOGD", "f32", dst: .reg(fl, 0), x)
      let ls = newReg()
      alu("FADD_LSCALE", "f32", dst: .reg(ls, 0), .const(16), x, set: [("neg0", 1)])
      alu("FMA", "f32", dst: def32(i), .reg(fl, 0), .reg(ls, 0), .reg(ef, 0))
    case .fsin, .fcos:
      try sinCos(i)
    default: throw BackendError.unsupported("float operation " + i.op.rawValue)
    }
  }

  /// 11c.13.11.
  mutating func sinCos(_ i: Inst) throws(BackendError) {
    let x = opd(i.args[0])
    let cA = materialize(0x3F22_F983)
    let cB = materialize(0xBFC9_0FDB)
    let cK = materialize(0x4940_0000)
    let u = newReg()
    alu("FMA", "f32", dst: .reg(u, 0), x, cA, cK)
    let r = newReg()
    alu("FADD", "f32", dst: .reg(r, 0), .reg(u, 0), cK, set: [("neg1", 1)])
    let e = newReg()
    alu("FMA", "f32", dst: .reg(e, 0), .reg(r, 0), cB, x)
    let sn = newReg()
    alu("FSIN_TABLE", "u6", dst: .reg(sn, 0), .reg(u, 0))
    let cs = newReg()
    alu("FCOS_TABLE", "u6", dst: .reg(cs, 0), .reg(u, 0))
    let h = newReg()
    let minusOne = Opd.const(1)
    alu("FMA_RSCALE", "f32", dst: .reg(h, 0), .reg(e, 0), .reg(e, 0), .const(0), minusOne, set: [("neg2", 1)])
    let isSin = i.op == .fsin
    let fv = isSin ? sn : cs
    let g = isSin ? cs : sn
    let q = newReg()
    alu("FMA", "f32", dst: .reg(q, 0), .reg(h, 0), .reg(fv, 0), .const(0), set: [("neg0", 1), ("neg2", 1)])
    let lin = newReg()
    alu(
      "FMA", "f32", dst: .reg(lin, 0), .reg(e, 0), .reg(g, 0), .reg(q, 0), set: isSin ? [] : [("neg1", 1)],
      named: [("clamp", "clamp_m1_1")])
    alu("FADD", "f32", dst: def32(i), .reg(lin, 0), .reg(fv, 0))
  }

  // MARK: conversions

  mutating func selectConvert(_ i: Inst) throws(BackendError) {
    let a = i.args[0]
    guard case .scalar(let from) = f.values[a].type, case .scalar(let to) = i.type else {
      throw BackendError.unsupported("a vector conversion")
    }
    switch i.op {
    case .bitcast:
      guard from.bits == to.bits, from.bits == 32 || from.bits == 64 else { throw BackendError.unsupported("bitcast") }
      loc[i.result] = loc[a]
    case .zext:
      if from == .bool && to == .i32 {
        let x = opd(a)
        alu("AND_IMM", "i32", dst: def32(i), x, set: [("imm", 1)])
      } else if from == .i32 && to == .i64 {
        let x = opd(a)
        let d = def64(i)
        guard case .reg(let dv, _) = d else { return }
        alu("MOV", "i32", dst: .reg(dv, 0), x)
        alu("MOV", "i32", dst: .reg(dv, 1), .const(0))
        zeroHigh[i.result] = true
      } else {
        throw BackendError.unsupported("zext " + from.name + " to " + to.name)
      }
    case .sext:
      if from == .bool && to == .i32 {
        loc[i.result] = loc[a]
      } else if from == .i32 && to == .i64 {
        let x = opd(a)
        let d = def64(i)
        guard case .reg(let dv, _) = d else { return }
        alu("MOV", "i32", dst: .reg(dv, 0), x)
        alu("ARSHIFT_OR", "i32", dst: .reg(dv, 1), x, .const(15), .const(0), set: [("wd1", 7)])
      } else {
        throw BackendError.unsupported("sext " + from.name + " to " + to.name)
      }
    case .trunc:
      if from == .i64 && to == .i32 {
        if case .reg(let r) = loc[a] {
          loc[i.result] = .reg(r)
        } else if case .const(let bits) = loc[a] {
          loc[i.result] = .const(bits & 0xFFFF_FFFF)
        }
      } else if from == .i32 && to == .bool {
        let x = opd(a)
        let t = newReg()
        alu("AND_IMM", "i32", dst: .reg(t, 0), x, set: [("imm", 1)])
        alu("ICMP_OR", "u32", dst: def32(i), .reg(t, 0), .const(0), .const(0), named: [("cmp", "ne"), ("rtype", "m1")])
      } else {
        throw BackendError.unsupported("trunc " + from.name + " to " + to.name)
      }
    case .fptosi, .fptoui:
      guard from == .f32 && to == .i32 else { throw BackendError.unsupported("float conversion to " + to.name) }
      let x = opd(a)
      alu(i.op == .fptosi ? "F32_TO_S32" : "F32_TO_U32", "", dst: def32(i), x, named: [("round", "round_zero")])
    case .sitofp, .uitofp:
      guard from == .i32 && to == .f32 else { throw BackendError.unsupported("integer conversion to " + to.name) }
      let x = opd(a)
      alu(i.op == .sitofp ? "S32_TO_F32" : "U32_TO_F32", "", dst: def32(i), x)
    default: throw BackendError.unsupported("conversion " + i.op.rawValue)
    }
  }
}
