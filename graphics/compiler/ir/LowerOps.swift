// SPDX-License-Identifier: BSD-3-Clause

// SPIR-V to IR, continued: arithmetic, logic, comparison, conversion,
// composites and the GLSL.std.450 extended instructions. Operations the IR
// has no instruction for (dot, any, all, mix, pow, clamp, ...) are written
// out here in the IR's own operations; the IR is deliberately small.

/// The bit pattern of a float constant of this scalar type.
func floatBits(_ s: Scalar, _ d: Double) -> UInt64 {
  switch s {
  case .f64: return d.bitPattern
  case .f32: return UInt64(Float(d).bitPattern)
  default:
    let b = Float(d).bitPattern
    let sign = UInt64(b >> 31) << 15
    let exp = Int((b >> 23) & 0xff)
    let man = UInt64(b & 0x7f_ffff)
    if exp == 0xff { return sign | 0x7c00 | (man != 0 ? 0x200 : 0) }
    let e = exp - 127 + 15
    if e >= 31 { return sign | 0x7c00 }
    if e <= 0 {
      if e < -10 { return sign }
      let m = man | 0x80_0000
      let shift = UInt64(14 - e)
      var h = m >> shift
      let rem = m & ((1 << shift) - 1)
      let half = UInt64(1) << (shift - 1)
      if rem > half || (rem == half && h & 1 == 1) { h += 1 }
      return sign | h
    }
    var h = UInt64(e) << 10 | man >> 13
    let rem = man & 0x1fff
    if rem > 0x1000 || (rem == 0x1000 && h & 1 == 1) { h += 1 }
    return sign | h
  }
}

let glslNames: [String] = [
  "", "Round", "RoundEven", "Trunc", "FAbs", "SAbs", "FSign", "SSign", "Floor", "Ceil", "Fract", "Radians",
  "Degrees", "Sin", "Cos", "Tan", "Asin", "Acos", "Atan", "Sinh", "Cosh", "Tanh", "Asinh", "Acosh", "Atanh",
  "Atan2", "Pow", "Exp", "Log", "Exp2", "Log2", "Sqrt", "InverseSqrt", "Determinant", "MatrixInverse", "Modf",
  "ModfStruct", "FMin", "UMin", "SMin", "FMax", "UMax", "SMax", "FClamp", "UClamp", "SClamp", "FMix", "IMix",
  "Step", "SmoothStep", "Fma", "Frexp", "FrexpStruct", "Ldexp", "PackSnorm4x8", "PackUnorm4x8", "PackSnorm2x16",
  "PackUnorm2x16", "PackHalf2x16", "UnpackSnorm2x16", "UnpackUnorm2x16", "UnpackHalf2x16", "UnpackSnorm4x8",
  "UnpackUnorm4x8", "UnpackDouble2x32", "Length", "Distance", "Cross", "Normalize", "FaceForward", "Reflect",
  "Refract", "FindILsb", "FindSMsb", "FindUMsb", "InterpolateAtCentroid", "InterpolateAtSample",
  "InterpolateAtOffset", "NMin", "NMax", "NClamp",
]

extension Lowerer {
  func binaryOp(_ op: UInt16) -> IROp? {
    switch op {
    case Op.iAdd: return .iadd
    case Op.iSub: return .isub
    case Op.iMul: return .imul
    case Op.uDiv: return .udiv
    case Op.sDiv: return .sdiv
    case Op.uMod: return .urem
    case Op.sRem: return .srem
    case Op.fAdd: return .fadd
    case Op.fSub: return .fsub
    case Op.fMul: return .fmul
    case Op.fDiv: return .fdiv
    case Op.bitwiseOr, Op.logicalOr: return .or
    case Op.bitwiseXor, Op.logicalNotEqual: return .xor
    case Op.bitwiseAnd, Op.logicalAnd: return .and
    default: return nil
    }
  }

  func compare(_ op: UInt16) -> (IROp, Int)? {
    switch op {
    case Op.iEqual: return (.icmp, ICmpPred.eq)
    case Op.iNotEqual: return (.icmp, ICmpPred.ne)
    case Op.uGreaterThan: return (.icmp, ICmpPred.ugt)
    case Op.sGreaterThan: return (.icmp, ICmpPred.sgt)
    case Op.uGreaterThanEqual: return (.icmp, ICmpPred.uge)
    case Op.sGreaterThanEqual: return (.icmp, ICmpPred.sge)
    case Op.uLessThan: return (.icmp, ICmpPred.ult)
    case Op.sLessThan: return (.icmp, ICmpPred.slt)
    case Op.uLessThanEqual: return (.icmp, ICmpPred.ule)
    case Op.sLessThanEqual: return (.icmp, ICmpPred.sle)
    case Op.fOrdEqual: return (.fcmp, FCmpPred.oeq)
    case Op.fUnordEqual: return (.fcmp, FCmpPred.ueq)
    case Op.fOrdNotEqual: return (.fcmp, FCmpPred.one)
    case Op.fUnordNotEqual: return (.fcmp, FCmpPred.une)
    case Op.fOrdLessThan: return (.fcmp, FCmpPred.olt)
    case Op.fUnordLessThan: return (.fcmp, FCmpPred.ult)
    case Op.fOrdGreaterThan: return (.fcmp, FCmpPred.ogt)
    case Op.fUnordGreaterThan: return (.fcmp, FCmpPred.ugt)
    case Op.fOrdLessThanEqual: return (.fcmp, FCmpPred.ole)
    case Op.fUnordLessThanEqual: return (.fcmp, FCmpPred.ule)
    case Op.fOrdGreaterThanEqual: return (.fcmp, FCmpPred.oge)
    case Op.fUnordGreaterThanEqual: return (.fcmp, FCmpPred.uge)
    default: return nil
    }
  }

  /// The lanes of a value as scalars (a scalar is its own).
  mutating func lanes(_ v: ValueID) -> [ValueID] {
    guard case .vector(let s, let n) = f.type(v) else { return [v] }
    if case .constVec(let es) = f.values[v].kind { return es }
    var r: [ValueID] = []
    for k in 0..<n { r.append(emit(.extract, .scalar(s), [v], imm: k)) }
    return r
  }

  mutating func makeVector(_ lanes: [ValueID]) -> ValueID {
    if lanes.count == 1 { return lanes[0] }
    guard case .scalar(let s) = f.type(lanes[0]) else { fatalError("vector of non-scalars") }
    return emit(.vecbuild, .vector(s, lanes.count), lanes)
  }

  /// A scalar splatted to a vector type's width.
  mutating func splatValue(_ v: ValueID, to t: IRType) -> ValueID {
    guard case .vector(_, let n) = t, !f.type(v).isVector else { return v }
    return makeVector([ValueID](repeating: v, count: n))
  }

  mutating func fc(_ t: IRType, _ d: Double) -> ValueID { f.splat(t, floatBits(t.scalarKind!, d)) }

  mutating func lowerValueOp(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    if let bop = binaryOp(i.op) {
      guard o.count == 2 else { throw fail(i, "needs two operands") }
      let r = try irType(i.type, i)
      let a = try val(o[0], i)
      let b = try val(o[1], i)
      try expect(a, r, o[0], i)
      try expect(b, r, o[1], i)
      lv[Int(i.result)] = [emit(bop, r, [a, b])]
      return
    }
    if let (cop, pred) = compare(i.op) {
      guard o.count == 2 else { throw fail(i, "needs two operands") }
      let r = try irType(i.type, i)
      let a = try val(o[0], i)
      let b = try val(o[1], i)
      guard f.type(a) == f.type(b) else { throw fail(i, "the operands have different types") }
      guard r == f.type(a).with(.bool) else { throw fail(i, "the result type is not a bool of the operands' shape") }
      lv[Int(i.result)] = [emit(cop, r, [a, b], imm: pred)]
      return
    }
    switch i.op {
    case Op.undef:
      var all: [ValueID] = []
      for t in try leafTypesOf(i.type, i) { all.append(f.undef(t)) }
      lv[Int(i.result)] = all
    case Op.copyObject, Op.copyLogical:
      lv[Int(i.result)] = try leaves(o[0], i)
    case Op.sNegate, Op.fNegate, Op.not, Op.logicalNot:
      let r = try irType(i.type, i)
      let a = try val(o[0], i)
      try expect(a, r, o[0], i)
      let op: IROp = i.op == Op.sNegate ? .ineg : i.op == Op.fNegate ? .fneg : .not
      lv[Int(i.result)] = [emit(op, r, [a])]
    case Op.logicalEqual:
      let r = try irType(i.type, i)
      let a = try val(o[0], i)
      let b = try val(o[1], i)
      let x = emit(.xor, r, [a, b])
      lv[Int(i.result)] = [emit(.not, r, [x])]
    case Op.shiftLeftLogical, Op.shiftRightLogical, Op.shiftRightArithmetic:
      let r = try irType(i.type, i)
      let a = try val(o[0], i)
      var b = try val(o[1], i)
      try expect(a, r, o[0], i)
      if f.type(b) != r, let rs = r.scalarKind, let bs = f.type(b).scalarKind, bs.isInt, f.type(b).lanes == r.lanes {
        if bs.bits < rs.bits { b = emit(.zext, r, [b]) } else if bs.bits > rs.bits { b = emit(.trunc, r, [b]) }
      }
      try expect(b, r, o[1], i)
      let op: IROp = i.op == Op.shiftLeftLogical ? .shl : i.op == Op.shiftRightLogical ? .lshr : .ashr
      lv[Int(i.result)] = [emit(op, r, [a, b])]
    case Op.sMod:
      let r = try irType(i.type, i)
      let a = try val(o[0], i)
      let b = try val(o[1], i)
      try expect(a, r, o[0], i)
      try expect(b, r, o[1], i)
      // The remainder takes the divisor's sign: r + b when r != 0 and the signs differ.
      let rem = emit(.srem, r, [a, b])
      let x = emit(.xor, r, [rem, b])
      let zero = f.splat(r, 0)
      let neg = emit(.icmp, r.with(.bool), [x, zero], imm: ICmpPred.slt)
      let nz = emit(.icmp, r.with(.bool), [rem, zero], imm: ICmpPred.ne)
      let adj = emit(.and, r.with(.bool), [neg, nz])
      let sum = emit(.iadd, r, [rem, b])
      lv[Int(i.result)] = [emit(.select, r, [adj, sum, rem])]
    case Op.vectorTimesScalar:
      let r = try irType(i.type, i)
      let a = try val(o[0], i)
      let s = try val(o[1], i)
      try expect(a, r, o[0], i)
      lv[Int(i.result)] = [emit(.fmul, r, [a, splatValue(s, to: r)])]
    case Op.dot:
      let a = try val(o[0], i)
      let b = try val(o[1], i)
      guard f.type(a) == f.type(b), f.type(a).isVector, f.type(a).scalarKind!.isFloat else {
        throw fail(i, "the operands must be float vectors of the same type")
      }
      let la = lanes(a)
      let lb = lanes(b)
      let et = f.type(a).element
      var acc = emit(.fmul, et, [la[0], lb[0]])
      for k in 1..<la.count { acc = emit(.fma, et, [la[k], lb[k], acc]) }
      lv[Int(i.result)] = [acc]
    case Op.any, Op.all:
      let a = try val(o[0], i)
      guard f.type(a).isVector, f.type(a).scalarKind == .bool else { throw fail(i, "the operand is not a bool vector") }
      let l = lanes(a)
      var acc = l[0]
      for k in 1..<l.count { acc = emit(i.op == Op.any ? .or : .and, .bool, [acc, l[k]]) }
      lv[Int(i.result)] = [acc]
    case Op.isNan:
      let a = try val(o[0], i)
      let r = try irType(i.type, i)
      lv[Int(i.result)] = [emit(.fcmp, r, [a, a], imm: FCmpPred.uno)]
    case Op.isInf:
      let a = try val(o[0], i)
      let r = try irType(i.type, i)
      guard let k = f.type(a).scalarKind, k.isFloat else { throw fail(i, "the operand is not a float") }
      let ab = emit(.fabs, f.type(a), [a])
      lv[Int(i.result)] = [emit(.fcmp, r, [ab, fc(f.type(a), Double.infinity)], imm: FCmpPred.oeq)]
    case Op.select:
      let r = try irType(i.type, i)
      let c = try val(o[0], i)
      let a = try val(o[1], i)
      let b = try val(o[2], i)
      try expect(a, r, o[1], i)
      try expect(b, r, o[2], i)
      guard f.type(c) == .bool || f.type(c) == r.with(.bool) else {
        throw fail(i, "the condition must be a bool or a bool vector of the result's width")
      }
      lv[Int(i.result)] = [emit(.select, r, [c, a, b])]
    case Op.convertFToU, Op.convertFToS, Op.convertSToF, Op.convertUToF:
      let r = try irType(i.type, i)
      let a = try val(o[0], i)
      guard f.type(a).lanes == r.lanes else { throw fail(i, "the operand and result widths differ") }
      let op: IROp =
        i.op == Op.convertFToU ? .fptoui : i.op == Op.convertFToS ? .fptosi : i.op == Op.convertSToF ? .sitofp : .uitofp
      let fromFloat = i.op == Op.convertFToU || i.op == Op.convertFToS
      guard f.type(a).scalarKind?.isFloat == fromFloat, r.scalarKind?.isFloat == !fromFloat else {
        throw fail(i, "the operand or result has the wrong kind")
      }
      lv[Int(i.result)] = [emit(op, r, [a])]
    case Op.uConvert, Op.sConvert, Op.fConvert:
      let r = try irType(i.type, i)
      let a = try val(o[0], i)
      guard let from = f.type(a).scalarKind, let to = r.scalarKind, f.type(a).lanes == r.lanes else {
        throw fail(i, "the operand and result must be scalars or vectors of the same width")
      }
      guard from.isFloat == (i.op == Op.fConvert), to.isFloat == (i.op == Op.fConvert) else {
        throw fail(i, "the operand or result has the wrong kind")
      }
      if from.bits == to.bits {
        lv[Int(i.result)] = [a]
      } else {
        let op: IROp =
          i.op == Op.fConvert
          ? (to.bits > from.bits ? .fpext : .fptrunc)
          : (to.bits < from.bits ? .trunc : (i.op == Op.sConvert ? .sext : .zext))
        lv[Int(i.result)] = [emit(op, r, [a])]
      }
    case Op.convertPtrToU, Op.convertUToPtr:
      let r = try irType(i.type, i)
      let a = try val(o[0], i)
      if i.op == Op.convertPtrToU {
        guard f.type(a) == .ptr(.global), r == .i64 else {
          throw fail(i, "only a PhysicalStorageBuffer pointer converts, to a 64-bit integer")
        }
        lv[Int(i.result)] = [emit(.ptrtoint, r, [a])]
      } else {
        guard r == .ptr(.global), f.type(a) == .i64 else {
          throw fail(i, "only a 64-bit integer converts, to a PhysicalStorageBuffer pointer")
        }
        lv[Int(i.result)] = [emit(.inttoptr, r, [a])]
      }
    case Op.bitcast:
      let r = try irType(i.type, i)
      let a = try val(o[0], i)
      if f.type(a) == r {
        lv[Int(i.result)] = [a]
      } else if f.type(a).isPointer || r.isPointer {
        guard f.type(a).isPointer && r.isPointer else {
          throw fail(i, "a bitcast between a pointer and a non-pointer: use OpConvertPtrToU")
        }
        throw fail(i, "a bitcast between pointers of different storage classes")
      } else {
        guard f.type(a).totalBits == r.totalBits else { throw fail(i, "the operand and result sizes differ") }
        lv[Int(i.result)] = [emit(.bitcast, r, [a])]
      }
    case Op.vectorExtractDynamic:
      let v = try val(o[0], i)
      let idx = try val(o[1], i)
      guard case .vector(let s, let n) = f.type(v) else { throw fail(i, "the operand is not a vector") }
      if let c = f.constantBits(idx) {
        guard Int(c) < n else { throw fail(i, "the index \(c) is out of range") }
        lv[Int(i.result)] = [emit(.extract, .scalar(s), [v], imm: Int(c))]
      } else {
        let l = lanes(v)
        var r = l[n - 1]
        for k in stride(from: n - 2, through: 0, by: -1) {
          let eq = emit(.icmp, .bool, [idx, f.constant(f.type(idx).scalarKind!, UInt64(k))], imm: ICmpPred.eq)
          r = emit(.select, .scalar(s), [eq, l[k], r])
        }
        lv[Int(i.result)] = [r]
      }
    case Op.vectorInsertDynamic:
      let v = try val(o[0], i)
      let c = try val(o[1], i)
      let idx = try val(o[2], i)
      guard case .vector(let s, let n) = f.type(v) else { throw fail(i, "the operand is not a vector") }
      if let k = f.constantBits(idx) {
        guard Int(k) < n else { throw fail(i, "the index \(k) is out of range") }
        lv[Int(i.result)] = [emit(.insert, f.type(v), [v, c], imm: Int(k))]
      } else {
        var l = lanes(v)
        for k in 0..<n {
          let eq = emit(.icmp, .bool, [idx, f.constant(f.type(idx).scalarKind!, UInt64(k))], imm: ICmpPred.eq)
          l[k] = emit(.select, .scalar(s), [eq, c, l[k]])
        }
        lv[Int(i.result)] = [makeVector(l)]
      }
    case Op.vectorShuffle:
      let a = try val(o[0], i)
      let b = try val(o[1], i)
      let r = try irType(i.type, i)
      guard f.type(a) == f.type(b), case .vector(_, let n) = f.type(a), case .vector(let rs, let rn) = r,
        rs == f.type(a).scalarKind, o.count - 2 == rn
      else { throw fail(i, "the operands and result must be vectors with the same element type") }
      var lanes: [UInt64] = []
      for w in o[2...] {
        let l = w == 0xffff_ffff ? 0 : Int(w)
        guard l < 2 * n else { throw fail(i, "the lane \(l) is out of range") }
        lanes.append(UInt64(l))
      }
      lv[Int(i.result)] = [f.append(Inst(.shuffle, r, [a, b], payload: lanes), to: cur)]
    case Op.compositeConstruct:
      if case .vector(let s, let n)? = m.type(i.type) {
        _ = s
        var scalars: [ValueID] = []
        for p in o { scalars.append(contentsOf: lanes(try val(p, i))) }
        guard scalars.count == n else { throw fail(i, "the constituents make \(scalars.count) lanes, not \(n)") }
        lv[Int(i.result)] = [makeVector(scalars)]
      } else {
        var all: [ValueID] = []
        for p in o { all.append(contentsOf: try leaves(p, i)) }
        guard all.count == (try leafCount(i.type, i)) else { throw fail(i, "the constituents don't fill the type") }
        lv[Int(i.result)] = all
      }
    case Op.compositeExtract, Op.compositeInsert:
      try lowerCompositeAccess(i)
    case Op.extInst:
      try lowerExtInst(i)
    case Op.fRem, Op.fMod:
      throw fail(i, "not supported yet")
    default:
      if let info = OpTable.info(i.op) { throw fail(i, "\(info.name) is not supported yet") }
      throw fail(i, "unknown instruction")
    }
  }

  /// Walk a composite type by literal indices: the leaf range it names and,
  /// if the walk ends in a vector component, that component.
  func compositeRange(_ t: UInt32, _ idx: [UInt32], _ i: SPIRVInstruction) throws(CompileError)
    -> (start: Int, count: Int, component: Int, type: UInt32)
  {
    var cur = t
    var off = 0
    var k = 0
    while k < idx.count {
      switch m.type(cur) {
      case .structure(let ms)?:
        guard Int(idx[k]) < ms.count else { throw fail(i, "member \(idx[k]) is out of range") }
        for x in 0..<Int(idx[k]) { off += try leafCount(ms[x], i) }
        cur = ms[Int(idx[k])]
      case .array(let e, let len)?:
        guard idx[k] < UInt32(truncatingIfNeeded: try evalInt(len, i)) else { throw fail(i, "index \(idx[k]) is out of range") }
        off += Int(idx[k]) * (try leafCount(e, i))
        cur = e
      case .vector(let e, let n)?:
        guard k == idx.count - 1, Int(idx[k]) < n else { throw fail(i, "a bad vector index") }
        return (off, 1, Int(idx[k]), e)
      default: throw fail(i, "can't index into this type")
      }
      k += 1
    }
    return (off, try leafCount(cur, i), -1, cur)
  }

  mutating func lowerCompositeAccess(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    if i.op == Op.compositeExtract {
      guard o.count >= 2 else { throw fail(i, "needs a composite and an index") }
      let src = try leaves(o[0], i)
      let r = try compositeRange(m.idType[Int(o[0])], Array(o[1...]), i)
      if r.component >= 0 {
        let v = src[r.start]
        guard case .vector(let s, _) = f.type(v) else { throw fail(i, "not a vector") }
        lv[Int(i.result)] = [emit(.extract, .scalar(s), [v], imm: r.component)]
      } else {
        lv[Int(i.result)] = Array(src[r.start..<r.start + r.count])
      }
    } else {
      guard o.count >= 3 else { throw fail(i, "needs an object, a composite and an index") }
      let obj = try leaves(o[0], i)
      var all = try leaves(o[1], i)
      let r = try compositeRange(i.type, Array(o[2...]), i)
      if r.component >= 0 {
        let v = all[r.start]
        all[r.start] = emit(.insert, f.type(v), [v, obj[0]], imm: r.component)
      } else {
        guard obj.count == r.count else { throw fail(i, "the object doesn't match the indexed part") }
        for k in 0..<r.count { all[r.start + k] = obj[k] }
      }
      lv[Int(i.result)] = all
    }
  }

  mutating func lowerExtInst(_ i: SPIRVInstruction) throws(CompileError) {
    let o = i.operands
    guard o.count >= 2 else { throw fail(i, "needs a set and an instruction") }
    guard m.extInstImports.contains(where: { $0.id == o[0] }) else { throw fail(i, "set %\(o[0]) is not imported") }
    let n = Int(o[1])
    let name = n < glslNames.count ? glslNames[n] : "#\(n)"
    var a: [ValueID] = []
    for x in o[2...] { a.append(try val(x, i)) }
    let r = try irType(i.type, i)
    func arity(_ k: Int) throws(CompileError) {
      guard a.count == k else { throw fail(i, "GLSL.std.450 \(name) takes \(k) operands") }
      for (j, v) in a.enumerated() where f.type(v) != r {
        throw fail(i, "operand \(j) has type \(f.type(v).name), expected \(r.name)")
      }
    }
    func float() throws(CompileError) {
      guard let k = r.scalarKind, k.isFloat else { throw fail(i, "GLSL.std.450 \(name) needs float operands") }
    }
    func int() throws(CompileError) {
      guard let k = r.scalarKind, k.isInt else { throw fail(i, "GLSL.std.450 \(name) needs integer operands") }
    }
    var res: ValueID
    switch n {
    case 1, 2: try arity(1); try float(); res = emit(.fround, r, a)
    case 3: try arity(1); try float(); res = emit(.ftrunc, r, a)
    case 4: try arity(1); try float(); res = emit(.fabs, r, a)
    case 5:
      try arity(1); try int()
      let neg = emit(.ineg, r, a)
      let isNeg = emit(.icmp, r.with(.bool), [a[0], f.splat(r, 0)], imm: ICmpPred.slt)
      res = emit(.select, r, [isNeg, neg, a[0]])
    case 6:
      try arity(1); try float()
      let gt = emit(.fcmp, r.with(.bool), [a[0], fc(r, 0)], imm: FCmpPred.ogt)
      let lt = emit(.fcmp, r.with(.bool), [a[0], fc(r, 0)], imm: FCmpPred.olt)
      let inner = emit(.select, r, [lt, fc(r, -1), fc(r, 0)])
      res = emit(.select, r, [gt, fc(r, 1), inner])
    case 7:
      try arity(1); try int()
      let gt = emit(.icmp, r.with(.bool), [a[0], f.splat(r, 0)], imm: ICmpPred.sgt)
      let lt = emit(.icmp, r.with(.bool), [a[0], f.splat(r, 0)], imm: ICmpPred.slt)
      let inner = emit(.select, r, [lt, f.splat(r, UInt64.max), f.splat(r, 0)])
      res = emit(.select, r, [gt, f.splat(r, 1), inner])
    case 8: try arity(1); try float(); res = emit(.ffloor, r, a)
    case 9: try arity(1); try float(); res = emit(.fceil, r, a)
    case 10:
      try arity(1); try float()
      let fl = emit(.ffloor, r, a)
      res = emit(.fsub, r, [a[0], fl])
    case 13: try arity(1); try float(); res = emit(.fsin, r, a)
    case 14: try arity(1); try float(); res = emit(.fcos, r, a)
    case 26:
      try arity(2); try float()
      res = lowerPowAccurate(r, a[0], a[1])
    case 27:
      try arity(1); try float()
      res = lowerExpAccurate(r, a[0])
    case 28:
      try arity(1); try float()
      res = lowerLogAccurate(r, a[0])
    case 29: try arity(1); try float(); res = emit(.fexp2, r, a)
    case 30: try arity(1); try float(); res = emit(.flog2, r, a)
    case 31: try arity(1); try float(); res = emit(.fsqrt, r, a)
    case 32: try arity(1); try float(); res = emit(.frsq, r, a)
    case 37, 79: try arity(2); try float(); res = emit(.fmin, r, a)
    case 38: try arity(2); try int(); res = emit(.umin, r, a)
    case 39: try arity(2); try int(); res = emit(.smin, r, a)
    case 40, 80: try arity(2); try float(); res = emit(.fmax, r, a)
    case 41: try arity(2); try int(); res = emit(.umax, r, a)
    case 42: try arity(2); try int(); res = emit(.smax, r, a)
    case 43, 81:
      try arity(3); try float()
      res = emit(.fmin, r, [emit(.fmax, r, [a[0], a[1]]), a[2]])
    case 44:
      try arity(3); try int()
      res = emit(.umin, r, [emit(.umax, r, [a[0], a[1]]), a[2]])
    case 45:
      try arity(3); try int()
      res = emit(.smin, r, [emit(.smax, r, [a[0], a[1]]), a[2]])
    case 46:
      // x * (1 - a) + y * a
      try arity(3); try float()
      let t = emit(.fsub, r, [fc(r, 1), a[2]])
      res = emit(.fma, r, [a[1], a[2], emit(.fmul, r, [a[0], t])])
    case 48:
      try arity(2); try float()
      let lt = emit(.fcmp, r.with(.bool), [a[1], a[0]], imm: FCmpPred.olt)
      res = emit(.select, r, [lt, fc(r, 0), fc(r, 1)])
    case 49:
      try arity(3); try float()
      let num = emit(.fsub, r, [a[2], a[0]])
      let den = emit(.fsub, r, [a[1], a[0]])
      let q = emit(.fdiv, r, [num, den])
      let t = emit(.fmin, r, [emit(.fmax, r, [q, fc(r, 0)]), fc(r, 1)])
      let two = emit(.fmul, r, [fc(r, 2), t])
      let c = emit(.fsub, r, [fc(r, 3), two])
      res = emit(.fmul, r, [emit(.fmul, r, [t, t]), c])
    case 50: try arity(3); try float(); res = emit(.fma, r, a)
    default:
      guard let m = try lowerMathExt(n, a, r, name, i) else { throw fail(i, "GLSL.std.450 \(name) is not supported yet") }
      res = m
    }
    lv[Int(i.result)] = [res]
  }
}
