// SPDX-License-Identifier: BSD-3-Clause

// Export and import (9gate): a tree served as Node, exported in 9P over
// a channel, plainly and sealed by Noise IK, read as 9P by hand; then
// imported back and used through a namespace as any mount is: reads,
// listings, writes, creates, removes, renames, errors as Node's, and a
// read that waits while other channels are served.

import Gate
import IPC
@testable import NineP
import Node
@testable import Noise
import Sys
import SysHost
import Testing

/// A tree on its own dispatcher thread, in a namespace at /, exported
/// over one end of a channel; the other end is the client's.
final class Exported: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let tree: NodeTree
  let namespace = Namespace()
  let cons = Locked<[UInt8]>([])
  var consNode: TreeNode?
  var client: ByteStream

  init(sealed: Bool = false) throws {
    dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
    tree.file("motd", Array("hello from the node\n".utf8))
    tree.file("d/a", Array("a".utf8))
    tree.file("d/b", Array("bb".utf8))
    tree.file("notes", [], writable: true)
    _ = tree.directory("tmp", allowsCreate: true)
    let cons = self.cons
    consNode = tree.stream("cons", NodeStream(take: { max in
      cons.withLock { (c: inout [UInt8]) -> [UInt8]? in
        guard !c.isEmpty else { return nil }
        defer { c.removeFirst(min(max, c.count)) }
        return Array(c.prefix(max))
      }
    }))
    let d = dispatcher
    _ = try Thread.spawn { try? d.run() }.release()
    let mount = try Channel.create()
    try tree.serve(mount.b)
    try namespace.mount(mount.a, at: "/")
    let ends = try Channel.create()
    let server = ByteStream.channel(ends.b)
    client = ByteStream.channel(ends.a)
    let ns = namespace
    if sealed {
      let serverKey = StaticKey(privateKey: Array(repeating: 7, count: 32))
      let clientKey = StaticKey(privateKey: Array(repeating: 9, count: 32))
      _ = try Thread.spawn {
        let s = try? SealedStream.respond(server, key: serverKey, ephemeral: Array(repeating: 1, count: 32),
                                          prologue: Array("9gate".utf8)) { $0 == clientKey.publicKey }
        if let stream = s?.0 { _ = Export.serve(stream, namespace: ns, root: "/") }
      }.release()
      client = try SealedStream.initiate(client, key: clientKey, remote: serverKey.publicKey,
                                         ephemeral: Array(repeating: 2, count: 32), prologue: Array("9gate".utf8))
    } else {
      let s = server
      _ = try Thread.spawn { _ = Export.serve(s, namespace: ns, root: "/") }.release()
    }
  }

  func say(_ text: String) {
    cons.withLock { $0 += Array(text.utf8) }
    if let consNode { tree.ready(consNode) }
  }

  deinit { dispatcher.stop() }
}

func names(_ data: [UInt8]) -> [String] { (Dir.decodeAll(data) ?? []).map { $0.name } }

/// A file longer than a read: each read as large as the client may ask
/// comes back whole, up to the file's end (an msize larger than Node's
/// reads gave half of each, which the import's read ahead asked again).
@Test func exportFillsTheReadsItsMsizeAllows() throws {
  let e = try Exported()
  let big = (0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
  e.tree.file("big", big)
  let c = try NinePClient(e.client)
  let root = c.fid(), f = c.fid()
  _ = try c.attach(root, uname: "glenda", aname: "")
  _ = try c.walk(root, f, ["big"])
  _ = try c.open(f, mode: OpenMode.read)
  var got: [UInt8] = []
  while true {
    let data = try c.read(f, offset: UInt64(got.count), count: c.iounit)
    if data.isEmpty { break }
    #expect(data.count == Int(c.iounit) || got.count + data.count == big.count)
    got += data
  }
  #expect(got == big)
}

@Test(arguments: [false, true])
func exportServes9P(sealed: Bool) throws {
  let e = try Exported(sealed: sealed)
  let c = try NinePClient(e.client)
  #expect(c.version == "9P2000.vx")
  let root = c.fid()
  let qid = try c.attach(root, uname: "glenda", aname: "")
  #expect(qid.type == QidType.dir)
  // A walk, an open, a read.
  let motd = c.fid()
  #expect(try c.walk(root, motd, ["motd"]).count == 1)
  _ = try c.open(motd, mode: OpenMode.read)
  #expect(try c.read(motd, offset: 0, count: 100) == Array("hello from the node\n".utf8))
  #expect(try c.read(motd, offset: 6, count: 4) == Array("from".utf8))
  #expect(try c.stat(motd).length == 20)
  #expect(try c.stat(motd).uid == "none")
  c.clunk(motd)
  // A short walk: the first name there, the second not.
  let short = c.fid()
  #expect(try c.walk(root, short, ["d", "zz"]).count == 1)
  #expect(throws: GateError.error("file does not exist")) { try c.walk(root, short, ["zz"]) }
  // ".." at the root stays there.
  let up = c.fid()
  #expect(try c.walk(root, up, ["..", "..", "motd"]).count == 3)
  c.clunk(up)
  // A directory's stats, whole, read on from where the last ended.
  let d = c.fid()
  _ = try c.walk(root, d, ["d"])
  _ = try c.open(d, mode: OpenMode.read)
  let all = try c.read(d, offset: 0, count: 8192)
  #expect(names(all) == ["a", "b"])
  #expect(try c.read(d, offset: UInt64(all.count), count: 8192).isEmpty)
  let first = try #require(Dir.decodeAll(all)?.first?.encode())
  let one = try c.read(d, offset: 0, count: UInt32(first.count + 2))
  #expect(names(one) == ["a"])
  #expect(names(try c.read(d, offset: UInt64(one.count), count: 8192)) == ["b"])
  #expect(throws: GateError.self) { try c.read(d, offset: 3, count: 8192) }
  c.clunk(d)
  // Create, write, read back, rename, remove.
  let tmp = c.fid()
  _ = try c.walk(root, tmp, ["tmp"])
  _ = try c.create(tmp, name: "new", perm: 0o664, mode: OpenMode.rdwr)
  #expect(try c.write(tmp, offset: 0, Array("abc".utf8)) == 3)
  #expect(try c.read(tmp, offset: 0, count: 10) == Array("abc".utf8))
  c.clunk(tmp)
  let new = c.fid()
  _ = try c.walk(root, new, ["tmp", "new"])
  var rename = Dir.unchanged
  rename.name = "renamed"
  try c.wstat(new, rename)
  #expect(try c.stat(new).name == "renamed")
  try c.remove(new)
  let gone = c.fid()
  #expect(try c.walk(root, gone, ["tmp", "renamed"]).count == 1)  // tmp, but no longer renamed
  // Refusals: a write to a file that can't be written, an unknown fid,
  // auth.
  let ro = c.fid()
  _ = try c.walk(root, ro, ["motd"])
  _ = try c.open(ro, mode: OpenMode.read)
  #expect(throws: GateError.self) { try c.write(ro, offset: 0, [1]) }
  #expect(throws: GateError.error("unknown fid")) { try c.stat(999) }
  #expect(throws: GateError.error("authentication not required")) {
    try c.rpc(.tauth(afid: 5, uname: "glenda", aname: ""))
  }
}

@Test func exportRefusesTheWrongKey() throws {
  let ends = try Channel.create()
  let server = ByteStream.channel(ends.b), client = ByteStream.channel(ends.a)
  let serverKey = StaticKey(privateKey: Array(repeating: 7, count: 32))
  let stranger = StaticKey(privateKey: Array(repeating: 3, count: 32))
  let refused = Locked<GateError?>(nil)
  let done = Lock()
  done.lock()
  _ = try Thread.spawn {
    do throws(GateError) {
      _ = try SealedStream.respond(server, key: serverKey, ephemeral: Array(repeating: 1, count: 32),
                                   prologue: []) { _ in false }
    } catch { refused.withLock { $0 = error } }
    done.unlock()
  }.release()
  #expect(throws: GateError.self) {
    _ = try SealedStream.initiate(client, key: stranger, remote: serverKey.publicKey,
                                  ephemeral: Array(repeating: 2, count: 32), prologue: [])
  }
  done.lock()
  #expect(refused.withLock { $0 } == .protocolError("caller refused"))
}

/// The tree exported, then imported on a dispatcher of its own and
/// mounted at /n/remote of a second namespace.
final class Imported: @unchecked Sendable {
  let exported: Exported
  let dispatcher: IPCDispatcher
  let namespace = Namespace()

  init(sealed: Bool) throws {
    exported = try Exported(sealed: sealed)
    dispatcher = try IPCDispatcher()
    let d = dispatcher
    _ = try Thread.spawn { try? d.run() }.release()
    let gate = Import(try NinePClient(exported.client), dispatcher: dispatcher)
    try namespace.mount(try gate.attach(), at: "/n/remote")
  }

  deinit { dispatcher.stop() }
}

@Test(arguments: [false, true])
func importMountsTheTree(sealed: Bool) throws {
  let i = try Imported(sealed: sealed)
  let ns = i.namespace
  var motd = try ns.open("/n/remote/motd")
  #expect(try motd.readText() == "hello from the node\n")
  #expect(try ns.list("/n/remote").map { $0.name }.sorted() == ["cons", "d", "motd", "notes", "tmp"])
  #expect(try ns.list("/n/remote/d").map { $0.name } == ["a", "b"])
  var b = try ns.open("/n/remote/d/b")
  #expect(try b.stat().size == 2)
  #expect(try b.stat().qid.kind == .file)
  // Errors come back as Node's.
  #expect(throws: NamespaceError.notFound) { _ = try ns.open("/n/remote/nothing") }
  var ro = try ns.open("/n/remote/motd")
  #expect(throws: NodeIPC.NodeClient.Failure.self) { _ = try ro.write(offset: 0, [1]) }
  // A file made, written, read back, renamed and removed.
  var made = try ns.create("/n/remote/tmp/f", kind: .file)
  #expect(try made.write(offset: 0, Array("over 9P".utf8)) == 7)
  var f = try ns.open("/n/remote/tmp/f")
  #expect(try f.readText() == "over 9P")
  try ns.wstat("/n/remote/tmp/f", NodeIPC.Wstat(name: "g"))
  #expect(try ns.list("/n/remote/tmp").map { $0.name } == ["g"])
  var g = try ns.open("/n/remote/tmp/g")
  try g.remove()
  #expect(try ns.list("/n/remote/tmp").isEmpty)
  _ = try ns.create("/n/remote/tmp/sub", kind: .directory)
  var sub = try ns.open("/n/remote/tmp/sub")
  #expect(try sub.stat().qid.kind == .directory)
  // Writes reach the tree itself.
  var notes = try ns.open("/n/remote/notes")
  _ = try notes.write(offset: 0, Array("noted".utf8))
  var local = try i.exported.namespace.open("/notes")
  #expect(try local.readText() == "noted")
}

/// A request's thread lets its handle go: reads through the import leave
/// no handles to threads that have ended, in the importer or the
/// exporter (each kept one, and each new handle was found a slot past
/// them all, so every request cost more than the last).
@Test func importedReadsKeepNoEndedThreads() throws {
  let i = try Imported(sealed: false)
  var motd = try i.namespace.open("/n/remote/motd")
  _ = try motd.read(offset: 0, max: 100)
  let before = HostKernel.shared.endedThreadHandles()
  for _ in 0..<500 { _ = try motd.read(offset: 0, max: 100) }
  // Other tests' threads end meanwhile; 500 reads kept a thousand.
  #expect(HostKernel.shared.endedThreadHandles() - before < 100)
}

@Test func importedReadsWaitWithoutHoldingOthersUp() throws {
  let i = try Imported(sealed: true)
  let ns = i.namespace
  let cons = try ns.open("/n/remote/cons")
  let got = Locked<[UInt8]?>(nil)
  let done = Lock()
  done.lock()
  let reader = Shared(cons)
  _ = try Thread.spawn {
    let bytes = try? reader.read()
    got.withLock { $0 = bytes }
    done.unlock()
  }.release()
  // While that read waits, the others are answered.
  for _ in 0..<5 {
    var motd = try ns.open("/n/remote/motd")
    #expect(try motd.readText() == "hello from the node\n")
  }
  #expect(got.withLock { $0 } == nil)
  i.exported.say("typed\n")
  done.lock()
  #expect(got.withLock { $0 } == Array("typed\n".utf8))
}

/// A client a test's thread reads on.
final class Shared: @unchecked Sendable {
  var client: NodeIPC.NodeClient
  init(_ client: consuming NodeIPC.NodeClient) { self.client = client }
  func read() throws -> [UInt8] { try client.read(offset: 0, max: 100) }
}

/// An imported file's bulk on its channel's ring (D103): its entries 9P
/// reads and writes under way together, the same bytes as the tree's,
/// both ways.
@Test func importedFilesMoveBulkOnTheirRing() throws {
  let i = try Imported(sealed: true)
  let bytes = (0..<(3 << 19) + 777).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ $0 >> 12) }
  i.exported.tree.file("big", bytes)
  var file = NodeFile(try i.namespace.open("/n/remote/big"))
  var back: [UInt8] = []
  while true {
    let b = try file.read(offset: UInt64(back.count), max: NodeFile.preferredIO)
    if b.isEmpty { break }
    back += b
  }
  let readOnRing = file.onRing
  #expect(readOnRing)
  #expect(back == bytes)
  // A read elsewhere, then writes behind to a file there, and finish.
  #expect(try file.read(offset: 700_001, max: 9) == Array(bytes[700_001..<700_010]))
  var out = NodeFile(try i.namespace.open("/n/remote/notes"))
  var at = 0
  while at < bytes.count {
    let n = Swift.min(NodeFile.preferredIO, bytes.count - at)
    try out.write(offset: UInt64(at), Array(bytes[at..<at + n]))
    at += n
  }
  try out.finish()
  let wroteOnRing = out.onRing
  #expect(wroteOnRing)
  var local = try i.exported.namespace.open("/notes")
  #expect(try local.readAll() == bytes)
}

/// An import whose channels attached rings goes with its last channel,
/// as a cpu session's import of /mnt/term does at the session's end: the
/// ring held what it served (a cycle), so each session's import, its 9P
/// link and the link's TCP conversation were kept, until net had none
/// left for a call.
@Test(arguments: [false, true]) func anImportGoesWithItsChannels(ring: Bool) throws {
  let exported = try Exported()
  let bytes = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
  exported.tree.file("big", bytes)
  let dispatcher = try IPCDispatcher()
  let d = dispatcher
  _ = try Thread.spawn { try? d.run() }.release()
  defer { dispatcher.stop() }
  weak var held: Import?
  do {
    let gate = Import(try NinePClient(exported.client), dispatcher: dispatcher)
    held = gate
    let mounted = Namespace()
    try mounted.mount(try gate.attach(), at: "/n/remote")
    var file = NodeFile(try mounted.open("/n/remote/big"))
    var back: [UInt8] = []
    while ring || back.isEmpty {
      let b = try file.read(offset: UInt64(back.count), max: NodeFile.preferredIO)
      if b.isEmpty { break }
      back += b
    }
    let onRing = file.onRing
    #expect(onRing == ring)
    #expect(back == Array(bytes.prefix(back.count)))
    _ = consume file
    try mounted.unmount("/n/remote")
  }
  var kept = true
  for _ in 0..<300 {
    kept = held != nil
    if !kept { break }
    Sys.sleep(until: Clock.monotonic() + 10_000_000)
  }
  #expect(!kept)
}

