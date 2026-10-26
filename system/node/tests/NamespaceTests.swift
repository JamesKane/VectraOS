// SPDX-License-Identifier: BSD-3-Clause

// Namespaces (N0d): mounts, unions, creating in them, sealing, clones,
// lexical paths, and the /srv board.

import IPC
import Node
import Testing

/// A service whose tree holds `files` (path: contents).
func service(_ files: [String: String], creatable: [String] = []) throws -> Service {
  let s = try Service()
  for (path, text) in files { s.tree.file(path, Array(text.utf8)) }
  for path in creatable { s.tree.directory(path, allowsCreate: true) }
  s.start()
  return s
}

func text(_ ns: Namespace, _ path: String) throws -> String {
  var c = try ns.open(path)
  return try c.readText()
}

func names(_ ns: Namespace, _ path: String) throws -> [String] { try ns.list(path).map(\.name) }

func failure<R>(_ body: () throws(NamespaceError) -> R) -> NamespaceError? {
  do throws(NamespaceError) {
    _ = try body()
    return nil
  } catch {
    return error
  }
}

@Test func mountsAndPaths() throws {
  let a = try service(["status": "a\n"]), b = try service(["status": "b\n", "dir/x": "x"])
  defer { a.stop(); b.stop() }
  let ns = Namespace()
  try ns.mount(a.channel(), at: "/svc/a")
  try ns.mount(b.channel(), at: "/svc/b")

  #expect(try text(ns, "/svc/a/status") == "a\n")
  #expect(try text(ns, "/svc/b/dir/x") == "x")
  // Lexical cleaning: ".." takes off the name before it.
  #expect(try text(ns, "/svc/a/../b/./status") == "b\n")
  #expect(try text(ns, "/../svc/b/status") == "b\n")
  #expect(failure { () throws(NamespaceError) in try ns.open("svc/a") } == .badPath)
  #expect(failure { () throws(NamespaceError) in try ns.open("/svc/c/status") } == .notFound)
  #expect(failure { () throws(NamespaceError) in try ns.open("/svc/a/nope") } == .notFound)

  // Mount points show as directories above them.
  #expect(try names(ns, "/") == ["svc"])
  #expect(try names(ns, "/svc").sorted() == ["a", "b"])
  #expect(try names(ns, "/svc/b").sorted() == ["dir", "status"])
  #expect(ns.mountPoints == ["/svc/a", "/svc/b"])
  // A mount below another shows once above both, and joins its listing.
  try ns.mount(a.channel(), at: "/svc/b/deep")
  #expect(try names(ns, "/svc").sorted() == ["a", "b"])
  #expect(try names(ns, "/svc/b").sorted() == ["deep", "dir", "status"])
  try ns.unmount("/svc/b/deep")

  try ns.unmount("/svc/a")
  #expect(failure { () throws(NamespaceError) in try ns.open("/svc/a/status") } == .notFound)
}

@Test func unionsLookInOrderAndMergeListings() throws {
  let system = try service(["ls": "system ls", "cat": "system cat"])
  let dev = try service(["ls": "dev ls", "make": "dev make"])
  defer { system.stop(); dev.stop() }
  let ns = Namespace()
  try ns.mount(system.channel(), at: "/bin")
  try ns.mount(dev.channel(), at: "/bin", .before)

  #expect(try text(ns, "/bin/ls") == "dev ls")  // the dev SDK over the system's
  #expect(try text(ns, "/bin/cat") == "system cat")  // a miss tries the next
  // The dev tree's entries, then the system's it doesn't have: no duplicates.
  let listed = try names(ns, "/bin")
  #expect(listed.count == 3 && Set(listed) == ["ls", "make", "cat"] && listed.last == "cat")

  try ns.mount(dev.channel(), at: "/sdk")
  try ns.mount(system.channel(), at: "/sdk", .after)
  #expect(try text(ns, "/sdk/ls") == "dev ls")
  try ns.mount(system.channel(), at: "/sdk")  // replacing both
  #expect(try text(ns, "/sdk/ls") == "system ls")

  for _ in 0..<6 { try ns.mount(system.channel(), at: "/bin", .after) }
  let extrabin = try system.channel().release()
  #expect(failure { () throws(NamespaceError) in try ns.mount(Handle(raw: extrabin), at: "/bin", .after) } == .unionFull)
}

@Test func creatingGoesToTheCreateMember() throws {
  let readOnly = try service(["a": "1"]), writable = try service([:], creatable: ["home"])
  defer { readOnly.stop(); writable.stop() }
  let ns = Namespace()
  try ns.mount(readOnly.channel(), at: "/data")
  #expect(failure { () throws(NamespaceError) in try ns.create("/data/new", kind: .file) } == .cantCreate)

  try ns.mount(writable.channel(path: "home"), at: "/data", .after, create: true)
  var made = try ns.create("/data/new", kind: .file)
  _ = try made.write(offset: 0, Array("hi".utf8))
  #expect(try text(ns, "/data/new") == "hi")
  #expect(writable.tree.node("home/new") != nil)
  // Deeper, the node goes where its parent is.
  _ = try ns.create("/data/sub", kind: .directory)
  _ = try ns.create("/data/sub/leaf", kind: .file)
  #expect(writable.tree.node("home/sub/leaf") != nil)
}

@Test func sealingStopsMountsButNotBindsAndChildrenInheritIt() throws {
  let a = try service(["f": "a"])
  defer { a.stop() }
  let ns = Namespace()
  try ns.mount(a.channel(), at: "/svc/a")
  ns.seal()
  let extrax = try a.channel().release()
  #expect(failure { () throws(NamespaceError) in try ns.mount(Handle(raw: extrax), at: "/x") } == .sealed)
  try ns.bind("/svc/a", at: "/x")  // rearranging what it holds
  #expect(try text(ns, "/x/f") == "a")

  let child = try ns.clone()
  #expect(child.sealed)
  let extray = try a.channel().release()
  #expect(failure { () throws(NamespaceError) in try child.mount(Handle(raw: extray), at: "/y") } == .sealed)
  #expect(try text(child, "/svc/a/f") == "a")
  // A clone is its own: unmounting there leaves the parent's.
  try child.unmount("/svc/a")
  #expect(try text(ns, "/svc/a/f") == "a")

  let open = Namespace()
  try open.mount(a.channel(), at: "/a")
  #expect(!(try open.clone()).sealed)

  // Through a Startup too (a parent says so on its entries).
  let sealedStart = Startup(), openStart = Startup()
  sealedStart.mount(try a.channel(), at: "/svc/a", sealed: true)
  openStart.mount(try a.channel(), at: "/svc/a")
  let given = try Namespace(sealedStart)
  let unsealed = try Namespace(openStart)
  #expect(given.sealed && !unsealed.sealed)
  #expect(try text(given, "/svc/a/f") == "a")
}

@Test func theSrvBoardFindsPostedServices() throws {
  // The session's board, on its own thread.
  let boardService = try Service()
  let board = SrvBoard(dispatcher: boardService.dispatcher)
  let posting = try Channel.create()
  try board.serveBoard(posting.b)
  boardService.start()
  defer { boardService.stop() }
  var poster = SrvIPC.BoardClient(channel: posting.a)

  let ns = Namespace()
  let reading = try Channel.create()
  try board.serveNode(reading.b)
  try ns.mount(reading.a, at: "/srv")

  // A program posts its tree; another finds it by name.
  let editor = try service(["status": "editing\n"])
  defer { editor.stop() }
  try poster.post("editor", editor.channel())
  #expect(try names(ns, "/srv") == ["editor"])
  #expect(try text(ns, "/srv/editor/status") == "editing\n")
  var duplicate: SrvIPC.BoardError?
  let second = try editor.channel()
  do throws(IPCError<SrvIPC.BoardError>) { try poster.post("editor", second) } catch {
    if case .remote(let e) = error { duplicate = e }
  }
  #expect(duplicate == .exists)

  try poster.withdraw("editor")
  #expect(failure { () throws(NamespaceError) in try ns.open("/srv/editor/status") } == .notFound)

  // A post whose program has gone disappears when next looked for.
  try poster.post("gone", editor.channel())
  editor.end()
  #expect(failure { () throws(NamespaceError) in try ns.open("/srv/gone/status") } == .notFound)
  #expect(try names(ns, "/srv").isEmpty)
}

/// Node's `memory` (version 3): a memory file's VMO given to read or map,
/// to run only if its tree says so; any other file copied into a VMO that
/// can't run; a directory none.
@Test func filesAsMemory() throws {
  let s = try Service()
  defer { s.stop() }
  let script = Array("#!/bin/rc\necho hi\n".utf8)
  let vmo = try VMO.create(size: 4096)
  try VMO.map(vmo, length: 4096).write(script, at: 0)
  s.tree.memory("bin/program", try vmo.duplicate(), size: UInt64(script.count), executable: true)
  s.tree.memory("lib/data", vmo, size: 5, executable: false)
  s.tree.file("etc/motd", Array("hello".utf8))
  s.start()
  let ns = Namespace()
  try ns.mount(s.channel(), at: "/")
  #expect(try text(ns, "/bin/program") == "#!/bin/rc\necho hi\n")
  #expect(try text(ns, "/lib/data") == "#!/bi")
  func contents(_ m: borrowing NodeIPC.Memory) throws -> [UInt8] {
    try VMO.map(m.vmo, length: 4096, writable: false).read(at: 0, count: Int(m.size))
  }
  // (Hosted VMOs can't run, so a program's is read here; launch-test runs
  // one from /bin.)
  let program = try ns.memory("/bin/program", executable: false)
  #expect(try contents(program) == script)
  #expect(failure { () throws(NamespaceError) in _ = try ns.memory("/lib/data", executable: true) } == .node(.denied))
  let motd = try ns.memory("/etc/motd", executable: false)
  #expect(try contents(motd) == Array("hello".utf8))
  #expect(failure { () throws(NamespaceError) in _ = try ns.memory("/etc/motd", executable: true) } == .node(.denied))
  #expect(failure { () throws(NamespaceError) in _ = try ns.memory("/etc", executable: false) } == .node(.isDirectory))
}

/// A writable memory file (ramdisk(4)'s data): written in place, short at
/// its end, never grown or cut, its memory given read only.
@Test func aDiskFileIsWrittenInPlace() throws {
  let s = try Service()
  defer { s.stop() }
  let vmo = try VMO.create(size: 8192)
  try s.tree.memory("sd/data", writable: vmo, size: 8192)
  s.start()
  let ns = Namespace()
  try ns.mount(s.channel(), at: "/")
  var d = try ns.open("/sd/data")
  #expect(try d.stat().size == 8192)
  #expect(try d.write(offset: 4096, Array("block".utf8)) == 5)
  #expect(try d.read(offset: 4096, max: 5) == Array("block".utf8))
  #expect(try d.read(offset: 0, max: 4) == [0, 0, 0, 0])
  #expect(try d.write(offset: 8190, Array("tail".utf8)) == 2)
  #expect(try d.write(offset: 8192, Array("past".utf8)) == 0)
  #expect(try d.read(offset: 8188, max: 16) == [0, 0, UInt8(ascii: "t"), UInt8(ascii: "a")])
  #expect(failure { () throws(NamespaceError) in try ns.wstat("/sd/data", NodeIPC.Wstat(size: 4096)) } != nil)
  let m = try ns.memory("/sd/data", executable: false)
  #expect(try VMO.map(m.vmo, offset: 4096, length: 4096, writable: false).read(at: 0, count: 5) == Array("block".utf8))
  #expect(throws: Status.self) { _ = try VMO.map(m.vmo, length: 4096, writable: true) }
}

/// A growable memory file (/dev/warm's): as long as its highest write, a
/// gap zeros, cut and regrown by wstat without an older write showing
/// through, short at its capacity.
@Test func aGrowableFileFollowsItsWrites() throws {
  let s = try Service()
  defer { s.stop() }
  let node = try s.tree.memory("warm/kernel", growable: try VMO.create(size: 8192), capacity: 8192)
  s.start()
  let ns = Namespace()
  try ns.mount(s.channel(), at: "/")
  var f = try ns.open("/warm/kernel")
  #expect(try f.stat().size == 0)
  #expect(try f.write(offset: 0, Array("head".utf8)) == 4)
  #expect(try f.write(offset: 8, Array("tail".utf8)) == 4)
  #expect(try f.stat().size == 12 && s.tree.length(node) == 12)
  #expect(try f.readAll() == Array("head".utf8) + [0, 0, 0, 0] + Array("tail".utf8))
  try ns.wstat("/warm/kernel", NodeIPC.Wstat(size: 2))
  try ns.wstat("/warm/kernel", NodeIPC.Wstat(size: 6))
  #expect(try f.readAll() == Array("he".utf8) + [0, 0, 0, 0])
  #expect(try f.write(offset: 8190, Array("over".utf8)) == 2)
  #expect(try f.stat().size == 8192)
  #expect(failure { () throws(NamespaceError) in try ns.wstat("/warm/kernel", NodeIPC.Wstat(size: 8193)) } != nil)
}

@Test func wstatRenamesTimesAndCuts() throws {
  let s = try Service()
  defer { s.stop() }
  s.tree.directory("box", allowsCreate: true)
  s.tree.file("etc/motd", Array("hello".utf8))
  s.start()
  let ns = Namespace()
  try ns.mount(s.channel(), at: "/")
  var f = try ns.create("/box/a", kind: .file)
  try f.write(offset: 0, Array("abcdef".utf8))
  _ = try ns.create("/box/b", kind: .file)
  // A client's file: renamed in its directory, given a time, cut and grown.
  try ns.wstat("/box/a", NodeIPC.Wstat(name: "c", modified: 1_000_000_000, size: 3))
  #expect(try ns.list("/box").map(\.name).sorted() == ["b", "c"])
  var c = try ns.open("/box/c")
  let st = try c.stat()
  #expect(st.modified == 1_000_000_000 && st.size == 3)
  #expect(try text(ns, "/box/c") == "abc")
  try ns.wstat("/box/c", NodeIPC.Wstat(size: 5))
  #expect(try c.readAll() == Array("abc".utf8) + [0, 0])
  // All or none: a name taken, and nothing else changed.
  #expect(failure { () throws(NamespaceError) in try ns.wstat("/box/c", NodeIPC.Wstat(name: "b", size: 0)) } == .node(.exists))
  #expect(try c.stat().size == 5)
  #expect(failure { () throws(NamespaceError) in try ns.wstat("/box/c", NodeIPC.Wstat(name: "x/y")) } == .node(.badName))
  // The service's own nodes: not the client's to rename or cut.
  #expect(failure { () throws(NamespaceError) in try ns.wstat("/etc/motd", NodeIPC.Wstat(name: "m")) } == .node(.denied))
  #expect(failure { () throws(NamespaceError) in try ns.wstat("/etc/motd", NodeIPC.Wstat(size: 0)) } == .node(.unsupported))
  #expect(failure { () throws(NamespaceError) in try ns.wstat("/box", NodeIPC.Wstat(size: 0)) } == .node(.isDirectory))
}

@Test func namesAreCleanedAsPlan9s() {
  #expect(Namespace.cleanname("/a/b/../c/./d//") == "/a/c/d")
  #expect(Namespace.cleanname("/..") == "/")
  #expect(Namespace.cleanname("a/..") == ".")
  #expect(Namespace.cleanname("../x") == "../x")
  #expect(Namespace.cleanname("/x/y/../a/./b") == "/x/a/b")
}
