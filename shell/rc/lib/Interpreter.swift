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
}

extension RcSystem {
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
  /// Whether the last `if` ran its body (for `if not`).
  var lastIf = true

  public init(system: RcSystem, arguments: [String] = []) {
    self.system = system
    variables["*"] = arguments
  }

  public var status: String { (variables["status"] ?? [""]).joined(separator: "|") }
  /// Whether the status is true: every stage's empty (9front's truestatus).
  public var succeeded: Bool { (variables["status"] ?? [""]).allSatisfy { $0.isEmpty } }

  /// Runs a script's text with these descriptors; its status, or nil
  /// after `exit` (the status in $status).
  @discardableResult
  public func run(_ text: String, fds: [Int32: RcStream]) -> Bool {
    do {
      let c = try Parser.parse(text)
      try execute(c, fds)
      return true
    } catch let e as RcSyntaxError {
      fds[2]?.write(Array((e.description + "\n").utf8))
      variables["status"] = ["syntax error"]
      return true
    } catch let e as RcExit {
      variables["status"] = [e.status]
      return false
    } catch {
      return true
    }
  }

  func ok() -> Bool { status.allSatisfy { $0 == "|" } }

  // MARK: Words

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
      for s in try index.flatMap({ try value($0, fds) }) {
        if let n = Int(s), n >= 1, n <= all.count { out.append(all[n - 1]) }
      }
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
      try execute(c, inner)
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
  public static func matches(_ pattern: String, _ s: String) -> Bool {
    let p = Array(pattern.unicodeScalars), t = Array(s.unicodeScalars)
    func m(_ i: Int, _ j: Int) -> Bool {
      if i == p.count { return j == t.count }
      switch p[i] {
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
  func expand(_ pattern: String) -> [String] {
    let absolute = pattern.hasPrefix("/")
    let parts = pattern.split(separator: "/").map(String.init)
    var found: [String] = [absolute ? "/" : ""]
    for (n, part) in parts.enumerated() {
      let last = n == parts.count - 1
      var next: [String] = []
      for base in found {
        if !part.contains(where: { "*?[".contains($0) }) {
          next.append(join(base, part))
          continue
        }
        let dir = base.isEmpty ? system.directory : base
        for name in (system.list(dir) ?? []).sorted() where Rc.matches(part, name) {
          if name.hasPrefix(".") && !part.hasPrefix(".") { continue }
          next.append(join(base, name))
        }
      }
      found = next
      if found.isEmpty { return [] }
      _ = last
    }
    return found
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

  func execute(_ c: Command, _ fds: [Int32: RcStream]) throws {
    do {
      try executeChecked(c, fds)
    } catch let e as RcError {
      fds[2]?.write(Array(("rc: " + e.message + "\n").utf8))
      setStatus("error")
    }
  }

  func executeChecked(_ c: Command, _ fds: [Int32: RcStream]) throws {
    switch c {
    case .empty: break
    case .sequence(let cs): for c in cs { try execute(c, fds) }
    case .simple(let words, let redirs):
      let io = try redirect(redirs, fds)
      let argv = try words.flatMap { try value($0, fds) }
      guard !argv.isEmpty else {
        setStatus("")
        return
      }
      if let job = try call(argv, io) { setStatus(job.wait()) }
    case .assign(let name, let w, let body):
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
        let first = argv.first, functions[first] == nil, Rc.builtins[first] == nil
      {
        let io = try redirect(redirs, fds)
        if let job = system.start(argv, fds: io, environment: environment) {
          background.append(job)
          variables["apid"] = [String(background.count)]
        }
        setStatus("")
      } else {
        try execute(c, fds)
      }
    case .brace(let c, let redirs): try execute(c, try redirect(redirs, fds))
    case .ifThen(let condition, let body):
      try execute(condition, fds)
      lastIf = ok()
      if lastIf { try execute(body, fds) }
    case .ifNot(let body):
      if !lastIf { try execute(body, fds) }
    case .forIn(let name, let list, let body):
      let items = try list.map { try $0.flatMap { try value($0, fds) } } ?? (variables["*"] ?? [])
      for item in items {
        variables[name] = [item]
        try execute(body, fds)
      }
    case .whileDo(let condition, let body):
      while true {
        try execute(condition, fds)
        guard ok() else { break }
        try execute(body, fds)
      }
      setStatus("")
    case .switchOn(let subject, let cases):
      let s = try value(subject, fds)
      guard s.count == 1 else { throw RcError(message: "switch needs one string") }
      for k in cases {
        let patterns = try k.patterns.flatMap { try value($0, fds, glob: false) }
        if patterns.contains(where: { Rc.matches($0, s[0]) }) {
          for c in k.body { try execute(c, fds) }
          return
        }
      }
    case .match(let subject, let patterns):
      let s = try value(subject, fds)
      let ps = try patterns.flatMap { try value($0, fds, glob: false) }
      setStatus(s.contains { str in ps.contains { Rc.matches($0, str) } } ? "" : "no match")
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
      try execute(stage, ios[k])
      statuses[k] = status
      if k < pipes.count { pipes[k].1.close() }
    }
    for (k, job) in jobs.enumerated() { if let job { statuses[k] = job.wait() } }
    variables["status"] = statuses
  }

  // MARK: Builtins

  nonisolated(unsafe) static let builtins: [String: (Rc, [String], [Int32: RcStream]) throws -> Void] = [
    "cd": { rc, argv, fds in
      let target = argv.count > 1 ? argv[1] : (rc.variables["home"]?.first ?? "/")
      if rc.system.changeDirectory(target) {
        rc.setStatus("")
      } else {
        fds[2]?.write(Array(("cd: " + target + ": not found\n").utf8))
        rc.setStatus("cd failed")
      }
    },
    "echo": { rc, argv, fds in
      var args = Array(argv.dropFirst())
      var newline = true
      if args.first == "-n" {
        newline = false
        args.removeFirst()
      }
      fds[1]?.write(Array((args.joined(separator: " ") + (newline ? "\n" : "")).utf8))
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
      for name in argv.dropFirst() {
        if let v = rc.variables[name] {
          fds[1]?.write(Array((name + "=(" + v.map(Rc.quote).joined(separator: " ") + ")\n").utf8))
        } else if rc.functions[name] != nil {
          fds[1]?.write(Array(("fn " + name + "\n").utf8))
        } else if builtins[name] != nil {
          fds[1]?.write(Array(("builtin " + name + "\n").utf8))
        } else if rc.system.exists(name) {
          fds[1]?.write(Array((name + "\n").utf8))
        } else {
          fds[2]?.write(Array((name + ": not found\n").utf8))
        }
      }
      rc.setStatus("")
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
      try rc.execute(try Parser.parse(String(decoding: text, as: UTF8.self)), fds)
    },
  ]

  /// A string as rc would read it back.
  static func quote(_ s: String) -> String {
    if !s.isEmpty && s.unicodeScalars.allSatisfy({ Lexer.isWordChar($0) }) { return s }
    return "'" + s.replacingOccurrences("'", "''") + "'"
  }
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
