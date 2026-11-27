// SPDX-License-Identifier: BSD-3-Clause

// The GLSL ES 1.00 preprocessor (section 3.4): #define with and without parameters, #undef, #if, #ifdef, #ifndef,
// #elif, #else and #endif with C's integer expressions and defined(), #error, #pragma, #extension, #version and #line,
// and the predefined macros __LINE__, __FILE__, __VERSION__, GL_ES, GL_FRAGMENT_PRECISION_HIGH and one for each
// extension the compiler supports. Macros expand as C's do (hide sets, after Prosser); the language has no # or ##
// operators. Unlike C, an undefined name in an #if is an error.
//
// The lines between two directives are expanded together, when the next directive (or the end) is reached, so a
// function-like macro's arguments may span lines.

struct Macro {
  var params: [String]?
  var body: [Token]
  var predefined = false
}

/// An extension's behaviour, as #extension sets it.
enum ExtensionBehavior: Sendable { case disable, warn, enable, require }

struct PreprocessResult {
  var tokens: [Token]
  var diags: Diagnostics
  /// GL_OES_standard_derivatives was enabled (or warned about) by #extension.
  var derivatives: Bool
  /// `#pragma STDGL invariant(all)` was given.
  var invariantAll: Bool
}

struct Preprocessor {
  var diags: Diagnostics
  var macros: [String: Macro] = [:]
  var out: [Token] = []
  var pending: [Token] = []
  var lineDelta = 0
  var sourceNumber = 0
  var sawContent = false
  var derivatives = false
  var invariantAll = false
  /// Each open conditional: whether its text is being kept, whether a branch has been taken, whether #else was seen.
  var conds: [(active: Bool, taken: Bool, sawElse: Bool, at: SourceLocation)] = []

  static let supportedExtensions = ["GL_OES_standard_derivatives"]

  init(stage: GLSLStage, diags: Diagnostics) {
    self.diags = diags
    func define(_ name: String, _ value: String) {
      let t = Token(kind: .number, text: value, at: SourceLocation(), space: true)
      macros[name] = Macro(params: nil, body: [t], predefined: true)
    }
    define("GL_ES", "1")
    define("__VERSION__", "100")
    define("GL_FRAGMENT_PRECISION_HIGH", "1")
    for e in Preprocessor.supportedExtensions { define(e, "1") }
    macros["__LINE__"] = Macro(params: nil, body: [], predefined: true)
    macros["__FILE__"] = Macro(params: nil, body: [], predefined: true)
  }

  var active: Bool { conds.allSatisfy { $0.active } }

  mutating func run(_ tokens: [Token]) -> PreprocessResult {
    var lineStart = 0
    var k = 0
    while k < tokens.count {
      if tokens[k].kind == .newline || tokens[k].kind == .end {
        var line = Array(tokens[lineStart..<k])
        for j in 0..<line.count {
          line[j].at.line += lineDelta
          line[j].at.source = sourceNumber
        }
        let nl = tokens[k].at
        if let first = line.first, first.is("#") {
          flush()
          directive(line, end: SourceLocation(source: sourceNumber, line: nl.line + lineDelta, column: nl.column))
        } else if active && !line.isEmpty {
          sawContent = true
          pending += line
        }
        if tokens[k].kind == .end { break }
        lineStart = k + 1
      }
      k += 1
    }
    flush()
    if let c = conds.last { diags.error(c.at, "unterminated #if (no #endif)") }
    var end = tokens.last?.at ?? SourceLocation()
    end.line += lineDelta
    out.append(Token(kind: .end, text: "", at: end, space: false))
    return PreprocessResult(tokens: out, diags: diags, derivatives: derivatives, invariantAll: invariantAll)
  }

  mutating func flush() {
    if pending.isEmpty { return }
    out += expand(pending)
    pending = []
  }

  // MARK: directives

  mutating func directive(_ line: [Token], end: SourceLocation) {
    guard line.count > 1 else { return }  // the null directive
    let name = line[1]
    let rest = Array(line[2...])
    let conditional = ["if", "ifdef", "ifndef", "elif", "else", "endif"]
    if name.kind != .identifier {
      if active { diags.error(name.at, "'\(name.text)' is not a preprocessor directive") }
      return
    }
    if !active && !conditional.contains(name.text) { return }
    switch name.text {
    case "define": define(rest, at: name.at)
    case "undef":
      guard let n = rest.first, n.kind == .identifier else {
        diags.error(name.at, "#undef needs a macro name")
        return
      }
      if rest.count > 1 { diags.error(rest[1].at, "unexpected '\(rest[1].text)' after #undef \(n.text)") }
      if let m = macros[n.text], m.predefined {
        diags.error(n.at, "#undef of the predefined macro \(n.text)")
        return
      }
      macros[n.text] = nil
    case "if":
      let was = active
      let v = was ? evaluate(rest, at: name.at) : false
      conds.append((active: v, taken: v, sawElse: false, at: name.at))
      if !was { conds[conds.count - 1].taken = true }
    case "ifdef", "ifndef":
      guard let n = rest.first, n.kind == .identifier else {
        if active { diags.error(name.at, "#\(name.text) needs a macro name") }
        conds.append((active: false, taken: true, sawElse: false, at: name.at))
        return
      }
      let was = active
      let d = macros[n.text] != nil
      let v = name.text == "ifdef" ? d : !d
      conds.append((active: was && v, taken: v || !was, sawElse: false, at: name.at))
    case "elif":
      guard !conds.isEmpty else {
        diags.error(name.at, "#elif without #if")
        return
      }
      let c = conds.removeLast()
      if c.sawElse { diags.error(name.at, "#elif after #else") }
      if c.taken {
        conds.append((active: false, taken: true, sawElse: false, at: c.at))
      } else {
        let v = active && evaluate(rest, at: name.at)
        conds.append((active: v, taken: v, sawElse: false, at: c.at))
      }
    case "else":
      guard !conds.isEmpty else {
        diags.error(name.at, "#else without #if")
        return
      }
      let c = conds.removeLast()
      if c.sawElse { diags.error(name.at, "#else after #else") }
      conds.append((active: !c.taken, taken: true, sawElse: true, at: c.at))
    case "endif":
      guard !conds.isEmpty else {
        diags.error(name.at, "#endif without #if")
        return
      }
      conds.removeLast()
    case "error":
      var text = ""
      for t in rest { text += (text.isEmpty || !t.space ? "" : " ") + t.text }
      diags.error(name.at, "#error \(text)")
    case "pragma":
      // STDGL's pragmas: invariant(all) takes effect; optimize and debug change nothing here; others are ignored.
      let words = rest.map { $0.text }
      if words.count >= 5 && words[0] == "STDGL" && words[1] == "invariant" && words[2] == "(" && words[3] == "all" {
        invariantAll = true
      }
    case "extension": extensionDirective(rest, at: name.at)
    case "version":
      if sawContent || out.count > 0 { diags.error(name.at, "#version must come before anything else") }
      guard let v = rest.first, v.kind == .number else {
        diags.error(name.at, "#version needs a number")
        return
      }
      if v.text != "100" {
        diags.error(v.at, rest.count > 1 && rest[1].text == "es"
          ? "version \(v.text) es is not supported (only GLSL ES 1.00, #version 100)" : "version \(v.text) is not supported (only GLSL ES 1.00, #version 100)")
      } else if rest.count > 1 {
        diags.error(rest[1].at, "unexpected '\(rest[1].text)' after #version 100")
      }
    case "line":
      let ex = expand(rest)
      guard let l = ex.first, l.kind == .number, let n = Int(l.text) else {
        diags.error(name.at, "#line needs a line number")
        return
      }
      // The line after this one is line n.
      lineDelta += n - (end.line + 1)
      if ex.count > 1 {
        if ex[1].kind == .number, let s = Int(ex[1].text) { sourceNumber = s } else { diags.error(ex[1].at, "#line's source string number must be an integer") }
      }
    default:
      diags.error(name.at, "unknown directive #\(name.text)")
    }
    sawContent = true
  }

  mutating func define(_ rest: [Token], at: SourceLocation) {
    guard let n = rest.first, n.kind == .identifier else {
      diags.error(at, "#define needs a macro name")
      return
    }
    if n.text.hasPrefix("GL_") {
      diags.error(n.at, "macro names beginning with GL_ are reserved")
      return
    }
    if n.text == "defined" {
      diags.error(n.at, "'defined' cannot be a macro name")
      return
    }
    if let m = macros[n.text], m.predefined {
      diags.error(n.at, "redefinition of the predefined macro \(n.text)")
      return
    }
    if n.text.utf8.count > 1 && containsDoubleUnderscore(n.text) {
      diags.warning(n.at, "macro names containing __ are reserved")
    }
    var params: [String]? = nil
    var k = 1
    if k < rest.count && rest[k].is("(") && !rest[k].space {
      var ps: [String] = []
      k += 1
      var closed = false
      while k < rest.count {
        if rest[k].is(")") {
          closed = true
          k += 1
          break
        }
        guard rest[k].kind == .identifier else {
          diags.error(rest[k].at, "'\(rest[k].text)' in a macro's parameter list")
          return
        }
        if ps.contains(rest[k].text) {
          diags.error(rest[k].at, "parameter \(rest[k].text) appears twice")
          return
        }
        ps.append(rest[k].text)
        k += 1
        if k < rest.count && rest[k].is(",") {
          k += 1
        } else if !(k < rest.count && rest[k].is(")")) {
          diags.error(k < rest.count ? rest[k].at : n.at, "a macro's parameters are separated by commas")
          return
        }
      }
      if !closed {
        diags.error(n.at, "unterminated parameter list of macro \(n.text)")
        return
      }
      params = ps
    }
    var body = Array(rest[k...])
    if !body.isEmpty { body[0].space = true }
    let m = Macro(params: params, body: body)
    if let old = macros[n.text] {
      if !same(old, m) { diags.error(n.at, "macro \(n.text) redefined differently") }
      return
    }
    macros[n.text] = m
  }

  func containsDoubleUnderscore(_ s: String) -> Bool {
    var last: UInt8 = 0
    for c in s.utf8 {
      if c == 95 && last == 95 { return true }
      last = c
    }
    return false
  }

  func same(_ a: Macro, _ b: Macro) -> Bool {
    guard a.params == b.params, a.body.count == b.body.count else { return false }
    for (x, y) in zip(a.body, b.body) where x.text != y.text || (x.space != y.space) { return false }
    return true
  }

  mutating func extensionDirective(_ rest: [Token], at: SourceLocation) {
    guard rest.count == 3, rest[0].kind == .identifier, rest[1].is(":"), rest[2].kind == .identifier else {
      diags.error(at, "#extension needs a name, a colon and a behaviour")
      return
    }
    let name = rest[0].text
    let b: ExtensionBehavior
    switch rest[2].text {
    case "require": b = .require
    case "enable": b = .enable
    case "warn": b = .warn
    case "disable": b = .disable
    default:
      diags.error(rest[2].at, "unknown extension behaviour '\(rest[2].text)'")
      return
    }
    if name == "all" {
      if b == .require || b == .enable { diags.error(rest[2].at, "#extension all : \(rest[2].text) is not allowed") }
      if b == .disable { derivatives = false }
      if b == .warn { derivatives = true }
      return
    }
    if Preprocessor.supportedExtensions.contains(name) {
      derivatives = b != .disable
      return
    }
    switch b {
    case .require: diags.error(rest[0].at, "extension \(name) is not supported")
    case .enable, .warn: diags.warning(rest[0].at, "extension \(name) is not supported")
    case .disable: break
    }
  }

  // MARK: expansion

  /// Expands the macros in `input`, rescanning each replacement (C 6.10.3.4).
  mutating func expand(_ input: [Token]) -> [Token] {
    var ts = input
    var result: [Token] = []
    var i = 0
    while i < ts.count {
      let t = ts[i]
      guard t.kind == .identifier, !t.hide.contains(t.text), let m = macros[t.text] else {
        result.append(t)
        i += 1
        continue
      }
      if t.text == "__LINE__" || t.text == "__FILE__" {
        var r = t
        r.kind = .number
        r.text = t.text == "__LINE__" ? String(t.at.line) : String(t.at.source)
        result.append(r)
        i += 1
        continue
      }
      guard let params = m.params else {
        var rep = m.body
        for j in 0..<rep.count {
          rep[j].at = t.at
          rep[j].hide = t.hide + [t.text]
        }
        if !rep.isEmpty { rep[0].space = t.space }
        ts.replaceSubrange(i..<(i + 1), with: rep)
        continue
      }
      // A function-like macro's name not followed by '(' is just a name.
      guard i + 1 < ts.count, ts[i + 1].is("(") else {
        result.append(t)
        i += 1
        continue
      }
      var args: [[Token]] = [[]]
      var depth = 0
      var j = i + 2
      var closed = false
      while j < ts.count {
        let a = ts[j]
        if a.is("(") { depth += 1 }
        if a.is(")") {
          if depth == 0 {
            closed = true
            break
          }
          depth -= 1
        }
        if a.is(",") && depth == 0 {
          args.append([])
        } else {
          args[args.count - 1].append(a)
        }
        j += 1
      }
      guard closed else {
        diags.error(t.at, "unterminated call of macro \(t.text)")
        return result
      }
      if params.isEmpty && args.count == 1 && args[0].isEmpty { args = [] }
      guard args.count == params.count else {
        diags.error(t.at, "macro \(t.text) takes \(params.count) argument\(params.count == 1 ? "" : "s"), given \(args.count)")
        i = j + 1
        continue
      }
      let hide = t.hide.filter { ts[j].hide.contains($0) } + [t.text]
      var expandedArgs: [[Token]] = []
      for a in args { expandedArgs.append(expand(a)) }
      var rep: [Token] = []
      for b in m.body {
        if b.kind == .identifier, let p = params.firstIndex(of: b.text) {
          var arg = expandedArgs[p]
          if !arg.isEmpty { arg[0].space = b.space }
          rep += arg
        } else {
          rep.append(b)
        }
      }
      for k in 0..<rep.count {
        rep[k].at = t.at
        rep[k].hide = rep[k].hide + hide
      }
      if !rep.isEmpty { rep[0].space = t.space }
      ts.replaceSubrange(i...j, with: rep)
    }
    return result
  }

  // MARK: #if expressions

  /// The value of an #if's or #elif's expression (non-zero is true); an error is false.
  mutating func evaluate(_ tokens: [Token], at: SourceLocation) -> Bool {
    // defined X and defined(X) first, then the macros.
    var ts: [Token] = []
    var k = 0
    while k < tokens.count {
      let t = tokens[k]
      if t.kind == .identifier && t.text == "defined" {
        var n: Token? = nil
        if k + 1 < tokens.count && tokens[k + 1].kind == .identifier {
          n = tokens[k + 1]
          k += 2
        } else if k + 3 < tokens.count && tokens[k + 1].is("(") && tokens[k + 2].kind == .identifier && tokens[k + 3].is(")") {
          n = tokens[k + 2]
          k += 4
        }
        guard let name = n else {
          diags.error(t.at, "'defined' needs a macro name")
          return false
        }
        ts.append(Token(kind: .number, text: macros[name.text] != nil ? "1" : "0", at: t.at, space: true))
        continue
      }
      ts.append(t)
      k += 1
    }
    let ex = expand(ts)
    if ex.isEmpty {
      diags.error(at, "#if with no expression")
      return false
    }
    var p = ExprParser(ts: ex, at: at)
    let v = p.parse(0)
    if p.failed == nil && p.k < ex.count { p.failed = (ex[p.k].at, "unexpected '\(ex[p.k].text)' in a preprocessor expression") }
    if let (where_, msg) = p.failed {
      diags.error(where_, msg)
      return false
    }
    return v != 0
  }
}

/// C's integer constant expressions, by precedence climbing, in 64-bit arithmetic.
private struct ExprParser {
  let ts: [Token]
  let at: SourceLocation
  var k = 0
  var failed: (SourceLocation, String)? = nil

  init(ts: [Token], at: SourceLocation) {
    self.ts = ts
    self.at = at
  }

  static let binary: [String: Int] = [
    "||": 1, "&&": 2, "|": 3, "^": 4, "&": 5, "==": 6, "!=": 6, "<": 7, ">": 7, "<=": 7, ">=": 7, "<<": 8, ">>": 8,
    "+": 9, "-": 9, "*": 10, "/": 10, "%": 10,
  ]

  mutating func fail(_ where_: SourceLocation, _ msg: String) {
    if failed == nil { failed = (where_, msg) }
  }

  mutating func primary() -> Int64 {
    guard k < ts.count else {
      fail(at, "a preprocessor expression ends early")
      return 0
    }
    let t = ts[k]
    k += 1
    if t.is("(") {
      let v = parse(0)
      if k < ts.count && ts[k].is(")") { k += 1 } else { fail(t.at, "missing ')' in a preprocessor expression") }
      return v
    }
    if t.is("-") { return 0 &- primary() }
    if t.is("+") { return primary() }
    if t.is("!") { return primary() == 0 ? 1 : 0 }
    if t.is("~") { return ~primary() }
    if t.kind == .number {
      if let v = ExprParser.integer(t.text) { return v }
      fail(t.at, "'\(t.text)' is not an integer in a preprocessor expression")
      return 0
    }
    if t.kind == .identifier {
      fail(t.at, "undefined macro \(t.text) in a preprocessor expression")
      return 0
    }
    fail(t.at, "unexpected '\(t.text)' in a preprocessor expression")
    return 0
  }

  static func integer(_ s: String) -> Int64? {
    let u = Array(s.utf8)
    if u.count > 2 && u[0] == 48 && (u[1] == 120 || u[1] == 88) { return Int64(String(decoding: u[2...], as: UTF8.self), radix: 16) }
    if u.count > 1 && u[0] == 48 { return Int64(s, radix: 8) }
    return Int64(s)
  }

  mutating func parse(_ minPrec: Int) -> Int64 {
    var lhs = primary()
    while failed == nil, k < ts.count {
      let t = ts[k]
      if t.is("?") && minPrec == 0 {
        k += 1
        let a = parse(0)
        guard k < ts.count, ts[k].is(":") else {
          fail(t.at, "missing ':' in a preprocessor expression")
          return 0
        }
        k += 1
        let b = parse(0)
        lhs = lhs != 0 ? a : b
        continue
      }
      guard t.kind == .punct, let p = ExprParser.binary[t.text], p > minPrec else { break }
      k += 1
      let rhs = parse(p)
      switch t.text {
      case "||": lhs = (lhs != 0 || rhs != 0) ? 1 : 0
      case "&&": lhs = (lhs != 0 && rhs != 0) ? 1 : 0
      case "|": lhs |= rhs
      case "^": lhs ^= rhs
      case "&": lhs &= rhs
      case "==": lhs = lhs == rhs ? 1 : 0
      case "!=": lhs = lhs != rhs ? 1 : 0
      case "<": lhs = lhs < rhs ? 1 : 0
      case ">": lhs = lhs > rhs ? 1 : 0
      case "<=": lhs = lhs <= rhs ? 1 : 0
      case ">=": lhs = lhs >= rhs ? 1 : 0
      case "<<": lhs = rhs >= 0 && rhs < 64 ? lhs << rhs : 0
      case ">>": lhs = rhs >= 0 && rhs < 64 ? lhs >> rhs : 0
      case "+": lhs = lhs &+ rhs
      case "-": lhs = lhs &- rhs
      case "*": lhs = lhs &* rhs
      default:
        if rhs == 0 {
          fail(t.at, "division by zero in a preprocessor expression")
          return 0
        }
        lhs = t.text == "/" ? lhs / rhs : lhs % rhs
      }
    }
    return lhs
  }
}
