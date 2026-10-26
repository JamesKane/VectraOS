// SPDX-License-Identifier: BSD-3-Clause

// The fs service (fs(4)) over a RAM disk's partition, as the node runs
// them: a NodeTree's writable memory file (ramdisk(4)'s data) on one
// thread, the volume's channels on another, and Node and FsIPC clients.
// Files are made, written, read, listed, renamed, cut and removed; an
// open file outlives its name; attributes are typed; what is committed is
// there for the next fs over the same disk; what isn't served yet says so.

import FDIO
import Foundation
import Fs
import FsServer
import IPC
import Node
import Sd
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

/// A RAM disk of `blocks` blocks, as ramdisk(4) serves it: the block
/// class's unit (D106) over memory.
final class Disk: @unchecked Sendable {
  let unit: SdUnit
  let running: Running

  init(blocks: Int = 2048) throws {
    let dispatcher = try IPCDispatcher()
    let memory = try MemoryDisk(name: "ramdisk0", try VMO.create(size: blocks * 4096), sectors: UInt64(blocks),
                                sectorSize: 4096)
    unit = SdUnit(memory, dispatcher: dispatcher)
    running = Running(dispatcher)
  }

  /// A file of the unit's: `data`, or `ctl`.
  func open(_ name: String) throws -> Handle {
    var dir = NodeIPC.NodeClient(channel: try unit.channel())
    return try dir.open(name).takeChannel()
  }

  func partition() throws -> Handle { try open("data") }

  deinit { running.stop() }
}

/// An fs service over `disk`, formatted if it holds no volume, and a
/// namespace with its volume at /data.
final class Volume: @unchecked Sendable {
  let service: FsService
  let running: Running
  let ns = Namespace()
  /// Kept: its dispatcher stops when it goes, and the volume's disk with it.
  let disk: Disk

  init(_ disk: Disk) throws {
    self.disk = disk
    let device = try NodeDevice(try disk.partition(), ctl: try disk.open("ctl"))
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

/// An open asking ahead gets a file's first bytes, up to what it asked
/// for; a directory's open gets none. fdio's read-only opens ask, and
/// their first reads take the bytes without a round trip, until the
/// process writes; another client's write isn't seen (close-to-open).
@Test func anOpenGivesAFilesFirstBytes() throws {
  let disk = try Disk()
  let v = try Volume(disk)
  let bytes = (0..<6000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
  var big = try v.ns.create("/data/big", kind: .file)
  try big.write(offset: 0, bytes)
  var small = try v.ns.create("/data/small", kind: .file)
  try small.write(offset: 0, Array("aaaa".utf8))
  _ = try v.ns.create("/data/dir", kind: .directory)
  #expect(try v.ns.open("/data/big", stat: NodeIPC.Fields.size, ahead: 4096).ahead == Array(bytes[..<4096]))
  #expect(try v.ns.open("/data/small", stat: NodeIPC.Fields.size, ahead: 4096).ahead == Array("aaaa".utf8))
  #expect(try v.ns.open("/data/small", stat: NodeIPC.Fields.size).ahead == nil)
  #expect(try v.ns.open("/data/dir", stat: NodeIPC.Fields.size, ahead: 4096).ahead == nil)

  // The namespace given to each open, none installed: tests run at once.
  func read(_ fd: Int32, _ count: Int, at offset: Int64? = nil) -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: count)
    guard case .success(let n) = buffer.withUnsafeMutableBytes({ FDIO.read(fd, into: $0, at: offset) }) else { return nil }
    return Array(buffer[..<n])
  }
  func open(_ path: String, _ flags: Int32) throws -> Int32 {
    guard case .success(let fd) = FDIO.open(path, flags: flags, in: v.ns) else { throw NamespaceError.notFound }
    return fd
  }
  // Read across the bytes ahead and past them, and at an offset elsewhere.
  let fd = try open("/data/big", OpenFlags.readOnly)
  #expect(read(fd, 100) == Array(bytes[..<100]))
  #expect(read(fd, 5000) == Array(bytes[100..<5100]))
  #expect(read(fd, 10, at: 50) == Array(bytes[50..<60]))
  _ = FDIO.close(fd)
  // Another client's write after the open is missed by the first read...
  let stale = try open("/data/small", OpenFlags.readOnly)
  try small.write(offset: 0, Array("bbbb".utf8))
  #expect(read(stale, 100) == Array("aaaa".utf8))
  #expect(read(stale, 100) == [])
  _ = FDIO.close(stale)
  // ...and the process's own, through another descriptor, is not.
  let reader = try open("/data/small", OpenFlags.readOnly)
  let writer = try open("/data/small", OpenFlags.writeOnly)
  _ = Array("cccc".utf8).withUnsafeBytes { FDIO.write(writer, $0) }
  _ = FDIO.close(writer)
  #expect(read(reader, 100) == Array("cccc".utf8))
  _ = FDIO.close(reader)
}

/// The channels and fids open on the volume, as `status` says.
func sessions(_ v: Volume) -> Int {
  for line in v.service.status.split(separator: "\n") where line.hasPrefix("sessions ") {
    return Int(line.dropFirst(9)) ?? -1
  }
  return -1
}

@Test func aReadOnlyOpenIsAFid() throws {
  let disk = try Disk()
  let v = try Volume(disk)
  let bytes = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }
  var big = try v.ns.create("/data/big", kind: .file)
  var at = 0
  while at < bytes.count {
    let n = min(bytes.count - at, NodeIPC.maxIO)
    try big.write(offset: UInt64(at), Array(bytes[at..<at + n]))
    at += n
  }
  var small = try v.ns.create("/data/small", kind: .file)
  try small.write(offset: 0, Array("small".utf8))
  // A tree keeps no fids: its files open as channels.
  let dispatcher = try IPCDispatcher()
  let tree = NodeTree(dispatcher: dispatcher)
  tree.text("hello", read: { "from a tree" })
  let ends = try Channel.create()
  try tree.serve(ends.b)
  let running = Running(dispatcher)
  defer { running.stop() }
  try v.ns.mount(ends.a, at: "/tree")

  // The namespace given to each open, none installed: tests run at once.
  func read(_ fd: Int32, _ count: Int) -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: count)
    guard case .success(let n) = buffer.withUnsafeMutableBytes({ FDIO.read(fd, into: $0) }) else { return nil }
    return Array(buffer[..<n])
  }
  func open(_ path: String) throws -> Int32 {
    guard case .success(let fd) = FDIO.open(path, flags: OpenFlags.readOnly, in: v.ns) else { throw NamespaceError.notFound }
    return fd
  }
  let base = sessions(v)
  // A fid: a session on the volume, but no channel of its own.
  let fd = try open("/data/small")
  #expect(sessions(v) == base + 1)
  guard case .success(let s) = FDIO.status(fd) else { throw NamespaceError.notFound }
  #expect(s.size == 5)
  #expect(read(fd, 100) == Array("small".utf8))
  // Its close is sent with the next open's request, which opens another.
  _ = FDIO.close(fd)
  #expect(sessions(v) == base + 1)
  let whole = try open("/data/big")
  #expect(sessions(v) == base + 1)
  // Read past two full reads, it moves to a channel and a ring.
  #expect(read(whole, bytes.count + 10) == bytes)
  _ = FDIO.close(whole)
  // A removed file stays readable through its fid.
  let kept = try open("/data/small")
  var remover = try v.ns.open("/data/small")
  _ = try remover.run([.remove])
  #expect(read(kept, 100) == Array("small".utf8))
  _ = FDIO.close(kept)
  // Where the server keeps none, a channel.
  let fromTree = try open("/tree/hello")
  #expect(read(fromTree, 100) == Array("from a tree".utf8))
  _ = FDIO.close(fromTree)
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

/// A VMO's bytes, read through a mapping.
func bytes(_ vmo: borrowing Handle) throws -> [UInt8] {
  let size = try VMO.size(vmo)
  return try VMO.map(vmo, length: (size + 4095) & ~4095, writable: false).read(at: 0, count: size)
}

/// Queries need an index (or `scan`), which declaring fills in from what
/// is there; a live query hears the matches, `current`, then each change.
@Test func queriesAndLiveQueries() throws {
  let v = try Volume(try Disk())
  var root = FsIPC.DirectoryClient(channel: try v.root())
  var old = try root.makeFile("old.flac")
  try old.setAttribute(.int64("Audio:Year", 1982))
  #expect(refusal { () throws(IPCError<FsIPC.FsError>) in _ = try root.query("Audio:Year > 1990", scan: false) } == .needsIndex)
  try root.declareIndex("Audio:Year", kind: 2, caseless: false)
  #expect(try root.indices().contains { $0.name == "Audio:Year" && !$0.building })
  #expect(refusal { () throws(IPCError<FsIPC.FsError>) in _ = try root.query("Audio:Year >", scan: false) } == .badQuery)

  var live = FsIPC.LiveQueryClient(channel: try root.live("Audio:Year > 1980", scan: false))
  func next() throws -> FsIPC.QueryChange {
    guard case .changed(let c) = try live.nextEvent(deadline: Clock.monotonic() + 2_000_000_000) else {
      throw IPCError<Never>.wire(.unexpectedMessage)
    }
    return c
  }
  #expect(try next().path == "/old.flac")
  #expect(try next().kind == .current)
  var song = try root.makeFile("song.flac")
  try song.setAttribute(.int64("Audio:Year", 1993))
  let added = try next()
  #expect(added.kind == .added && added.path == "/song.flac")
  try song.setAttribute(.int64("Audio:Year", 1994))
  #expect(try next().kind == .changed)
  try song.setAttribute(.int64("Audio:Year", 1970))
  #expect(try next().kind == .removed)
  #expect(try root.query("Audio:Year < 1990", scan: false).map(\.path).sorted() == ["/old.flac", "/song.flac"])
  #expect(v.service.status.contains("live-queries 1\n"))
}

/// A mapped file's reads are copies from memory the service keeps
/// current: a write, one past its room (mapped again), a resize; a rename
/// or an unlink drops the mapping, and the path is looked up again.
@Test func mappedFilesStayCurrent() throws {
  let v = try Volume(try Disk())
  var root = FsIPC.DirectoryClient(channel: try v.root())
  var a = try root.makeFile("a.txt")
  let first = (0..<9000).map { UInt8(truncatingIfNeeded: $0) }
  try a.write(first)
  _ = try root.makeFile("b.txt")
  let files = FileCache(v.ns)
  #expect(try files.read("/data/a.txt", count: 9000) == first)
  #expect(try files.read("/data/a.txt", offset: 4096, count: 4096) == Array(first[4096..<8192]))
  #expect(files.misses == 1 && files.hits == 1 && v.service.mappedCount == 1)
  try a.write([1, 2, 3], at: 8999)
  #expect(try files.read("/data/a.txt", offset: 8998, count: 10) == [first[8998], 1, 2, 3])
  #expect(files.misses == 1)
  let big = [UInt8](repeating: 7, count: 40000)
  try a.write(big, at: 0)
  #expect(try files.read("/data/a.txt", count: 50000) == big)
  #expect(files.misses == 2)
  try a.resize(10)
  #expect(try files.readAll("/data/a.txt") == [UInt8](repeating: 7, count: 10))
  _ = try files.read("/data/b.txt", count: 1)
  try root.rename("b.txt", to: "c.txt")
  #expect(try files.readAll("/data/a.txt").count == 10)
  #expect(throws: FileCache.Failure.namespace(.notFound)) { try files.read("/data/b.txt", count: 1) }
  #expect(try files.readAll("/data/c.txt") == [])
  var data = try v.ns.open("/data")
  try data.remove("a.txt")
  #expect(throws: FileCache.Failure.namespace(.notFound)) { try files.read("/data/a.txt", count: 1) }
}

/// A listing kept warm (M6m) is never stale: a file made, an attribute
/// set, a rename, a removal, each seen by the next listing.
@Test func aKeptListingSeesEveryChange() throws {
  let v = try Volume(try Disk(blocks: 4096))
  var root = FsIPC.DirectoryClient(channel: try v.root())
  for i in 0..<600 { _ = try root.makeFile("f\(i)") }
  var all = try root.listAll(attributes: ["Audio:Year"])
  #expect(all.count == 600 && Set(all.map(\.name)).count == 600)
  #expect(try root.listAll(attributes: ["Audio:Year"]).count == 600)  // from what's kept
  var f = try root.makeFile("new")
  #expect(try root.listAll(attributes: ["Audio:Year"]).contains { $0.name == "new" })
  try f.setAttribute(.int64("Audio:Year", 1993))
  all = try root.listAll(attributes: ["Audio:Year"])
  #expect(all.first { $0.name == "new" }?.attributes.first?.int64Value == 1993)
  try root.rename("new", to: "renamed")
  all = try root.listAll(attributes: ["Audio:Year"])
  #expect(all.contains { $0.name == "renamed" } && !all.contains { $0.name == "new" })
  var data = try v.ns.open("/data")
  try data.remove("renamed")
  #expect(try root.listAll(attributes: ["Audio:Year"]).count == 600)
}

/// A listing asks for the stat fields it needs: without them each entry
/// has its node and kind but no size, and a kept listing without them
/// never serves one with them.
@Test func aListingStatsOnlyWhenAsked() throws {
  let v = try Volume(try Disk())
  var a = try v.ns.create("/data/a", kind: .file)
  try a.write(offset: 0, Array("hello\n".utf8))
  _ = try v.ns.create("/data/dir", kind: .directory)
  let node = try a.stat().qid.path
  for _ in 0..<2 {  // the second from what's kept
    let bare = try v.ns.list("/data", fields: 0).sorted { $0.name < $1.name }
    #expect(bare.map(\.name) == ["a", "dir"] && bare.map(\.size) == [0, 0])
    #expect(bare.map(\.qid.kind) == [.file, .directory] && bare[0].qid.path == node)
    let full = try v.ns.list("/data", fields: NodeIPC.Fields.size).sorted { $0.name < $1.name }
    #expect(full.first?.size == 6)
  }
}

/// The whole listing is cold until a batched one has been served whole,
/// then the batched one's entries, in one VMO; a change makes it cold.
@Test func theWholeListingIsTheBatchedOne() throws {
  let v = try Volume(try Disk(blocks: 4096))
  var root = FsIPC.DirectoryClient(channel: try v.root())
  for i in 0..<300 {
    var f = try root.makeFile("f\(i)")
    if i % 2 == 0 { try f.setAttribute(.int64("Audio:Year", Int64(1900 + i))) }
  }
  func whole() throws -> [(String, UInt64)] {
    let r = try #require(ListingVMO.Reader(try bytes(try root.wholeListing(attributes: ["Audio:Year"]))))
    return (0..<r.count).map { i in
      let e = r.entry(i)
      return (String(decoding: r.bytes[e.name], as: UTF8.self), e.node)
    }
  }
  #expect(refusal { () throws(IPCError<FsIPC.FsError>) in _ = try root.wholeListing(attributes: ["Audio:Year"]) } == .cold)
  let batched = try root.listAll(attributes: ["Audio:Year"])
  var all = try whole()
  #expect(all.map(\.0) == batched.map(\.name) && all.map(\.1) == batched.map(\.node))
  _ = try root.makeFile("new")
  #expect(refusal { () throws(IPCError<FsIPC.FsError>) in _ = try root.wholeListing(attributes: ["Audio:Year"]) } == .cold)
  _ = try root.listAll(attributes: ["Audio:Year"])
  all = try whole()
  #expect(all.count == 301 && all.contains { $0.0 == "new" })
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
