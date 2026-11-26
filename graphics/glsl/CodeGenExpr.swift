// SPDX-License-Identifier: BSD-3-Clause

// Expressions into SPIR-V: operators, constructors, the built-in functions (GLSL.std.450 and the core's own
// instructions), and the calls of user functions, inlined.

extension CodeGen {
  /// The expression's value, of its logical type.
  mutating func value(_ e: Expr) -> UInt32 {
    if let v = e.value, !prog.hasSampler(e.type) { return constant(e.type, v) }
    let relaxed = e.precision.relaxed
    switch e.kind {
    case .constant: return constant(e.type, e.value ?? [.f(0)])
    case .variable, .field, .index, .swizzle:
      let r = ref(e)
      if case .value(let x) = r.root, r.steps.isEmpty, r.swizzle == nil { return x }
      return load(r, relaxed: relaxed)
    case .unary(let op, let a):
      let x = value(a)
      if op == .not { return emit(SpvOp.logicalNot, b.bool, [x]) }
      return negate(x, a.type, relaxed: relaxed)
    case .binary(let op, let l, let r):
      return binary(op, l, r, e)
    case .assign(let op, let l, let r):
      let lr = ref(l)
      var v = value(r)
      if let o = op {
        let old = load(lr, relaxed: relaxed)
        v = arith(o, old, l.type, v, r.type, l.type, relaxed: relaxed)
      }
      store(lr, v)
      return v
    case .increment(let inc, let prefix, let a):
      let lr = ref(a)
      let old = load(lr, relaxed: relaxed)
      let nv = arith(inc ? .add : .sub, old, a.type, one(a.type), a.type, a.type, relaxed: relaxed)
      store(lr, nv)
      return prefix ? nv : old
    case .select(let c, let x, let y):
      return select(c, x, y, e)
    case .comma(let a, let c):
      _ = value(a)
      return value(c)
    case .call(let f, let args):
      return inline(f, args) ?? b.undef(ty(e.type))
    case .builtin(let f, let args):
      return builtin(f, args, e)
    case .construct(let args):
      return construct(e.type, args, relaxed: relaxed)
    case .declare(let v, let i):
      let x = value(i)
      let p = place(v)
      if case .memory(let ptr, _, _, _) = p { emitVoid(SpvOp.store, [ptr, x]) }
      return x
    }
  }

  /// The expression has no effect but its value: it can be computed whether or not it is needed.
  func pure(_ e: Expr) -> Bool {
    if e.value != nil { return true }
    switch e.kind {
    case .constant, .variable: return true
    case .field(let a, _), .swizzle(let a, _), .unary(_, let a): return pure(a)
    case .index(let a, let i): return pure(a) && pure(i)
    case .binary(_, let a, let c): return pure(a) && pure(c)
    case .select(let c, let a, let d): return pure(c) && pure(a) && pure(d)
    case .construct(let args), .builtin(_, let args): return args.allSatisfy { pure($0) }
    default: return false
    }
  }

  /// A pure expression cheap enough to compute on both sides of a branch.
  func cheap(_ e: Expr, _ budget: Int = 24) -> Bool { pure(e) && cost(e) <= budget }

  func cost(_ e: Expr) -> Int {
    if e.value != nil { return 0 }
    switch e.kind {
    case .constant, .variable: return 1
    case .field(let a, _), .swizzle(let a, _), .unary(_, let a): return 1 + cost(a)
    case .index(let a, let i): return 1 + cost(a) + cost(i)
    case .binary(_, let a, let c): return e.type.components + cost(a) + cost(c)
    case .select(let c, let a, let d): return 1 + cost(c) + cost(a) + cost(d)
    case .construct(let args): return args.reduce(1) { $0 + cost($1) }
    case .builtin(let f, let args):
      let own = [BuiltinFunction.texture2D, .texture2DBias, .texture2DProj, .texture2DProjBias, .texture2DLod, .texture2DProjLod,
        .textureCube, .textureCubeBias, .textureCubeLod].contains(f) ? 100 : 4 * e.type.components
      return args.reduce(own) { $0 + cost($1) }
    default: return 1000
    }
  }

  // MARK: arithmetic

  mutating func negate(_ x: UInt32, _ t: GType, relaxed: Bool) -> UInt32 {
    if t.isMatrix {
      var cols: [UInt32] = []
      for c in 0..<t.cols {
        let col = emit(SpvOp.compositeExtract, ty(t.column), [x, UInt32(c)])
        cols.append(emit(SpvOp.fNegate, ty(t.column), [col], relaxed: relaxed))
      }
      return emit(SpvOp.compositeConstruct, ty(t), cols)
    }
    return emit(t.basic == .float ? SpvOp.fNegate : SpvOp.sNegate, ty(t), [x], relaxed: relaxed)
  }

  mutating func column(_ m: UInt32, _ t: GType, _ c: Int) -> UInt32 { emit(SpvOp.compositeExtract, ty(t.column), [m, UInt32(c)]) }

  /// An arithmetic operation of section 5.9 on values: component-wise, a scalar spread over a vector or a matrix, or
  /// linear algebra for a matrix product.
  mutating func arith(_ op: BinaryOp, _ a: UInt32, _ at: GType, _ c: UInt32, _ ct: GType, _ rt: GType, relaxed: Bool) -> UInt32 {
    let float = rt.basic == .float
    if at.isMatrix || ct.isMatrix {
      if op == .mul && !(at.isScalar || ct.isScalar) {
        if at.isMatrix && ct.isMatrix {
          var cols: [UInt32] = []
          for j in 0..<ct.cols { cols.append(matrixTimesVector(a, at, column(c, ct, j), relaxed: relaxed)) }
          return emit(SpvOp.compositeConstruct, ty(rt), cols)
        }
        if at.isMatrix { return matrixTimesVector(a, at, c, relaxed: relaxed) }
        // A vector times a matrix: each component a column's dot product.
        var comps: [UInt32] = []
        for j in 0..<ct.cols { comps.append(emit(SpvOp.dot, b.float, [a, column(c, ct, j)], relaxed: relaxed)) }
        return emit(SpvOp.compositeConstruct, ty(rt), comps)
      }
      var cols: [UInt32] = []
      for j in 0..<rt.cols {
        let x = at.isMatrix ? column(a, at, j) : a
        let y = ct.isMatrix ? column(c, ct, j) : c
        cols.append(arith(op, x, at.isMatrix ? at.column : at, y, ct.isMatrix ? ct.column : ct, rt.column, relaxed: relaxed))
      }
      return emit(SpvOp.compositeConstruct, ty(rt), cols)
    }
    var x = a
    var y = c
    if op == .mul && float && at.isScalar != ct.isScalar {
      return at.isScalar
        ? emit(SpvOp.vectorTimesScalar, ty(rt), [c, a], relaxed: relaxed) : emit(SpvOp.vectorTimesScalar, ty(rt), [a, c], relaxed: relaxed)
    }
    if at.isScalar && !ct.isScalar { x = splat(a, rt) }
    if ct.isScalar && !at.isScalar { y = splat(c, rt) }
    let ops: [BinaryOp: (UInt16, UInt16)] = [
      .add: (SpvOp.fAdd, SpvOp.iAdd), .sub: (SpvOp.fSub, SpvOp.iSub), .mul: (SpvOp.fMul, SpvOp.iMul), .div: (SpvOp.fDiv, SpvOp.sDiv),
    ]
    let o = ops[op]!
    return emit(float ? o.0 : o.1, ty(rt), [x, y], relaxed: relaxed && float)
  }

  /// m * v: the first column times v.x, then a fused multiply-add of each other column.
  mutating func matrixTimesVector(_ m: UInt32, _ mt: GType, _ v: UInt32, relaxed: Bool) -> UInt32 {
    let ct = mt.column
    var acc = emit(SpvOp.vectorTimesScalar, ty(ct), [column(m, mt, 0), emit(SpvOp.compositeExtract, b.float, [v, 0])], relaxed: relaxed)
    for c in 1..<mt.cols {
      let s = splat(emit(SpvOp.compositeExtract, b.float, [v, UInt32(c)]), ct)
      acc = ext(50, ty(ct), [column(m, mt, c), s, acc], relaxed: relaxed)
    }
    return acc
  }

  mutating func binary(_ op: BinaryOp, _ l: Expr, _ r: Expr, _ e: Expr) -> UInt32 {
    let relaxed = e.precision.relaxed
    switch op {
    case .add, .sub, .mul, .div:
      let x = value(l)
      let y = value(r)
      return arith(op, x, l.type, y, r.type, e.type, relaxed: relaxed)
    case .lt, .gt, .le, .ge:
      let x = value(l)
      let y = value(r)
      let f = l.type.basic == .float
      let o: UInt16
      switch op {
      case .lt: o = f ? SpvOp.fOrdLessThan : SpvOp.sLessThan
      case .gt: o = f ? SpvOp.fOrdGreaterThan : SpvOp.sGreaterThan
      case .le: o = f ? SpvOp.fOrdLessThanEqual : SpvOp.sLessThanEqual
      default: o = f ? SpvOp.fOrdGreaterThanEqual : SpvOp.sGreaterThanEqual
      }
      return emit(o, b.bool, [x, y])
    case .eq, .ne:
      let x = value(l)
      let y = value(r)
      return equality(x, y, l.type, equal: op == .eq)
    case .xor:
      return emit(SpvOp.logicalNotEqual, b.bool, [value(l), value(r)])
    case .and, .or:
      if pure(r) && cheap(r) {
        return emit(op == .and ? SpvOp.logicalAnd : SpvOp.logicalOr, b.bool, [value(l), value(r)])
      }
      // Short-circuit: the right side only when it decides.
      let x = value(l)
      let from = currentLabel
      let rhs = b.id()
      let merge = b.id()
      emitVoid(SpvOp.selectionMerge, [merge, 0])
      emitVoid(SpvOp.branchConditional, op == .and ? [x, rhs, merge] : [x, merge, rhs])
      label(rhs)
      let y = value(r)
      let rhsEnd = currentLabel
      branch(merge)
      label(merge)
      return emit(SpvOp.phi, b.bool, [b.constant(bool: op == .or), from, y, rhsEnd])
    }
  }

  /// `==` (or `!=`) of two values of type t: every component equal.
  mutating func equality(_ x: UInt32, _ y: UInt32, _ t: GType, equal: Bool) -> UInt32 {
    var r: UInt32
    if t.isStruct || t.isMatrix {
      var parts: [UInt32] = []
      if t.isMatrix {
        for c in 0..<t.cols { parts.append(equality(column(x, t, c), column(y, t, c), t.column, equal: true)) }
      } else {
        var k = 0
        for m in prog.structs[t.structID].members where !m.type.isSampler {
          let a = emit(SpvOp.compositeExtract, ty(m.type), [x, UInt32(k)])
          let c = emit(SpvOp.compositeExtract, ty(m.type), [y, UInt32(k)])
          parts.append(equality(a, c, m.type, equal: true))
          k += 1
        }
      }
      r = parts[0]
      for p in parts.dropFirst() { r = emit(SpvOp.logicalAnd, b.bool, [r, p]) }
      return equal ? r : emit(SpvOp.logicalNot, b.bool, [r])
    }
    let o: UInt16
    switch t.basic {
    case .float: o = equal ? SpvOp.fOrdEqual : SpvOp.fUnordNotEqual
    case .int: o = equal ? SpvOp.iEqual : SpvOp.iNotEqual
    default: o = equal ? SpvOp.logicalEqual : SpvOp.logicalNotEqual
    }
    r = emit(o, b.vector(b.bool, t.rows), [x, y])
    if t.rows > 1 { r = emit(equal ? SpvOp.all : SpvOp.any, b.bool, [r]) }
    return r
  }

  mutating func select(_ c: Expr, _ x: Expr, _ y: Expr, _ e: Expr) -> UInt32 {
    let t = e.type
    if cheap(x) && cheap(y) && (t.isScalar || t.isVector || t.isMatrix) {
      let cv = value(c)
      let a = value(x)
      let d = value(y)
      return selectValues(cv, a, d, t)
    }
    let cv = value(c)
    let thenL = b.id()
    let elseL = b.id()
    let merge = b.id()
    emitVoid(SpvOp.selectionMerge, [merge, 0])
    emitVoid(SpvOp.branchConditional, [cv, thenL, elseL])
    label(thenL)
    let a = value(x)
    let aEnd = currentLabel
    branch(merge)
    label(elseL)
    let d = value(y)
    let dEnd = currentLabel
    branch(merge)
    label(merge)
    return emit(SpvOp.phi, ty(t), [a, aEnd, d, dEnd])
  }

  /// SPIR-V 1.0's OpSelect wants a condition of the value's width: a matrix is selected column by column.
  mutating func selectValues(_ c: UInt32, _ a: UInt32, _ d: UInt32, _ t: GType) -> UInt32 {
    if t.isMatrix {
      var cols: [UInt32] = []
      for k in 0..<t.cols { cols.append(selectValues(c, column(a, t, k), column(d, t, k), t.column)) }
      return emit(SpvOp.compositeConstruct, ty(t), cols)
    }
    let cc = t.rows > 1 ? emit(SpvOp.compositeConstruct, b.vector(b.bool, t.rows), [UInt32](repeating: c, count: t.rows)) : c
    return emit(SpvOp.select, ty(t), [cc, a, d])
  }

  // MARK: constructors

  /// The scalar components of a value: a vector's, a matrix's column by column.
  mutating func components(_ x: UInt32, _ t: GType) -> [UInt32] {
    if t.isScalar { return [x] }
    if t.isMatrix {
      var r: [UInt32] = []
      for c in 0..<t.cols { r += components(column(x, t, c), t.column) }
      return r
    }
    return (0..<t.rows).map { emit(SpvOp.compositeExtract, ty(t.scalar), [x, UInt32($0)]) }
  }

  /// A scalar converted between float, int and bool, as the constructors convert (section 5.4.1).
  mutating func convert(_ x: UInt32, from: Basic, to: Basic) -> UInt32 {
    if from == to { return x }
    switch (from, to) {
    case (.int, .float): return emit(SpvOp.convertSToF, b.float, [x])
    case (.float, .int): return emit(SpvOp.convertFToS, b.int, [x])
    case (.bool, .float): return emit(SpvOp.select, b.float, [x, b.constant(float: 1), b.constant(float: 0)])
    case (.bool, .int): return emit(SpvOp.select, b.int, [x, b.constant(int: 1), b.constant(int: 0)])
    case (.float, .bool): return emit(SpvOp.fUnordNotEqual, b.bool, [x, b.constant(float: 0)])
    default: return emit(SpvOp.iNotEqual, b.bool, [x, b.constant(int: 0)])
    }
  }

  mutating func construct(_ t: GType, _ args: [Expr], relaxed: Bool) -> UInt32 {
    if t.isStruct { return emit(SpvOp.compositeConstruct, ty(t), args.map { value($0) }) }
    let vals = args.map { value($0) }
    // A vector made of vectors and scalars of its own type, exactly: one construct.
    if t.isVector && args.count > 1 && args.allSatisfy({ $0.type.basic == t.basic && ($0.type.isScalar || $0.type.isVector) })
      && args.reduce(0, { $0 + $1.type.components }) == t.rows
    {
      return emit(SpvOp.compositeConstruct, ty(t), vals)
    }
    if args.count == 1 && args[0].type == t { return vals[0] }
    let a0 = args[0].type
    if args.count == 1 && a0.isScalar && !t.isScalar {
      let s = convert(vals[0], from: a0.basic, to: t.basic)
      if t.isVector { return splat(s, t) }
      // A matrix's diagonal.
      let zero = b.constant(float: 0)
      var cols: [UInt32] = []
      for c in 0..<t.cols {
        cols.append(emit(SpvOp.compositeConstruct, ty(t.column), (0..<t.rows).map { $0 == c ? s : zero }))
      }
      return emit(SpvOp.compositeConstruct, ty(t), cols)
    }
    if args.count == 1 && a0.isMatrix && t.isMatrix {
      var cols: [UInt32] = []
      for c in 0..<t.cols {
        if c < a0.cols {
          let src = column(vals[0], a0, c)
          if a0.rows == t.rows {
            cols.append(src)
          } else if a0.rows > t.rows {
            cols.append(emit(SpvOp.vectorShuffle, ty(t.column), [src, src] + (0..<t.rows).map { UInt32($0) }))
          } else {
            var parts = components(src, a0.column)
            for r in a0.rows..<t.rows { parts.append(b.constant(float: r == c ? 1 : 0)) }
            cols.append(emit(SpvOp.compositeConstruct, ty(t.column), parts))
          }
        } else {
          cols.append(constant(t.column, (0..<t.rows).map { .f($0 == c ? 1 : 0) }))
        }
      }
      return emit(SpvOp.compositeConstruct, ty(t), cols)
    }
    // Component by component, each converted, as many as the type takes.
    var comps: [UInt32] = []
    for (a, v) in zip(args, vals) {
      if comps.count >= t.components { break }
      for c in components(v, a.type) {
        if comps.count >= t.components { break }
        comps.append(convert(c, from: a.type.basic, to: t.basic))
      }
    }
    if t.isScalar { return comps[0] }
    if t.isVector { return emit(SpvOp.compositeConstruct, ty(t), comps) }
    var cols: [UInt32] = []
    for c in 0..<t.cols {
      cols.append(emit(SpvOp.compositeConstruct, ty(t.column), Array(comps[(c * t.rows)..<((c + 1) * t.rows)])))
    }
    return emit(SpvOp.compositeConstruct, ty(t), cols)
  }

  // MARK: built-in functions

  mutating func builtin(_ f: BuiltinFunction, _ args: [Expr], _ e: Expr) -> UInt32 {
    let relaxed = e.precision.relaxed
    let rt = ty(e.type)
    // A sampler argument is a reference; the rest are values.
    if [.texture2D, .texture2DBias, .texture2DProj, .texture2DProjBias, .texture2DLod, .texture2DProjLod, .textureCube,
      .textureCubeBias, .textureCubeLod].contains(f)
    {
      let s = load(ref(args[0]))
      let coord = value(args[1])
      let v4 = b.vector(b.float, 4)
      let proj = f == .texture2DProj || f == .texture2DProjBias || f == .texture2DProjLod
      var p = coord
      if proj && args[1].type.rows == 4 {
        // (s, t, q) of an (s, t, r, q).
        p = emit(SpvOp.vectorShuffle, b.vector(b.float, 3), [coord, coord, 0, 1, 3])
      }
      switch f {
      case .texture2DBias, .texture2DProjBias, .textureCubeBias:
        return emit(proj ? SpvOp.imageSampleProjImplicitLod : SpvOp.imageSampleImplicitLod, v4, [s, p, 1, value(args[2])], relaxed: relaxed)
      case .texture2DLod, .texture2DProjLod, .textureCubeLod:
        return emit(proj ? SpvOp.imageSampleProjExplicitLod : SpvOp.imageSampleExplicitLod, v4, [s, p, 2, value(args[2])], relaxed: relaxed)
      default:
        if prog.stage == .vertex {
          // A vertex shader has no derivatives: level 0.
          return emit(proj ? SpvOp.imageSampleProjExplicitLod : SpvOp.imageSampleExplicitLod, v4, [s, p, 2, b.constant(float: 0)], relaxed: relaxed)
        }
        return emit(proj ? SpvOp.imageSampleProjImplicitLod : SpvOp.imageSampleImplicitLod, v4, [s, p], relaxed: relaxed)
      }
    }
    var a = args.map { value($0) }
    let t = e.type
    /// The arguments spread to the result's width where the signature takes a float for a vector.
    func widen(_ i: Int) -> UInt32 { args[i].type.isScalar && !t.isScalar && t.basic == .float ? splat(a[i], t) : a[i] }
    let one: [BuiltinFunction: UInt32] = [
      .radians: 11, .degrees: 12, .sin: 13, .cos: 14, .tan: 15, .asin: 16, .acos: 17, .atan: 18, .exp: 27, .log: 28,
      .exp2: 29, .log2: 30, .sqrt: 31, .inversesqrt: 32, .abs: 4, .sign: 6, .floor: 8, .ceil: 9, .fract: 10, .normalize: 69,
    ]
    if let n = one[f] { return ext(n, rt, [a[0]], relaxed: relaxed) }
    switch f {
    case .atan2: return ext(25, rt, [a[0], a[1]], relaxed: relaxed)
    case .pow: return ext(26, rt, [a[0], a[1]], relaxed: relaxed)
    case .min: return ext(37, rt, [a[0], widen(1)], relaxed: relaxed)
    case .max: return ext(40, rt, [a[0], widen(1)], relaxed: relaxed)
    case .clamp: return ext(43, rt, [a[0], widen(1), widen(2)], relaxed: relaxed)
    case .mix: return ext(46, rt, [a[0], a[1], widen(2)], relaxed: relaxed)
    case .step: return ext(48, rt, [widen(0), a[1]], relaxed: relaxed)
    case .smoothstep: return ext(49, rt, [widen(0), widen(1), a[2]], relaxed: relaxed)
    case .mod:
      // x - y * floor(x / y), as section 8.3 defines it.
      let y = widen(1)
      let q = emit(SpvOp.fDiv, rt, [a[0], y], relaxed: relaxed)
      let fl = ext(8, rt, [q], relaxed: relaxed)
      let p = emit(SpvOp.fMul, rt, [y, fl], relaxed: relaxed)
      return emit(SpvOp.fSub, rt, [a[0], p], relaxed: relaxed)
    case .length: return ext(66, rt, [a[0]], relaxed: relaxed)
    case .distance: return ext(67, rt, [a[0], a[1]], relaxed: relaxed)
    case .dot:
      if args[0].type.isScalar { return emit(SpvOp.fMul, rt, [a[0], a[1]], relaxed: relaxed) }
      return emit(SpvOp.dot, rt, [a[0], a[1]], relaxed: relaxed)
    case .cross: return ext(68, rt, [a[0], a[1]], relaxed: relaxed)
    case .faceforward: return ext(70, rt, [a[0], a[1], a[2]], relaxed: relaxed)
    case .reflect: return ext(71, rt, [a[0], a[1]], relaxed: relaxed)
    case .refract: return ext(72, rt, [a[0], a[1], a[2]], relaxed: relaxed)
    case .matrixCompMult:
      var cols: [UInt32] = []
      for c in 0..<t.cols {
        cols.append(emit(SpvOp.fMul, ty(t.column), [column(a[0], t, c), column(a[1], t, c)], relaxed: relaxed))
      }
      return emit(SpvOp.compositeConstruct, rt, cols)
    case .lessThan, .lessThanEqual, .greaterThan, .greaterThanEqual, .equal, .notEqual:
      let at = args[0].type
      let fl = at.basic == .float
      let o: UInt16
      switch f {
      case .lessThan: o = fl ? SpvOp.fOrdLessThan : SpvOp.sLessThan
      case .lessThanEqual: o = fl ? SpvOp.fOrdLessThanEqual : SpvOp.sLessThanEqual
      case .greaterThan: o = fl ? SpvOp.fOrdGreaterThan : SpvOp.sGreaterThan
      case .greaterThanEqual: o = fl ? SpvOp.fOrdGreaterThanEqual : SpvOp.sGreaterThanEqual
      case .equal: o = fl ? SpvOp.fOrdEqual : at.basic == .int ? SpvOp.iEqual : SpvOp.logicalEqual
      default: o = fl ? SpvOp.fUnordNotEqual : at.basic == .int ? SpvOp.iNotEqual : SpvOp.logicalNotEqual
      }
      return emit(o, rt, [a[0], a[1]])
    case .any: return emit(SpvOp.any, b.bool, [a[0]])
    case .all: return emit(SpvOp.all, b.bool, [a[0]])
    case .not: return emit(SpvOp.logicalNot, rt, [a[0]])
    case .dFdx: return emit(SpvOp.dPdx, rt, [a[0]], relaxed: relaxed)
    case .dFdy: return emit(SpvOp.dPdy, rt, [a[0]], relaxed: relaxed)
    case .fwidth: return emit(SpvOp.fwidth, rt, [a[0]], relaxed: relaxed)
    default:
      a = []
      errors.append("built-in function \(f) has no code")
      return b.undef(rt)
    }
  }
}
