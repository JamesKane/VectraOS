// SPDX-License-Identifier: BSD-3-Clause

// The shell's file commands over a NodeTree mounted at /t (V2: no fs
// service until Taisce, V3, when todhchai's tests over a volume come):
// paths from rc's directory, ls's lines, cat, mkdir (-p), rm (-r), cp,
// touch; mv says it can't without the fs protocol; failures said and the
// rest still run.

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

  func stop() {
    dispatcher.stop()
    pthread_join(thread, nil)
    dispatcher.removeAll()
  }
}

func text(_ r: Commands.Result) -> String { String(decoding: r.output, as: UTF8.self) }

@Test func catJoinsWhatItReads() throws {
  let rig = try Rig()
  defer { rig.stop() }
  #expect(text(rig.run("cat", "status", "/t/data/hello")) == "running\nhello\n")
  let missing = rig.run("cat", "nope", "status")
  #expect(text(missing) == "running\n" && missing.errors == ["cat: nope: can't read"] && missing.status == 1)
}

@Test func lsListsAndMakesAreSeen() throws {
  let rig = try Rig()
  defer { rig.stop() }
  #expect(text(rig.run("ls")) == "box/\ndata/\nstatus\n")
  #expect(rig.run("mkdir", "-p", "box/a/b").status == 0)
  #expect(rig.run("touch", "box/a/b/f").status == 0)
  #expect(text(rig.run("ls", "a", pwd: "/t/box")) == "b/\n")
  #expect(text(rig.run("ls", "-l", "data")).hasSuffix(" hello\n"))
  #expect(rig.run("mkdir", "box").errors == ["mkdir: box: exists"])
}

@Test func cpAndRm() throws {
  let rig = try Rig()
  defer { rig.stop() }
  #expect(rig.run("cp", "data/hello", "box/copy").status == 0)
  #expect(text(rig.run("cat", "box/copy")) == "hello\n")
  #expect(rig.run("cp", "status", "data/hello", "box").status == 0)  // into a directory
  #expect(text(rig.run("ls", "box")) == "copy\nhello\nstatus\n")
  #expect(rig.run("mkdir", "box/d").status == 0 && rig.run("touch", "box/d/x").status == 0)
  #expect(rig.run("rm", "box/d").errors == ["rm: box/d: a directory with something in it (rm -r)"])
  #expect(rig.run("rm", "-r", "box/d", "box/copy").status == 0)
  #expect(text(rig.run("ls", "box")) == "hello\nstatus\n")
  // mv is the fs protocol's rename: a NodeTree doesn't speak it.
  let moved = rig.run("mv", "box/hello", "box/again")
  #expect(moved.status == 1 && moved.errors.first?.hasPrefix("mv: box/hello: can't move it") == true)
}

@Test func pathsAndDates() {
  #expect(Commands.resolve("../a/./b", from: "/x/y") == "/x/a/b")
  #expect(Commands.resolve("/abs", from: "/x") == "/abs")
  #expect(Commands.date(0) == "1970-01-01 00:00")
  #expect(Commands.date(1_792_163_875_000_000_000) == "2026-10-16 15:17")
}

@Test func catWithNoFilesCopiesStdin() throws {
  let rig = try Rig()
  defer { rig.stop() }
  var chunks: [[UInt8]] = [Array("one\n".utf8), Array("two\n".utf8)]
  let r = Commands.run("cat", [], pwd: "/t", in: rig.ns, stdin: { chunks.isEmpty ? nil : chunks.removeFirst() })
  #expect(text(r) == "one\ntwo\n" && r.status == 0)
}
