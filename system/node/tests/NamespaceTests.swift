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
