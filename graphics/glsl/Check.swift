// SPDX-License-Identifier: BSD-3-Clause

// Expressions (chapter 5): parsed by precedence, each checked as it is made against the language's rules (no implicit
// conversions, the operators' shapes of section 5.9, l-values, swizzles, constructors of section 5.4) and folded when
// it is a constant expression (Fold.swift).

extension Parser {
  // MARK: parsing

  mutating func expression() throws(SyntaxError) -> Expr {
    var e = try assignment()
    while at(",") {
      let c = tok
      k += 1
      let r = try assignment()
      if e.type.isError || r.type.isError {
        e = .error(c.at)
        continue
      }
      e = Expr(type: r.type, precision: r.precision, kind: .comma(e, r), at: c.at)
    }
    return e
  }

  static let assignOps: [String: BinaryOp?] = ["=": nil, "+=": .add, "-=": .sub, "*=": .mul, "/=": .div]
  static let reservedAssign: Set<String> = ["%=", "<<=", ">>=", "&=", "|=", "^="]

  mutating func assignment() throws(SyntaxError) -> Expr {
    let lhs = try conditional()
    if tok.kind == .punct, Parser.reservedAssign.contains(tok.text) {
      throw syntax("'\(tok.text)' is a reserved operator")
    }
    guard tok.kind == .punct, let op = Parser.assignOps[tok.text] else { return lhs }
    let o = tok
    k += 1
    let rhs = try assignment()
    return assign(op, lhs, rhs, at: o.at)
  }

  mutating func conditional() throws(SyntaxError) -> Expr {
    let c = try binary(0)
    guard at("?") else { return c }
    let q = tok
    k += 1
    let a = try expression()
    try expect(":")
    let b = try assignment()
    return select(c, a, b, at: q.at)
  }

  static let binaryPrecedence: [String: Int] = [
    "||": 1, "^^": 2, "&&": 3, "|": 4, "^": 5, "&": 6, "==": 7, "!=": 7, "<": 8, ">": 8, "<=": 8, ">=": 8,
    "<<": 9, ">>": 9, "+": 10, "-": 10, "*": 11, "/": 11, "%": 11,
  ]

  mutating func binary(_ minPrec: Int) throws(SyntaxError) -> Expr {
    var lhs = try unary()
    while tok.kind == .punct, let p = Parser.binaryPrecedence[tok.text], p > minPrec {
      let o = tok
      k += 1
      if ["|", "^", "&", "<<", ">>", "%"].contains(o.text) { throw syntax("'\(o.text)' is a reserved operator") }
      let rhs = try binary(p)
      let op: BinaryOp
      switch o.text {
      case "||": op = .or
      case "^^": op = .xor
      case "&&": op = .and
      case "==": op = .eq
      case "!=": op = .ne
      case "<": op = .lt
      case ">": op = .gt
      case "<=": op = .le
      case ">=": op = .ge
      case "+": op = .add
      case "-": op = .sub
      case "*": op = .mul
      default: op = .div
      }
      lhs = binaryOp(op, lhs, rhs, at: o.at)
    }
    return lhs
  }

  mutating func unary() throws(SyntaxError) -> Expr {
    let t = tok
    if t.is("~") { throw syntax("'~' is a reserved operator") }
    if t.is("-") || t.is("+") || t.is("!") {
      k += 1
      let e = try unary()
      return unaryOp(t.is("-") ? .neg : t.is("!") ? .not : .plus, e, at: t.at)
    }
    if t.is("++") || t.is("--") {
      k += 1
      let e = try unary()
      return increment(t.is("++"), prefix: true, e, at: t.at)
    }
    return try postfix()
  }

  mutating func postfix() throws(SyntaxError) -> Expr {
    var e = try primary()
    while true {
      let t = tok
      if t.is("[") {
        k += 1
        let i = try expression()
        try expect("]")
        e = index(e, i, at: t.at)
      } else if t.is(".") {
        k += 1
        guard tok.kind == .identifier else { throw syntax("syntax error: expected a field or a swizzle after '.', found \(describe(tok))") }
        let n = tok
        k += 1
        e = field(e, n)
      } else if t.is("++") || t.is("--") {
        k += 1
        e = increment(t.is("++"), prefix: false, e, at: t.at)
      } else {
        return e
      }
    }
  }

  mutating func primary() throws(SyntaxError) -> Expr {
    let t = tok
    switch t.kind {
    case .number:
      k += 1
      return number(t)
    case .identifier:
      if t.text == "true" || t.text == "false" {
        k += 1
        return Expr(type: .bool, precision: .none, kind: .constant, at: t.at, value: [.b(t.text == "true")])
      }
      if let ty = typeAt(t) {
        k += 1
        guard at("(") else { throw syntax("syntax error: unexpected type name '\(t.text)'") }
        let args = try arguments()
        return construct(ty, args, at: t.at)
      }
      if Parser.reserved.contains(t.text) { throw syntax("'\(t.text)' is a reserved keyword") }
      if Parser.keywords.contains(t.text) { throw syntax("syntax error: unexpected '\(t.text)'") }
      k += 1
      if at("(") {
        let args = try arguments()
        return call(t, args)
      }
      return variableReference(t)
    case .punct:
      if t.is("(") {
        k += 1
        let e = try expression()
        try expect(")")
        return e
      }
      throw syntax("syntax error: unexpected \(describe(t))")
    default:
      throw syntax("syntax error: unexpected \(describe(t))")
    }
  }

  mutating func arguments() throws(SyntaxError) -> [Expr] {
    try expect("(")
    var args: [Expr] = []
    if accept(")") { return args }
    if at("void") && peek().is(")") {
      k += 2
      return args
    }
    repeat { args.append(try assignment()) } while accept(",")
    try expect(")")
    return args
  }

  mutating func number(_ t: Token) -> Expr {
    let u = Array(t.text.utf8)
    let isFloat = u.contains(46) || (!(u.count > 1 && u[0] == 48 && (u[1] == 120 || u[1] == 88)) && (u.contains(101) || u.contains(69)))
    if isFloat {
      if u.last == 102 || u.last == 70 {
        diags.error(t.at, "'\(t.text)': a float constant has no suffix in GLSL ES 1.00")
        return .error(t.at)
      }
      guard let f = Float(t.text) else {
        diags.error(t.at, "'\(t.text)' is not a valid float constant")
        return .error(t.at)
      }
      return Expr(type: .float, precision: .none, kind: .constant, at: t.at, value: [.f(f)])
    }
    var v: UInt64? = nil
    if u.count > 2 && u[0] == 48 && (u[1] == 120 || u[1] == 88) {
      v = UInt64(String(decoding: u[2...], as: UTF8.self), radix: 16)
    } else if u.count > 1 && u[0] == 48 {
      v = UInt64(t.text, radix: 8)
    } else {
      v = UInt64(t.text)
    }
    guard let x = v else {
      diags.error(t.at, "'\(t.text)' is not a valid integer constant")
      return .error(t.at)
    }
    if x > 0xFFFF_FFFF {
      diags.error(t.at, "integer constant \(t.text) is too large")
      return .error(t.at)
    }
    return Expr(type: .int, precision: .none, kind: .constant, at: t.at, value: [.i(Int32(bitPattern: UInt32(x)))])
  }

  // MARK: names

  mutating func variableReference(_ t: Token) -> Expr {
    guard let s = lookup(t.text) else {
      diags.error(t.at, "'\(t.text)': undeclared identifier")
      return .error(t.at)
    }
    switch s {
    case .variable(let v):
      return reference(v, at: t.at)
    case .structure:
      diags.error(t.at, "'\(t.text)' is a structure, not a value")
    case .function:
      diags.error(t.at, "'\(t.text)' is a function, not a value")
    }
    return .error(t.at)
  }

  mutating func reference(_ v: Int, at: SourceLocation) -> Expr {
    let x = prog.variables[v]
    prog.variables[v].read = true
    if x.storage != .local && x.storage != .param && x.storage != .constant && !uses.contains(v) { uses.append(v) }
    var e = Expr(type: x.type, precision: x.precision, kind: .variable(v), at: at)
    if x.storage == .constant, let val = x.value { e.value = val }
    return e
  }

  // MARK: l-values

  /// The variable an l-value writes, or nil (with the error logged).
  mutating func lvalue(_ e: Expr, _ what: String) -> Int? {
    switch e.kind {
    case .variable(let v):
      let x = prog.variables[v]
      var why: String? = nil
      switch x.storage {
      case .constant: why = "a const variable"
      case .uniform: why = "a uniform"
      case .attribute: why = "an attribute"
      case .varying where prog.stage == .fragment: why = "a varying in a fragment shader"
      case .builtin where [.fragCoord, .frontFacing, .pointCoord, .depthRange].contains(x.builtin): why = "the read-only built-in \(x.name)"
      default: break
      }
      if let w = why {
        diags.error(e.at, "'\(x.name)': cannot \(what) \(w)")
        return nil
      }
      prog.variables[v].written = true
      if x.storage != .local && x.storage != .param && !uses.contains(v) { uses.append(v) }
      return v
    case .swizzle(let b, let c):
      for (i, a) in c.enumerated() where c[(i + 1)...].contains(a) {
        diags.error(e.at, "cannot \(what) a swizzle that names a component twice")
        return nil
      }
      return lvalue(b, what)
    case .index(let b, _), .field(let b, _):
      return lvalue(b, what)
    default:
      if !e.type.isError { diags.error(e.at, "cannot \(what) an expression that is not an l-value") }
      return nil
    }
  }

  // MARK: operators

  /// The type of an arithmetic operation's result (section 5.9), or nil.
  func arithmeticType(_ op: BinaryOp, _ a: GType, _ b: GType) -> GType? {
    guard a.isBasicValue, b.isBasicValue, a.basic == b.basic, a.isNumeric else { return nil }
    if a.isScalar && b.isScalar { return a }
    if a.isScalar { return b }
    if b.isScalar { return a }
    if a.isVector && b.isVector { return a.rows == b.rows ? a : nil }
    if a.isMatrix && b.isMatrix { return a.cols == b.cols ? a : nil }
    if op == .mul {
      if a.isMatrix && b.isVector && a.cols == b.rows { return b }
      if a.isVector && b.isMatrix && a.rows == b.rows { return a }
    }
    return nil
  }

  mutating func binaryOp(_ op: BinaryOp, _ a: Expr, _ b: Expr, at: SourceLocation) -> Expr {
    if a.type.isError || b.type.isError { return .error(at) }
    let names: [BinaryOp: String] = [
      .add: "+", .sub: "-", .mul: "*", .div: "/", .lt: "<", .gt: ">", .le: "<=", .ge: ">=", .eq: "==", .ne: "!=",
      .and: "&&", .or: "||", .xor: "^^",
    ]
    var t: GType? = nil
    switch op {
    case .add, .sub, .mul, .div: t = arithmeticType(op, a.type, b.type)
    case .lt, .gt, .le, .ge:
      if a.type == b.type && a.type.isScalar && a.type.isNumeric { t = .bool }
    case .eq, .ne:
      if a.type == b.type && !prog.hasArray(a.type) && !prog.hasSampler(a.type) && a.type.basic != .void { t = .bool }
    case .and, .or, .xor:
      if a.type == .bool && b.type == .bool { t = .bool }
    }
    guard let rt = t else {
      diags.error(at, "'\(names[op]!)' cannot take \(prog.name(a.type)) and \(prog.name(b.type))")
      return .error(at)
    }
    let p = (rt == .bool) ? Precision.none : max(a.precision, b.precision)
    var e = Expr(type: rt, precision: p, kind: .binary(op, a, b), at: at)
    e.value = Fold.binary(op, a, b, rt, prog)
    if op == .div, a.type.basic == .int, let bv = b.value, bv.contains(where: { $0 == .i(0) }) {
      diags.warning(at, "integer division by zero")
      e.value = nil
    }
    return e
  }

  mutating func unaryOp(_ op: UnaryOp, _ a: Expr, at: SourceLocation) -> Expr {
    if a.type.isError { return .error(at) }
    let ok = op == .not ? a.type == .bool : (a.type.isBasicValue && a.type.isNumeric)
    guard ok else {
      diags.error(at, "'\(op == .neg ? "-" : op == .plus ? "+" : "!")' cannot take \(prog.name(a.type))")
      return .error(at)
    }
    if op == .plus { return a }
    var e = Expr(type: a.type, precision: a.precision, kind: .unary(op, a), at: at)
    if let v = a.value {
      e.value = v.map { s in
        switch s {
        case .f(let x): return .f(-x)
        case .i(let x): return .i(0 &- x)
        case .b(let x): return .b(!x)
        }
      }
    }
    return e
  }

  mutating func increment(_ inc: Bool, prefix: Bool, _ a: Expr, at: SourceLocation) -> Expr {
    if a.type.isError { return .error(at) }
    guard a.type.isBasicValue && a.type.isNumeric else {
      diags.error(at, "'\(inc ? "++" : "--")' cannot take \(prog.name(a.type))")
      return .error(at)
    }
    guard lvalue(a, inc ? "increment" : "decrement") != nil else { return .error(at) }
    return Expr(type: a.type, precision: a.precision, kind: .increment(inc, prefix: prefix, a), at: at)
  }

  mutating func assign(_ op: BinaryOp?, _ l: Expr, _ r: Expr, at: SourceLocation) -> Expr {
    if l.type.isError || r.type.isError {
      _ = l.type.isError ? nil : lvalue(l, "assign to")
      return .error(at)
    }
    guard lvalue(l, "assign to") != nil else { return .error(at) }
    if let o = op {
      guard arithmeticType(o, l.type, r.type) == l.type else {
        diags.error(at, "'\(["+", "-", "*", "/"][Int(o.rawValue)])=' cannot take \(prog.name(l.type)) and \(prog.name(r.type))")
        return .error(at)
      }
    } else {
      if prog.hasArray(l.type) && l.type.isArray {
        diags.error(at, "an array cannot be assigned")
        return .error(at)
      }
      if prog.hasSampler(l.type) {
        diags.error(at, "a sampler cannot be assigned")
        return .error(at)
      }
      guard l.type == r.type else {
        diags.error(at, "cannot assign a \(prog.name(r.type)) to a \(prog.name(l.type))")
        return .error(at)
      }
    }
    return Expr(type: l.type, precision: l.precision, kind: .assign(op, l, r), at: at)
  }

  mutating func select(_ c: Expr, _ a: Expr, _ b: Expr, at: SourceLocation) -> Expr {
    if c.type.isError || a.type.isError || b.type.isError { return .error(at) }
    guard c.type == .bool else {
      diags.error(c.at, "the condition of '?:' must be a bool, not \(prog.name(c.type))")
      return .error(at)
    }
    guard a.type == b.type, !a.type.isArray, !prog.hasSampler(a.type) else {
      diags.error(at, "the two sides of '?:' must have the same type (not an array), not \(prog.name(a.type)) and \(prog.name(b.type))")
      return .error(at)
    }
    var e = Expr(type: a.type, precision: max(a.precision, b.precision), kind: .select(c, a, b), at: at)
    if let cv = c.value, let av = a.value, let bv = b.value { e.value = cv[0].bool ? av : bv }
    return e
  }

  // MARK: fields, swizzles and indices

  mutating func field(_ e: Expr, _ n: Token) -> Expr {
    if e.type.isError { return .error(n.at) }
    if e.type.isStruct {
      let s = prog.structs[e.type.structID]
      guard let i = s.members.firstIndex(where: { $0.name == n.text }) else {
        diags.error(n.at, "'\(n.text)' is not a member of structure \(s.name)")
        return .error(n.at)
      }
      var r = Expr(type: s.members[i].type, precision: s.members[i].precision, kind: .field(e, i), at: n.at)
      if let v = e.value {
        var off = 0
        for m in s.members[..<i] { off += prog.flatCount(m.type) }
        r.value = Array(v[off..<(off + prog.flatCount(s.members[i].type))])
      }
      return r
    }
    guard e.type.isVector else {
      diags.error(n.at, "'.\(n.text)' on \(prog.name(e.type)): only a vector has components and only a structure members")
      return .error(n.at)
    }
    let sets: [[UInt8]] = [Array("xyzw".utf8), Array("rgba".utf8), Array("stpq".utf8)]
    let chars = Array(n.text.utf8)
    var set = -1
    var comps: [Int] = []
    for c in chars {
      var found = false
      for (si, s) in sets.enumerated() {
        if let j = s.firstIndex(of: c) {
          if set >= 0 && set != si {
            diags.error(n.at, "swizzle '\(n.text)' mixes the component sets xyzw, rgba and stpq")
            return .error(n.at)
          }
          set = si
          comps.append(j)
          found = true
        }
      }
      if !found {
        diags.error(n.at, "'\(n.text)' is not a swizzle of \(prog.name(e.type))")
        return .error(n.at)
      }
    }
    guard comps.count <= 4, !comps.isEmpty else {
      diags.error(n.at, "swizzle '\(n.text)' has more than four components")
      return .error(n.at)
    }
    for c in comps where c >= e.type.rows {
      diags.error(n.at, "swizzle '\(n.text)' names a component \(prog.name(e.type)) does not have")
      return .error(n.at)
    }
    let t = GType(basic: e.type.basic, rows: comps.count)
    var r = Expr(type: t, precision: e.precision, kind: .swizzle(e, comps), at: n.at)
    if let v = e.value { r.value = comps.map { v[$0] } }
    return r
  }

  mutating func index(_ e: Expr, _ i: Expr, at: SourceLocation) -> Expr {
    if e.type.isError || i.type.isError { return .error(at) }
    guard i.type == .int else {
      diags.error(i.at, "an index must be an int, not \(prog.name(i.type))")
      return .error(at)
    }
    var t: GType
    var bound: Int
    if e.type.isArray {
      t = e.type.element
      bound = e.type.arraySize
    } else if e.type.isMatrix {
      t = e.type.column
      bound = e.type.cols
    } else if e.type.isVector {
      t = e.type.scalar
      bound = e.type.rows
    } else {
      diags.error(at, "\(prog.name(e.type)) cannot be indexed")
      return .error(at)
    }
    var r = Expr(type: t, precision: e.precision, kind: .index(e, i), at: at)
    if let iv = i.value {
      let n = Int(iv[0].int)
      if n < 0 || n >= bound {
        diags.error(i.at, "index \(n) is out of range (\(prog.name(e.type)) has \(bound))")
        return .error(at)
      }
      if let v = e.value {
        let w = prog.flatCount(t)
        r.value = Array(v[(n * w)..<((n + 1) * w)])
      }
    }
    return r
  }

  // MARK: calls and constructors

  mutating func call(_ name: Token, _ args: [Expr]) -> Expr {
    if args.contains(where: { $0.type.isError }) { return .error(name.at) }
    if let s = lookup(name.text) {
      switch s {
      case .variable:
        diags.error(name.at, "'\(name.text)' is a variable, not a function")
        return .error(name.at)
      case .structure(let id):
        return construct(GType(basic: .structure, structID: id), args, at: name.at)
      case .function:
        break
      }
    }
    if let fs = overloads[name.text], lookup(name.text) != nil {
      for f in fs {
        let def = prog.functions[f]
        guard def.params.count == args.count else { continue }
        var ok = true
        for (p, a) in zip(def.params, args) where prog.variables[p].type != a.type { ok = false }
        if !ok { continue }
        for (p, a) in zip(def.params, args) where prog.variables[p].qualifier != .in {
          _ = lvalue(a, "pass as an out or inout argument")
        }
        if function >= 0 && !calls.contains(f) { calls.append(f) }
        if function < 0 {
          diags.error(name.at, "a global initializer cannot call a function")
          return .error(name.at)
        }
        return Expr(type: def.returnType, precision: def.returnPrecision, kind: .call(f, args), at: name.at)
      }
      diags.error(name.at, "no overload of '\(name.text)' takes (\(args.map { prog.name($0.type) }.joined(separator: ", ")))")
      return .error(name.at)
    }
    if builtinFunctionNames.contains(name.text) { return builtinCall(name, args) }
    diags.error(name.at, "'\(name.text)': no such function")
    return .error(name.at)
  }

  mutating func construct(_ t: GType, _ args: [Expr], at: SourceLocation) -> Expr {
    if args.contains(where: { $0.type.isError }) { return .error(at) }
    let tn = prog.name(t)
    if t.basic == .void || t.isSampler {
      diags.error(at, "\(tn) has no constructor")
      return .error(at)
    }
    if args.isEmpty {
      diags.error(at, "a constructor of \(tn) needs arguments")
      return .error(at)
    }
    var p = Precision.none
    for a in args { p = max(p, a.precision) }
    if t.isStruct {
      let s = prog.structs[t.structID]
      guard args.count == s.members.count else {
        diags.error(at, "structure \(s.name) has \(s.members.count) members; its constructor was given \(args.count) arguments")
        return .error(at)
      }
      for (m, a) in zip(s.members, args) where m.type != a.type {
        diags.error(a.at, "member \(m.name) of \(s.name) is \(prog.name(m.type)), not \(prog.name(a.type))")
        return .error(at)
      }
      var e = Expr(type: t, precision: .none, kind: .construct(args), at: at)
      if args.allSatisfy({ $0.value != nil }) { e.value = args.flatMap { $0.value! } }
      return e
    }
    for a in args where !a.type.isBasicValue {
      diags.error(a.at, "a constructor of \(tn) cannot take \(prog.name(a.type))")
      return .error(at)
    }
    let need = t.components
    if t.isMatrix && args.count > 1 && args.contains(where: { $0.type.isMatrix }) {
      diags.error(at, "a matrix constructed from a matrix takes that one argument")
      return .error(at)
    }
    if !(args.count == 1 && (args[0].type.isScalar || (t.isMatrix && args[0].type.isMatrix))) {
      var have = 0
      for (i, a) in args.enumerated() {
        if have >= need {
          diags.error(args[i].at, "too many arguments to a constructor of \(tn)")
          return .error(at)
        }
        have += a.type.components
      }
      if have < need && !(t.isScalar) {
        diags.error(at, "too few components for a constructor of \(tn): \(have) of \(need)")
        return .error(at)
      }
      if t.isScalar && args.count > 1 {
        diags.error(at, "a constructor of \(tn) takes one argument")
        return .error(at)
      }
    }
    var e = Expr(type: t, precision: t.basic == .bool ? .none : p, kind: .construct(args), at: at)
    e.value = Fold.construct(t, args)
    return e
  }

  /// A constant expression (section 4.3.3), whether or not the compiler folds its value: what a const variable's and a
  /// global's initializer must be.
  func isConstantExpression(_ e: Expr) -> Bool {
    if e.value != nil { return true }
    switch e.kind {
    case .constant: return true
    case .variable(let v): return prog.variables[v].storage == .constant
    case .swizzle(let b, _), .field(let b, _): return isConstantExpression(b)
    case .index(let b, let i): return isConstantExpression(b) && isConstantExpression(i)
    case .unary(_, let a): return isConstantExpression(a)
    case .binary(_, let a, let b): return isConstantExpression(a) && isConstantExpression(b)
    case .select(let c, let a, let b): return isConstantExpression(c) && isConstantExpression(a) && isConstantExpression(b)
    case .construct(let args): return args.allSatisfy { isConstantExpression($0) }
    case .builtin(let f, let args):
      switch f {
      case .texture2D, .texture2DBias, .texture2DProj, .texture2DProjBias, .texture2DLod, .texture2DProjLod, .textureCube,
        .textureCubeBias, .textureCubeLod, .dFdx, .dFdy, .fwidth:
        return false
      default: return args.allSatisfy { isConstantExpression($0) }
      }
    default: return false
    }
  }
}
