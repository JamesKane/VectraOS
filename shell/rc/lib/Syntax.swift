// SPDX-License-Identifier: BSD-3-Clause

// rc (M6j part 2c; decided 2026-10-12: the shell is rc-style), written from
// Tom Duff's "Rc - The Plan 9 Shell": its grammar, read into a tree.
//
// Words are lists of strings. A word is a literal (quoted with '' and ''
// inside it for one quote, or plain), a variable ($x, $x(subscripts), $#x
// its count, $"x its strings joined), a backquote substitution (`{cmd}),
// a parenthesized list, or pieces joined by ^ (written, or free: pieces
// with no space between them join). Commands are simple ones with their
// redirections (> >> < <<tag and >[n] >[n=m]), assignments (alone, or
// local to one command), pipelines (|, |[n]), ! && || ; &, braces, if /
// if not, for, while, switch with its cases, ~ (a match), and fn.

public indirect enum Word: Equatable, Sendable {
  /// A string; `quoted` ones aren't globbed.
  case literal(String, quoted: Bool)
  /// $name, or $name(subscripts).
  case variable(String, index: [Word]?)
  /// $#name: how many strings it holds.
  case count(String)
  /// $"name: its strings joined by spaces, one string.
  case joined(String)
  /// Pieces joined by ^.
  case concat([Word])
  /// (a b c): the strings of each.
  case list([Word])
  /// `{command}: its output, split at spaces, tabs and newlines.
  case backquote(Command)
}

public struct Redirection: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case read(fd: Int32)  // <
    case write(fd: Int32)  // >
    case append(fd: Int32)  // >>
    case duplicate(fd: Int32, to: Int32)  // >[fd=to]
    case close(fd: Int32)  // >[fd=]
    /// <<tag: the lines after the command's, up to one that is only the
    /// tag (the target, a quoted literal, holds them); `quoted`, a quoted
    /// tag's, has no $ substituted.
    case here(fd: Int32, quoted: Bool)
  }
  public var kind: Kind
  /// The file (none for duplicate and close).
  public var target: Word?
}

public indirect enum Command: Equatable, Sendable {
  /// A command and its words, redirected.
  case simple([Word], [Redirection])
  /// name=value, alone (`body` nil) or for one command. The name is a
  /// word (9front's `first`: `$a=v` sets the variable $a names), one
  /// string when it runs.
  case assign(Word, Word, body: Command?)
  /// Stages, each one's fd 1 (or the given one) into the next's 0.
  case pipeline([Command], fds: [Int32])
  case not(Command)
  /// @ cmd: run as if forked: what it changes (variables, functions, the
  /// directory) is undone after.
  case subshell(Command)
  case and(Command, Command)
  case or(Command, Command)
  case sequence([Command])
  /// Run without waiting for it.
  case background(Command)
  case brace(Command, [Redirection])
  case ifThen(condition: Command, body: Command)
  /// Runs if the last `if`'s condition failed.
  case ifNot(Command)
  case forIn(String, list: [Word]?, body: Command)
  case whileDo(condition: Command, body: Command)
  case switchOn(Word, cases: [(patterns: [Word], body: [Command])])
  /// ~ subject patterns...
  case match(Word, [Word])
  /// fn name { body }, or fn name (deleting it).
  case function(String, body: Command?)
  case empty

  public static func == (a: Command, b: Command) -> Bool { "\(a)" == "\(b)" }
}

public struct RcSyntaxError: Error, Equatable, Sendable, CustomStringConvertible {
  public var message: String
  /// The text ended inside something (a brace, a quote, an if's
  /// condition): more lines would finish it.
  public var incomplete = false
  public init(message: String, incomplete: Bool = false) {
    self.message = message
    self.incomplete = incomplete
  }
  public var description: String { "rc: syntax error: " + message }
}

// MARK: Lexing

enum Token: Equatable {
  /// A word's piece, and whether a space came before it (free carets
  /// join pieces with none).
  case word(Word, spaced: Bool)
  case semicolon, newline, ampersand, pipe([Int32]), andAnd, orOr, caret
  case leftBrace, rightBrace, leftParen, rightParen, equals, backquote
  case redirect(Redirection.Kind)
  /// A here document's body, read after its line: `Lexer.bodies`' index.
  case hereBody(Int)
  case end
}

struct Lexer {
  let s: [Unicode.Scalar]
  var i = 0
  var spaced = true
  /// Here documents' bodies, by index; the tags whose bodies follow the
  /// current line, in order (9front's readhere); and a body's token, given
  /// after its redirection.
  var bodies: [String] = []
  var pending: [(tag: [Unicode.Scalar], index: Int)] = []
  var queued: [Token] = []

  init(_ text: String) { s = Array(text.unicodeScalars) }

  /// The bodies of the line's here documents, from the input after its
  /// newline: each its lines up to one that is only its tag. One the
  /// input ends inside stays pending (the text is unfinished).
  mutating func readBodies() {
    while let (tag, index) = pending.first {
      var body = ""
      while true {
        guard i < s.count else { return }
        var line: [Unicode.Scalar] = []
        while i < s.count, s[i] != "\n" {
          line.append(s[i])
          i += 1
        }
        guard i < s.count else {
          // The last line, without its newline: the tag, or more to come.
          if line == tag { break }
          i -= line.count
          return
        }
        i += 1  // the newline
        if line == tag { break }
        body.unicodeScalars.append(contentsOf: line)
        body += "\n"
      }
      bodies[index] = body
      pending.removeFirst()
    }
  }

  /// ~, ! and @ are word characters: a word that is just one of them is a
  /// keyword only at a command's start (9front's klook).
  /// Whether a backslash-newline starts at `i`: outside quotes, a space
  /// (9front's getnext), so it ends a word.
  func continues(_ i: Int) -> Bool { s[i] == "\\" && i + 1 < s.count && s[i + 1] == "\n" }

  static func isWordChar(_ c: Unicode.Scalar) -> Bool {
    !" \t\n;&|^$=`'{}()<>#".unicodeScalars.contains(c)
  }

  mutating func next() throws(RcSyntaxError) -> Token {
    if !queued.isEmpty { return queued.removeFirst() }
    spaced = false
    while i < s.count, s[i] == " " || s[i] == "\t" || (s[i] == "\\" && i + 1 < s.count && s[i + 1] == "\n") {
      i += s[i] == "\\" ? 2 : 1
      spaced = true
    }
    if i < s.count, s[i] == "#" {
      while i < s.count, s[i] != "\n" { i += 1 }
    }
    guard i < s.count else { return .end }
    let c = s[i]
    func one(_ t: Token) -> Token {
      i += 1
      return t
    }
    switch c {
    case "\n":
      i += 1
      if !pending.isEmpty { readBodies() }
      return .newline
    case "<" where i + 1 < s.count && s[i + 1] == "<":
      // <<tag, or <<[n]tag: the tag now, its body after the line.
      i += 2
      var fd: Int32 = 0
      if i < s.count, s[i] == "[" { fd = try bracket().0 ?? 0 }
      while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
      var tag: [Unicode.Scalar] = [], quoted = false
      if i < s.count, s[i] == "'" {
        guard case .word(.literal(let text, _), _) = try next() else { throw RcSyntaxError(message: "bad here tag") }
        tag = Array(text.unicodeScalars)
        quoted = true
      } else {
        while i < s.count, Lexer.isWordChar(s[i]), !continues(i) {
          tag.append(s[i])
          i += 1
        }
      }
      guard !tag.isEmpty else { throw RcSyntaxError(message: "a here document needs a tag") }
      bodies.append("")
      pending.append((tag, bodies.count - 1))
      queued.append(.hereBody(bodies.count - 1))
      return .redirect(.here(fd: fd, quoted: quoted))
    case ";": return one(.semicolon)
    case "^": return one(.caret)
    case "{": return one(.leftBrace)
    case "}": return one(.rightBrace)
    case "(":
      // Straight after a word, ( is 9front's SUB: a subscript, which only
      // $name takes (lexed with it), so anywhere else it's an error. A
      // keyword (if, while, ...) isn't a word: `if(c)` is a paren.
      if i > 0, Lexer.isWordChar(s[i - 1]) || s[i - 1] == "'" {
        var k = i
        while k > 0, Lexer.isWordChar(s[k - 1]) { k -= 1 }
        let word = String(String.UnicodeScalarView(s[k..<i]))
        let keyword = s[i - 1] != "'" && (k == 0 || (s[k - 1] != "$" && s[k - 1] != "#"))
          && ["for", "in", "while", "if", "not", "switch", "fn", "~", "!", "@"].contains(word)
        if !keyword { throw RcSyntaxError(message: "( after a word") }
      }
      return one(.leftParen)
    case ")": return one(.rightParen)
    case "=": return one(.equals)
    case "`": return one(.backquote)
    case "&":
      if i + 1 < s.count, s[i + 1] == "&" {
        i += 2
        return .andAnd
      }
      return one(.ampersand)
    case "|":
      if i + 1 < s.count, s[i + 1] == "|" {
        i += 2
        return .orOr
      }
      i += 1
      if i < s.count, s[i] == "[" {
        let fds = try bracket()
        return .pipe([fds.0 ?? 1])
      }
      return .pipe([1])
    case "<", ">":
      let append = c == ">" && i + 1 < s.count && s[i + 1] == ">"
      i += append ? 2 : 1
      var fd: Int32 = c == "<" ? 0 : 1
      if i < s.count, s[i] == "[" {
        let (a, b, dup) = try bracketDup()
        fd = a ?? fd
        if dup { return .redirect(b.map { .duplicate(fd: fd, to: $0) } ?? .close(fd: fd)) }
      }
      return .redirect(c == "<" ? .read(fd: fd) : append ? .append(fd: fd) : .write(fd: fd))
    case "'":
      i += 1
      var text = ""
      while true {
        guard i < s.count else { throw RcSyntaxError(message: "eof in quoted string", incomplete: true) }
        if s[i] == "'" {
          if i + 1 < s.count, s[i + 1] == "'" {
            text.unicodeScalars.append("'")
            i += 2
            continue
          }
          i += 1
          break
        }
        text.unicodeScalars.append(s[i])
        i += 1
      }
      return .word(.literal(text, quoted: true), spaced: spaced)
    case "$":
      i += 1
      var kind = 0  // 1: count, 2: joined
      if i < s.count, s[i] == "#" {
        kind = 1
        i += 1
      } else if i < s.count, s[i] == "\"" {
        kind = 2
        i += 1
      }
      // A name: letters, digits and _, or * (the arguments).
      var name = ""
      while i < s.count, s[i].properties.isAlphabetic || s[i].properties.numericType != nil || s[i] == "_"
        || (s[i] == "*" && name.isEmpty)
      {
        name.unicodeScalars.append(s[i])
        i += 1
        if name == "*" { break }
      }
      guard !name.isEmpty else { throw RcSyntaxError(message: "$ without a name") }
      if kind == 1 { return .word(.count(name), spaced: spaced) }
      if kind == 2 { return .word(.joined(name), spaced: spaced) }
      // A subscript: $x(1 2), with no space before the parenthesis.
      if i < s.count, s[i] == "(" {
        i += 1
        var subs: [Word] = []
        let sp = spaced
        while true {
          let t = try next()
          if t == .rightParen { break }
          guard case .word(let w, _) = t else { throw RcSyntaxError(message: "bad subscript") }
          subs.append(w)
        }
        return .word(.variable(name, index: subs), spaced: sp)
      }
      return .word(.variable(name, index: nil), spaced: spaced)
    default:
      var text = ""
      while i < s.count, Lexer.isWordChar(s[i]), !continues(i) {
        text.unicodeScalars.append(s[i])
        i += 1
      }
      return .word(.literal(text, quoted: false), spaced: spaced)
    }
  }

  /// [n] after | or a redirection.
  mutating func bracket() throws(RcSyntaxError) -> (Int32?, Int32?) {
    let (a, b, _) = try bracketDup()
    return (a, b)
  }

  /// [n], [n=m] or [n=]: the numbers, and whether there was an =.
  mutating func bracketDup() throws(RcSyntaxError) -> (Int32?, Int32?, Bool) {
    i += 1  // [
    func number() -> Int32? {
      var n: Int32? = nil
      while i < s.count, let d = s[i].properties.numericType != nil ? Int32(String(s[i])) : nil {
        n = (n ?? 0) * 10 + d
        i += 1
      }
      return n
    }
    let a = number()
    var b: Int32? = nil, dup = false
    if i < s.count, s[i] == "=" {
      dup = true
      i += 1
      b = number()
    }
    guard i < s.count, s[i] == "]" else { throw RcSyntaxError(message: "bad [n] or [n=m]") }
    i += 1
    return (a, b, dup)
  }
}

// MARK: Parsing

public struct Parser {
  var tokens: [Token] = []
  var at = 0

  /// Parses a whole script (or one line typed).
  public static func parse(_ text: String) throws(RcSyntaxError) -> Command {
    var (p, lexError) = tokens(text)
    if let lexError { throw lexError }
    do throws(RcSyntaxError) {
      return try p.list(until: [.end])
    } catch {
      throw p.judged(error)
    }
  }

  /// A script's lines, as 9front reads them (`rc: line '\n'`): each
  /// parsed alone, so a syntax error stops the script at its line, the
  /// lines before it still run. The error, if any, comes after them.
  public static func lines(_ text: String) -> (lines: [Command], error: RcSyntaxError?) {
    var (p, lexError) = tokens(text)
    var lines: [Command] = []
    while true {
      while p.peek == .newline || p.peek == .semicolon { p.at += 1 }
      if p.peek == .end { return (lines, lexError) }
      do throws(RcSyntaxError) {
        lines.append(try p.list(until: [.newline, .end]))
      } catch {
        // A line cut short by a lexing error is that error.
        return (lines, lexError ?? p.judged(error))
      }
    }
  }

  /// The text's tokens, each here document's body in its redirection's
  /// place, and the error that ended the lexing early, if one did (the
  /// tokens then stop there).
  static func tokens(_ text: String) -> (Parser, RcSyntaxError?) {
    var lexer = Lexer(text)
    var p = Parser()
    var lexError: RcSyntaxError? = nil
    do throws(RcSyntaxError) {
      while true {
        let t = try lexer.next()
        p.tokens.append(t)
        if t == .end { break }
      }
    } catch {
      // The line it cut short goes too: none of it runs.
      lexError = error
      while let last = p.tokens.last, last != .newline { p.tokens.removeLast() }
      p.tokens.append(.end)
    }
    // The input ending inside a here document leaves the text unfinished.
    if lexError == nil && !lexer.pending.isEmpty {
      lexError = RcSyntaxError(message: "unfinished here document", incomplete: true)
    }
    for k in p.tokens.indices {
      if case .hereBody(let index) = p.tokens[k] {
        let body = index < lexer.bodies.count ? lexer.bodies[index] : ""
        p.tokens[k] = .word(.literal(body, quoted: true), spaced: true)
      }
    }
    return (p, lexError)
  }

  /// Failing at the text's end: unfinished, not wrong.
  func judged(_ error: RcSyntaxError) -> RcSyntaxError {
    var e = error
    if at >= tokens.count - 1 { e.incomplete = true }
    return e
  }

  var peek: Token { tokens[at] }
  mutating func take() -> Token {
    defer { at += 1 }
    return tokens[at]
  }
  mutating func expect(_ t: Token, _ what: String) throws(RcSyntaxError) {
    guard take() == t else { throw RcSyntaxError(message: "expected " + what) }
  }
  mutating func skipNewlines() { while peek == .newline { at += 1 } }

  /// Commands separated by ; & and newlines, until one of `stops`.
  mutating func list(until stops: [Token]) throws(RcSyntaxError) -> Command {
    var commands: [Command] = []
    while true {
      while (peek == .newline && !stops.contains(.newline)) || peek == .semicolon { at += 1 }
      if stops.contains(peek) { break }
      if peek == .end { throw RcSyntaxError(message: "unfinished", incomplete: true) }
      var c = try andOr()
      if peek == .ampersand {
        at += 1
        c = .background(c)
      }
      commands.append(c)
      guard peek == .semicolon || peek == .newline || peek == .ampersand || stops.contains(peek) else {
        throw RcSyntaxError(message: "unexpected \(peek)")
      }
    }
    return commands.count == 1 ? commands[0] : commands.isEmpty ? .empty : .sequence(commands)
  }

  mutating func andOr() throws(RcSyntaxError) -> Command {
    var c = try notCommand()
    while peek == .andAnd || peek == .orOr {
      let op = take()
      skipNewlines()
      let r = try notCommand()
      c = op == .andAnd ? .and(c, r) : .or(c, r)
    }
    return c
  }

  mutating func notCommand() throws(RcSyntaxError) -> Command {
    if keyword("!") {
      at += 1
      return .not(try notCommand())
    }
    // @ cmd: a subshell (9front's SUBSHELL, with BANG's precedence).
    if keyword("@") {
      at += 1
      return .subshell(try notCommand())
    }
    if let assigned = try assignments(then: { (p: inout Parser) throws(RcSyntaxError) in try p.notCommand() }) {
      return assigned
    }
    return try pipeline()
  }

  /// The name of an assignment starting here (a word, then =), taken.
  mutating func assignmentName() -> Word? {
    guard case .word = peek else { return nil }
    let start = at
    if let name = try? word(), peek == .equals {
      at += 1
      return name
    }
    at = start
    return nil
  }

  /// name=value ..., then a command or nothing (9front's `assign cmd`,
  /// with BANG's precedence: the command is a whole pipeline). With
  /// nothing after them, each is global, in order; with a command, all are
  /// local to it, each seeing those before. Nil if none starts here.
  mutating func assignments(then command: (inout Parser) throws(RcSyntaxError) -> Command)
    throws(RcSyntaxError) -> Command?
  {
    var assigns: [(Word, Word)] = []
    while let name = assignmentName() {
      assigns.append((name, try word() ?? .list([])))
    }
    guard !assigns.isEmpty else { return nil }
    let ends: [Token] = [.semicolon, .newline, .end, .ampersand, .rightBrace, .rightParen, .andAnd, .orOr]
    var isPipe = false
    if case .pipe = peek { isPipe = true }
    if ends.contains(peek) || isPipe {
      let global = assigns.map { Command.assign($0.0, $0.1, body: nil) }
      return global.count == 1 ? global[0] : .sequence(global)
    }
    var body = try command(&self)
    for (name, value) in assigns.reversed() { body = .assign(name, value, body: body) }
    return body
  }

  mutating func pipeline() throws(RcSyntaxError) -> Command {
    var stages = [try command()]
    var fds: [Int32] = []
    while case .pipe(let f) = peek {
      at += 1
      skipNewlines()
      fds.append(f[0])
      stages.append(try command())
    }
    return stages.count == 1 ? stages[0] : .pipeline(stages, fds: fds)
  }

  /// A word, joining pieces that touch (free carets) and ^.
  mutating func word() throws(RcSyntaxError) -> Word? {
    var pieces: [Word] = []
    func piece() throws(RcSyntaxError) -> Word? {
      switch peek {
      case .word(let w, _):
        at += 1
        return w
      case .backquote:
        at += 1
        try expect(.leftBrace, "{ after `")
        let c = try list(until: [.rightBrace])
        try expect(.rightBrace, "}")
        return .backquote(c)
      case .leftParen:
        at += 1
        var items: [Word] = []
        while peek != .rightParen {
          skipNewlines()
          if peek == .rightParen { break }
          guard let w = try word() else { throw RcSyntaxError(message: "bad list") }
          items.append(w)
        }
        at += 1
        return .list(items)
      default:
        return nil
      }
    }
    guard let first = try piece() else { return nil }
    pieces.append(first)
    while true {
      if peek == .caret {
        at += 1
        guard let p = try piece() else { throw RcSyntaxError(message: "^ at the end of a word") }
        pieces.append(p)
        continue
      }
      // Free carets: a piece with no space before it.
      if case .word(let w, let spaced) = peek, !spaced {
        at += 1
        pieces.append(w)
        continue
      }
      break
    }
    return pieces.count == 1 ? pieces[0] : .concat(pieces)
  }

  func keyword(_ name: String) -> Bool {
    if case .word(.literal(let s, quoted: false), _) = peek { return s == name }
    return false
  }

  mutating func redirection() throws(RcSyntaxError) -> Redirection? {
    guard case .redirect(let kind) = peek else { return nil }
    at += 1
    switch kind {
    case .duplicate, .close: return Redirection(kind: kind, target: nil)
    default:
      guard let w = try word() else { throw RcSyntaxError(message: "redirection without a file") }
      return Redirection(kind: kind, target: w)
    }
  }

  mutating func body() throws(RcSyntaxError) -> Command {
    skipNewlines()
    if peek == .end { throw RcSyntaxError(message: "a body to come", incomplete: true) }
    // IF, WHILE and FOR bind loosest (9front's precedence): a body takes
    // pipes, && and ||, to the end of its line or list.
    return try andOr()
  }

  mutating func command() throws(RcSyntaxError) -> Command {
    if peek == .leftBrace {
      at += 1
      let c = try list(until: [.rightBrace])
      try expect(.rightBrace, "}")
      var redirs: [Redirection] = []
      while let r = try redirection() { redirs.append(r) }
      return .brace(c, redirs)
    }
    if keyword("~") {
      at += 1
      guard let subject = try word() else { throw RcSyntaxError(message: "~ without a subject") }
      var patterns: [Word] = []
      while let w = try word() { patterns.append(w) }
      return .match(subject, patterns)
    }
    if keyword("if") {
      at += 1
      if keyword("not") {
        at += 1
        return .ifNot(try body())
      }
      try expect(.leftParen, "( after if")
      let c = try list(until: [.rightParen])
      try expect(.rightParen, ")")
      return .ifThen(condition: c, body: try body())
    }
    if keyword("while") {
      at += 1
      try expect(.leftParen, "( after while")
      let c = try list(until: [.rightParen])
      try expect(.rightParen, ")")
      return .whileDo(condition: c, body: try body())
    }
    if keyword("for") {
      at += 1
      try expect(.leftParen, "( after for")
      guard case .word(.literal(let name, _), _) = take() else { throw RcSyntaxError(message: "for without a name") }
      var items: [Word]? = nil
      if keyword("in") {
        at += 1
        items = []
        while peek != .rightParen {
          guard let w = try word() else { throw RcSyntaxError(message: "bad for list") }
          items!.append(w)
        }
      }
      try expect(.rightParen, ")")
      return .forIn(name, list: items, body: try body())
    }
    if keyword("switch") {
      at += 1
      try expect(.leftParen, "( after switch")
      guard let subject = try word() else { throw RcSyntaxError(message: "switch without a subject") }
      try expect(.rightParen, ")")
      skipNewlines()
      try expect(.leftBrace, "{ after switch")
      var cases: [(patterns: [Word], body: [Command])] = []
      while true {
        while peek == .newline || peek == .semicolon { at += 1 }
        if peek == .rightBrace { break }
        guard keyword("case") else { throw RcSyntaxError(message: "expected case") }
        at += 1
        var patterns: [Word] = []
        while let w = try word() { patterns.append(w) }
        var body: [Command] = []
        while true {
          while peek == .newline || peek == .semicolon { at += 1 }
          if peek == .rightBrace || keyword("case") { break }
          if peek == .end { throw RcSyntaxError(message: "unfinished", incomplete: true) }
          let c = try andOr()
          if peek == .ampersand {
            at += 1
            body.append(.background(c))
            continue
          }
          body.append(c)
          guard peek == .semicolon || peek == .newline || peek == .rightBrace || keyword("case")
          else { throw RcSyntaxError(message: "unexpected \(peek)") }
        }
        cases.append((patterns, body))
      }
      at += 1
      return .switchOn(subject, cases: cases)
    }
    if keyword("fn") {
      at += 1
      guard case .word(.literal(let name, _), _) = take() else { throw RcSyntaxError(message: "fn without a name") }
      if peek == .leftBrace {
        at += 1
        let c = try list(until: [.rightBrace])
        try expect(.rightBrace, "}")
        return .function(name, body: c)
      }
      return .function(name, body: nil)
    }
    // Assignments, where a command is parsed alone (a body).
    if let assigned = try assignments(then: { (p: inout Parser) throws(RcSyntaxError) in try p.command() }) {
      return assigned
    }
    var words: [Word] = []
    var redirs: [Redirection] = []
    while true {
      if let r = try redirection() {
        redirs.append(r)
      } else if let w = try word() {
        words.append(w)
      } else {
        // = outside an assignment is an error, as in 9front: quote it.
        break
      }
    }
    if words.isEmpty && redirs.isEmpty { return .empty }
    return .simple(words, redirs)
  }
}
