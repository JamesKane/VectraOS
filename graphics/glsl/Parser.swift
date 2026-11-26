// SPDX-License-Identifier: BSD-3-Clause

// The GLSL ES 1.00 parser (the grammar of chapter 9) and the checks of declarations and statements (chapters 4 and
// 6). It checks as it parses, in one pass, since the language declares everything before its use; the checks of
// expressions are in Check.swift, the built-ins in Builtins.swift. A syntax error ends the parse; a semantic error
// is logged and the parse goes on, the erroneous expression typed `error` so it causes no more messages.

struct SyntaxError: Error {}

enum Symbol {
  case variable(Int)
  case structure(Int)
  /// One or more user functions by this name.
  case function
}

struct Parser {
  var ts: [Token]
  var k = 0
  var diags: Diagnostics
  var prog: Program
  var limits: GLSLLimits
  var derivatives: Bool
  var scopes: [[String: Symbol]] = [[:]]
  /// The default precisions, a dictionary a scope (float, int, sampler2D, samplerCube).
  var precisions: [[Basic: Precision]] = []
  var overloads: [String: [Int]] = [:]
  var function = -1
  var loops = 0
  /// The global variables the function being parsed uses (or the global initializers', when -1).
  var uses: [Int] = []
  var globalUses: [Int] = []
  var calls: [Int] = []

  static let reserved: Set<String> = [
    "asm", "class", "union", "enum", "typedef", "template", "this", "packed", "goto", "switch", "default", "inline",
    "noinline", "volatile", "public", "static", "extern", "external", "interface", "flat", "long", "short", "double",
    "half", "fixed", "unsigned", "superp", "input", "output", "hvec2", "hvec3", "hvec4", "dvec2", "dvec3", "dvec4",
    "fvec2", "fvec3", "fvec4", "sampler1D", "sampler3D", "sampler1DShadow", "sampler2DShadow", "sampler2DRect",
    "sampler3DRect", "sampler2DRectShadow", "sizeof", "cast", "namespace", "using",
  ]
  static let keywords: Set<String> = [
    "attribute", "const", "uniform", "varying", "break", "continue", "do", "for", "while", "if", "else", "in", "out",
    "inout", "float", "int", "void", "bool", "true", "false", "lowp", "mediump", "highp", "precision", "invariant",
    "discard", "return", "mat2", "mat3", "mat4", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "bvec2", "bvec3",
    "bvec4", "sampler2D", "samplerCube", "struct",
  ]

  init(tokens: [Token], stage: GLSLStage, diags: Diagnostics, limits: GLSLLimits, derivatives: Bool, invariantAll: Bool) {
    ts = tokens
    self.diags = diags
    self.limits = limits
    self.derivatives = derivatives
    prog = Program(stage: stage)
    prog.invariantAll = invariantAll
    var p: [Basic: Precision] = [.int: stage == .vertex ? .high : .medium, .sampler2D: .low, .samplerCube: .low]
    if stage == .vertex { p[.float] = .high }
    precisions = [p]
    declareBuiltins()
    scopes.append([:])
    precisions.append([:])
  }

  // MARK: tokens

  var tok: Token { ts[k] }
  func peek(_ n: Int = 1) -> Token { k + n < ts.count ? ts[k + n] : ts[ts.count - 1] }
  func at(_ s: String) -> Bool { (tok.kind == .punct || tok.kind == .identifier) && tok.text == s }
  mutating func accept(_ s: String) -> Bool {
    if at(s) {
      k += 1
      return true
    }
    return false
  }

  func describe(_ t: Token) -> String { t.kind == .end ? "the end of the shader" : "'\(t.text)'" }

  mutating func syntax(_ msg: String) -> SyntaxError {
    diags.error(tok.at, msg)
    return SyntaxError()
  }

  mutating func expect(_ s: String) throws(SyntaxError) {
    if !accept(s) { throw syntax("syntax error: expected '\(s)', found \(describe(tok))") }
  }

  mutating func identifier(_ what: String) throws(SyntaxError) -> Token {
    guard tok.kind == .identifier, !Parser.keywords.contains(tok.text) else {
      throw syntax("syntax error: expected \(what), found \(describe(tok))")
    }
    if Parser.reserved.contains(tok.text) { throw syntax("'\(tok.text)' is a reserved keyword") }
    let t = tok
    k += 1
    return t
  }

  // MARK: scopes

  func lookup(_ name: String) -> Symbol? {
    var s = scopes.count - 1
    while s >= 0 {
      if let x = scopes[s][name] { return x }
      s -= 1
    }
    return nil
  }

  mutating func push() {
    scopes.append([:])
    precisions.append([:])
  }

  mutating func pop() {
    scopes.removeLast()
    precisions.removeLast()
  }

  func defaultPrecision(_ b: Basic) -> Precision? {
    var s = precisions.count - 1
    while s >= 0 {
      if let p = precisions[s][b] { return p }
      s -= 1
    }
    return nil
  }

  /// A name a declaration may introduce in the current scope.
  mutating func checkName(_ t: Token) {
    if t.text.hasPrefix("gl_") {
      diags.error(t.at, "'\(t.text)': names beginning with gl_ are reserved")
    } else if t.text.utf8.count > 1, Preprocessor(stage: prog.stage, diags: Diagnostics()).containsDoubleUnderscore(t.text) {
      diags.warning(t.at, "'\(t.text)': names containing __ are reserved")
    }
    if let old = scopes[scopes.count - 1][t.text] {
      if case .function = old {
        diags.error(t.at, "'\(t.text)' is already declared as a function")
      } else {
        diags.error(t.at, "'\(t.text)' is already declared in this scope")
      }
    } else if scopes.count == 2, builtinFunctionNames.contains(t.text) {
      diags.error(t.at, "'\(t.text)' is a built-in function and cannot be redeclared")
    }
  }

  mutating func addVariable(_ v: Variable, scoped name: Token? = nil) -> Int {
    let id = prog.variables.count
    prog.variables.append(v)
    if let n = name {
      checkName(n)
      scopes[scopes.count - 1][n.text] = .variable(id)
    }
    return id
  }

  // MARK: types

  static func typeKeyword(_ s: String) -> GType? {
    switch s {
    case "void": return .void
    case "float": return .float
    case "int": return .int
    case "bool": return .bool
    case "vec2", "vec3", "vec4": return .vec(Int(String(s.last!))!)
    case "ivec2", "ivec3", "ivec4": return .vec(Int(String(s.last!))!, .int)
    case "bvec2", "bvec3", "bvec4": return .vec(Int(String(s.last!))!, .bool)
    case "mat2", "mat3", "mat4": return .mat(Int(String(s.last!))!)
    case "sampler2D": return GType(basic: .sampler2D)
    case "samplerCube": return GType(basic: .samplerCube)
    default: return nil
    }
  }

  /// A type name here: a keyword or a structure in scope.
  func typeAt(_ t: Token) -> GType? {
    guard t.kind == .identifier else { return nil }
    if let g = Parser.typeKeyword(t.text) { return g }
    if case .structure(let s)? = lookup(t.text) { return GType(basic: .structure, structID: s) }
    return nil
  }

  static func precisionKeyword(_ s: String) -> Precision? {
    switch s {
    case "lowp": return .low
    case "mediump": return .medium
    case "highp": return .high
    default: return nil
    }
  }

  /// The basic type a precision applies to (float for vectors and matrices), or nil.
  static func precisionBasic(_ t: GType) -> Basic? {
    switch t.basic {
    case .float, .int, .sampler2D, .samplerCube: return t.basic
    default: return nil
    }
  }

  /// A type specifier: an optional precision, then a type keyword, a structure's name or a structure's definition.
  mutating func typeSpecifier() throws(SyntaxError) -> (type: GType, precision: Precision?) {
    var p: Precision? = nil
    if let q = Parser.precisionKeyword(tok.text), tok.kind == .identifier {
      p = q
      k += 1
    }
    if at("struct") {
      let s = try structSpecifier()
      if p != nil { diags.error(tok.at, "a precision qualifier does not apply to a structure") }
      return (GType(basic: .structure, structID: s), nil)
    }
    guard let t = typeAt(tok) else { throw syntax("syntax error: expected a type, found \(describe(tok))") }
    if p != nil && Parser.precisionBasic(t) == nil {
      diags.error(tok.at, "a precision qualifier does not apply to \(prog.name(t))")
      p = nil
    }
    k += 1
    return (t, p)
  }

  /// The precision a declaration of `t` takes: its own, or the default in scope; an error for a float without either in a
  /// fragment shader.
  mutating func resolvePrecision(_ t: GType, _ p: Precision?, at: SourceLocation) -> Precision {
    if let p = p { return p }
    guard let b = Parser.precisionBasic(t) else { return .none }
    if let d = defaultPrecision(b) { return d }
    diags.error(at, "no precision specified for \(b == .float ? "float" : prog.name(GType(basic: b))) (a fragment shader has no default float precision)")
    return .medium
  }

  mutating func structSpecifier() throws(SyntaxError) -> Int {
    let at0 = tok.at
    try expect("struct")
    var name: Token? = nil
    if !at("{") { name = try identifier("a structure name") }
    try expect("{")
    var members: [StructMember] = []
    while !at("}") {
      if at("const") || at("uniform") || at("attribute") || at("varying") || at("invariant") {
        diags.error(tok.at, "a structure member cannot be qualified '\(tok.text)'")
        k += 1
      }
      let (t, p) = try typeSpecifier()
      if t.basic == .void { diags.error(tok.at, "a structure member cannot be void") }
      repeat {
        let n = try identifier("a member name")
        var mt = t
        if accept("[") {
          mt = mt.array(try arraySize())
          try expect("]")
        }
        if members.contains(where: { $0.name == n.text }) { diags.error(n.at, "member '\(n.text)' is declared twice") }
        let mp = resolvePrecision(mt, p, at: n.at)
        members.append(StructMember(name: n.text, type: mt, precision: mp))
      } while accept(",")
      try expect(";")
    }
    try expect("}")
    if members.isEmpty { diags.error(at0, "a structure needs at least one member") }
    let id = prog.structs.count
    prog.structs.append(StructDef(name: name?.text ?? "__anon\(id)", members: members))
    if let n = name {
      checkName(n)
      scopes[scopes.count - 1][n.text] = .structure(id)
    }
    return id
  }

  /// An array's size: a constant integer expression, greater than zero.
  mutating func arraySize() throws(SyntaxError) -> Int {
    let e = try conditional()
    guard e.type == .int, let v = e.value, case .i(let n) = v[0] else {
      if !e.type.isError { diags.error(e.at, "an array's size must be a constant integer expression") }
      return 1
    }
    if n <= 0 {
      diags.error(e.at, "an array's size must be greater than zero")
      return 1
    }
    return Int(n)
  }

  // MARK: the translation unit

  mutating func translationUnit() throws(SyntaxError) {
    while tok.kind != .end {
      try externalDeclaration()
    }
    guard let mains = overloads["main"], let m = mains.first(where: { prog.functions[$0].body != nil }) else {
      // GL reports a missing main at link; the shader compiles.
      return
    }
    prog.main = m
    let f = prog.functions[m]
    if f.returnType != .void || !f.params.isEmpty { diags.error(f.at, "main must be declared void main()") }
  }

  mutating func externalDeclaration() throws(SyntaxError) {
    if accept(";") { return }
    if at("precision") {
      try precisionStatement()
      return
    }
    if at("invariant") && peek().kind == .identifier && typeAt(peek()) == nil && !["varying", "uniform", "attribute", "const"].contains(peek().text)
      && Parser.precisionKeyword(peek().text) == nil
    {
      try invariantStatement()
      return
    }
    try declaration(global: true)
  }

  mutating func precisionStatement() throws(SyntaxError) {
    try expect("precision")
    guard let p = Parser.precisionKeyword(tok.text) else { throw syntax("syntax error: expected lowp, mediump or highp, found \(describe(tok))") }
    k += 1
    guard let t = typeAt(tok), t.basic == .float || t.basic == .int || t.isSampler, !t.isVector, !t.isMatrix else {
      throw syntax("a default precision is for float, int, sampler2D or samplerCube, not \(describe(tok))")
    }
    k += 1
    try expect(";")
    precisions[precisions.count - 1][t.basic] = p
  }

  mutating func invariantStatement() throws(SyntaxError) {
    let at0 = tok.at
    try expect("invariant")
    repeat {
      let n = tok
      guard n.kind == .identifier else { throw syntax("syntax error: expected a name after invariant, found \(describe(tok))") }
      k += 1
      guard case .variable(let v)? = lookup(n.text) else {
        diags.error(n.at, "'\(n.text)': undeclared identifier")
        continue
      }
      let x = prog.variables[v]
      let ok = (x.storage == .varying) || [.position, .pointSize, .fragCoord, .frontFacing, .pointCoord].contains(x.builtin)
      if !ok || scopes.count > 2 {
        diags.error(n.at, "'\(n.text)' cannot be qualified invariant (only varyings and the built-in varyings can)")
      }
      prog.variables[v].invariant = true
    } while accept(",")
    _ = at0
    try expect(";")
  }

  /// A declaration: variables, a function's prototype or definition, or a structure alone.
  mutating func declaration(global: Bool) throws(SyntaxError) {
    let at0 = tok.at
    var invariant = false
    var storage = global ? Storage.global : Storage.local
    if accept("invariant") {
      invariant = true
      if !global { diags.error(at0, "invariant is only for global declarations") }
    }
    if at("const") {
      storage = .constant
      k += 1
    } else if at("attribute") || at("uniform") || at("varying") {
      let q = tok
      k += 1
      if !global {
        diags.error(q.at, "'\(q.text)' declarations are only allowed at global scope")
      } else if q.text == "attribute" {
        storage = .attribute
        if prog.stage != .vertex { diags.error(q.at, "attribute declarations are only allowed in a vertex shader") }
      } else {
        storage = q.text == "uniform" ? .uniform : .varying
      }
    }
    if invariant && storage != .varying { diags.error(at0, "only varyings can be declared invariant") }
    let (type, prec) = try typeSpecifier()
    // A structure alone, or a declaration with no name.
    if accept(";") {
      if !type.isStruct { diags.warning(at0, "a declaration declares nothing") }
      return
    }
    let name = try identifier("a name")
    if at("(") {
      if storage != .global && storage != .local { diags.error(at0, "a function's return type cannot be qualified") }
      if !global { throw syntax("a function cannot be declared inside a function") }
      try functionDeclaration(returning: type, precision: prec, name: name)
      return
    }
    try declarators(type, prec, storage: storage, invariant: invariant, first: name, global: global)
  }

  mutating func declarators(_ type: GType, _ prec: Precision?, storage: Storage, invariant: Bool, first: Token, global: Bool)
    throws(SyntaxError)
  {
    var name = first
    while true {
      var t = type
      if accept("[") {
        t = t.array(try arraySize())
        try expect("]")
      }
      try declareOne(t, prec, storage: storage, invariant: invariant, name: name, global: global)
      if !accept(",") { break }
      name = try identifier("a name")
    }
    try expect(";")
  }

  mutating func declareOne(_ t: GType, _ prec: Precision?, storage: Storage, invariant: Bool, name: Token, global: Bool)
    throws(SyntaxError)
  {
    if t.basic == .void { diags.error(name.at, "'\(name.text)': a variable cannot be void") }
    switch storage {
    case .attribute:
      if !(t.basic == .float && !t.isArray && !t.isStruct) {
        diags.error(name.at, "'\(name.text)': an attribute must be a float, a vector or a matrix of floats")
      }
    case .varying:
      if !(t.basic == .float && !t.isStruct) {
        diags.error(name.at, "'\(name.text)': a varying must be a float, a float vector or matrix, or an array of them")
      }
    case .uniform: break
    default:
      if prog.hasSampler(t) { diags.error(name.at, "'\(name.text)': a sampler can only be a uniform or a function parameter") }
    }
    let p = resolvePrecision(t, prec, at: name.at)
    var v = Variable(name: name.text, type: t, precision: p, storage: storage, at: name.at)
    v.declaredPrecision = prec ?? .none
    v.invariant = invariant || (prog.invariantAll && storage == .varying)
    var initializer: Expr? = nil
    if accept("=") {
      if storage == .uniform || storage == .attribute || storage == .varying {
        diags.error(name.at, "'\(name.text)': a \(storage == .uniform ? "uniform" : storage == .attribute ? "attribute" : "varying") cannot have an initializer")
      }
      if t.isArray { diags.error(name.at, "'\(name.text)': an array cannot have an initializer") }
      var e = try assignment()
      e = convertForInit(e, to: t, name: name)
      if storage == .constant {
        if let val = e.value { v.value = val } else if !e.type.isError && !isConstantExpression(e) {
          diags.error(e.at, "'\(name.text)': a const variable's initializer must be a constant expression")
        }
      } else if global && !e.type.isError && !isConstantExpression(e) {
        diags.error(e.at, "'\(name.text)': a global variable's initializer must be a constant expression")
      }
      initializer = e
    } else if storage == .constant {
      diags.error(name.at, "'\(name.text)': a const variable needs an initializer")
      v.value = [Scalar](repeating: .f(0), count: prog.flatCount(t))
    }
    let id = addVariable(v, scoped: name)
    if global {
      prog.globals.append((variable: id, initializer: initializer))
    } else {
      pendingDecls.append(.declare(id, initializer))
    }
  }

  /// The statements a declaration in a function makes (one each variable).
  var pendingDecls: [Stmt] = []

  /// An initializer of `t`: the same type, as GLSL ES has no implicit conversions.
  mutating func convertForInit(_ e: Expr, to t: GType, name: Token) -> Expr {
    if e.type.isError || t.isError { return e }
    if e.type != t {
      diags.error(e.at, "'\(name.text)': cannot initialize a \(prog.name(t)) with a \(prog.name(e.type))")
      return .error(e.at)
    }
    return e
  }

  // MARK: functions

  mutating func functionDeclaration(returning type: GType, precision prec: Precision?, name: Token) throws(SyntaxError) {
    try expect("(")
    var params: [Variable] = []
    var paramNames: [Token?] = []
    if at("void") && peek().is(")") {
      k += 1
    } else if !at(")") {
      repeat {
        let pat = tok.at
        var q = ParamQualifier.in
        var isConst = false
        if accept("const") { isConst = true }
        if accept("in") {
          q = .in
        } else if accept("out") {
          q = .out
        } else if accept("inout") {
          q = .inout
        }
        if isConst && q != .in { diags.error(pat, "const parameters must be in parameters") }
        let (pt0, pp) = try typeSpecifier()
        var pt = pt0
        var pn: Token? = nil
        if tok.kind == .identifier && !Parser.keywords.contains(tok.text) {
          pn = try identifier("a parameter name")
        }
        if accept("[") {
          pt = pt.array(try arraySize())
          try expect("]")
        }
        if pt.basic == .void { diags.error(pat, "a parameter cannot be void") }
        if pt.isSampler && q != .in { diags.error(pat, "a sampler parameter must be an in parameter") }
        let precision = resolvePrecision(pt, pp, at: pat)
        var v = Variable(name: pn?.text ?? "", type: pt, precision: precision, storage: .param, at: pn?.at ?? pat)
        v.qualifier = q
        if isConst { v.storage = .param }
        params.append(v)
        paramNames.append(pn)
      } while accept(",")
    }
    try expect(")")
    if prog.hasSampler(type) || type.isArray { diags.error(name.at, "a function cannot return \(prog.name(type))") }
    let retPrec = resolvePrecision(type, prec, at: name.at)
    // The same signature as one declared before is that function.
    var id = -1
    if let old = overloads[name.text] {
      for o in old {
        let f = prog.functions[o]
        guard f.params.count == params.count else { continue }
        var same = true
        for (pi, p) in zip(f.params, params) where prog.variables[pi].type != p.type { same = false }
        if same { id = o }
      }
    } else {
      if lookup(name.text) != nil, scopes[1][name.text] != nil {
        diags.error(name.at, "'\(name.text)' is already declared and is not a function")
      }
      if builtinFunctionNames.contains(name.text) {
        diags.error(name.at, "'\(name.text)' is a built-in function and cannot be redeclared or overloaded")
      }
      if name.text.hasPrefix("gl_") { diags.error(name.at, "'\(name.text)': names beginning with gl_ are reserved") }
    }
    if id >= 0 {
      let f = prog.functions[id]
      if f.returnType != type { diags.error(name.at, "'\(name.text)' was declared returning \(prog.name(f.returnType)), not \(prog.name(type))") }
      for (pi, p) in zip(f.params, params) where prog.variables[pi].qualifier != p.qualifier {
        diags.error(name.at, "'\(name.text)': a parameter's qualifier differs from its earlier declaration")
      }
    }
    let isDefinition = at("{")
    var vids: [Int] = []
    for p in params { vids.append(addVariable(p)) }
    if id < 0 {
      id = prog.functions.count
      prog.functions.append(FunctionDef(name: name.text, returnType: type, returnPrecision: retPrec, params: vids, body: nil, at: name.at))
      overloads[name.text, default: []].append(id)
      scopes[1][name.text] = .function
    } else if isDefinition {
      if prog.functions[id].body != nil {
        diags.error(name.at, "function '\(name.text)' is already defined")
      }
      prog.functions[id].params = vids
      prog.functions[id].at = name.at
    }
    if !isDefinition {
      try expect(";")
      return
    }
    if name.text == "main" && overloads["main"]!.count > 1 { diags.error(name.at, "main cannot be overloaded") }
    // The body: the parameters are in the function's scope, the body's statements too.
    push()
    for (vi, pn) in zip(vids, paramNames) {
      if let n = pn {
        checkName(n)
        scopes[scopes.count - 1][n.text] = .variable(vi)
      }
    }
    function = id
    uses = []
    calls = []
    try expect("{")
    var body: [Stmt] = []
    while !at("}") {
      if tok.kind == .end { throw syntax("syntax error: the function's body is not closed") }
      body += try statement()
    }
    try expect("}")
    pop()
    if type != .void && !endsInReturn(body) && name.text != "main" {
      // GL leaves the value undefined; a warning, since glslang and Mesa accept it.
      diags.warning(name.at, "function '\(name.text)' can end without returning a value")
    }
    prog.functions[id].body = body
    prog.functions[id].calls = calls
    prog.functions[id].uses = uses
    function = -1
  }

  /// The checks of the whole shader, after its last declaration: no recursion, and not both gl_FragColor and
  /// gl_FragData.
  mutating func finish() {
    var color: SourceLocation? = nil
    var data: SourceLocation? = nil
    for v in prog.variables {
      if v.builtin == .fragColor && (v.read || v.written) { color = v.at }
      if v.builtin == .fragData && (v.read || v.written) { data = v.at }
    }
    if color != nil && data != nil { diags.error(SourceLocation(), "a shader cannot use both gl_FragColor and gl_FragData") }
    // A cycle in the call graph is recursion, which GLSL ES does not allow.
    var state = [UInt8](repeating: 0, count: prog.functions.count)
    func visit(_ f: Int, _ p: inout Parser) -> Bool {
      if state[f] == 1 { return true }
      if state[f] == 2 { return false }
      state[f] = 1
      for c in p.prog.functions[f].calls where visit(c, &p) {
        if state[f] == 1 { p.diags.error(p.prog.functions[f].at, "function '\(p.prog.functions[f].name)' is recursive") }
        state[f] = 2
        return false
      }
      state[f] = 2
      return false
    }
    for f in 0..<prog.functions.count { _ = visit(f, &self) }
  }

  func endsInReturn(_ body: [Stmt]) -> Bool {
    guard let last = body.last else { return false }
    switch last {
    case .ret, .discard: return true
    case .block(let b): return endsInReturn(b)
    case .ifElse(_, let a, let b?): return endsInReturn([a]) && endsInReturn([b])
    default: return false
    }
  }

  // MARK: statements

  mutating func statement() throws(SyntaxError) -> [Stmt] {
    let t = tok
    if t.is("{") {
      k += 1
      push()
      var b: [Stmt] = []
      while !at("}") {
        if tok.kind == .end { throw syntax("syntax error: a block is not closed") }
        b += try statement()
      }
      k += 1
      pop()
      return [.block(b)]
    }
    if t.is(";") {
      k += 1
      return []
    }
    if t.kind == .identifier {
      switch t.text {
      case "if":
        k += 1
        try expect("(")
        let c = condition(try expression(), "if")
        try expect(")")
        let a = try scopedStatement()
        var b: Stmt? = nil
        if accept("else") { b = try scopedStatement() }
        return [.ifElse(c, a, b)]
      case "while":
        k += 1
        try expect("(")
        push()
        var pre: [Stmt] = []
        let c = try loopCondition(&pre)
        try expect(")")
        loops += 1
        let body = try statementNoNewScope()
        loops -= 1
        pop()
        return pre + [.loop(initializer: [], condition: c, step: nil, body: .block(body))]
      case "do":
        k += 1
        loops += 1
        let body = try scopedStatement()
        loops -= 1
        if !accept("while") { throw syntax("syntax error: expected 'while' after a do statement's body") }
        try expect("(")
        let c = condition(try expression(), "do-while")
        try expect(")")
        try expect(";")
        return [.doWhile(body: body, condition: c)]
      case "for":
        k += 1
        try expect("(")
        push()
        var initializer: [Stmt] = []
        if !accept(";") {
          if isDeclarationStart() {
            try declaration(global: false)
            initializer = pendingDecls
            pendingDecls = []
          } else {
            initializer = [.expr(try expression())]
            try expect(";")
          }
        }
        var c: Expr? = nil
        if !at(";") { c = try loopCondition(&initializer) }
        try expect(";")
        var step: Expr? = nil
        if !at(")") { step = try expression() }
        try expect(")")
        loops += 1
        let body = try statementNoNewScope()
        loops -= 1
        pop()
        return [.block([.loop(initializer: initializer, condition: c, step: step, body: .block(body))])]
      case "return":
        k += 1
        var e: Expr? = nil
        if !at(";") { e = try expression() }
        try expect(";")
        let f = prog.functions[function]
        if let x = e {
          if f.returnType == .void {
            diags.error(x.at, "a void function cannot return a value")
          } else if !x.type.isError && x.type != f.returnType {
            diags.error(x.at, "'\(f.name)' returns \(prog.name(f.returnType)), not \(prog.name(x.type))")
          }
        } else if f.returnType != .void {
          diags.error(t.at, "'\(f.name)' must return a \(prog.name(f.returnType))")
        }
        return [.ret(e, t.at)]
      case "break", "continue":
        k += 1
        try expect(";")
        if loops == 0 { diags.error(t.at, "'\(t.text)' outside a loop") }
        return [t.text == "break" ? .brk : .cont]
      case "discard":
        k += 1
        try expect(";")
        if prog.stage != .fragment { diags.error(t.at, "discard is only allowed in a fragment shader") }
        return [.discard]
      case "precision":
        try precisionStatement()
        return []
      default: break
      }
    }
    if isDeclarationStart() {
      try declaration(global: false)
      let d = pendingDecls
      pendingDecls = []
      return d
    }
    let e = try expression()
    try expect(";")
    return [.expr(e)]
  }

  /// A statement with a scope of its own (an if's branches, a do's body).
  mutating func scopedStatement() throws(SyntaxError) -> Stmt {
    push()
    let s = try statement()
    pop()
    return s.count == 1 ? s[0] : .block(s)
  }

  /// A loop's body: a block's statements share the loop's scope (the grammar's statement_no_new_scope).
  mutating func statementNoNewScope() throws(SyntaxError) -> [Stmt] {
    if accept("{") {
      var b: [Stmt] = []
      while !at("}") {
        if tok.kind == .end { throw syntax("syntax error: a block is not closed") }
        b += try statement()
      }
      k += 1
      return b
    }
    return try statement()
  }

  /// A loop's condition: an expression, or a declaration of a bool with its initializer.
  mutating func loopCondition(_ pre: inout [Stmt]) throws(SyntaxError) -> Expr {
    if let t = typeAt(tok), peek().kind == .identifier, !peek(2).is("(") {
      _ = t
      let at0 = tok.at
      let (type, prec) = try typeSpecifier()
      let n = try identifier("a name")
      try expect("=")
      let e = convertForInit(try assignment(), to: type, name: n)
      let p = resolvePrecision(type, prec, at: n.at)
      let id = addVariable(Variable(name: n.text, type: type, precision: p, storage: .local, at: n.at), scoped: n)
      pre.append(.declare(id, nil))
      let d = Expr(type: type, precision: p, kind: .declare(id, e), at: at0)
      return condition(d, "loop")
    }
    return condition(try expression(), "loop")
  }

  mutating func condition(_ e: Expr, _ what: String) -> Expr {
    if !e.type.isError && e.type != .bool {
      diags.error(e.at, "a\(what == "if" ? "n" : "") \(what) condition must be a bool, not \(prog.name(e.type))")
      return .error(e.at)
    }
    return e
  }

  func isDeclarationStart() -> Bool {
    let t = tok
    guard t.kind == .identifier else { return false }
    switch t.text {
    case "const", "attribute", "uniform", "varying", "invariant", "lowp", "mediump", "highp", "struct": return true
    default: break
    }
    if typeAt(t) != nil {
      // A constructor call is an expression.
      return !peek().is("(")
    }
    return false
  }
}
