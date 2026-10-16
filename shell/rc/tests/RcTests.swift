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
    init(_ body: @escaping () -> String) { self.body = body }
    func wait() -> String { body() }
  }

  func absolute(_ p: String) -> String { p.hasPrefix("/") ? p : (cwd == "/" ? "/" + p : cwd + "/" + p) }

  func open(_ path: String, _ mode: RcOpen) -> RcStream? {
    let p = absolute(path)
    switch mode {
    case .read: return files[p].map { File(self, p, $0) }
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

  static let programs = ["cat", "upper", "wc", "false"]
  func exists(_ name: String) -> Bool { Machine.programs.contains(name) }

  func start(_ argv: [String], fds: [Int32: RcStream], environment: [(String, [String])]) -> RcJob? {
    guard exists(argv[0]) else { return nil }
    return Job { [self] in
      func input() -> [UInt8] {
        if argv.count > 1 {
          return argv.dropFirst().flatMap { files[absolute($0)] ?? [] }
        }
        var all: [UInt8] = []
        while let b = fds[0]?.read() { all += b }
        return all
      }
      switch argv[0] {
      case "cat": fds[1]?.write(input())
      case "upper": fds[1]?.write(input().map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 })
      case "wc": fds[1]?.write(Array("\(input().filter { $0 == 0x0A }.count)\n".utf8))
      case "false": return "1"
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
