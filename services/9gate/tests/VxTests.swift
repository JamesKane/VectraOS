// SPDX-License-Identifier: BSD-3-Clause

// 9P2000.vx (D151): an fs volume exported and imported back, its fs
// protocol used through the import as FDIO uses it: a rename between
// directories (Trename) and within one (wstat's name), a resize (wstat's
// length) and a sync (a wstat that changes nothing); what isn't carried
// yet says `unsupported`; typed attributes (Tgetattrs, Tsetattr,
// Tdelattr) carry Settings between nodes; a plain 9P2000 export renames
// only within a directory and has no attributes; and a T-message of ours
// a peer doesn't know is answered, not fatal.

import Fs
import FsServer
import Gate
import IPC
@testable import NineP
import Node
import Sd
import Settings
import Sys
import Taisce
import Testing

/// An fs volume over a RAM disk, at /data in its namespace, exported
/// (9P2000.vx, or plain 9P2000 if not `extended`) over a channel and
/// imported back at `at` (/n) in the client's namespace.
final class VxVolume: @unchecked Sendable {
  let disk: IPCDispatcher, fsDispatcher: IPCDispatcher, imports: IPCDispatcher
  let service: FsService
  let ns = Namespace()
  let client = Namespace()
  let import9: Import

  init(extended: Bool = true, at mountPoint: String = "/n") throws {
    disk = try IPCDispatcher()
    let memory = try MemoryDisk(name: "ramdisk0", try VMO.create(size: 2048 * 4096), sectors: 2048, sectorSize: 4096)
    let unit = SdUnit(memory, dispatcher: disk)
    fsDispatcher = try IPCDispatcher()
    imports = try IPCDispatcher()
    for d in [disk, fsDispatcher, imports] { _ = try Thread.spawn { try? d.run() }.release() }
    var dir = NodeIPC.NodeClient(channel: try unit.channel())
    let data = try dir.open("data").takeChannel()
    var ctlDir = NodeIPC.NodeClient(channel: try unit.channel())
    let device = try NodeDevice(data, ctl: try ctlDir.open("ctl").takeChannel())
    let fs = try FileSystem.format(device, label: Array("data".utf8), uuid: Array(1...16), now: 1)
    service = try FsService(fs, device: "/dev/sdZ0/data", dispatcher: fsDispatcher)
    try ns.mount(try service.root(), at: "/data", create: true)
    let ends = try Channel.create()
    let server = ByteStream.channel(ends.b), stream = ByteStream.channel(ends.a)
    let exported = ns
    _ = try Thread.spawn { _ = Export.serve(server, namespace: exported, root: "/data", extended: extended) }.release()
    import9 = Import(try NinePClient(stream), dispatcher: imports)
    try client.mount(try import9.attach(), at: mountPoint)
  }

  func make(_ path: String, _ text: String) throws {
    var f = try ns.create(path, kind: .file)
    _ = try f.write(offset: 0, Array(text.utf8))
  }

  func directory(_ path: String) throws -> FsIPC.DirectoryClient {
    FsIPC.DirectoryClient(channel: try client.open(path).takeChannel())
  }

  func file(_ path: String) throws -> FsIPC.FileClient {
    FsIPC.FileClient(channel: try client.open(path).takeChannel())
  }

  deinit {
    for d in [imports, fsDispatcher, disk] { d.stop() }
  }
}

func read(_ ns: Namespace, _ path: String) -> String? {
  guard var f = try? ns.open(path), let t = try? f.readText() else { return nil }
  return t
}

func fsRefusal(_ body: () throws(IPCError<FsIPC.FsError>) -> Void) -> FsIPC.FsError? {
  do throws(IPCError<FsIPC.FsError>) {
    try body()
    return nil
  } catch {
    if case .remote(let e) = error { return e }
    return .io
  }
}

@Test func vxCarriesFsRenamesResizesAndSyncs() throws {
  let v = try VxVolume()
  _ = try v.ns.create("/data/d1", kind: .directory)
  _ = try v.ns.create("/data/d2", kind: .directory)
  try v.make("/data/d1/a", "moved")
  try v.make("/data/d1/b", "renamed")
  try v.make("/data/d1/c", "cut short")

  // Between directories: Trename. Within one: wstat's name.
  var root = try v.directory("/n")
  try root.rename("d1/a", to: "d2/a2")
  #expect(read(v.ns, "/data/d2/a2") == "moved")
  #expect(read(v.ns, "/data/d1/a") == nil)
  try root.rename("d1/b", to: "d1/b2")
  #expect(read(v.ns, "/data/d1/b2") == "renamed")
  #expect(fsRefusal { () throws(IPCError<FsIPC.FsError>) in try root.rename("d1/nothing", to: "d2/x") } == .notFound)

  // A resize is a wstat of the length; a sync, one that changes nothing.
  var c = try v.file("/n/d1/c")
  try c.resize(3)
  #expect(read(v.ns, "/data/d1/c") == "cut")
  try c.sync()
  var d = try v.directory("/n/d2")
  try d.sync()

  // What 9P2000.vx doesn't carry yet says so.
  #expect(fsRefusal { () throws(IPCError<FsIPC.FsError>) in _ = try d.list(cursor: 0, max: 8, attributes: []) } == .unsupported)
}

@Test func settingsLiveOnAnotherNodesVolume() throws {
  // The importing node's /data is the other's volume: Settings writes
  // and reads its typed attributes there through 9P2000.vx.
  let v = try VxVolume(at: "/data")
  #expect(Settings.value(Settings.clock24, v.client) == .bool(true))  // the default: nothing there yet
  #expect(Settings.set(Settings.clock24, .bool(false), v.client))
  #expect(Settings.store("Workspaces", "Workspaces:Count", .int(3), v.client))
  #expect(Settings.value(Settings.clock24, v.client) == .bool(false))
  // On the volume itself, as a local reader sees them.
  #expect(Settings.value(Settings.clock24, v.ns) == .bool(false))
  #expect(Settings.read("Workspaces", v.ns).map { $0.name } == ["Workspaces:Count"])
  // Removed through the import.
  var f = try FsIPC.FileClient(channel: v.client.open("/data/Settings/Workspaces").takeChannel())
  try f.removeAttribute("Workspaces:Count")
  #expect(Settings.read("Workspaces", v.ns).isEmpty)
  #expect(fsRefusal { () throws(IPCError<FsIPC.FsError>) in _ = try f.getAttribute("Workspaces:Count") } == .notFound)
}

@Test func plain9P2000HasNoAttributes() throws {
  let v = try VxVolume(extended: false, at: "/data")
  #expect(!Settings.set(Settings.clock24, .bool(false), v.client))
  #expect(Settings.value(Settings.clock24, v.client) == .bool(true))
}

@Test func plain9P2000RenamesOnlyWithinADirectory() throws {
  let v = try VxVolume(extended: false)
  _ = try v.ns.create("/data/d1", kind: .directory)
  _ = try v.ns.create("/data/d2", kind: .directory)
  try v.make("/data/d1/a", "stays")
  var root = try v.directory("/n")
  #expect(fsRefusal { () throws(IPCError<FsIPC.FsError>) in try root.rename("d1/a", to: "d2/a") } == .unsupported)
  try root.rename("d1/a", to: "d1/a2")
  #expect(read(v.ns, "/data/d1/a2") == "stays")
}

@Test func anUnknownExtensionIsAnsweredNotFatal() {
  // A T-message of 9P2000.vx's range this side doesn't know.
  let bytes: [UInt8] = [11, 0, 0, 0, 200, 7, 0, 1, 2, 3, 4]
  #expect(Message.decode(bytes) == Message(tag: 7, .unknown(type: 200)))
  // An R-message type, or one of 9P2000's, that doesn't parse is still refused.
  #expect(Message.decode([11, 0, 0, 0, 201, 7, 0, 1, 2, 3, 4]) == nil)
  #expect(Message.decode([11, 0, 0, 0, 116, 7, 0, 1, 2, 3, 4]) == nil)
}
