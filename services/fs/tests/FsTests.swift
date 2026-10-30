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
    let device = VolumeDevice(try NodeDevice(try disk.partition(), ctl: try disk.open("ctl")))
    var fs: FileSystem<VolumeDevice>
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
  // From the file's own node too, where the walk hasn't read it.
  var fromFile = try v.ns.open("/data/a")
  var refused: NodeIPC.NodeError? = nil
  do throws(NodeIPC.NodeClient.Failure) {
    _ = try fromFile.run([.walk(names: ["b"])])
  } catch {
    if case .remote(let e) = error { refused = e }
  }
  #expect(refused == .notDirectory)
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

/// Writes go behind, into the file's VMO: their size shows at once, a
/// truncate writes them back first, and File.sync makes them durable.
@Test func writesBehindShowAtOnceAndAFileSyncKeepsThem() throws {
  let disk = try Disk()
  do {
    let v = try Volume(disk)
    var c = try v.ns.create("/data/behind", kind: .file)
    try c.write(offset: 0, Array("one\n".utf8))
    try c.write(offset: 8192, Array("two\n".utf8))
    #expect(try c.stat().size == 8196)
    var f = FsIPC.FileClient(channel: try v.ns.connect("/data/behind"))
    try f.resize(8195)
    #expect(try c.stat().size == 8195)
    try c.write(offset: 8195, Array("!".utf8))
    try f.sync()
  }
  let again = try Volume(disk)
  var c = try again.ns.open("/data/behind")
  #expect(try c.read(offset: 0, max: 16384) == Array("one\n".utf8) + [UInt8](repeating: 0, count: 8188) + Array("two!".utf8))
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
  #expect(files.misses == 1 && files.hits == 1 && v.service.mappedFiles == 1)
  try a.write([1, 2, 3], at: 8999)
  #expect(try files.read("/data/a.txt", offset: 8998, count: 10) == [first[8998], 1, 2, 3])
  #expect(files.misses == 1)
  let big = [UInt8](repeating: 7, count: 40000)
  try a.write(big, at: 0)
  #expect(try files.read("/data/a.txt", count: 50000) == big)
  #expect(files.misses == 2)
  try a.resize(10)
  #expect(try files.readAll("/data/a.txt") == [UInt8](repeating: 7, count: 10))
  // Shrunk, then written past a gap: the gap reads zeros, not the old bytes.
  try a.write([9], at: 20)
  #expect(try files.readAll("/data/a.txt") == [UInt8](repeating: 7, count: 10) + [UInt8](repeating: 0, count: 10) + [9])
  try a.resize(10)
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

/// Waits up to 5 s for the service's status to say `line`.
func waitFor(_ v: Volume, _ line: String) -> Bool { waitFor(v.service, line) }

func waitFor(_ service: FsService, _ line: String) -> Bool {
  let deadline = Date().addingTimeInterval(5)
  while !service.status.contains(line), Date() < deadline { usleep(20_000) }
  return service.status.contains(line)
}

/// A snapshot is taken through `ctl`, written-behind bytes and all, and
/// read at `snap/YYYY/MMDD`, unchanged by what follows and read-only; then
/// deleted by name.
@Test func aSnapshotIsTakenReadAndDeleted() throws {
  let disk = try Disk()
  let v = try Volume(disk)
  try v.ns.mount(try v.service.snapshotRoot(), at: "/snap", create: true)
  var a = try v.ns.create("/data/a", kind: .file)
  try a.write(offset: 0, Array("before\n".utf8))
  _ = try v.ns.create("/data/dir", kind: .directory)
  try v.service.control("snap")
  #expect(waitFor(v, "snapshots 1"))
  try a.write(offset: 0, Array("AFTER!\n".utf8))
  _ = try v.ns.create("/data/b", kind: .file)
  let years = try names(v.ns, "/snap")
  #expect(years.count == 1)
  let days = try names(v.ns, "/snap/" + years[0])
  #expect(days.count == 1 && days[0].utf8.count == 4)
  let at = "/snap/" + years[0] + "/" + days[0]
  #expect(try names(v.ns, at) == ["a", "dir"])
  #expect(try text(v.ns, at + "/a") == "before\n")
  #expect(try text(v.ns, "/data/a") == "AFTER!\n")
  var old = try v.ns.open(at + "/a")
  #expect(try old.stat().size == 7)
  #expect(throws: NodeIPC.NodeClient.Failure.self) { _ = try old.run([.write(offset: 0, data: [1])]) }
  #expect(failure { () throws(NamespaceError) in try v.ns.create(at + "/c", kind: .file) } != nil)
  #expect(throws: NodeError.invalid) { try v.service.control("snap now") }
  try v.service.control("unsnap " + years[0] + "/" + days[0])
  #expect(waitFor(v, "snapshots 0"))
  #expect(v.service.status.contains(" deleted"))
  #expect(try names(v.ns, "/snap").isEmpty)
  try v.service.control("unsnap " + years[0] + "/" + days[0])
  #expect(waitFor(v, "failed: no such snapshot"))
}

/// Copies `spec`'s stream from `source` (a `send`) to `target` (a
/// `receive/<sys>`), as send(1) does.
func copyStream(_ ns: Namespace, _ spec: String, from source: String, to target: String) throws {
  var src = try ns.open(source)
  try src.write(offset: 0, Array(spec.utf8))
  var dst = try ns.open(target)
  var at: UInt64 = 0
  while true {
    let bytes = try src.read(offset: at, max: UInt32(NodeIPC.maxIO))
    if bytes.isEmpty { break }
    _ = try dst.write(offset: at, bytes)
    at += UInt64(bytes.count)
  }
}

/// One volume's snapshot sent whole to another's `receive/a`, then a
/// change of it as an incremental: the receiver's `recv/a` follows, and
/// takes a snapshot of its own each time.
@Test func aSnapshotIsSentToAnotherVolume() throws {
  let a = try Volume(try Disk(blocks: 4096))
  let b = try Volume(try Disk(blocks: 4096))
  let ns = Namespace()
  try ns.mount(try a.root(), at: "/a", create: true)
  try ns.mount(try a.service.sendRoot(), at: "/a-send", create: true)
  try ns.mount(try b.root(), at: "/b", create: true)
  try ns.mount(try b.service.receiveRoot(), at: "/b-receive", create: true)
  var f = try ns.create("/a/f", kind: .file)
  try f.write(offset: 0, Array("first\n".utf8))
  _ = try ns.create("/a/dir", kind: .directory)
  var g = try ns.create("/a/dir/g", kind: .file)
  for at in stride(from: 0, to: 100_000, by: 25_000) {
    _ = try g.write(offset: UInt64(at), [UInt8](repeating: 7, count: 25_000))
  }
  try a.service.control("snap")
  #expect(waitFor(a, "snapshots 1"))
  let day = a.service.status.split(separator: "\n").first { $0.hasPrefix("snap ") }!.split(separator: " ")[1]
  try copyStream(ns, String(day), from: "/a-send", to: "/b-receive/a")
  #expect(waitFor(b, "receive a to txg"))
  #expect(try text(ns, "/b/recv/a/f") == "first\n")
  var copied = try ns.open("/b/recv/a/dir/g")
  #expect(try copied.stat().size == 100_000)
  #expect(try copied.read(offset: 75_000, max: 30_000) == [UInt8](repeating: 7, count: 25_000))
  #expect(try names(ns, "/b-receive") == ["a"])
  // A change, and only it is sent.
  try f.write(offset: 0, Array("second".utf8))
  _ = try ns.create("/a/new", kind: .file)
  try a.service.control("snap")
  #expect(waitFor(a, "snapshots 2"))
  let later = a.service.status.split(separator: "\n").last { $0.hasPrefix("snap ") }!.split(separator: " ")[1]
  try copyStream(ns, String(day) + " " + String(later), from: "/a-send", to: "/b-receive/a")
  #expect(waitFor(b, "snapshots 2"))
  #expect(try text(ns, "/b/recv/a/f") == "second")
  #expect(try names(ns, "/b/recv/a") == ["dir", "f", "new"])
  // The same changes again: the base is past them, so they're refused.
  #expect(throws: (any Error).self) {
    try copyStream(ns, String(day) + " " + String(later), from: "/a-send", to: "/b-receive/a")
  }
  #expect(waitFor(b, "receive a failed"))
}

/// An encrypted volume (S2, D153 §3): made by its first `unlock`, which
/// becomes its first slot; a slot added through `ctl`; then, mounted
/// again, locked until `unlock` gives a passphrase a slot takes.
@Test func anEncryptedVolumeUnlocksThroughCtl() throws {
  let disk = try Disk()
  func partition() throws -> NodeDevice { try NodeDevice(try disk.partition(), ctl: try disk.open("ctl")) }
  func serve(_ fs: consuming FileSystem<VolumeDevice>, _ key: VolumeKey, _ opening: Opening) throws
    -> (FsService, Running)
  {
    let dispatcher = try IPCDispatcher()
    let service = try FsService(fs, device: "/dev/sdZ0/data", dispatcher: dispatcher, key: key)
    opening.serving(service)
    return (service, Running(dispatcher))
  }
  do {
    let opening = try Opening(keybag: nil, encrypted: true, device: "/dev/sdZ0/data")
    #expect(opening.status.contains("volume locked, new"))
    #expect(throws: NodeError.invalid) { try opening.control("snap") }
    #expect(throws: NodeError.invalid) { try opening.control("unlock \n") }
    try opening.control("unlock first  words\n")
    #expect(throws: NodeError.exists) { try opening.control("unlock again") }
    let (key, made) = opening.waitForKey()
    let keybag = try #require(made)
    #expect(keybag.unlock(Array("first  words".utf8)) == key)
    let fs = try FileSystem.format(VolumeDevice(try partition(), sealing: Sealing(key)), label: Array("data".utf8),
                                   uuid: Array(1...16), now: 1, keybag: keybag)
    let (service, running) = try serve(fs, key, opening)
    defer { running.stop() }
    let ns = Namespace()
    try ns.mount(try service.root(), at: "/data", create: true)
    var a = try ns.create("/data/kept", kind: .file)
    try a.write(offset: 0, Array("kept\n".utf8))
    try opening.control("slot add passphrase second one")
    #expect(waitFor(service, "slot 1 passphrase added"))
    #expect(opening.status.contains("keybag passphrase passphrase empty empty\n"))
    #expect(!opening.status.contains("second one"))
    try opening.control("slot remove 3")
    #expect(waitFor(service, "slot remove 3 failed: the slot is empty"))
    var d = FsIPC.DirectoryClient(channel: try service.root())
    try d.sync()
  }
  // Again, from what is on the disk.
  var probe = VolumeDevice(try partition())
  let keybag = try #require(try Taisce.Volume.newestSuperblock(&probe).keybag)
  let opening = try Opening(keybag: keybag, encrypted: true, device: "/dev/sdZ0/data")
  #expect(opening.status.contains("volume locked\n"))
  #expect(throws: TaisceError.locked) { _ = try FileSystem.mount(VolumeDevice(try partition())) }
  #expect(throws: NodeError.denied) { try opening.control("unlock first words") }
  try opening.control("unlock second one")
  let (key, made) = opening.waitForKey()
  #expect(made == nil)
  let fs = try FileSystem.mount(VolumeDevice(try partition(), sealing: Sealing(key)))
  let (service, running) = try serve(fs, key, opening)
  defer { running.stop() }
  let ns = Namespace()
  try ns.mount(try service.root(), at: "/data", create: true)
  #expect(try text(ns, "/data/kept") == "kept\n")
  try opening.control("slot remove 0")
  #expect(waitFor(service, "slot 0 removed"))
  try opening.control("slot remove 1")
  #expect(waitFor(service, "slot remove 1 failed: it is the last"))
}

/// A plain volume has no slots to change.
@Test func aPlainVolumeHasNoSlots() throws {
  let v = try Volume(try Disk())
  #expect(throws: NodeError.unsupported) { try v.service.control("slot add passphrase words") }
  #expect(!v.service.status.contains("keybag"))
}
