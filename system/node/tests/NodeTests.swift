// SPDX-License-Identifier: BSD-3-Clause

// Node over the tree helper (N0c), in batches (D64): walks, stat, reads and
// writes, text leaves, paging, watches, create and remove, service nodes
// and mounts.

import Glibc
import IDL
import IPC
import Node
import Testing

typealias Client = NodeIPC.NodeClient

/// A service publishing a tree, on its own thread.
final class Service: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let tree: NodeTree
  var thread = pthread_t()
  /// What `ctl` was told.
  var commands: [String] = []
  var counter = 0

  init() throws {
    dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
  }

  func start() {
    pthread_create(&thread, nil, { arg in
      let s = Unmanaged<Service>.fromOpaque(arg!).takeUnretainedValue()
      try? s.dispatcher.run()
      return nil
    }, Unmanaged.passUnretained(self).toOpaque())
  }

  /// A client of the tree's root.
  func connect() throws -> Client {
    let ends = try Channel.create()
    try tree.serve(ends.b)
    return Client(channel: ends.a)
  }

  /// A channel served at the node at `path` (the root if empty).
  func channel(path: String = "") throws -> Handle {
    let ends = try Channel.create()
    try tree.serve(ends.b, at: path.isEmpty ? tree.root : tree.node(path)!)
    return ends.a
  }

  /// Stops the dispatcher and waits for it.
  func stop() {
    guard !stopped else { return }
    stopped = true
    dispatcher.stop()
    pthread_join(thread, nil)
  }

  var stopped = false

  /// Stops, and closes every channel it served: as if its program ended.
  func end() {
    stop()
    dispatcher.removeAll()
  }
}

/// The tree most tests use: status and ctl leaves, a data directory, a box
/// clients may create in.
func standard() throws -> Service {
  let s = try Service()
  s.tree.text("status", read: { [s] in "count \(s.counter)\n" })
  s.tree.text("ctl", read: { "" }, write: { [s] command throws(NodeError) in
    guard command.hasPrefix("set ") else { throw .invalid }
    s.commands.append(command)
  })
  s.tree.file("data/hello", Array("hello, world".utf8))
  s.tree.file("data/scratch", [], writable: true)
  s.tree.directory("box", allowsCreate: true)
  s.start()
  return s
}

/// A client of the channel a batch opened; throws if there is none.
func opened(_ reply: inout NodeIPC.Reply) throws -> Client {
  struct NoChannel: Error {}
  guard let channel = reply.node.take() else { throw NoChannel() }
  return Client(channel: channel)
}

func remoteError<R>(_ body: () throws(Client.Failure) -> R) -> NodeError? {
  do throws(Client.Failure) {
    _ = try body()
    return nil
  } catch {
    if case .remote(let e) = error { return e }
    return nil
  }
}

@Test func walksStatAndReads() throws {
  let s = try standard()
  var root = try s.connect()
  defer { s.stop() }

  var status = try root.open("status")
  #expect(try status.readText() == "count 0\n")
  s.counter = 3
  #expect(try status.readText() == "count 3\n")

  let qids = try root.walk("data/hello")
  #expect(qids.map(\.kind) == [.directory, .file])
  var hello = try root.open("data/hello")
  let stat = try hello.stat()
  #expect(stat.name == "hello" && stat.size == 12 && stat.qid == qids[1] && stat.modified > 0)
  #expect(try hello.read(offset: 7, max: 100) == Array("world".utf8))
  #expect(try hello.read(offset: 50, max: 100).isEmpty)
  // A path from the root: the walk and the read are one batch.
  #expect(try root.read("data/hello", offset: 0, max: 5) == Array("hello".utf8))

  // Walks that fail: every name must be there.
  #expect(remoteError { () throws(Client.Failure) in try root.walk("data/nope/x") } == .notFound)
  #expect(remoteError { () throws(Client.Failure) in try root.run([.walk(names: ["a/b"])]) } == .badName)
  #expect(remoteError { () throws(Client.Failure) in try root.run([.walk(names: Array(repeating: "data", count: 17))]) }
    == .tooManyNames)
  #expect(remoteError { () throws(Client.Failure) in try hello.walk("x") } == .notDirectory)

  // ".." goes up, and stays at the root.
  let up = try root.walk("data/../../status")
  let statusPath = try status.stat(fields: 0).qid.path
  #expect(up.map(\.path) == [qids[0].path, 1, 1, statusPath])

  #expect(remoteError { () throws(Client.Failure) in try root.read(offset: 0, max: 10) } == .isDirectory)
  #expect(remoteError { () throws(Client.Failure) in try hello.readdir(cursor: 0, max: 10, fields: 0) } == .notDirectory)
  _ = consume hello
  _ = consume status
  _ = consume root
}

@Test func aBatchRunsOnACurrentNodeAndStopsAtItsFirstFailure() throws {
  let s = try standard()
  var root = try s.connect()
  defer { s.stop() }

  // Walk, stat, read and open, in one call.
  var reply = try root.batch([.walk(names: ["data", "hello"]), .stat(fields: NodeIPC.Fields.size),
                              .read(offset: 7, max: 100)], open: true)
  #expect(reply.failure == nil && reply.results.count == 3)
  guard case .walked(let qids) = reply.results[0], case .stat(let stat) = reply.results[1],
    case .data(let data) = reply.results[2] else {
    Issue.record("results \(reply.results)")
    return
  }
  #expect(qids.count == 2 && stat.size == 12 && data == Array("world".utf8))
  var hello = try opened(&reply)
  #expect(try hello.stat(fields: 0).qid == qids[1])

  // The batch stops at the first failure, with the results before it and
  // no channel.
  reply = try root.batch([.walk(names: ["data"]), .stat(fields: 0), .walk(names: ["nope"]), .stat(fields: 0)],
                         open: true)
  #expect(reply.results.count == 2 && reply.failure == NodeIPC.Failure(index: 2, code: NodeError.notFound.rawValue))
  let none = reply.node == nil
  #expect(none)

  // A walk doesn't move this channel: the next batch starts at the root.
  #expect(try root.stat(fields: 0).qid.path == 1)
  // No operations: a clone. Too many: refused whole.
  var clone = try root.open("")
  #expect(try clone.stat(fields: 0).qid.path == 1)
  reply = try root.batch(Array(repeating: .stat(fields: 0), count: NodeIPC.maxOps + 1), open: false)
  #expect(reply.results.isEmpty && reply.failure?.error == .tooManyOps)

  // Create moves the current node; remove leaves it, and what follows fails.
  reply = try root.batch([.walk(names: ["box"]), .create(name: "made", kind: .file), .write(offset: 0, data: [7]),
                          .read(offset: 0, max: 8), .remove, .stat(fields: 0)], open: false)
  #expect(reply.results.count == 5 && reply.failure == NodeIPC.Failure(index: 5, code: NodeError.notFound.rawValue))
  #expect(reply.results[3] == .data([7]) && reply.results[4] == .removed)
  _ = consume hello
  _ = consume clone
  _ = consume root
}

@Test func serviceNodesOpenTheirOwnProtocol() throws {
  let s = try standard()
  let served = Locked<[UInt32]>([])
  s.tree.service("svc/echo") { (channel: consuming Handle) throws(Status) in
    let raw = channel.release()
    served.withLock { $0.append(raw) }
  }
  var root = try s.connect()
  defer { s.stop() }
  let channel = try root.open("svc/echo").takeChannel()
  #expect(served.withLock { $0.count } == 1)
  // The service holds the other end.
  let peer = Handle(raw: served.withLock { $0[0] })
  try Channel.write(channel, bytes: [1, 2, 3])
  #expect(try Channel.read(peer).bytes == [1, 2, 3])
  #expect(try root.stat("svc/echo", fields: 0).qid.kind == .service)
  #expect(remoteError { () throws(Client.Failure) in try root.read("svc/echo", offset: 0, max: 1) } == .unsupported)
  #expect(remoteError { () throws(Client.Failure) in try root.walk("svc/echo/x") } == .notDirectory)
  _ = consume root
}

@Test func aMountTakesTheRestOfTheBatch() throws {
  let outer = try standard()
  let inner = try standard()
  outer.tree.mount("mnt", try inner.channel())
  var root = try outer.connect()
  defer {
    outer.stop()
    inner.stop()
  }

  // Into the other service and on, in one call from the client.
  var reply = try root.batch([.walk(names: ["mnt", "data", "hello"]), .stat(fields: 0), .read(offset: 0, max: 5)],
                             open: true)
  #expect(reply.failure == nil && reply.results.count == 3)
  guard case .walked(let qids) = reply.results[0] else {
    Issue.record("results \(reply.results)")
    return
  }
  #expect(qids.count == 3 && reply.results[2] == .data(Array("hello".utf8)))
  var hello = try opened(&reply)
  #expect(try hello.readText() == "hello, world")
  inner.counter = 5
  #expect(try root.readText("mnt/status") == "count 5\n")

  // Its failures count from the batch's start.
  let failed = try root.batch([.walk(names: ["mnt"]), .stat(fields: 0), .walk(names: ["nope"])], open: false)
  #expect(failed.results.count == 2 && failed.failure?.index == 2 && failed.failure?.error == .notFound)

  // When the other service goes, so does its node.
  inner.end()
  #expect(remoteError { () throws(Client.Failure) in try root.walk("mnt/data") } == .notFound)
  #expect(outer.tree.node("mnt") == nil)
  _ = consume hello
  _ = consume root
}

/// D135: a batch forwarded to a service that doesn't answer holds up only
/// itself; the tree's own nodes answer meanwhile.
@Test func aMountThatDoesntAnswerHoldsUpOnlyItsOwnBatches() throws {
  let outer = try standard()
  let silent = try Channel.create()
  let unserved = silent.b  // nobody reads it
  outer.tree.mount("slow", silent.a)
  defer { outer.stop() }

  var waiting = try outer.connect()
  waiting.connection.timeout = 200_000_000
  #expect(throws: (any Error).self) { try waiting.walk("slow/x") }

  var other = try outer.connect()
  other.connection.timeout = 2_000_000_000
  #expect(try other.readText("status") == "count 0\n")

  // The other service going ends the forward: its node goes.
  _ = consume unserved
  var gone = false
  for _ in 0..<200 where !gone {
    gone = outer.tree.node("slow") == nil
    if !gone { usleep(10_000) }
  }
  #expect(gone)
  #expect(try other.readText("status") == "count 0\n")
  _ = consume waiting
  _ = consume other
}

@Test func ctlAndWrites() throws {
  let s = try standard()
  var root = try s.connect()
  defer { s.stop() }
  var ctl = try root.open("ctl")
  try ctl.writeText("set latency 64")
  #expect(remoteError { () throws(Client.Failure) in try ctl.writeText("explode") } == .invalid)
  #expect(remoteError { () throws(Client.Failure) in try ctl.write(offset: 0, [0xff]) } == .invalid)
  #expect(s.commands == ["set latency 64"])

  var hello = try root.open("data/hello")
  #expect(remoteError { () throws(Client.Failure) in try hello.write(offset: 0, [1]) } == .unsupported)
  var scratch = try root.open("data/scratch")
  #expect(try scratch.write(offset: 4, Array("abc".utf8)) == 3)
  #expect(try scratch.readAll() == [0, 0, 0, 0] + Array("abc".utf8))
  _ = consume ctl
  _ = consume hello
  _ = consume scratch
  _ = consume root
}

@Test func listingsPageAndDeepPathsOpen() throws {
  let s = try Service()
  for i in 0..<300 { s.tree.file("many/f\(i)", [UInt8(i & 0xff)]) }
  let deep = (0..<40).map { "d\($0)" }.joined(separator: "/")
  s.tree.text(deep + "/leaf", read: { "deep\n" })
  var root = try s.connect()
  s.start()
  defer { s.stop() }

  var many = try root.open("many")
  let first = try many.readdir(cursor: 0, max: 10, fields: NodeIPC.Fields.size)
  #expect(first.entries.map(\.name) == (0..<10).map { "f\($0)" } && first.next == 10 && !first.done)
  #expect(first.entries.allSatisfy { $0.size == 1 && $0.modified == 0 })
  let all = try many.list()
  #expect(all.map(\.name) == (0..<300).map { "f\($0)" })

  // 41 names: three walks of at most 16.
  var leaf = try root.open(deep + "/leaf")
  #expect(try leaf.readText() == "deep\n")
  _ = consume many
  _ = consume leaf
  _ = consume root
}

/// The next change event, or nil within `ms`.
func nextChange(_ c: inout Client, ms: Int64 = 2000) -> NodeIPC.Change? {
  guard let event = try? c.nextEvent(deadline: Clock.monotonic() + ms * 1_000_000) else { return nil }
  guard case .changed(let change) = event else { return nil }
  return change
}

@Test func watchersHearOfChanges() throws {
  let s = try standard()
  var root = try s.connect()
  defer { s.stop() }

  var box = try root.open("box")
  var watcher = try root.open("box")
  _ = try watcher.watch(since: 0)

  // A client creates a file, writes it, removes it.
  var file = try box.create("note", kind: .file)
  #expect(nextChange(&watcher).map { $0.kind == .created && $0.name == "note" } == true)
  _ = try file.write(offset: 0, [1, 2, 3])
  #expect(nextChange(&watcher).map { $0.kind == .modified && $0.name == "note" } == true)
  #expect(remoteError { () throws(Client.Failure) in try box.create("note", kind: .file) } == .exists)
  try file.remove()
  #expect(nextChange(&watcher).map { $0.kind == .removed && $0.name == "note" } == true)
  #expect(remoteError { () throws(Client.Failure) in try file.stat(fields: 0) } == .notFound)
  #expect(remoteError { () throws(Client.Failure) in try root.create("x", kind: .file) } == .unsupported)

  // The service changes a leaf: its watcher hears.
  var status = try root.open("status")
  let before = try status.watch(since: 0)
  s.counter = 9
  s.tree.touch(s.tree.node("status")!)
  let change = nextChange(&status)
  #expect(change?.kind == .modified && change?.name == "status" && (change?.seq ?? 0) > before)
  #expect(nextChange(&status, ms: 20) == nil)

  // A watch in a batch, on the node it walked to: its events come on this
  // channel and name that node.
  var other = try s.connect()
  let watched = try other.run([.walk(names: ["box"]), .watch(since: 0)])
  guard case .walked(let boxQids) = watched.results[0] else { return }
  _ = try box.create("second", kind: .file)
  let seen = nextChange(&other)
  #expect(seen?.kind == .created && seen?.node == boxQids[0].path)
  _ = consume other
  _ = consume file
  _ = consume box
  _ = consume watcher
  _ = consume status
  _ = consume root
}

@Test func watchReplaysWhatWasMissedOrSaysItOverflowed() throws {
  let s = try standard()
  var root = try s.connect()
  defer { s.stop() }
  var status = try root.open("status")
  let start = try status.watch(since: 0)
  _ = consume status
  let leaf = s.tree.node("status")!
  for _ in 0..<3 { s.tree.touch(leaf) }

  // A new watcher asks for what came after `start`: the three changes.
  var again = try root.open("status")
  _ = try again.watch(since: start)
  let replayed = (0..<3).compactMap { _ in nextChange(&again) }
  #expect(replayed.map(\.kind) == [.modified, .modified, .modified])
  #expect(replayed.map(\.seq) == replayed.map(\.seq).sorted() && replayed.first!.seq > start)

  // More changes than the log keeps: an overflow first.
  for _ in 0..<100 { s.tree.touch(leaf) }
  var late = try root.open("status")
  _ = try late.watch(since: start)
  #expect(nextChange(&late)?.kind == .overflow)
  _ = consume again
  _ = consume late
  _ = consume root
}

@Test func closedChannelsLeaveTheDispatcher() throws {
  let s = try standard()
  var root = try s.connect()
  for _ in 0..<50 { _ = try root.open("data/hello") }
  _ = try root.stat(fields: 0)
  _ = consume root
  // The closes are served on the dispatcher's thread, so wait for them
  // before stopping it: root's wait is re-armed after its last reply is
  // written, so its close can be noticed after a stop queued at once.
  let deadline = Clock.monotonic() + 5_000_000_000
  while s.dispatcher.count > 0 && Clock.monotonic() < deadline { usleep(1000) }
  s.stop()
  #expect(s.dispatcher.count == 0)
}

// MARK: Generated files stay in step with idlc

@Test func checkedInOutputsMatchIdlc() throws {
  var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
  parts.removeLast(4)  // system/node/tests/NodeTests.swift
  let root = parts.joined(separator: "/")
  func read(_ path: String) -> String? {
    guard let f = fopen("\(root)/\(path)", "r") else { return nil }
    defer { fclose(f) }
    var out: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      let n = fread(&buffer, 1, buffer.count, f)
      if n == 0 { break }
      out += buffer[..<n]
    }
    return String(decoding: out, as: UTF8.self)
  }
  for (source, header) in [("system/node/lib/Node.swift", "node_ipc.h"), ("system/node/lib/Srv.swift", "srv_ipc.h")] {
    let interface = try scan([(source, try #require(read(source)))])
    let (library, p) = try #require(interface.protocols.first)
    let regenerate = "regenerate: .build/debug/idlc --c-out system/node/idl \(source)"
    #expect(cHeader(library, source: source) == read("system/node/idl/\(header)"), "\(regenerate)")
    #expect(Baseline(p, library).text == read("system/node/idl/\(p.id).api"))
  }
}
