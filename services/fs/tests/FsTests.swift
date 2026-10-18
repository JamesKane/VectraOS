// SPDX-License-Identifier: BSD-3-Clause

// The fs service (fs(4)) over a RAM disk's partition, as the node runs
// them: a NodeTree's writable memory file (ramdisk(4)'s data) on one
// thread, the volume's channels on another, and Node and FsIPC clients.
// Files are made, written, read, listed, renamed, cut and removed; an
// open file outlives its name; attributes are typed; what is committed is
// there for the next fs over the same disk; what isn't served yet says so.

import Foundation
import Fs
import FsServer
import IPC
import Node
import Sys
import Taisce
import Testing

/// A dispatcher run on a thread of its own until stopped.
final class Running: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let thread: Foundation.Thread

  init(_ dispatcher: IPCDispatcher) {
    self.dispatcher = dispatcher
    thread = Foundation.Thread { try? dispatcher.run() }
    thread.start()
  }

  func stop() { dispatcher.stop() }
}

/// A RAM disk of `blocks` blocks: its partition's tree.
final class Disk: @unchecked Sendable {
  let tree: NodeTree
  let running: Running

  init(blocks: Int = 2048) throws {
    let dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
    try tree.memory("sdZ0/data", writable: try VMO.create(size: blocks * 4096), size: UInt64(blocks * 4096))
    running = Running(dispatcher)
  }

  func partition() throws -> Handle {
    let ends = try Channel.create()
    try tree.serve(ends.b, at: tree.node("sdZ0/data")!)
    return ends.a
  }

  deinit { running.stop() }
}

/// An fs service over `disk`, formatted if it holds no volume, and a
/// namespace with its volume at /data.
final class Volume: @unchecked Sendable {
  let service: FsService
  let running: Running
  let ns = Namespace()

  init(_ disk: Disk) throws {
    let device = try NodeDevice(try disk.partition())
    var fs: FileSystem<NodeDevice>
    do {
      fs = try FileSystem.mount(device)
    } catch .notAVolume {
      fs = try FileSystem.format(device, label: Array("data".utf8), uuid: Array(1...16), now: 1)
    }
    let dispatcher = try IPCDispatcher()
    service = try FsService(fs, device: "/dev/sdZ0/data", dispatcher: dispatcher)
    running = Running(dispatcher)
    try ns.mount(try root(), at: "/data", create: true)
  }

  func root() throws -> Handle { try service.root() }

  deinit { running.stop() }
}

func text(_ ns: Namespace, _ path: String) throws -> String {
  var c = try ns.open(path)
  return try c.readText()
}

func names(_ ns: Namespace, _ path: String) throws -> [String] { try ns.list(path).map(\.name).sorted() }

func failure<R>(_ body: () throws(NamespaceError) -> R) -> NamespaceError? {
  do { _ = try body() } catch { return error }
  return nil
}

/// The fs protocol's error a call was refused with, if it was.
func refusal(_ body: () throws(IPCError<FsIPC.FsError>) -> Void) -> FsIPC.FsError? {
  do throws(IPCError<FsIPC.FsError>) { try body() } catch {
    if case .remote(let e) = error { return e }
    return .io
  }
  return nil
}

@Test func filesAreMadeReadListedAndRemoved() throws {
  let disk = try Disk()
  let v = try Volume(disk)
  var a = try v.ns.create("/data/a", kind: .file)
  try a.write(offset: 0, Array("hello\n".utf8))
  _ = try v.ns.create("/data/dir", kind: .directory)
  _ = try v.ns.create("/data/dir/b", kind: .file)
  #expect(try names(v.ns, "/data") == ["a", "dir"])
  #expect(try names(v.ns, "/data/dir") == ["b"])
  #expect(try text(v.ns, "/data/a") == "hello\n")
  var c = try v.ns.open("/data/a")
  let st = try c.stat()
  #expect(st.name == "a" && st.size == 6 && st.qid.kind == .file)
  var dirNode = try v.ns.open("/data/dir")
  #expect(try dirNode.stat().qid.kind == .directory)
  #expect(failure { () throws(NamespaceError) in try v.ns.open("/data/none") } == .notFound)
  #expect(failure { () throws(NamespaceError) in try v.ns.create("/data/a", kind: .file) } == .node(.exists))
  #expect(failure { () throws(NamespaceError) in try v.ns.open("/data/a/b") } == .node(.notDirectory))
  // A directory with something in it stays; empty, it goes.
  var dir = try v.ns.open("/data/dir")
  #expect(throws: NodeIPC.NodeClient.Failure.self) { _ = try dir.run([.remove]) }
  var b = try v.ns.open("/data/dir/b")
  _ = try b.run([.remove])
  _ = try dir.run([.remove])
  #expect(try names(v.ns, "/data") == ["a"])
}

@Test func aFileOfManyBlocksComesBackWhole() throws {
  let disk = try Disk(blocks: 4096)
  let v = try Volume(disk)
  // 2 MiB and a bit: more than one batch of the device's, and of Node's.
  let bytes = (0..<(2 << 20) + 1234).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) }
  _ = try v.ns.create("/data/big", kind: .file)
  var f = FsIPC.FileClient(channel: try v.ns.connect("/data/big"))
  try f.write(bytes)
  #expect(try f.readAll() == bytes)
  var d = FsIPC.DirectoryClient(channel: try v.root())
  try d.sync()
  let again = try Volume(disk)
  var g = try again.ns.open("/data/big")
  #expect(try g.readAll() == bytes)
}

@Test func wstatRenamesCutsAndTimes() throws {
  let disk = try Disk()
  let v = try Volume(disk)
  var a = try v.ns.create("/data/a", kind: .file)
  try a.write(offset: 0, Array("abcdef".utf8))
  _ = try v.ns.create("/data/b", kind: .file)
  try v.ns.wstat("/data/a", NodeIPC.Wstat(name: "c", modified: 2_000_000_000, size: 3))
  #expect(try names(v.ns, "/data") == ["b", "c"])
  var c = try v.ns.open("/data/c")
  let st = try c.stat()
  #expect(st.size == 3 && st.modified == 2_000_000_000)
  #expect(try text(v.ns, "/data/c") == "abc")
  // A name taken, and nothing else changed.
  #expect(failure { () throws(NamespaceError) in try v.ns.wstat("/data/c", NodeIPC.Wstat(name: "b", size: 0)) } == .node(.exists))
  #expect(try c.stat().size == 3)
  #expect(failure { () throws(NamespaceError) in try v.ns.wstat("/data/c", NodeIPC.Wstat(name: "x/y")) } == .node(.badName))
  // Across directories, through the fs protocol.
  _ = try v.ns.create("/data/sub", kind: .directory)
  var root = FsIPC.DirectoryClient(channel: try v.root())
  try root.rename("c", to: "sub/d")
  #expect(try names(v.ns, "/data/sub") == ["d"])
  try root.rename("sub/d", to: "e")
  var e = FsIPC.FileClient(channel: try v.ns.connect("/data/e"))
  try e.resize(1)
  #expect(try text(v.ns, "/data/e") == "a")
}

@Test func anOpenFileOutlivesItsName() throws {
  let disk = try Disk()
  let v = try Volume(disk)
  var a = try v.ns.create("/data/a", kind: .file)
  try a.write(offset: 0, Array("still here".utf8))
  var gone = try v.ns.open("/data/a")
  _ = try gone.run([.remove])
  #expect(try names(v.ns, "/data").isEmpty)
  #expect(try a.readText() == "still here")
}

@Test func attributesAreTyped() throws {
  let disk = try Disk()
  let v = try Volume(disk)
  _ = try v.ns.create("/data/song", kind: .file)
  var f = FsIPC.FileClient(channel: try v.ns.connect("/data/song"))
  try f.setAttribute(.string("Audio:Artist", "Clannad"))
  try f.setAttribute(.int64("Audio:Year", 1990))
  #expect(try f.getAttribute("Audio:Year").int64Value == 1990)
  #expect(try f.getAttribute("Audio:Artist").stringValue == "Clannad")
  var c = try v.ns.open("/data/song")
  #expect(try c.stat().attributes.map(\.name).sorted() == ["Audio:Artist", "Audio:Year"])
  var d = FsIPC.DirectoryClient(channel: try v.root())
  #expect(try d.listAll(attributes: ["Audio:Year"]).first?.attributes.first?.int64Value == 1990)
  try f.removeAttribute("Audio:Artist")
  #expect(refusal { () throws(IPCError<FsIPC.FsError>) in _ = try f.getAttribute("Audio:Artist") } == .notFound)
}

@Test func whatIsCommittedOutlivesTheService() throws {
  let disk = try Disk()
  do {
    let v = try Volume(disk)
    var a = try v.ns.create("/data/kept", kind: .file)
    try a.write(offset: 0, Array("kept\n".utf8))
    var d = FsIPC.DirectoryClient(channel: try v.root())
    try d.sync()
    #expect(v.service.status.contains("commits 1"))
  }
  let again = try Volume(disk)
  #expect(try text(again.ns, "/data/kept") == "kept\n")
  #expect(again.service.status.contains("volume data"))
}

@Test func aChangeCommitsWithinTheDelay() throws {
  let disk = try Disk()
  let v = try Volume(disk)
  _ = try v.ns.create("/data/soon", kind: .file)
  let deadline = Date().addingTimeInterval(5)
  while !v.service.status.contains("commits 1"), Date() < deadline { usleep(50_000) }
  #expect(v.service.status.contains("commits 1"))
}

@Test func whatIsNotServedYetSaysSo() throws {
  let disk = try Disk()
  let v = try Volume(disk)
  _ = try v.ns.create("/data/f", kind: .file)
  var d = FsIPC.DirectoryClient(channel: try v.root())
  #expect(refusal { () throws(IPCError<FsIPC.FsError>) in _ = try d.query("Audio:Year > 1", scan: true) } == .unsupported)
  #expect(refusal { () throws(IPCError<FsIPC.FsError>) in _ = try d.live("Audio:Year > 1", scan: true) } == .unsupported)
  #expect(refusal { () throws(IPCError<FsIPC.FsError>) in _ = try d.declareIndex("Audio:Year", kind: 2, caseless: false) } == .unsupported)
  #expect(refusal { () throws(IPCError<FsIPC.FsError>) in _ = try d.wholeListing(attributes: []) } == .unsupported)
  #expect(try d.indices().isEmpty)
  var f = FsIPC.FileClient(channel: try v.ns.connect("/data/f"))
  #expect(refusal { () throws(IPCError<FsIPC.FsError>) in _ = try f.map() } == .unsupported)
}

/// A file's bulk through the volume (D103): its channel's ring, the disk's
/// below it, the same bytes after a remount.
@Test func aFilesBulkGoesOnTheRings() throws {
  let disk = try Disk(blocks: 4096)
  let bytes = (0..<(3 << 20) + 4321).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ $0 >> 14) }
  do {
    let v = try Volume(disk)
    var out = NodeFile(try v.ns.create("/data/big", kind: .file))
    var at = 0
    while at < bytes.count {
      let n = Swift.min(NodeFile.preferredIO, bytes.count - at)
      try out.write(offset: UInt64(at), Array(bytes[at..<at + n]))
      at += n
    }
    try out.finish()
    let wrote = out.onRing
    #expect(wrote)
    var d = FsIPC.DirectoryClient(channel: try v.root())
    try d.sync()
  }
  let v = try Volume(disk)
  var file = NodeFile(try v.ns.open("/data/big"))
  var back: [UInt8] = []
  while true {
    let b = try file.read(offset: UInt64(back.count), max: NodeFile.preferredIO)
    if b.isEmpty { break }
    back += b
  }
  let read = file.onRing
  #expect(read)
  #expect(back == bytes)
}
