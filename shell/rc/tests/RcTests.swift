// SPDX-License-Identifier: BSD-3-Clause

// rc (M6j part 2c) on an in-memory machine: Duff's paper's examples and
// rules. Lists, subscripts, counts and joins; concatenation (pairwise,
// distributed, free carets, its errors); quoting; if / if not, for, while,
// switch, ~; fn and $*; redirections and >[2=1]; pipelines and their
// statuses; backquotes; globbing; && || !; local assignment; exit.

import Rc
import Testing

/// A machine: files in memory, and programs that run when waited for
/// (cat, upper, wc, false), so a pipeline's order is the interpreter's.
final class Machine: RcSystem {
  var files: [String: [UInt8]] = [:]
  var cwd = "/home"
  /// Files' attributes, by path (M6j's `attr`).
  var attrs: [String: [(name: String, value: AttributeText)]] = [:]

  func attributes(_ path: String) -> [(name: String, value: AttributeText)]? {
    files[absolute(path)] == nil ? nil : attrs[absolute(path)] ?? []
  }

  func setAttribute(_ path: String, _ name: String, _ value: AttributeText?) -> Bool {
    let p = absolute(path)
    guard files[p] != nil else { return false }
    var a = attrs[p] ?? []
    a.removeAll { $0.name == name }
    if let value { a.append((name, value)) }
    attrs[p] = a
    return true
  }

  final class File: RcStream {
    let machine: Machine
    let path: String
    var stream: MemoryStream
    init(_ m: Machine, _ path: String, _ bytes: [UInt8]) {
      machine = m
      self.path = path
      stream = MemoryStream(bytes)
    }
    func write(_ b: [UInt8]) {
      stream.write(b)
      machine.files[path] = stream.bytes
    }
    func read() -> [UInt8]? { stream.read() }
    func close() {}
  }

  final class Job: RcJob {
    let body: () -> String
    /// Numbered from 100, a job a number.
    nonisolated(unsafe) static var last: UInt64 = 99
    let id: UInt64
    init(_ body: @escaping () -> String) {
      self.body = body
      Job.last += 1
      id = Job.last
    }
    func wait() -> String { body() }
  }

  func absolute(_ p: String) -> String { p.hasPrefix("/") ? p : (cwd == "/" ? "/" + p : cwd + "/" + p) }

  func open(_ path: String, _ mode: RcOpen) -> RcStream? {
    let p = absolute(path)
    switch mode {
    case .read, .readWrite: return files[p].map { File(self, p, $0) }
    case .write:
      files[p] = []
      return File(self, p, [])
    case .append:
      let f = File(self, p, files[p] ?? [])
      _ = f.stream.read()  // past what's there
      return f
    }
  }

  func pipe() -> (RcStream, RcStream) {
    let m = MemoryStream()
    return (m, m)
  }

  /// rfork's namespace changes (clean, seal), as asked.
  var forks: [(clean: Bool, seal: Bool)] = []
  func forkNamespace(clean: Bool, seal: Bool) -> Bool {
    forks.append((clean, seal))
    return true
  }

  /// /env's files (D81), when it has them: its group's directory in
  /// `files`, a new one for each rfork e or E.
  var envGroup: String? = nil
  var groups = 0
  func environmentFiles() -> [(name: String, bytes: [UInt8])]? {
    guard let g = envGroup else { return nil }
    return files.filter { $0.key.hasPrefix(g + "/") }.map { (String($0.key.dropFirst(g.count + 1)), $0.value) }
      .sorted { $0.name < $1.name }
  }
  func setEnvironmentFile(_ name: String, _ bytes: [UInt8]) {
    if let g = envGroup { files[g + "/" + name] = bytes }
  }
  func forkEnvironment(clean: Bool) -> Bool {
    guard let g = envGroup else { return false }
    groups += 1
    let next = "/env\(groups)"
    if !clean { for (p, b) in files where p.hasPrefix(g + "/") { files[next + p.dropFirst(g.count)] = b } }
    envGroup = next
    return true
  }

  /// Notes sent to rc (by `notify NAME`), not yet taken.
  var notes: [String] = []
  func takeNotes() -> [String] {
    defer { notes = [] }
    return notes
  }

  static let programs = ["cat", "upper", "wc", "false", "env", "notify"]
  /// Its programs are /bin's.
  func executable(_ path: String) -> Bool { path.hasPrefix("/bin/") && Machine.programs.contains(String(path.dropFirst(5))) }

  func start(_ path: String, _ argv: [String], fds: [Int32: RcStream], environment: [String]) -> RcJob? {
    guard executable(path) else { return nil }
    let program = String(path.dropFirst(5))
    return Job { [self] in
      func input() -> [UInt8] {
        if argv.count > 1 {
          return argv.dropFirst().flatMap { files[absolute($0)] ?? [] }
        }
        var all: [UInt8] = []
        while let b = fds[0]?.read() { all += b }
        return all
      }
      switch program {
      case "cat": fds[1]?.write(input())
      case "upper": fds[1]?.write(input().map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 })
      case "wc": fds[1]?.write(Array("\(input().filter { $0 == 0x0A }.count)\n".utf8))
      case "false": return "1"
      case "env": fds[1]?.write(Array(environment.map { $0 + "\n" }.joined().utf8))
      case "notify": notes += argv.dropFirst()
      default: break
      }
      return ""
    }
  }

  func changeDirectory(_ path: String) -> Bool {
    let p = absolute(path)
    guard p == "/" || files.keys.contains(where: { $0.hasPrefix(p + "/") }) else { return false }
    cwd = p
    return true
  }
  var directory: String { cwd }
  func list(_ directory: String) -> [String]? {
    let d = absolute(directory)
    let prefix = d == "/" ? "/" : d + "/"
    var names: [String] = []
    for p in files.keys where p.hasPrefix(prefix) {
      let rest = p.dropFirst(prefix.count)
      let name = String(rest.prefix { $0 != "/" })
      if !names.contains(name) { names.append(name) }
    }
    return names
  }
}

/// Runs a script; what it wrote to stdout and stderr.
func rc(_ script: String, _ machine: Machine = Machine(), args: [String] = []) -> (out: String, err: String, rc: Rc) {
  let shell = Rc(system: machine, arguments: args)
  let out = MemoryStream(), err = MemoryStream()
  shell.run(script, fds: [0: MemoryStream(), 1: out, 2: err])
  return (out.text, err.text, shell)
}

@Test func listsSubscriptsCountsAndJoins() {
  let r = rc("a=(x y z)\necho $a; echo $#a; echo $a(2) $a(3 1); echo $\"a; b=(); echo $#b")
  #expect(r.out == "x y z\n3\ny z x\nx y z\n0\n")
}

@Test func concatenation() {
  #expect(rc("echo (a b)^(1 2)").out == "a1 b2\n")
  #expect(rc("echo x^(1 2 3)").out == "x1 x2 x3\n")
  #expect(rc("a=foo; echo $a.c /usr/$a/lib").out == "foo.c /usr/foo/lib\n")  // free carets
  #expect(rc("echo (a b c)^(1 2)").err == "rc: mismatched list lengths in concatenation\n")
  #expect(rc("e=(); echo x^$e").err == "rc: null list in concatenation\n")
}

@Test func quoting() {
  #expect(rc("echo 'it''s' '$a' 'a b'").out == "it's $a a b\n")
  #expect(rc("echo '*.c'", files(["/home/a.c"])).out == "*.c\n")  // quoted: not globbed
}

func files(_ paths: [String]) -> Machine {
  let m = Machine()
  for p in paths { m.files[p] = [] }
  return m
}

@Test func controlFlow() {
  #expect(rc("if(~ a a) echo yes\nif not echo no").out == "yes\n")
  #expect(rc("if(~ a b) echo yes\nif not echo no").out == "no\n")
  #expect(rc("for(i in 1 2 3) echo $i").out == "1\n2\n3\n")
  #expect(rc("for(i) echo $i", args: ["p", "q"]).out == "p\nq\n")
  #expect(rc("x=(a b c); while(! ~ $#x 0) { echo $x(1); x=$x(2 3 4 5) }").out == "a\nb\nc\n")
  #expect(rc("""
    switch(file.c) {
    case *.h
      echo header
    case *.c *.s
      echo source
    case *
      echo other
    }
    """).out == "source\n")
  #expect(rc("~ abc a*; echo $status; ~ abc x*; echo $status; ~ b [a-c]; echo $status").out == "\nno match\n\n")
  #expect(rc("~ a b && echo yes || echo no; ! ~ a b && echo negated").out == "no\nnegated\n")
}

@Test func functionsAndArguments() {
  #expect(rc("fn greet { echo hello $1; echo all $*; shift; echo then $* }\ngreet world wide").out
    == "hello world\nall world wide\nthen wide\n")
  #expect(rc("fn f { echo f }; fn f; f").err == "f: not found\n")
  #expect(rc("x=1; x=2 { echo $x }; echo $x").out == "2\n1\n")  // local assignment
}

@Test func redirections() {
  let m = Machine()
  m.files["/home/in"] = Array("from a file\n".utf8)
  let r = rc("echo hi > out; echo more >> out; cat out; cat < in; echo oops >[2=1] > e; cat e", m)
  #expect(r.out == "hi\nmore\nfrom a file\noops\n")
  #expect(m.files["/home/out"] == Array("hi\nmore\n".utf8))
  #expect(rc("echo x >[1=2]").err == "x\n")
}

@Test func pipelinesAndStatus() {
  #expect(rc("echo hello | upper").out == "HELLO\n")
  #expect(rc("{ echo a; echo b; echo c } | cat | wc").out == "3\n")
  // A pipeline's status: one string, a | after each non-empty part
  // (9front's concstatus).
  #expect(rc("false | cat; echo $#status $status").out == "1 1|\n")
  #expect(rc("echo a | false; echo $status").out == "1\n")
  #expect(rc("nonesuch").err == "nonesuch: not found\n")
}

@Test func backquoteAndGlobs() {
  #expect(rc("x=`{echo a b c}; echo $#x $x(2)").out == "3 b\n")
  let m = files(["/home/a.c", "/home/b.c", "/home/d.h", "/home/src/x.c"])
  #expect(rc("echo *.c", m).out == "a.c b.c\n")
  #expect(rc("echo */*.c [ab].c", m).out == "src/x.c a.c b.c\n")
  #expect(rc("echo *.zip", m).out == "*.zip\n")  // no match: the pattern itself
  #expect(rc("cd src; pwd; echo *", m).out == "/home/src\nx.c\n")
}

@Test func exitEndsTheScript() {
  let r = rc("echo before; exit 3; echo after")
  #expect(r.out == "before\n" && r.rc.status == "3")
  #expect(rc("whatis echo; a=(1 'x y'); whatis a").out == "builtin echo\na=(1 'x y')\n")
}

/// Typed a line at a time: an unfinished construct asks for more, a
/// mistake doesn't.
@Test func unfinishedInputIsTold() {
  func incomplete(_ s: String) -> Bool {
    do { _ = try Parser.parse(s); return false } catch { return error.incomplete }
  }
  #expect(incomplete("for(i in a b) {\n") && incomplete("echo 'open\n") && incomplete("if(~ a a)\n"))
  #expect(!incomplete("echo hi\n") || false)
  #expect(!incomplete("echo )\n"))
}


/// `attr` (M6j): settings are files with attributes, and Terminal can
/// change them.
@Test func attrReadsAndSetsTypedAttributes() {
  let m = Machine()
  m.files["/home/Keyboard"] = []
  let set = rc("attr Keyboard Keyboard:RepeatDelay 250; attr Keyboard Keyboard:Layout us; attr Keyboard Keyboard:Repeat true", m)
  #expect(set.err.isEmpty && set.rc.status == "")
  #expect(m.attrs["/home/Keyboard"]?.map(\.value) == [.int(250), .string("us"), .bool(true)])
  #expect(rc("attr Keyboard Keyboard:RepeatDelay", m).out == "250\n")
  #expect(rc("attr Keyboard", m).out == "Keyboard:RepeatDelay 250\nKeyboard:Layout us\nKeyboard:Repeat true\n")
  #expect(rc("attr -d Keyboard Keyboard:Layout; attr Keyboard Keyboard:Layout", m).err == "attr: Keyboard: no Keyboard:Layout\n")
  let missing = rc("attr Nowhere", m)
  #expect(missing.err == "attr: Nowhere: no attributes\n" && missing.rc.status == "attr failed")
  // A phrase is one string.
  _ = rc("attr Keyboard Note:Text hello there", m)
  #expect(rc("attr Keyboard Note:Text", m).out == "hello there\n")
}

/// rc's command line, as 9front's getflags reads it.
@Test func argumentsReadAs9frontsGetflags() {
  let grouped = RcArguments(["-ex", "-c", "echo hi", "a", "b"])
  #expect(grouped?.flags == ["e", "x", "c"] && grouped?.command == "echo hi" && grouped?.rest == ["a", "b"])
  // -c's value: the rest of its group, or the next argument.
  #expect(RcArguments(["-ecfalse"])?.command == "false")
  // The first argument not starting with -, or - alone, ends the flags.
  #expect(RcArguments(["file", "-e"])?.flags == [] && RcArguments(["file", "-e"])?.rest == ["file", "-e"])
  #expect(RcArguments(["-", "-e"])?.rest == ["-", "-e"])
  // An unknown letter, one given twice, or -c without a value: nil.
  #expect(RcArguments(["-q"]) == nil && RcArguments(["-ee"]) == nil && RcArguments(["-c"]) == nil)
  #expect(RcArguments([])?.rest == [])
}

/// rfork, as 9front's execrfork: its letters, E hiding what programs were
/// given and what hasn't changed since, F taking away every descriptor,
/// n, N and m the system's.
@Test func rforkAs9frontsExecrfork() {
  func given(_ out: String, _ names: [String]) -> [String] {
    out.split(separator: "\n").map(String.init).filter { l in names.contains { l.hasPrefix($0 + "=") || l.hasPrefix("#()fn " + $0 + " ") } }
  }
  // E: a and f went to env before it, so they're hidden after it; b was set
  // since, and c is set after it, as is a again.
  let e = rc("a=1; fn f {echo}; env >/dev/x; b=2; rfork E; c=3; env; echo --; a=4; env")
  let both = e.out.split(separator: "--\n", omittingEmptySubsequences: false).map(String.init)
  #expect(both.count == 2)
  #expect(given(both[0], ["a", "b", "c", "f"]) == ["b=2", "c=3"])
  #expect(given(both[1], ["a", "b", "c", "f"]) == ["a=4", "b=2", "c=3"])
  // F: nothing after it has a descriptor, within its block or after it,
  // but what's opened since.
  let m = Machine()
  let f = rc("echo before; {rfork F; echo in; echo there >/home/x}; echo after", m)
  #expect(f.out == "before\n" && f.err.isEmpty && m.files["/home/x"] == Array("there\n".utf8))
  // n, N and m go to the system; e, f and s ask nothing of it.
  let ns = Machine()
  _ = rc("rfork; rfork n; rfork Nm; rfork efs", ns)
  #expect(ns.forks.map { "\($0.clean) \($0.seal)" } == ["false false", "false false", "true true"])
  // A letter it doesn't know, or two arguments: its usage.
  let bad = rc("rfork x; echo $status; rfork e n; echo $status")
  #expect(bad.out == "rfork usage\nrfork usage\n" && bad.err == "Usage: rfork [fnesFNEm]\n" + "Usage: rfork [fnesFNEm]\n")
  #expect(rc("whatis rfork").out == "builtin rfork\n")
}

/// Notes (9front's dotrap) where the oracle can't reach: an interactive
/// rc abandons its line at an interrupt and reads the next, a function
/// for the note runs instead, and at a prompt the notes are taken there.
@Test func notesInAnInteractiveRc() {
  let m = Machine()
  let shell = Rc(system: m)
  shell.interactive = true
  let out = MemoryStream(), err = MemoryStream()
  let fds: [Int32: RcStream] = [0: MemoryStream(), 1: out, 2: err]
  #expect(shell.run("echo a; notify sigint; echo never", fds: fds))
  #expect(shell.run("fn sigint { echo caught }; notify sigint; echo goes on", fds: fds))
  #expect(out.text == "a\ncaught\ngoes on\n")
  // At a prompt: an interrupt with no function, then a hangup's.
  shell.functions["sigint"] = nil
  m.notes = ["sigint"]
  #expect(shell.takeNotes(fds: fds) == .interrupted)
  m.notes = ["sighup"]
  #expect(shell.takeNotes(fds: fds) == .exit)
  // Not interactive, an interrupt ends rc, without sigexit.
  let script = rc("fn sigexit { echo bye }; echo a; notify sigint; echo never", m)
  #expect(script.out == "a\n")
  // Inside a fork, notes wait for rc, and an exit there is the fork's;
  // the function's status stands.
  let forked = rc("fn sigint { echo caught; status=handler }; @{ notify sigint; echo in; exit 3 }; echo $status", m)
  #expect(forked.out == "in\ncaught\nhandler\n")
}

/// sigexit as rc's input ends (a main calls `end`), once.
@Test func sigexitAtTheEnd() {
  let shell = Rc(system: Machine())
  let out = MemoryStream()
  let fds: [Int32: RcStream] = [0: MemoryStream(), 1: out, 2: MemoryStream()]
  #expect(shell.run("fn sigexit { echo bye $status }; ~ a b", fds: fds))
  shell.end()
  shell.end()
  #expect(out.text == "bye no match\n" && shell.status == "")
}

/// The environment as /env's files (D81), as Plan 9's rc keeps it: read at
/// start (a list's words each ended by a NUL, functions from `fn#NAME`),
/// what changed written before a program starts, and rfork's E an empty
/// group that gets only what changes after, e a copy.
@Test func theEnvironmentIsEnvsFiles() {
  let m = Machine()
  m.envGroup = "/env"
  m.files["/env/list"] = Array("a\0b c\0\0".utf8)
  m.files["/env/fn#f"] = Array("fn f {echo hi}\n".utf8)
  m.files["/env/empty"] = []
  let shell = Rc(system: m, arguments: [])
  #expect(shell.takeEnvironmentFiles())
  let out = MemoryStream(), err = MemoryStream()
  let run = { (script: String) in shell.run(script, fds: [0: MemoryStream(), 1: out, 2: err]) }
  run("echo $#list $list(2) $#empty; f; x=(1 2); fn g {echo}; list=(); false")
  #expect(out.text == "3 b c 0\nhi\n" && err.text == "")
  #expect(m.files["/env/x"] == Array("1\u{0}2\u{0}".utf8))
  let whatis = rc("fn g {echo}; whatis g").out  // its text as whatis prints it
  #expect(m.files["/env/fn#g"].map { String(decoding: $0, as: UTF8.self) } == whatis)
  #expect(m.files["/env/list"] == [])  // emptied, never removed
  #expect(m.files["/env/fn#f"] == Array("fn f {echo hi}\n".utf8))  // unchanged, not rewritten
  run("rfork E; y=3; false")
  #expect(m.envGroup == "/env1" && m.files["/env1/y"] == Array("3\u{0}".utf8) && m.files["/env1/x"] == nil)
  run("rfork e; false")
  #expect(m.envGroup == "/env2" && m.files["/env2/y"] == Array("3\u{0}".utf8))
  // Where there are no files (Linux), strings.
  #expect(!Rc(system: Machine(), arguments: []).takeEnvironmentFiles())
}

/// A stream whose writes all fail, as a ctl file refusing a command does.
final class RefusingStream: RcStream {
  func write(_ bytes: [UInt8]) {}
  func written(_ bytes: [UInt8]) -> String? { "file does not exist" }
  func read() -> [UInt8]? { nil }
  func close() {}
}

/// echo's failed write is 9front's: said on stderr, and its status.
@Test func echoSaysWhenItsWriteFails() {
  let shell = Rc(system: Machine(), arguments: [])
  let out = MemoryStream(), err = MemoryStream()
  shell.run("echo restart nobody >[1=3]; echo $status", fds: [0: MemoryStream(), 1: out, 2: err, 3: RefusingStream()])
  #expect(out.text == "write error\n")
  #expect(err.text == "echo: write error: file does not exist\n")
}
