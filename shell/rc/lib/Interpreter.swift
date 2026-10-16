// SPDX-License-Identifier: BSD-3-Clause

// rc's evaluation (M6j part 2c), after Duff's paper: every value is a list
// of strings; a concatenation pairs two lists of the same length, or
// distributes a one-string list over the other (an empty one is an error);
// $status is '' for success. Commands run with descriptors (0 stdin, 1
// stdout, 2 stderr, and any a redirection makes) that are streams the
// system gives: files, pipes, a terminal. What isn't rc's own (programs,
// files, pipes, directories) is `RcSystem`'s: natively processes from
// bootfs and fdio's files, in tests an in-memory machine.
//
// Builtins: cd, echo (-n), eval, exit, pwd, shift, whatis, wait, and `.`
// (a script, run here). A pipeline starts its programs first and then runs
// its builtins and functions in order, so a builtin never waits on a
// reader that hasn't started.

/// A descriptor's stream.
public protocol RcStream: AnyObject {
  func write(_ bytes: [UInt8])
  /// The next bytes, or nil at the end.
  func read() -> [UInt8]?
  func close()
}

/// A program the system started, not yet waited for.
public protocol RcJob: AnyObject {
  /// Its status: '' for success, else its exit code (or why it couldn't run).
  func wait() -> String
}

public enum RcOpen: Sendable {
  case read, write, append
}

/// What rc needs of the machine.
public protocol RcSystem: AnyObject {
  func open(_ path: String, _ mode: RcOpen) -> RcStream?
  /// A pipe: what's written to the second is read from the first.
  func pipe() -> (RcStream, RcStream)
  /// Starts a program with descriptors `fds`; nil if there's no such
  /// program (or it can't start: `why` says).
  func start(_ argv: [String], fds: [Int32: RcStream], environment: [(String, [String])]) -> RcJob?
  /// Whether `name` names a program the system can start.
  func exists(_ name: String) -> Bool
  func changeDirectory(_ path: String) -> Bool
  var directory: String { get }
  /// The names in `directory` (for globbing).
  func list(_ directory: String) -> [String]?
  /// A file's typed attributes (M6j, `attr`: settings are files with
  /// attributes), each as text; nil if it can't say.
  func attributes(_ path: String) -> [(name: String, value: AttributeText)]?
  /// Sets one (typed as `AttributeText.parse` reads the text), or removes
  /// it (nil); whether it could.
  func setAttribute(_ path: String, _ name: String, _ value: AttributeText?) -> Bool
  /// rc's own process's number ($pid).
  var processID: UInt64 { get }
  /// Runs `body` on a thread of its own, its job waiting for it: a
  /// background command that isn't one program (9front forks it). Nil if
  /// the system can't, and it runs in the foreground.
  func spawn(_ body: @escaping @Sendable () -> Void) -> RcJob?
}

extension RcSystem {
  public var processID: UInt64 { 1 }
  public func spawn(_ body: @escaping @Sendable () -> Void) -> RcJob? { nil }

  /// Whether `path` names something: its directory's listing holds its
  /// last name (globbing keeps a path ending in literal names only so).
  public func accessible(_ path: String) -> Bool {
    let names = path.split(separator: "/", omittingEmptySubsequences: false)
    guard let last = names.last, !last.isEmpty else { return list(path) != nil }
    let parent = names.dropLast().joined(separator: "/")
    let dir = parent.isEmpty ? (path.hasPrefix("/") ? "/" : directory) : parent
    return list(dir)?.contains(String(last)) ?? false
  }

  public func attributes(_ path: String) -> [(name: String, value: AttributeText)]? { nil }
  public func setAttribute(_ path: String, _ name: String, _ value: AttributeText?) -> Bool { false }
}

/// An attribute's value as rc writes and reads it: a number is an int64,
/// `true` and `false` a bool, anything else a string (Taisce's kinds:
/// string 1, int64 2, bool 6; others shown, not set).
public enum AttributeText: Equatable, Sendable {
  case string(String)
  case int(Int64)
  case bool(Bool)
  /// A kind rc only shows (its text).
  case other(String)

  public static func parse(_ text: String) -> AttributeText {
    if let v = Int64(text) { return .int(v) }
    if text == "true" { return .bool(true) }
    if text == "false" { return .bool(false) }
    return .string(text)
  }

  public var text: String {
    switch self {
    case .string(let s), .other(let s): return s
    case .int(let v): return String(v)
    case .bool(let v): return v ? "true" : "false"
    }
  }
}

/// A stream into memory: backquote's output, a builtin's in tests.
public final class MemoryStream: RcStream {
  public var bytes: [UInt8] = []
  var at = 0
  public var closed = false
  public init(_ bytes: [UInt8] = []) { self.bytes = bytes }
  public func write(_ b: [UInt8]) { bytes += b }
  public func read() -> [UInt8]? {
    guard at < bytes.count else { return nil }
    defer { at = bytes.count }
    return Array(bytes[at...])
  }
  public func close() { closed = true }
  public var text: String { String(decoding: bytes, as: UTF8.self) }
}

struct RcError: Error {
  var message: String
}

/// `exit`, unwinding to the top.
struct RcExit: Error {
  var status: String
}

public final class Rc {
  public let system: RcSystem
  public var variables: [String: [String]] = ["status": [""], "ifs": [" \t\n"]]
  public var functions: [String: Command] = [:]
  /// Programs started in the background (`&`), by $apid.
  var background: [RcJob] = []
  /// Whether an `if` has run whose `if not` should (9front's ifnot).
  var ifNotPending = false

  /// `name` is $0: the script's path, or rc for a line given (9front's
  /// execcmds sets it to its argv[0]).
  public init(system: RcSystem, name: String = "rc", arguments: [String] = []) {
    self.system = system
    variables["*"] = arguments
    variables["0"] = [name]
    variables["pid"] = [String(system.processID)]
  }

  public var status: String { (variables["status"] ?? [""]).joined(separator: "|") }
  /// Whether the status is true (9front's truestatus).
  public var succeeded: Bool { ok() }

  /// Runs a script's text with these descriptors; its status, or nil
  /// after `exit` (the status in $status).
  @discardableResult
  public func run(_ text: String, fds: [Int32: RcStream]) -> Bool {
    do {
      try runLines(text, fds)
      return true
    } catch let e as RcSyntaxError {
      fds[2]?.write(Array((e.description + "\n").utf8))
      variables["status"] = ["syntax error"]
      return true
    } catch let e as RcExit {
      variables["status"] = [e.status]
      return false
    } catch let e as RcError {
      report(e, fds)
      return true
    } catch {
      return true
    }
  }

  /// Runs a script line by line (Parser.lines); a syntax error is thrown
  /// once the lines before it have run.
  func runLines(_ text: String, _ fds: [Int32: RcStream]) throws {
    let (lines, error) = Parser.lines(text)
    for c in lines { try execute(c, fds) }
    if let error { throw error }
  }

  /// 9front's truestatus: nothing but `|` and `0`.
  func ok() -> Bool { status.allSatisfy { $0 == "|" || $0 == "0" } }

  // MARK: Words

  /// The elements of `all` one subscript names (9front's subwords): `n`,
  /// `n-m` or `n-` (to the end), origin 1. Digits are read from the
  /// start and anything after them ignored; a range past the end stops
  /// there; a start out of range, or an end before it, names none.
  static func subscripted(_ all: [String], _ s: String) -> [String] {
    var digits = s.utf8[...]
    func number() -> Int {
      var n = 0
      while let d = digits.first, d >= 0x30, d <= 0x39 {
        n = n * 10 + Int(d - 0x30)
        digits = digits.dropFirst()
      }
      return n
    }
    let n = number()
    var m = 0
    if digits.first == UInt8(ascii: "-") {
      digits = digits.dropFirst()
      m = digits.isEmpty ? all.count - n : number() - n
    }
    guard n >= 1, n <= all.count, m >= 0 else { return [] }
    return Array(all[(n - 1)..<min(all.count, n + m)])
  }

  func value(_ w: Word, _ fds: [Int32: RcStream], glob: Bool = true) throws -> [String] {
    switch w {
    case .literal(let s, let quoted):
      if !quoted && glob && s.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" }) {
        let found = expand(s)
        return found.isEmpty ? [s] : found
      }
      return [s]
    case .variable(let name, let index):
      let all = lookup(name)
      guard let index else { return all }
      var out: [String] = []
      for s in try index.flatMap({ try value($0, fds) }) { out += Self.subscripted(all, s) }
      return out
    case .count(let name): return [String(lookup(name).count)]
    case .joined(let name): return [lookup(name).joined(separator: " ")]
    case .list(let items): return try items.flatMap { try value($0, fds) }
    case .concat(let pieces):
      var acc: [String]? = nil
      for p in pieces {
        let v = try value(p, fds, glob: false)
        guard let a = acc else {
          acc = v
          continue
        }
        if a.isEmpty || v.isEmpty { throw RcError(message: "null list in concatenation") }
        if a.count == 1 {
          acc = v.map { a[0] + $0 }
        } else if v.count == 1 {
          acc = a.map { $0 + v[0] }
        } else if a.count == v.count {
          acc = zip(a, v).map { $0 + $1 }
        } else {
          throw RcError(message: "mismatched list lengths in concatenation")
        }
      }
      let out = acc ?? []
      // A concatenation is globbed as a whole if any piece was a plain
      // literal with a pattern character.
      if glob, pieces.contains(where: { if case .literal(let s, false) = $0 { return s.contains { "*?[".contains($0) } } else { return false } }) {
        return out.flatMap { let f = expand($0); return f.isEmpty ? [$0] : f }
      }
      return out
    case .backquote(let c):
      let captured = MemoryStream()
      var inner = fds
      inner[1] = captured
      try contained(c, inner)
      let ifs = Set((variables["ifs"] ?? [" \t\n"]).joined().unicodeScalars)
      var out: [String] = [], current = ""
      for u in captured.text.unicodeScalars {
        if ifs.contains(u) {
          if !current.isEmpty { out.append(current) }
          current = ""
        } else {
          current.unicodeScalars.append(u)
        }
      }
      if !current.isEmpty { out.append(current) }
      return out
    }
  }

  func lookup(_ name: String) -> [String] {
    if let n = Int(name), n >= 1 {
      let args = variables["*"] ?? []
      return n <= args.count ? [args[n - 1]] : []
    }
    return variables[name] ?? []
  }

  // MARK: Patterns

  /// rc's patterns: * any string, ? any character, [abc] [a-z] [~a] one
  /// of a class; matched against a whole string.
  /// A pattern as written: each scalar, and whether it may act as a
  /// pattern character (9front's GLOB marks: only those written unquoted
  /// do; a quoted one, or one from a variable's value, is itself).
  struct Pattern {
    var scalars: [Unicode.Scalar] = []
    var active: [Bool] = []
    init(_ s: String, active: Bool) {
      scalars = Array(s.unicodeScalars)
      self.active = Array(repeating: active, count: scalars.count)
    }
    static func + (a: Pattern, b: Pattern) -> Pattern {
      var p = a
      p.scalars += b.scalars
      p.active += b.active
      return p
    }
  }

  /// A word's patterns (for ~ and case): its strings, each scalar marked
  /// as written (concatenated as `value` does, with its errors).
  func patterns(_ w: Word, _ fds: [Int32: RcStream]) throws -> [Pattern] {
    switch w {
    case .literal(let s, let quoted): return [Pattern(s, active: !quoted)]
    case .list(let items): return try items.flatMap { try patterns($0, fds) }
    case .concat(let pieces):
      var acc: [Pattern]? = nil
      for piece in pieces {
        let v = try patterns(piece, fds)
        guard let a = acc else {
          acc = v
          continue
        }
        if a.isEmpty || v.isEmpty { throw RcError(message: "null list in concatenation") }
        if a.count == 1 {
          acc = v.map { a[0] + $0 }
        } else if v.count == 1 {
          acc = a.map { $0 + v[0] }
        } else if a.count == v.count {
          acc = zip(a, v).map { $0 + $1 }
        } else {
          throw RcError(message: "mismatched list lengths in concatenation")
        }
      }
      return acc ?? []
    default: return try value(w, fds, glob: false).map { Pattern($0, active: false) }
    }
  }

  /// A subject as ~ and switch take it: its strings joined by spaces, one
  /// string (9front's Xqw; none is the empty string).
  func subject(_ w: Word, _ fds: [Int32: RcStream]) throws -> String {
    try value(w, fds).joined(separator: " ")
  }

  public static func matches(_ pattern: String, _ s: String) -> Bool { matches(Pattern(pattern, active: true), s) }

  static func matches(_ pattern: Pattern, _ s: String) -> Bool {
    let p = pattern.scalars, on = pattern.active, t = Array(s.unicodeScalars)
    func m(_ i: Int, _ j: Int) -> Bool {
      if i == p.count { return j == t.count }
      switch on[i] ? p[i] : "\u{0}" {
      case "*":
        for k in j...t.count where m(i + 1, k) { return true }
        return false
      case "?": return j < t.count && m(i + 1, j + 1)
      case "[":
        guard j < t.count, let close = p[(i + 1)...].firstIndex(of: "]") else { return j < t.count && p[i] == t[j] && m(i + 1, j + 1) }
        var k = i + 1
        let negate = p[k] == "~"
        if negate { k += 1 }
        var hit = false
        while k < close {
          if k + 2 < close, p[k + 1] == "-" {
            if p[k].value <= t[j].value && t[j].value <= p[k + 2].value { hit = true }
            k += 3
          } else {
            if p[k] == t[j] { hit = true }
            k += 1
          }
        }
        return hit != negate && m(close + 1, j + 1)
      default: return j < t.count && p[i] == t[j] && m(i + 1, j + 1)
      }
    }
    return m(0, 0)
  }

  /// A pattern's matches among the files, directory by directory, sorted.
  /// As 9front's globdir: each component with a pattern character matches
  /// a directory's entries (`.` and `..` only by a pattern starting with
  /// `.`; other dot files by any), the literal ones between are appended,
  /// and a path that ends in literal ones is kept only if it exists. The
  /// matches sorted by their bytes (globsort).
  func expand(_ pattern: String) -> [String] {
    let absolute = pattern.hasPrefix("/")
    let parts = pattern.split(separator: "/").map(String.init)
    var found: [String] = [absolute ? "/" : ""]
    var literalTail = false, globbed = false
    for part in parts {
      var next: [String] = []
      let isPattern = part.contains(where: { "*?[".contains($0) })
      for base in found {
        guard isPattern else {
          next.append(join(base, part))
          continue
        }
        let dir = base.isEmpty ? system.directory : base
        for name in system.list(dir) ?? [] where Rc.matches(part, name) {
          if (name == "." || name == "..") && !part.hasPrefix(".") { continue }
          next.append(join(base, name))
        }
      }
      found = next
      if found.isEmpty { return [] }
      if isPattern {
        globbed = true
        literalTail = false
      } else if globbed {
        literalTail = true
      }
    }
    if literalTail { found = found.filter { system.accessible($0) } }
    return found.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
  }

  func join(_ base: String, _ name: String) -> String {
    base.isEmpty ? name : base.hasSuffix("/") ? base + name : base + "/" + name
  }

  // MARK: Commands

  func setStatus(_ s: String) { variables["status"] = [s] }

  /// A here document's text with its variables substituted (9front's
  /// psubst): `$name` its strings joined by spaces, `$n` the nth of `$*`,
  /// `$$` a `$`, and a `^` right after a name deleted.
  func hereSubstituted(_ text: String) -> String {
    // 9front's idchr: what a name may hold.
    func isName(_ c: Unicode.Scalar) -> Bool {
      c.value > 0x20 && !"!\"#$%&'()+,-./:;<=>?@[\\]^`{|}~".unicodeScalars.contains(c)
    }
    let s = Array(text.unicodeScalars)
    var out = "", i = 0
    while i < s.count {
      guard s[i] == "$" else {
        out.unicodeScalars.append(s[i])
        i += 1
        continue
      }
      i += 1
      if i < s.count, s[i] == "$" {
        out += "$"
        i += 1
        continue
      }
      var name = ""
      while i < s.count, isName(s[i]) {
        name.unicodeScalars.append(s[i])
        i += 1
      }
      if let n = Int(name), n >= 1, name.unicodeScalars.allSatisfy({ $0.properties.numericType != nil }) {
        let star = lookup("*")
        if n <= star.count { out += star[n - 1] }
      } else {
        out += lookup(name).joined(separator: " ")
      }
      if i < s.count, s[i] == "^" { i += 1 }
    }
    return out
  }

  func redirect(_ redirs: [Redirection], _ fds: [Int32: RcStream]) throws -> [Int32: RcStream] {
    var out = fds
    for r in redirs {
      switch r.kind {
      case .read(let fd), .write(let fd), .append(let fd):
        let names = try value(r.target!, fds)
        guard names.count == 1 else { throw RcError(message: "redirection needs one file") }
        let mode: RcOpen
        if case .read = r.kind { mode = .read } else if case .append = r.kind { mode = .append } else { mode = .write }
        guard let s = system.open(names[0], mode) else { throw RcError(message: "can't open " + names[0]) }
        out[fd] = s
      case .here(let fd, let quoted):
        guard case .literal(let body, _)? = r.target else { throw RcError(message: "bad here document") }
        out[fd] = MemoryStream(Array((quoted ? body : hereSubstituted(body)).utf8))
      case .duplicate(let fd, let to): out[fd] = out[to]  // left to right, as 9front does
      case .close(let fd): out[fd] = nil
      }
    }
    return out
  }

  /// Runs `c`. A runtime error (a bad concatenation, a file that won't
  /// open) unwinds to `run`, as 9front's Xerror does to its input loop:
  /// a script stops; a line typed is abandoned.
  func execute(_ c: Command, _ fds: [Int32: RcStream]) throws { try executeChecked(c, fds) }

  /// Runs `c` where 9front would fork it (a backquote, a builtin's or
  /// function's pipeline stage, a background job): an error ends it
  /// alone, said on fd 2, its status `error`.
  func contained(_ c: Command, _ fds: [Int32: RcStream]) throws {
    do {
      try executeChecked(c, fds)
    } catch let e as RcError {
      report(e, fds)
    }
  }

  func report(_ e: RcError, _ fds: [Int32: RcStream]) {
    fds[2]?.write(Array(("rc: " + e.message + "\n").utf8))
    setStatus("error")
  }

  func executeChecked(_ c: Command, _ fds: [Int32: RcStream]) throws {
    switch c {
    case .empty: break
    case .sequence(let cs, _): for c in cs { try execute(c, fds) }
    case .simple(let words, let redirs):
      let io = try redirect(redirs, fds)
      let argv = try words.flatMap { try value($0, fds) }
      guard !argv.isEmpty else {
        setStatus("")
        return
      }
      if let job = try call(argv, io) { setStatus(job.wait()) }
    case .assign(let nameWord, let w, let body):
      let names = try value(nameWord, fds, glob: false)
      guard names.count == 1, let name = names.first else { throw RcError(message: "variable name not singleton!") }
      let v = try value(w, fds)
      guard let body else {
        variables[name] = v
        return
      }
      let saved = variables[name]
      variables[name] = v
      defer { variables[name] = saved }
      try execute(body, fds)
    case .pipeline(let stages, let pipeFds):
      try pipeline(stages, pipeFds, fds)
    case .subshell(let c):
      // As a fork leaves its parent: rc's variables, functions and
      // directory as they were, the subshell's status kept.
      let saved = (variables, functions, ifNotPending, system.directory)
      try contained(c, fds)
      let status = variables["status"]
      (variables, functions, ifNotPending) = (saved.0, saved.1, saved.2)
      if system.directory != saved.3 { _ = system.changeDirectory(saved.3) }
      variables["status"] = status
    case .not(let c):
      try execute(c, fds)
      setStatus(ok() ? "false" : "")
    case .and(let a, let b):
      try execute(a, fds)
      if ok() { try execute(b, fds) }
    case .or(let a, let b):
      try execute(a, fds)
      if !ok() { try execute(b, fds) }
    case .background(let c):
      // A program runs on; anything else runs here first (rc forks it).
      if case .simple(let words, let redirs) = c, let argv = try? words.flatMap({ try value($0, fds) }),
        let first = argv.first, functions[first] == nil, Rc.builtins[first] == nil, first != "builtin"
      {
        let io = try redirect(redirs, fds)
        if let job = system.start(argv, fds: io, environment: environment) {
          background.append(job)
          variables["apid"] = [String(background.count)]
        }
        setStatus("")
      } else {
        // Anything else as a fork would run it: on a thread, in a copy of
        // rc's variables and functions (the directory is still the
        // process's: a `cd` in it is everyone's).
        let child = Rc(system: system)
        (child.variables, child.functions, child.ifNotPending) = (variables, functions, ifNotPending)
        let work = Unchecked((child, c, fds))
        if let job = system.spawn({
          let (child, c, fds) = work.value
          do { try child.contained(c, fds) } catch {}
        }) {
          background.append(job)
          variables["apid"] = [String(background.count)]
          setStatus("")
        } else {
          try contained(c, fds)
        }
      }
    case .brace(let c, let redirs): try execute(c, try redirect(redirs, fds))
    case .ifThen(let condition, let body):
      // 9front's ifnot: set by an if, cleared once a true one's body has
      // run (so an if inside that body can't leave it set).
      try execute(condition, fds)
      ifNotPending = true
      if ok() {
        try execute(body, fds)
        ifNotPending = false
      }
    case .ifNot(let body):
      if ifNotPending { try execute(body, fds) }
    case .forIn(let name, let list, let body):
      let items = try list.map { try $0.flatMap { try value($0, fds) } } ?? (variables["*"] ?? [])
      // Its variable is local to the loop (9front's Xlocal).
      let outer = variables[name]
      defer { variables[name] = outer }
      for item in items {
        variables[name] = [item]
        try execute(body, fds)
      }
    case .whileDo(let condition, let body):
      while true {
        // An empty condition is true (9front's Xsettrue); a failing one's
        // status is the loop's.
        if condition == .empty { setStatus("") } else { try execute(condition, fds) }
        guard ok() else { break }
        try execute(body, fds)
      }
    case .switchOn(let subject, let cases):
      let s = try self.subject(subject, fds)
      for k in cases {
        let ps = try k.patterns.flatMap { try patterns($0, fds) }
        if ps.contains(where: { Rc.matches($0, s) }) {
          for c in k.body { try execute(c, fds) }
          return
        }
      }
    case .match(let subject, let pats):
      let s = try self.subject(subject, fds)
      let ps = try pats.flatMap { try patterns($0, fds) }
      setStatus(ps.contains { Rc.matches($0, s) } ? "" : "no match")
    case .function(let name, let body):
      functions[name] = body
      if body == nil { functions[name] = nil }
    }
  }

  var environment: [(String, [String])] { variables.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }

  /// A command by its name: a function, a builtin, or a program (started;
  /// its job returned to wait for).
  func call(_ argv: [String], _ fds: [Int32: RcStream]) throws -> RcJob? {
    let name = argv[0]
    if let body = functions[name] {
      let saved = variables["*"]
      variables["*"] = Array(argv.dropFirst())
      defer { variables["*"] = saved }
      try execute(body, fds)
      return nil
    }
    // builtin cmd: cmd as a builtin or a program, never a function.
    if name == "builtin" {
      guard argv.count > 1 else { throw RcError(message: "builtin: empty argument list") }
      return try command(Array(argv.dropFirst()), fds)
    }
    return try command(argv, fds)
  }

  /// A builtin or a program, by its name.
  func command(_ argv: [String], _ fds: [Int32: RcStream]) throws -> RcJob? {
    let name = argv[0]
    if let builtin = Rc.builtins[name] {
      try builtin(self, argv, fds)
      return nil
    }
    guard let job = system.start(argv, fds: fds, environment: environment) else {
      fds[2]?.write(Array((name + ": not found\n").utf8))
      setStatus("not found")
      return nil
    }
    return job
  }

  func pipeline(_ stages: [Command], _ pipeFds: [Int32], _ fds: [Int32: RcStream]) throws {
    // Each stage's descriptors: its fd (1 or as |[n] says) into the
    // next's 0.
    var ios: [[Int32: RcStream]] = Array(repeating: fds, count: stages.count)
    var pipes: [(RcStream, RcStream)] = []
    for k in 0..<(stages.count - 1) {
      let p = system.pipe()
      pipes.append(p)
      ios[k][pipeFds[k]] = p.1
      ios[k + 1][0] = p.0
    }
    // Programs first; then the rest in order, each one's write end closed
    // once it's done (its reader's end of input).
    var jobs: [RcJob?] = Array(repeating: nil, count: stages.count)
    var started = Array(repeating: false, count: stages.count)
    for (k, stage) in stages.enumerated() {
      if case .simple(let words, let redirs) = stage, let argv = try? words.flatMap({ try value($0, ios[k]) }),
        let first = argv.first, functions[first] == nil, Rc.builtins[first] == nil, system.exists(first)
      {
        jobs[k] = system.start(argv, fds: try redirect(redirs, ios[k]), environment: environment)
        started[k] = true
        if k < pipes.count { pipes[k].1.close() }
      }
    }
    var statuses: [String] = Array(repeating: "", count: stages.count)
    for (k, stage) in stages.enumerated() where !started[k] {
      try contained(stage, ios[k])
      statuses[k] = status
      if k < pipes.count { pipes[k].1.close() }
    }
    for (k, job) in jobs.enumerated() { if let job { statuses[k] = job.wait() } }
    // One string, left to right, a | after each non-empty part (9front's
    // concstatus, as its pipeline nests: false|true is `1|`, true|false `1`).
    setStatus(statuses.dropFirst().reduce(statuses[0]) { ($0.isEmpty ? "" : $0 + "|") + $1 })
  }

  // MARK: Builtins

  nonisolated(unsafe) static let builtins: [String: (Rc, [String], [Int32: RcStream]) throws -> Void] = [
    "cd": { rc, argv, fds in
      let target = argv.count > 1 ? argv[1] : (rc.variables["home"]?.first ?? "/")
      if rc.system.changeDirectory(target) {
        rc.setStatus("")
      } else {
        fds[2]?.write(Array(("cd: " + target + ": not found\n").utf8))
        rc.setStatus("can't cd")
      }
    },
    "echo": { rc, argv, fds in
      var args = Array(argv.dropFirst())
      var newline = true
      if args.first == "-n" {
        newline = false
        args.removeFirst()
      }
      // As 9front's echo: fd 1 closed is a write error.
      guard let out = fds[1] else {
        fds[2]?.write(Array("echo: write error: fd 1 closed\n".utf8))
        return rc.setStatus("write error")
      }
      out.write(Array((args.joined(separator: " ") + (newline ? "\n" : "")).utf8))
      rc.setStatus("")
    },
    // attr FILE: its attributes, a line each; attr FILE NAME: one's value;
    // attr FILE NAME VALUE: sets it (a number an int64, true or false a
    // bool, else a string); attr -d FILE NAME: removes it (M6j: every
    // setting is a file with attributes, and Terminal can change it).
    "attr": { rc, argv, fds in
      var args = Array(argv.dropFirst())
      let remove = args.first == "-d"
      if remove { args.removeFirst() }
      func fail(_ why: String) {
        fds[2]?.write(Array(("attr: " + why + "\n").utf8))
        rc.setStatus("attr failed")
      }
      guard let file = args.first else { return fail("usage: attr [-d] file [name [value]]") }
      switch (remove, args.count) {
      case (true, 2):
        if rc.system.setAttribute(file, args[1], nil) { rc.setStatus("") } else { fail(file + ": can't remove " + args[1]) }
      case (false, 1), (false, 2):
        guard let all = rc.system.attributes(file) else { return fail(file + ": no attributes") }
        if args.count == 2 {
          guard let v = all.first(where: { $0.name == args[1] }) else { return fail(file + ": no " + args[1]) }
          fds[1]?.write(Array((v.value.text + "\n").utf8))
        } else {
          for a in all { fds[1]?.write(Array((a.name + " " + a.value.text + "\n").utf8)) }
        }
        rc.setStatus("")
      case (false, _):
        let value = AttributeText.parse(args.dropFirst(2).joined(separator: " "))
        if rc.system.setAttribute(file, args[1], value) { rc.setStatus("") } else { fail(file + ": can't set " + args[1]) }
      default:
        fail("usage: attr [-d] file [name [value]]")
      }
    },
    "pwd": { rc, _, fds in
      fds[1]?.write(Array((rc.system.directory + "\n").utf8))
      rc.setStatus("")
    },
    "exit": { rc, argv, _ in throw RcExit(status: argv.count > 1 ? argv[1] : rc.status) },
    "eval": { rc, argv, fds in
      let c = try Parser.parse(argv.dropFirst().joined(separator: " "))
      try rc.execute(c, fds)
    },
    "shift": { rc, argv, _ in
      let n = argv.count > 1 ? Int(argv[1]) ?? 1 : 1
      var args = rc.variables["*"] ?? []
      args.removeFirst(min(n, args.count))
      rc.variables["*"] = args
      rc.setStatus("")
    },
    "whatis": { rc, argv, fds in
      // As 9front's execwhatis: a variable, then a function, a builtin or a
      // program; a name that is none of them only sets the status.
      rc.setStatus("")
      for name in argv.dropFirst() {
        // One word bare, several in parentheses; an empty list is unset.
        let v = rc.variables[name].flatMap { $0.isEmpty ? nil : $0 }
        if let v {
          let text = v.count == 1 ? Rc.quote(v[0]) : "(" + v.map(Rc.quote).joined(separator: " ") + ")"
          fds[1]?.write(Array((name + "=" + text + "\n").utf8))
        }
        if let body = rc.functions[name] {
          fds[1]?.write(Array((Rc.text(.function(name, body: body), 0) + "\n").utf8))
        } else if builtins[name] != nil {
          fds[1]?.write(Array(("builtin " + name + "\n").utf8))
        } else if rc.system.exists(name) {
          fds[1]?.write(Array((name + "\n").utf8))
        } else if v == nil {
          rc.setStatus("not found")
        }
      }
    },
    "wait": { rc, _, _ in
      for job in rc.background { _ = job.wait() }
      rc.background.removeAll()
      rc.setStatus("")
    },
    ".": { rc, argv, fds in
      guard argv.count > 1, let s = rc.system.open(argv[1], .read) else {
        fds[2]?.write(Array((".: can't open " + (argv.count > 1 ? argv[1] : "") + "\n").utf8))
        rc.setStatus("can't open")
        return
      }
      var text: [UInt8] = []
      while let b = s.read() { text += b }
      let saved = rc.variables["*"]
      rc.variables["*"] = Array(argv.dropFirst(2))
      defer { rc.variables["*"] = saved }
      try rc.runLines(String(decoding: text, as: UTF8.self), fds)
    },
  ]
}

extension String {
  func replacingOccurrences(_ a: String, _ b: String) -> String {
    var out = ""
    var rest = self[...]
    while let r = rest.range(of: a) {
      out += rest[..<r.lowerBound] + b
      rest = rest[r.upperBound...]
    }
    return out + rest
  }
}

extension Substring {
  /// The first range of `s` (no Foundation here).
  func range(of s: String) -> Range<Index>? {
    guard !s.isEmpty else { return nil }
    var i = startIndex
    while i < endIndex {
      if self[i...].hasPrefix(s) { return i..<index(i, offsetBy: s.count) }
      i = index(after: i)
    }
    return nil
  }
}

/// A value handed to a thread that alone uses it from then on.
struct Unchecked<T>: @unchecked Sendable {
  var value: T
  init(_ value: T) { self.value = value }
}
