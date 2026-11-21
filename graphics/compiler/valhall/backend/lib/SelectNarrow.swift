// SPDX-License-Identifier: BSD-3-Clause

// Selection of the narrow types: float16 in registers and 8 and 16-bit integers in memory (valhall 11a, 11c.3, 11c.6, 12a.3).
//
// A float16 value is a register whose low half is the binary16 value (the upper half is not defined); its arithmetic is the
// `v2f16` form of the instruction with both sources read as lane 0 (swizzle `h00`), so both lanes compute the same thing and
// the result is exact and correctly rounded in binary16, as Vulkan's float16 operations are. Conversions are F16_TO_F32 and
// the narrowing destination of FADD (11c.6.2). The 8 and 16-bit integers are i32 registers (LegalizeNarrow); only a load
// (LOAD.i8 or LOAD.i16, lane `w0`, zero extended), a store (STORE.i8 or STORE.i16 of lane 0) and the widening conversions
// (S8_TO_S32 and its kin, which read the low byte or half) mention the narrow size.

#if canImport(ShaderCompiler)
  import ShaderCompiler
#endif
#if canImport(ValhallISA)
  import ValhallISA
#endif

extension Selector {
  /// The 8, 16-bit integer or float16 scalar type of a value, nil for others.
  func narrowKind(_ t: IRType) -> Scalar? {
    if case .scalar(let s) = t, s == .i8 || s == .i16 || s == .f16 { return s }
    return nil
  }

  // MARK: memory

  /// A load of an 8 or 16-bit value (or a float16): `LOAD.i8` or `.i16` with the lane `w0`, zero extended into a register; a push
  /// constant is its FAU word shifted to the low bits.
  mutating func selectNarrowLoad(_ i: Inst, _ s: Scalar, _ p: PtrVal) throws(BackendError) {
    let bytes = s.bits / 8
    if case .push = p.base {
      guard p.dyn < 0 else { throw BackendError.unsupported("a push constant read at a run-time offset") }
      let w = p.offset / 4
      noteFAU(push: w)
      let shift = (p.offset % 4) * 8
      if shift == 0 {
        loc[i.result] = .fau(fau.pushWord + w)
      } else {
        let x: Opd = .user((fau.pushWord + w) / 2, (fau.pushWord + w) % 2)
        let (amt, lane) = shiftAmount(shift)!
        alu("RSHIFT_OR", "i32", dst: def32(i), x, amt, .const(0), set: [("wd1", lane)])
      }
      return
    }
    let (a, imm) = address(p, wide: true)
    let d = def32(i)
    message(
      "LOAD", bytes == 1 ? "i8" : "i16", address: a, offset: imm, write: d, memory: 1,
      named: [("access", accessFor(p)), ("lane", "w0")])
  }

  mutating func selectNarrowStore(_ p: PtrVal, _ v: ValueID, _ s: Scalar) throws(BackendError) {
    let d = reg32(v)
    let (a, imm) = address(p, wide: true)
    message("STORE", s.bits == 8 ? "i8" : "i16", address: a, offset: imm, read: d, memory: 2, named: [("access", accessFor(p))])
  }

  // MARK: conversions

  /// The conversions that involve a narrow type; false when the instruction is not one.
  mutating func selectNarrowConvert(_ i: Inst) throws(BackendError) -> Bool {
    guard case .scalar(let from) = f.values[i.args[0]].type, case .scalar(let to) = i.type else { return false }
    let a = i.args[0]
    let narrowInt: (Scalar) -> Bool = { $0 == .i8 || $0 == .i16 }
    switch i.op {
    case .trunc where narrowInt(to):
      loc[i.result] = loc[a]
      return true
    case .zext where narrowInt(from), .sext where narrowInt(from):
      guard to == .i32 else { throw BackendError.unsupported("a widening of " + from.name + " to " + to.name) }
      let signed = i.op == .sext
      if case .const(let bits) = loc[a] {
        let m: UInt64 = from == .i8 ? 0xFF : 0xFFFF
        var x = bits & m
        if signed && x & (from == .i8 ? 0x80 : 0x8000) != 0 { x |= ~m }
        loc[i.result] = .const(x & 0xFFFF_FFFF)
        return true
      }
      // The loaded value is already zero extended.
      if !signed, let d = placedInst(a), d.op == .load {
        loc[i.result] = loc[a]
        return true
      }
      let x = opd(a)
      let mn = (signed ? "S" : "U") + (from == .i8 ? "8_TO_" : "16_TO_") + (signed ? "S32" : "U32")
      alu(mn, "", dst: def32(i), x)
      return true
    case .bitcast where (from == .f16 || narrowInt(from)) && (to == .f16 || narrowInt(to)):
      loc[i.result] = loc[a]
      return true
    case .fpext where from == .f16 && to == .f32:
      let x = opd(a)
      alu("F16_TO_F32", "", dst: def32(i), x)
      return true
    case .fptrunc where from == .f32 && to == .f16:
      let x = opd(a)
      alu("F32_TO_F16", "", dst: def32(i), x, named: [("dw", "h01")])
      return true
    case .fptosi where from == .f16, .fptoui where from == .f16:
      let x = opd(a)
      let t = newReg()
      alu("F16_TO_F32", "", dst: .reg(t, 0), x)
      alu(i.op == .fptosi ? "F32_TO_S32" : "F32_TO_U32", "", dst: def32(i), .reg(t, 0), named: [("round", "round_zero")])
      return true
    case .sitofp where to == .f16, .uitofp where to == .f16:
      guard from == .i32 else { return false }
      let x = opd(a)
      let t = newReg()
      alu(i.op == .sitofp ? "S32_TO_F32" : "U32_TO_F32", "", dst: .reg(t, 0), x)
      alu("F32_TO_F16", "", dst: def32(i), .reg(t, 0), named: [("dw", "h01")])
      return true
    default:
      return false
    }
  }

  // MARK: float16 arithmetic

  private var h00: [(String, String)] { [("wd0", "h00"), ("wd1", "h00")] }

  mutating func selectFloat16(_ i: Inst) throws(BackendError) {
    let a = i.args.count > 0 ? i.args[0] : -1
    let b = i.args.count > 1 ? i.args[1] : -1
    switch i.op {
    case .fadd, .fsub:
      let x = opd(a)
      let y = opd(b)
      alu("FADD", "v2f16", dst: def32(i), x, y, set: i.op == .fsub ? [("neg1", 1)] : [], named: h00)
    case .fmul:
      let x = opd(a)
      let y = opd(b)
      alu("FMA", "v2f16", dst: def32(i), x, y, .const(0), set: [("neg2", 1)], named: h00 + [("wd2", "h00")])
    case .fma:
      let x = opd(a)
      let y = opd(b)
      let z = opd(i.args[2])
      alu("FMA", "v2f16", dst: def32(i), x, y, z, named: h00 + [("wd2", "h00")])
    case .fneg:
      let x = opd(a)
      alu("FADD", "v2f16", dst: def32(i), x, .const(0), set: [("neg0", 1), ("neg1", 1)], named: h00)
    case .fabs:
      let x = opd(a)
      alu("FADD", "v2f16", dst: def32(i), x, .const(0), set: [("abs0", 1), ("neg1", 1)], named: h00)
    case .fmin, .fmax:
      let x = opd(a)
      let y = opd(b)
      alu(i.op == .fmin ? "FMIN" : "FMAX", "v2f16", dst: def32(i), x, y, named: h00)
    default:
      throw BackendError.unsupported("float16 operation " + i.op.rawValue)
    }
  }

  mutating func selectCompare16(_ i: Inst) throws(BackendError) {
    if fusedCmp[i.result] { return }
    let x = opd(i.args[0])
    let y = opd(i.args[1])
    if i.imm == FCmpPred.ord || i.imm == FCmpPred.uno {
      let t = newReg()
      alu("FCMP_OR", "v2f16", dst: .reg(t, 0), y, y, .const(0), named: [("cmp", "eq"), ("rtype", "m1")] + h00)
      if i.imm == FCmpPred.ord {
        alu("FCMP_AND", "v2f16", dst: def32(i), x, x, .reg(t, 0), named: [("cmp", "eq"), ("rtype", "m1")] + h00)
      } else {
        let o = newReg()
        alu("FCMP_AND", "v2f16", dst: .reg(o, 0), x, x, .reg(t, 0), named: [("cmp", "eq"), ("rtype", "m1")] + h00)
        complementMask(def32(i), .reg(o, 0))
      }
      return
    }
    guard let c = compareOf(i) else { throw BackendError.unsupported("compare predicate") }
    if c.negate {
      let t = newReg()
      alu("FCMP_OR", "v2f16", dst: .reg(t, 0), x, y, .const(0), named: [("cmp", c.cmp), ("rtype", "m1")] + h00)
      complementMask(def32(i), .reg(t, 0))
    } else {
      alu("FCMP_OR", "v2f16", dst: def32(i), x, y, .const(0), named: [("cmp", c.cmp), ("rtype", "m1")] + h00)
    }
  }
}
