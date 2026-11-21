// SPDX-License-Identifier: BSD-3-Clause

// Specialization constants (D174 step 5): before the rewrite reads the module, every OpSpecConstant,
// OpSpecConstantTrue and OpSpecConstantFalse takes the value the pipeline gave its SpecId (or its default), and every
// OpSpecConstantComposite and OpSpecConstantOp is evaluated, so that the module has plain constants only. The
// compiler downstream never sees a specialization constant. A constant decorated WorkgroupSize, and a LocalSizeId
// execution mode, become the entry points' LocalSize. The evaluator works on the constants' bits, with no floating
// point arithmetic; the float conversions it needs (FConvert) are done on the formats' fields.

/// The value a pipeline gives one specialization constant: the little-endian bytes of its VkSpecializationMapEntry,
/// as the low bytes of `value` (a boolean is any non-zero value).
public struct SpecConstant: Sendable, Equatable {
  public var id: UInt32
  public var value: UInt64
  public init(id: UInt32, value: UInt64) {
    self.id = id
    self.value = value
  }
}

/// A constant's value: the bits of a scalar (zero-extended from its width; a bool is 0 or 1), or the elements of a
/// vector, matrix, array or structure.
indirect enum ConstantValue: Equatable {
  case scalar(UInt64)
  case composite([ConstantValue])
}

enum SPVConst {
  static let opConstantTrue: UInt16 = 41
  static let opConstantFalse: UInt16 = 42
  static let opConstant: UInt16 = 43
  static let opConstantComposite: UInt16 = 44
  static let opConstantNull: UInt16 = 46
  static let opSpecConstantTrue: UInt16 = 48
  static let opSpecConstantFalse: UInt16 = 49
  static let opSpecConstant: UInt16 = 50
  static let opSpecConstantComposite: UInt16 = 51
  static let opSpecConstantOp: UInt16 = 52
  static let decSpecId: UInt32 = 1
  static let decWorkgroupSize: UInt32 = 25
  static let builtIn: UInt32 = 11
  static let modeLocalSize: UInt32 = 17
  static let modeLocalSizeId: UInt32 = 38
}

/// Mask of the low `w` bits.
func widthMask(_ w: Int) -> UInt64 { w >= 64 ? ~0 : (1 << UInt64(w)) - 1 }

/// `v`'s low `w` bits as a signed value.
func signExtend(_ v: UInt64, _ w: Int) -> Int64 {
  if w >= 64 || w <= 0 { return Int64(bitPattern: v) }
  let s = UInt64(64 - w)
  return Int64(bitPattern: v << s) >> Int64(s)
}

/// `n` right-shifted by `shift` and rounded to nearest, ties to even (a left shift for a negative `shift`).
func roundShift(_ n: UInt64, _ shift: Int) -> UInt64 {
  if shift <= 0 { return n << UInt64(-shift) }
  if shift >= 64 { return 0 }
  let kept = n >> UInt64(shift)
  let rest = n & widthMask(shift)
  let half: UInt64 = 1 << UInt64(shift - 1)
  if rest > half || (rest == half && kept & 1 == 1) { return kept + 1 }
  return kept
}

/// A float's bits converted between IEEE widths (16, 32, 64), rounding to nearest even.
func convertFloat(_ bits: UInt64, from: Int, to: Int) -> UInt64 {
  func format(_ w: Int) -> (exp: Int, man: Int) { w == 16 ? (5, 10) : w == 32 ? (8, 23) : (11, 52) }
  let (se, sm) = format(from)
  let (te, tm) = format(to)
  let sign = (bits >> UInt64(from - 1)) & 1
  let exp = Int((bits >> UInt64(sm)) & widthMask(se))
  let man = bits & widthMask(sm)
  let signBit = sign << UInt64(to - 1)
  let targetMaxExp = Int(widthMask(te))
  if exp == Int(widthMask(se)) {
    if man == 0 { return signBit | UInt64(targetMaxExp) << UInt64(tm) }
    // A NaN: quiet, keeping the top of its payload.
    let payload = tm >= sm ? man << UInt64(tm - sm) : man >> UInt64(sm - tm)
    return signBit | UInt64(targetMaxExp) << UInt64(tm) | (1 << UInt64(tm - 1)) | (payload & widthMask(tm))
  }
  let sourceBias = (1 << (se - 1)) - 1
  let targetBias = (1 << (te - 1)) - 1
  var sig = man
  var e = 1 - sourceBias
  if exp != 0 {
    sig |= 1 << UInt64(sm)
    e = exp - sourceBias
  }
  if sig == 0 { return signBit }
  // The value is sig * 2^(e - sm). Put the leading bit at position p.
  let p = 63 - sig.leadingZeroBitCount
  let unbiased = e + (p - sm)
  if unbiased >= 1 - targetBias {
    var rounded = roundShift(sig, p - tm)
    var ue = unbiased
    if rounded >> UInt64(tm + 1) != 0 {
      rounded >>= 1
      ue += 1
    }
    if ue + targetBias >= targetMaxExp { return signBit | UInt64(targetMaxExp) << UInt64(tm) }
    return signBit | UInt64(ue + targetBias) << UInt64(tm) | (rounded & widthMask(tm))
  }
  // A subnormal of the target: units of 2^(1 - bias - tm).
  let shift = (1 - targetBias - tm) - (unbiased - p)
  return signBit | roundShift(sig, shift)
}

struct Specializer {
  var m: RawModule
  let values: [SpecConstant]
  var types: [TypeInfo?]
  var constants: [ConstantValue?]
  /// The type each constant was declared with.
  var constantType: [UInt32]
  var specIds: [UInt32?]
  var out: [RawInst] = []

  /// Rewrites the module's constants and the execution modes that name them, if it has any specialization.
  static func run(_ m: inout RawModule, _ values: [SpecConstant]) throws(LoweringError) {
    var any = false
    for g in m.globals where g.op >= SPVConst.opSpecConstantTrue && g.op <= SPVConst.opSpecConstantOp { any = true }
    for e in m.executionModes where e.op == SPV.opExecutionModeId { any = true }
    guard any else { return }
    let n = Int(m.bound)
    var s = Specializer(
      m: m, values: values, types: [TypeInfo?](repeating: nil, count: n), constants: [ConstantValue?](repeating: nil, count: n),
      constantType: [UInt32](repeating: 0, count: n), specIds: [UInt32?](repeating: nil, count: n))
    try s.fold()
    m = s.m
  }

  func check(_ id: UInt32) throws(LoweringError) {
    guard id < m.bound else { throw .malformed("an id outside the module's bound") }
  }

  mutating func newId() -> UInt32 {
    let id = m.bound
    m.bound += 1
    types.append(nil)
    constants.append(nil)
    constantType.append(0)
    specIds.append(nil)
    return id
  }

  // MARK: types

  func scalarWidth(_ t: UInt32) -> Int {
    switch types[Int(t)] {
    case .bool?: return 1
    case .int(let w, _)?, .float(let w)?: return w
    default: return 0
    }
  }

  /// The types of the elements of a composite type.
  func elementTypes(_ t: UInt32) throws(LoweringError) -> [UInt32] {
    switch types[Int(t)] {
    case .vector(let e, let n)?: return [UInt32](repeating: e, count: n)
    case .matrix(let c, let n)?: return [UInt32](repeating: c, count: n)
    case .array(let e, let length)?:
      guard case .scalar(let n)? = constants[Int(length)] else { throw .malformed("an array length that isn't a constant") }
      return [UInt32](repeating: e, count: Int(n))
    case .structure(let members)?: return members
    default: throw .malformed("a composite constant of a type that isn't a composite")
    }
  }

  func zero(_ t: UInt32) throws(LoweringError) -> ConstantValue {
    switch types[Int(t)] {
    case .bool?, .int?, .float?: return .scalar(0)
    default:
      var parts: [ConstantValue] = []
      for e in try elementTypes(t) { parts.append(try zero(e)) }
      return .composite(parts)
    }
  }

  // MARK: folding

  func specValue(_ id: UInt32) -> UInt64? {
    guard let sid = specIds[Int(id)] else { return nil }
    for v in values where v.id == sid { return v.value }
    return nil
  }

  mutating func define(_ type: UInt32, _ id: UInt32, _ value: ConstantValue) {
    constants[Int(id)] = value
    constantType[Int(id)] = type
  }

  mutating func fold() throws(LoweringError) {
    for a in m.annotations where a.op == SPV.opDecorate && a.w.count >= 3 && a.w[1] == SPVConst.decSpecId {
      try check(a.w[0])
      specIds[Int(a.w[0])] = a.w[2]
    }
    for inst in m.globals {
      let w = inst.w
      if inst.op >= SPV.opTypeVoid && inst.op <= 38, !w.isEmpty {
        try check(w[0])
        if let t = Rewriter.typeInfo(inst) { types[Int(w[0])] = t }
        out.append(inst)
        continue
      }
      switch inst.op {
      case SPVConst.opConstantTrue, SPVConst.opConstantFalse:
        guard w.count >= 2 else { throw .malformed("a constant needs a type and an id") }
        try check(w[0])
        try check(w[1])
        define(w[0], w[1], .scalar(inst.op == SPVConst.opConstantTrue ? 1 : 0))
        out.append(inst)
      case SPVConst.opConstant:
        guard w.count >= 3 else { throw .malformed("OpConstant needs a type, an id and a value") }
        try check(w[0])
        try check(w[1])
        define(w[0], w[1], .scalar(literal(w, scalarWidth(w[0]))))
        out.append(inst)
      case SPVConst.opConstantComposite:
        guard w.count >= 2 else { throw .malformed("a constant needs a type and an id") }
        try check(w[0])
        try check(w[1])
        define(w[0], w[1], try compositeOf(w))
        out.append(inst)
      case SPVConst.opConstantNull:
        guard w.count >= 2 else { throw .malformed("a constant needs a type and an id") }
        try check(w[0])
        try check(w[1])
        define(w[0], w[1], try zero(w[0]))
        out.append(inst)
      case SPVConst.opSpecConstantTrue, SPVConst.opSpecConstantFalse:
        guard w.count >= 2 else { throw .malformed("a constant needs a type and an id") }
        try check(w[0])
        try check(w[1])
        var on = inst.op == SPVConst.opSpecConstantTrue
        if let v = specValue(w[1]) { on = v != 0 }
        define(w[0], w[1], .scalar(on ? 1 : 0))
        out.append(RawInst(on ? SPVConst.opConstantTrue : SPVConst.opConstantFalse, [w[0], w[1]]))
      case SPVConst.opSpecConstant:
        guard w.count >= 3 else { throw .malformed("OpSpecConstant needs a type, an id and a value") }
        try check(w[0])
        try check(w[1])
        let width = scalarWidth(w[0])
        var bits = literal(w, width)
        if let v = specValue(w[1]) { bits = v & widthMask(width) }
        define(w[0], w[1], .scalar(bits))
        out.append(scalarInstruction(w[0], w[1], bits))
      case SPVConst.opSpecConstantComposite:
        guard w.count >= 2 else { throw .malformed("a constant needs a type and an id") }
        try check(w[0])
        try check(w[1])
        define(w[0], w[1], try compositeOf(w))
        out.append(RawInst(SPVConst.opConstantComposite, w))
      case SPVConst.opSpecConstantOp:
        guard w.count >= 3 else { throw .malformed("OpSpecConstantOp needs a type, an id and an opcode") }
        try check(w[0])
        try check(w[1])
        let value = try evaluate(w)
        define(w[0], w[1], value)
        try emit(w[0], w[1], value)
      default:
        out.append(inst)
      }
    }
    m.globals = out

    // The decorations that named the specialization are spent. A constant's WorkgroupSize is the entry points' size.
    var workgroup: [ConstantValue]?
    var annotations: [RawInst] = []
    for a in m.annotations {
      if a.op == SPV.opDecorate, a.w.count >= 2, a.w[1] == SPVConst.decSpecId { continue }
      if a.op == SPV.opDecorate, a.w.count >= 3, a.w[1] == SPVConst.builtIn, a.w[2] == SPVConst.decWorkgroupSize {
        try check(a.w[0])
        if case .composite(let parts)? = constants[Int(a.w[0])], parts.count == 3 { workgroup = parts }
        continue
      }
      annotations.append(a)
    }
    m.annotations = annotations

    var modes: [RawInst] = []
    var sized: [UInt32] = []
    for e in m.executionModes {
      if e.op == SPV.opExecutionModeId, e.w.count >= 2, e.w[1] == SPVConst.modeLocalSizeId {
        guard e.w.count == 5 else { throw .malformed("LocalSizeId needs three sizes") }
        var size: [UInt32] = []
        for k in 2..<5 {
          try check(e.w[k])
          guard case .scalar(let v)? = constants[Int(e.w[k])] else { throw .invalid("LocalSizeId names an id that isn't a constant") }
          size.append(UInt32(truncatingIfNeeded: v))
        }
        modes.append(RawInst(SPV.opExecutionMode, [e.w[0], SPVConst.modeLocalSize] + size))
        sized.append(e.w[0])
      } else if e.op == SPV.opExecutionMode, e.w.count >= 2, e.w[1] == SPVConst.modeLocalSize {
        modes.append(e)
        sized.append(e.w[0])
      } else {
        modes.append(e)
      }
    }
    if let parts = workgroup {
      var size: [UInt32] = []
      for p in parts {
        guard case .scalar(let v) = p else { throw .invalid("WorkgroupSize isn't three integers") }
        size.append(UInt32(truncatingIfNeeded: v))
      }
      for k in modes.indices where modes[k].op == SPV.opExecutionMode && modes[k].w.count >= 2 && modes[k].w[1] == SPVConst.modeLocalSize {
        modes[k].w = [modes[k].w[0], SPVConst.modeLocalSize] + size
      }
      for e in m.entryPoints where e.w.count >= 2 && e.w[0] == SPV.modelGLCompute {
        var has = false
        for f in sized where f == e.w[1] { has = true }
        if !has { modes.append(RawInst(SPV.opExecutionMode, [e.w[1], SPVConst.modeLocalSize] + size)) }
      }
    }
    m.executionModes = modes
  }

  /// The literal of an OpConstant (word 2 and, for 64 bits, word 3), as the bits of a type `width` wide.
  func literal(_ w: [UInt32], _ width: Int) -> UInt64 {
    var v = UInt64(w[2])
    if width > 32, w.count >= 4 { v |= UInt64(w[3]) << 32 }
    return v & widthMask(width)
  }

  func scalarInstruction(_ type: UInt32, _ id: UInt32, _ bits: UInt64) -> RawInst {
    switch types[Int(type)] {
    case .bool?: return RawInst(bits != 0 ? SPVConst.opConstantTrue : SPVConst.opConstantFalse, [type, id])
    case .int(let w, let signed)?:
      if w > 32 { return RawInst(SPVConst.opConstant, [type, id, UInt32(truncatingIfNeeded: bits), UInt32(truncatingIfNeeded: bits >> 32)]) }
      let word = signed && w < 32 ? UInt32(truncatingIfNeeded: signExtend(bits, w)) : UInt32(truncatingIfNeeded: bits)
      return RawInst(SPVConst.opConstant, [type, id, word])
    default:
      if scalarWidth(type) > 32 {
        return RawInst(SPVConst.opConstant, [type, id, UInt32(truncatingIfNeeded: bits), UInt32(truncatingIfNeeded: bits >> 32)])
      }
      return RawInst(SPVConst.opConstant, [type, id, UInt32(truncatingIfNeeded: bits)])
    }
  }

  func compositeOf(_ w: [UInt32]) throws(LoweringError) -> ConstantValue {
    var parts: [ConstantValue] = []
    var k = 2
    while k < w.count {
      try check(w[k])
      guard let c = constants[Int(w[k])] else { throw .invalid("a constant composite of %\(w[k]), which is not a constant") }
      parts.append(c)
      k += 1
    }
    return .composite(parts)
  }

  /// Declares `value` as the constant `id` of type `type`, a composite's elements first.
  mutating func emit(_ type: UInt32, _ id: UInt32, _ value: ConstantValue) throws(LoweringError) {
    switch value {
    case .scalar(let bits): out.append(scalarInstruction(type, id, bits))
    case .composite(let parts):
      let elements = try elementTypes(type)
      guard elements.count == parts.count else { throw .invalid("a constant of the wrong number of elements") }
      var ids: [UInt32] = []
      for k in parts.indices {
        let e = newId()
        define(elements[k], e, parts[k])
        try emit(elements[k], e, parts[k])
        ids.append(e)
      }
      out.append(RawInst(SPVConst.opConstantComposite, [type, id] + ids))
    }
  }

  // MARK: evaluating OpSpecConstantOp

  func value(_ id: UInt32) throws(LoweringError) -> ConstantValue {
    try check(id)
    guard let c = constants[Int(id)] else { throw .invalid("OpSpecConstantOp names %\(id), which is not a constant") }
    return c
  }

  /// The value of `OpSpecConstantOp type id opcode operands...`.
  func evaluate(_ w: [UInt32]) throws(LoweringError) -> ConstantValue {
    let op = UInt16(truncatingIfNeeded: w[2])
    switch op {
    case 81:  // CompositeExtract
      guard w.count >= 5 else { throw .malformed("OpCompositeExtract needs a composite and an index") }
      var v = try value(w[3])
      for k in 4..<w.count {
        guard case .composite(let parts) = v, Int(w[k]) < parts.count else { throw .invalid("a constant extract out of range") }
        v = parts[Int(w[k])]
      }
      return v
    case 82:  // CompositeInsert
      guard w.count >= 6 else { throw .malformed("OpCompositeInsert needs an object, a composite and an index") }
      return try insert(try value(w[3]), into: try value(w[4]), Array(w[5...]))
    case 79:  // VectorShuffle
      guard w.count >= 5 else { throw .malformed("OpVectorShuffle needs two vectors") }
      guard case .composite(let a) = try value(w[3]), case .composite(let b) = try value(w[4]) else {
        throw .invalid("a constant shuffle of something that isn't a vector")
      }
      var parts: [ConstantValue] = []
      for k in 5..<w.count {
        let i = Int(w[k])
        if w[k] == 0xFFFF_FFFF {
          parts.append(.scalar(0))
        } else if i < a.count {
          parts.append(a[i])
        } else if i - a.count < b.count {
          parts.append(b[i - a.count])
        } else {
          throw .invalid("a constant shuffle out of range")
        }
      }
      return .composite(parts)
    default:
      var args: [ConstantValue] = []
      var argTypes: [UInt32] = []
      for k in 3..<w.count {
        args.append(try value(w[k]))
        argTypes.append(constantType[Int(w[k])])
      }
      return try apply(op, w[0], args, argTypes)
    }
  }

  func insert(_ object: ConstantValue, into composite: ConstantValue, _ path: [UInt32]) throws(LoweringError) -> ConstantValue {
    guard let first = path.first else { return object }
    guard case .composite(var parts) = composite, Int(first) < parts.count else { throw .invalid("a constant insert out of range") }
    parts[Int(first)] = try insert(object, into: parts[Int(first)], Array(path.dropFirst()))
    return .composite(parts)
  }

  /// `op` over the arguments, component by component where the result is a vector.
  func apply(_ op: UInt16, _ resultType: UInt32, _ args: [ConstantValue], _ argTypes: [UInt32]) throws(LoweringError)
    -> ConstantValue
  {
    guard args.count == argTypes.count, !args.isEmpty else { throw .malformed("OpSpecConstantOp needs operands") }
    if op == 169 {  // Select
      guard args.count == 3 else { throw .malformed("OpSelect needs three operands") }
      if case .scalar(let c) = args[0] { return c != 0 ? args[1] : args[2] }
    }
    if case .vector(let element, let n)? = types[Int(resultType)] {
      var parts: [ConstantValue] = []
      for k in 0..<n {
        var sub: [ConstantValue] = []
        var subTypes: [UInt32] = []
        for (a, t) in zip(args, argTypes) {
          if case .composite(let c) = a, case .vector(let e, _)? = types[Int(t)], k < c.count {
            sub.append(c[k])
            subTypes.append(e)
          } else {
            sub.append(a)
            subTypes.append(t)
          }
        }
        parts.append(try apply(op, element, sub, subTypes))
      }
      return .composite(parts)
    }
    var bits: [UInt64] = []
    for a in args {
      guard case .scalar(let v) = a else { throw .invalid("OpSpecConstantOp \(op) of a composite") }
      bits.append(v)
    }
    return .scalar(try scalar(op, bits, widthR: scalarWidth(resultType), widthA: scalarWidth(argTypes[0])))
  }

  func scalar(_ op: UInt16, _ a: [UInt64], widthR wr: Int, widthA wa: Int) throws(LoweringError) -> UInt64 {
    func need(_ n: Int) throws(LoweringError) {
      guard a.count == n else { throw .malformed("OpSpecConstantOp \(op) takes \(n) operands") }
    }
    func flag(_ b: Bool) -> UInt64 { b ? 1 : 0 }
    let mr = widthMask(wr)
    switch op {
    case 113:  // UConvert
      try need(1)
      return a[0] & mr
    case 114:  // SConvert
      try need(1)
      return UInt64(bitPattern: signExtend(a[0], wa)) & mr
    case 115:  // FConvert
      try need(1)
      return convertFloat(a[0], from: wa, to: wr)
    case 126:  // SNegate
      try need(1)
      return (0 &- a[0]) & mr
    case 200:  // Not
      try need(1)
      return ~a[0] & mr
    case 168:  // LogicalNot
      try need(1)
      return flag(a[0] == 0)
    case 128, 130, 132, 134, 135, 137, 138, 139, 194, 195, 196, 197, 198, 199, 164, 165, 166, 167, 170, 171, 172, 173, 174, 175, 176, 177,
      178, 179:
      try need(2)
    default:
      throw .unsupported("OpSpecConstantOp \(op)")
    }
    let x = a[0]
    let y = a[1]
    let sx = signExtend(x, wa)
    let sy = signExtend(y, wa)
    func nonZero() throws(LoweringError) {
      guard y != 0 else { throw .invalid("a specialization constant divides by zero") }
    }
    switch op {
    case 128: return (x &+ y) & mr
    case 130: return (x &- y) & mr
    case 132: return (x &* y) & mr
    case 134:
      try nonZero()
      return (x / y) & mr
    case 135:
      try nonZero()
      return UInt64(bitPattern: sx.dividedReportingOverflow(by: sy).partialValue) & mr
    case 137:
      try nonZero()
      return (x % y) & mr
    case 138:
      try nonZero()
      return UInt64(bitPattern: sx.remainderReportingOverflow(dividingBy: sy).partialValue) & mr
    case 139:
      try nonZero()
      var r = sx.remainderReportingOverflow(dividingBy: sy).partialValue
      if r != 0 && (r < 0) != (sy < 0) { r += sy }
      return UInt64(bitPattern: r) & mr
    case 194: return y >= UInt64(wr) ? 0 : (x >> y) & mr
    case 195: return UInt64(bitPattern: signExtend(x, wr) >> Int64(min(y, UInt64(63)))) & mr
    case 196: return y >= UInt64(wr) ? 0 : (x << y) & mr
    case 197: return (x | y) & mr
    case 198: return (x ^ y) & mr
    case 199: return (x & y) & mr
    case 164, 170: return flag(x == y)
    case 165, 171: return flag(x != y)
    case 166: return flag(x != 0 || y != 0)
    case 167: return flag(x != 0 && y != 0)
    case 172: return flag(x > y)
    case 173: return flag(sx > sy)
    case 174: return flag(x >= y)
    case 175: return flag(sx >= sy)
    case 176: return flag(x < y)
    case 177: return flag(sx < sy)
    case 178: return flag(x <= y)
    default: return flag(sx <= sy)
    }
  }
}
