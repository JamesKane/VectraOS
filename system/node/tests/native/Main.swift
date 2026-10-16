// SPDX-License-Identifier: BSD-3-Clause

// bin/node-test: Node over the kernel (V2), what NodeTests and
// NamespaceTests check hosted, natively: batches on a current node (walk,
// stat, read and open in one call; the first failure and its index; the
// operation limit; create, write, read and remove), ctl leaves, a mount
// that takes the rest of a batch and goes with its service, watches set
// by a batch, namespaces and their unions, and /srv's board. Services run
// on dispatcher threads of their own. userboot starts it
// (userboot.next=bin/node-test, the boot-node test); it exits 0 if every
// check passed.

import IPC
import LibSys
import Node

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ name: StaticString) {
  checks += 1
  if !condition {
    failures += 1
    print("node-test: FAILED: \(name)")
  }
}

typealias Client = NodeIPC.NodeClient
let millisecond: Int64 = 1_000_000
func soon(_ ms: Int64 = 2000) -> Int64 { Clock.monotonic() + ms * millisecond }

/// A String's bytes are `text`'s (String's `==` normalizes, which needs
/// Unicode tables only amd64's Embedded toolchain has).
func same(_ string: String, _ text: StaticString) -> Bool {
  unsafe Array(string.utf8) == Array(UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount))
}
func bytes(_ text: StaticString) -> [UInt8] {
  unsafe Array(UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount))
}

/// The NodeError a call threw, if it threw one.
func remoteError<R: ~Copyable>(_ body: () throws(Client.Failure) -> R) -> NodeError? {
  do throws(Client.Failure) {
    _ = try body()
    return nil
  } catch {
    if case .remote(let e) = error { return e }
    return nil
  }
}

/// A service publishing a tree from a dispatcher thread of its own.
final class Service {
  let dispatcher: IPCDispatcher
  let tree: NodeTree
  var thread: Handle?
  var commands = 0

  init() throws(Status) {
    dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
    tree.text("status", read: { "running\n" })
    tree.text("ctl", read: { "" }, write: { [self] (command: String) throws(NodeError) in
      guard command.utf8.starts(with: bytes("set ")) else { throw .invalid }
      commands += 1
    })
    tree.file("data/hello", bytes("hello, world"))
    tree.directory("box", allowsCreate: true)
  }

  func start() throws(Status) {
    let d = dispatcher
    thread = try Thread.spawn { _ = try? d.run() }
  }

  /// A channel served at the node at `path` (the root if empty).
  func channel(at path: String = "") throws(Status) -> Handle {
    let ends = try Channel.create()
    try tree.serve(ends.b, at: path.utf8.isEmpty ? tree.root : tree.node(path)!)
    return ends.a
  }

  func connect() throws(Status) -> Client { Client(channel: try channel()) }

  /// Stops its thread and closes every channel it served: as if its
  /// program ended.
  func end() {
    dispatcher.stop()
    if let t = thread.take() { _ = try? Thread.join(t) }
    dispatcher.removeAll()
  }
}

@main
struct NodeTest {
  static func main() {
    do throws(Status) {
      try batches()
      try leaves()
      try mounts()
      try watches()
      try namespaces()
      try board()
    } catch {
      print("node-test: FAILED: a call threw \(error.rawValue)")
      failures += 1
    }
    print("node-test: \(checks - failures) of \(checks) checks passed")
    Process.exit(code: failures == 0 ? 0 : 1)
  }

  static func batches() throws(Status) {
    let s = try Service()
    try s.start()
    var root = try s.connect()

    // Walk, stat, read and open, in one call.
    do throws(IPCError<Never>) {
      var reply = try root.batch([.walk(names: ["data", "hello"]), .stat(fields: NodeIPC.Fields.size),
                                  .read(offset: 7, max: 100)], open: true)
      var ok = reply.failure == nil && reply.results.count == 3
      if ok, case .walked(let qids) = reply.results[0], case .stat(let stat) = reply.results[1],
        case .data(let data) = reply.results[2] {
        ok = qids.count == 2 && stat.size == 12 && data == bytes("world")
      } else {
        ok = false
      }
      check(ok, "batch: walk, stat and read in one call")
      if let node = reply.node.take() {
        var hello = Client(channel: node)
        check((try? hello.readAll()) == bytes("hello, world"), "batch: and the channel it opened")
      } else {
        check(false, "batch: and the channel it opened")
      }

      reply = try root.batch([.walk(names: ["data"]), .stat(fields: 0), .walk(names: ["nope"]), .stat(fields: 0)],
                             open: true)
      let none = reply.node == nil
      check(reply.results.count == 2 && reply.failure?.index == 2 && reply.failure?.error == .notFound && none,
            "batch: it stops at the first failure, with what came before")

      reply = try root.batch(Array(repeating: .stat(fields: 0), count: NodeIPC.maxOps + 1), open: false)
      check(reply.results.isEmpty && reply.failure?.error == .tooManyOps, "batch: too many operations")

      reply = try root.batch([.walk(names: ["box"]), .create(name: "made", kind: .file), .write(offset: 0, data: [7]),
                              .read(offset: 0, max: 8), .remove, .stat(fields: 0)], open: false)
      check(reply.results.count == 5 && reply.results[3] == .data([7]) && reply.failure?.index == 5,
            "batch: create moves the current node, remove leaves it")
    } catch {
      check(false, "batch: a call failed")
    }
    check((try? root.stat(fields: 0))?.qid.path == 1, "batch: the channel stays at its node")
    check(remoteError { () throws(Client.Failure) in try root.walk("data/hello/x") } == .notDirectory,
          "batch: no walking through a file")
    _ = consume root
    s.end()
    check(s.dispatcher.count == 0, "batch: the service's channels are gone")
  }

  static func leaves() throws(Status) {
    let s = try Service()
    try s.start()
    var root = try s.connect()
    check((try? root.readText("status")).map { same($0, "running\n") } ?? false, "leaves: a text leaf")
    check((try? root.writeText("set level 3", "ctl")) != nil, "leaves: a ctl command")
    check(remoteError { () throws(Client.Failure) in try root.writeText("explode", "ctl") } == .invalid,
          "leaves: a bad command")
    check(remoteError { () throws(Client.Failure) in try root.write("data/hello", offset: 0, [1]) } == .unsupported,
          "leaves: a read-only file")
    _ = consume root
    s.end()
    check(s.commands == 1, "leaves: the service heard one command")
  }

  static func mounts() throws(Status) {
    let outer = try Service(), inner = try Service()
    try outer.start()
    try inner.start()
    outer.tree.mount("mnt", try inner.channel())
    var root = try outer.connect()
    do throws(IPCError<Never>) {
      let reply = try root.batch([.walk(names: ["mnt", "data", "hello"]), .read(offset: 0, max: 5)], open: false)
      var ok = reply.failure == nil && reply.results.count == 2 && reply.results[1] == .data(bytes("hello"))
      if case .walked(let qids)? = reply.results.first { ok = ok && qids.count == 3 } else { ok = false }
      check(ok, "mount: the rest of the batch goes on in the other service")
      let failed = try root.batch([.walk(names: ["mnt"]), .stat(fields: 0), .walk(names: ["nope"])], open: false)
      check(failed.results.count == 2 && failed.failure?.index == 2, "mount: its failures count from the start")
    } catch {
      check(false, "mount: a call failed")
    }
    inner.end()
    check(remoteError { () throws(Client.Failure) in try root.walk("mnt/data") } == .notFound,
          "mount: when the service goes, so does its node")
    check(outer.tree.node("mnt") == nil, "mount: it left the tree")
    _ = consume root
    outer.end()
  }

  static func watches() throws(Status) {
    let s = try Service()
    try s.start()
    var watcher = try s.connect()
    var maker = try s.connect()
    var boxPath: UInt64 = 0
    if let done = try? watcher.run([.walk(names: ["box"]), .watch(since: 0)]),
      case .walked(let qids) = done.results[0] {
      boxPath = qids[0].path
    }
    check(boxPath != 0, "watch: set by a batch")
    _ = try? maker.create("note", kind: .file, in: "box")
    if case .changed(let change)? = try? watcher.nextEvent(deadline: soon()) {
      check(change.kind == .created && change.node == boxPath && same(change.name, "note"),
            "watch: the change names its node")
    } else {
      check(false, "watch: the change names its node")
    }
    _ = consume watcher
    _ = consume maker
    s.end()
  }

  static func namespaces() throws(Status) {
    let a = try Service(), b = try Service()
    try a.start()
    try b.start()
    let ns = Namespace()
    let toA = try a.channel(), toB = try b.channel(), aBox = try a.channel(at: "box")
    do throws(NamespaceError) {
      try ns.mount(toA, at: "/svc/a")
      var hello = try ns.open("/svc/a/data/hello")
      check((try? hello.readAll()) == bytes("hello, world"), "namespace: open a path")
      let names = try ns.list("/svc").map { Array($0.name.utf8) }
      check(names == [bytes("a")], "namespace: a mount point shows as a directory")

      // A union: b's root first, then a's box, marked for creating.
      try ns.mount(toB, at: "/u")
      try ns.mount(aBox, at: "/u", .after, create: true)
      let listed = try ns.list("/u").count
      check(listed == 4, "namespace: a union's listings merged")
      _ = try ns.create("/u/made", kind: .file)
      check(a.tree.node("box/made") != nil && b.tree.node("made") == nil, "namespace: create goes to the member marked")
      check((try? ns.open("/u/nope")) == nil, "namespace: a name no member has")
      _ = consume hello
    } catch {
      check(false, "namespace: a call failed")
    }
    a.end()
    b.end()
  }

  static func board() throws(Status) {
    let d = try IPCDispatcher()
    let srv = SrvBoard(dispatcher: d)
    let thread = try Thread.spawn { _ = try? d.run() }
    let service = try Service()
    try service.start()

    let posting = try Channel.create()
    try srv.serveBoard(posting.b)
    var poster = SrvIPC.BoardClient(channel: posting.a)
    check((try? poster.post("svc", try service.channel())) != nil, "board: post a node")
    let reading = try Channel.create()
    try srv.serveNode(reading.b)
    var board = Client(channel: reading.a)
    check((try? board.readText("svc/status")).map { same($0, "running\n") } ?? false,
          "board: walks go to the node posted")
    check((try? poster.withdraw("svc")) != nil && srv.tree.node("svc") == nil, "board: withdraw it")
    _ = consume poster
    _ = consume board
    d.stop()
    _ = try? Thread.join(thread)
    d.removeAll()
    service.end()
  }
}
