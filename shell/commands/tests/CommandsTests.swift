// SPDX-License-Identifier: BSD-3-Clause

// The shell's file commands over a NodeTree mounted at /t (V2: no fs
// service until Taisce, V3, when todhchai's tests over a volume come),
// each against 9front's (sys/src/cmd): its flags, its messages, its exit
// string, and its output as it goes.

import Commands
import Glibc
import IPC
import Node
import Testing

final class Rig: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let tree: NodeTree
  let ns = Namespace()
  var thread = pthread_t()

  init() throws {
    dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
    tree.text("status", read: { "running\n" })
    tree.file("data/hello", Array("hello\n".utf8))
    tree.directory("box", allowsCreate: true)
    pthread_create(&thread, nil, { arg in
      let r = Unmanaged<Rig>.fromOpaque(arg!).takeUnretainedValue()
      try? r.dispatcher.run()
      return nil
    }, Unmanaged.passUnretained(self).toOpaque())
    let ends = try Channel.create()
    try tree.serve(ends.b)
    try ns.mount(ends.a, at: "/t", create: true)
  }

  func run(_ name: String, _ args: String..., pwd: String = "/t") -> Commands.Result {
    Commands.run(name, args, pwd: pwd, in: ns)
  }

  func stat(_ path: String) throws -> NodeIPC.Stat {
    var n = try ns.open(path)
    return try n.stat()
  }

  func stop() {
    dispatcher.stop()
    pthread_join(thread, nil)
    dispatcher.removeAll()
  }
}

func text(_ r: Commands.Result) -> String { String(decoding: r.output, as: UTF8.self) }

@Test func catStopsAtTheFirstItCantRead() throws {
  let rig = try Rig()
  defer { rig.stop() }
  let both = rig.run("cat", "status", "/t/data/hello")
  #expect(text(both) == "running\nhello\n" && both.status == "")
  // sysfatal: said, the exit string, and nothing after it.
  let missing = rig.run("cat", "status", "nope", "data/hello")
  #expect(text(missing) == "running\n")
  #expect(missing.errors == ["cat: can't open nope: file does not exist: 'nope'"])
  #expect(missing.status == "can't open nope: file does not exist: 'nope'")
}

@Test func catStreamsStdin() throws {
  let rig = try Rig()
  defer { rig.stop() }
  var chunks: [[UInt8]] = [Array("one\n".utf8), Array("two\n".utf8)]
  var writes: [[UInt8]] = []
  let io = Commands.IO(out: { writes.append($0) }, err: { _ in }, stdin: { chunks.isEmpty ? nil : chunks.removeFirst() })
  #expect(Commands.run("cat", [], pwd: "/t", in: rig.ns, io) == "")
  #expect(writes == [Array("one\n".utf8), Array("two\n".utf8)])  // each as it came
}

@Test func lsAsPlan9s() throws {
  let rig = try Rig()
  defer { rig.stop() }
  #expect(text(rig.run("ls")) == "box\ndata\nstatus\n")
  #expect(text(rig.run("ls", "-F")) == "box/\ndata/\nstatus\n")
  // A directory named: its entries under its name; a file, as named.
  #expect(text(rig.run("ls", "data")) == "data/hello\n")
  #expect(text(rig.run("ls", "data/hello", "box/", "/t/status")) == "data/hello\n/t/status\n")
  #expect(text(rig.run("ls", "-p", "data")) == "hello\n")
  #expect(text(rig.run("ls", "-d", "data", "box")) == "box\ndata\n")
  #expect(text(rig.run("ls", "-r")) == "status\ndata\nbox\n")
  let long = text(rig.run("ls", "-l", "data"))
  #expect(long.hasPrefix("--rw-r--r-- M 0 none none 6 ") && long.hasSuffix(" data/hello\n"))
  #expect(text(rig.run("ls", "-ld", "box")).hasPrefix("d-rwxr-xr-x M 0 none none 0 "))
  #expect(text(rig.run("ls", "-s", "data/hello")) == "1 data/hello\n")
  #expect(text(rig.run("ls", "-q", "data/hello")).hasSuffix(" 00) data/hello\n"))
  // Names quoted as rc would read them, unless -Q.
  #expect(rig.run("touch", "box/a b").status == "")
  #expect(text(rig.run("ls", "box")) == "'box/a b'\n")
  #expect(text(rig.run("ls", "-Q", "box")) == "box/a b\n")
  // Newest first with -t.
  #expect(rig.run("touch", "-t", "100", "box/old").status == "")
  #expect(text(rig.run("ls", "-pt", "box")) == "'a b'\nold\n")
  // Errors, and the rest still listed.
  let r = rig.run("ls", "nope", "data")
  #expect(text(r) == "data/hello\n" && r.errors == ["ls: nope: file does not exist: 'nope'"] && r.status == "errors")
  let bad = rig.run("ls", "-z")
  #expect(bad.status == "usage" && bad.errors == ["usage: ls [-dlmnpqrstuFQT] [file ...]"] && bad.output.isEmpty)
}

@Test func mkdirAndItsFlags() throws {
  let rig = try Rig()
  defer { rig.stop() }
  #expect(rig.run("mkdir", "-p", "box/a/b").status == "")
  #expect(rig.run("touch", "box/a/b/f").status == "")
  #expect(text(rig.run("ls", "a", pwd: "/t/box")) == "a/b\n")
  let again = rig.run("mkdir", "box", "box/c")
  #expect(again.errors == ["mkdir: box already exists"] && again.status == "error")
  #expect(text(rig.run("ls", "-p", "box")) == "a\nc\n")  // the rest still made
  #expect(rig.run("mkdir", "-m", "755", "box/d").status == "")
  #expect(rig.run("mkdir", "-m", "999", "box/e").status == "usage")
  #expect(rig.run("mkdir", "-x", "box/e").errors == ["usage: mkdir [-p] [-m mode] dir..."])
  let cant = rig.run("mkdir", "data/x")
  #expect(cant.errors == ["mkdir: can't create data/x: permission denied"] && cant.status == "error")
}

@Test func rmAsPlan9s() throws {
  let rig = try Rig()
  defer { rig.stop() }
  #expect(rig.run("mkdir", "-p", "box/d/e").status == "" && rig.run("touch", "box/d/x", "box/d/e/y").status == "")
  let full = rig.run("rm", "box/d")
  #expect(full.errors == ["rm: box/d: directory not empty"] && full.status == "directory not empty")
  let missing = rig.run("rm", "nope")
  #expect(missing.errors == ["rm: nope: file does not exist: 'nope'"] && missing.status == "file does not exist: 'nope'")
  // -f: nothing said, and success.
  let quiet = rig.run("rm", "-f", "nope")
  #expect(quiet.errors.isEmpty && quiet.status == "")
  #expect(rig.run("rm", "-r", "box/d").status == "")
  #expect(text(rig.run("ls", "box")) == "")
  #expect(rig.run("rm").status == "")  // nothing named, nothing done
  #expect(rig.run("rm", "-x", "a").errors == ["usage: rm [-fr] file ..."])
}

@Test func cpAsPlan9s() throws {
  let rig = try Rig()
  defer { rig.stop() }
  #expect(rig.run("cp", "data/hello", "box/copy").status == "")
  #expect(text(rig.run("cat", "box/copy")) == "hello\n")
  // Into a directory, under each one's last name.
  #expect(rig.run("cp", "status", "data/hello", "box").status == "")
  #expect(text(rig.run("ls", "-p", "box")) == "copy\nhello\nstatus\n")
  // Onto a file: cut to what's copied, the same file kept.
  #expect(rig.run("cp", "box/status", "box/hello").status == "")
  #expect(text(rig.run("cat", "box/hello")) == "running\n")
  let q = try rig.stat("/t/box/hello").qid.path
  #expect(rig.run("cp", "data/hello", "box/hello").status == "" && (try? rig.stat("/t/box/hello").qid.path) == q)
  #expect(text(rig.run("cat", "box/hello")) == "hello\n")
  // -x keeps its time.
  #expect(rig.run("touch", "-t", "1000", "box/copy").status == "")
  #expect(rig.run("cp", "-x", "box/copy", "box/kept").status == "")
  #expect(try rig.stat("/t/box/kept").modified == 1000 * 1_000_000_000)
  let dir = rig.run("cp", "box", "data/x")
  #expect(dir.errors == ["cp: box is a directory"] && dir.status == "errors")
  #expect(rig.run("cp", "box/copy", "box/copy").errors == ["cp: box/copy and box/copy are the same file"])
  let many = rig.run("cp", "status", "data/hello", "box/copy")
  #expect(many.errors == ["cp: box/copy not a directory"] && many.status == "bad usage")
  #expect(rig.run("cp", "-z", "a", "b").status == "usage")
  #expect(rig.run("cp", "nope", "box/n").errors == ["cp: can't stat nope: file does not exist: 'nope'"])
}

@Test func mvRenamesThenCopies() throws {
  let rig = try Rig()
  defer { rig.stop() }
  #expect(rig.run("cp", "data/hello", "box/hello").status == "" && rig.run("mkdir", "box/sub", "box/d").status == "")
  // Within a directory: a rename (the same file).
  let q = try rig.stat("/t/box/hello").qid.path
  #expect(rig.run("mv", "box/hello", "box/again").status == "")
  #expect(text(rig.run("ls", "-p", "box")) == "again\nd\nsub\n" && (try? rig.stat("/t/box/again").qid.path) == q)
  // Onto one there: that one goes first.
  #expect(rig.run("touch", "box/other").status == "" && rig.run("mv", "box/other", "box/again").status == "")
  #expect(text(rig.run("ls", "-p", "box")) == "again\nd\nsub\n")
  #expect(rig.run("cp", "data/hello", "box/again").status == "")
  // Into another directory: a copy, then the first removed.
  #expect(rig.run("mv", "box/again", "box/sub").status == "")
  #expect(text(rig.run("cat", "box/sub/again")) == "hello\n" && text(rig.run("ls", "-p", "box")) == "d\nsub\n")
  // A directory: renamed in its own, never copied.
  #expect(rig.run("mv", "box/d", "box/e").status == "")
  let into = rig.run("mv", "box/e", "status", "box/sub")
  #expect(into.errors == ["mv: box/e is a directory, not copied to box/sub/e", "mv: can't remove status: permission denied"])
  #expect(into.status == "failure")
  // mv dir1 dir2: dir1 renamed dir2, which goes first (if it can).
  let onto = rig.run("mv", "box/e", "box/sub")
  #expect(onto.errors == ["mv: can't remove box/sub: directory not empty"] && onto.status == "mv")
  // The service's own: not the client's to move.
  let theirs = rig.run("mv", "data/hello", "data/bye")
  #expect(theirs.errors == ["mv: can't create data/bye: permission denied"])
  #expect(theirs.status == "failure")
  #expect(rig.run("mv", "a").status == "bad usage")
  #expect(rig.run("mv", "box/sub/again", "status", "box/e/x").errors == ["mv: box/e/x not a directory"])
}

@Test func touchSetsTheTime() throws {
  let rig = try Rig()
  defer { rig.stop() }
  #expect(rig.run("touch", "-t", "1000", "box/f").status == "")  // made, then given the time
  #expect(try rig.stat("/t/box/f").modified == 1000 * 1_000_000_000)
  #expect(rig.run("touch", "-t", "0x10", "box/f").status == "")
  #expect(try rig.stat("/t/box/f").modified == 16 * 1_000_000_000)
  #expect(rig.run("touch", "box/f").status == "")
  #expect(try rig.stat("/t/box/f").modified > 16 * 1_000_000_000)
  let c = rig.run("touch", "-c", "box/nope")
  #expect(c.errors == ["touch: box/nope: cannot wstat: file does not exist: 'box/nope'"] && c.status == "touch")
  // A service's file: its time isn't the client's, and it's there.
  let theirs = rig.run("touch", "status")
  #expect(theirs.errors == ["touch: status: cannot create: permission denied"] && theirs.status == "touch")
  #expect(rig.run("touch").errors == ["usage: touch [-c] [-t time] files"])
  #expect(rig.run("touch", "-t", "soon", "box/f").status == "usage")
}

@Test func wordsAndDates() {
  #expect(Commands.resolve("../a/./b", from: "/x/y") == "/x/a/b")
  #expect(Commands.resolve("/abs", from: "/x") == "/abs")
  #expect(Commands.quote("plain") == "plain" && Commands.quote("") == "''" && Commands.quote("it's") == "'it''s'")
  #expect(Commands.quote("a=b") == "'a=b'" && Commands.quote("x", always: true) == "'x'")
  let now: Int64 = 1_792_163_875_000_000_000  // 2026-10-16 15:17:55 UTC
  #expect(Commands.asciitime(now, now: now) == "Oct 16 15:17")
  #expect(Commands.asciitime(0, now: now) == "Jan  1  1970")  // over six months before
  #expect(Commands.asciitime(now - 3 * 86_400_000_000_000, now: now) == "Oct 13 15:17")
}
