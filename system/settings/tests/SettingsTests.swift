// SPDX-License-Identifier: BSD-3-Clause

// Settings (D113), over the fs service on a RAM disk's partition, mounted
// at /data: defaults when nothing's set, a setting written (its folder and
// file made), read back, refused out of range, the folder's watch naming
// the area changed, D111's recorded grants (recorded, listed, revoked),
// the Recent lists, and rc's `attr` reading, setting and removing them on
// the volume.

import Foundation
import Fs
import FsServer
import IPC
import Node
import Rc
import Sd
import Settings
import Sys
import Taisce
import Testing

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

/// A RAM disk and an fs service over it, mounted at /data in a namespace
/// of its own.
final class Rig: @unchecked Sendable {
  let diskRunning: Running
  let unit: SdUnit
  let fsRunning: Running
  let service: FsService
  let ns = Namespace()

  init(blocks: Int = 2048) throws {
    let diskDispatcher = try IPCDispatcher()
    let memory = try MemoryDisk(name: "ramdisk0", try VMO.create(size: blocks * 4096), sectors: UInt64(blocks),
                                sectorSize: 4096)
    let u = SdUnit(memory, dispatcher: diskDispatcher)
    unit = u
    diskRunning = Running(diskDispatcher)
    func open(_ name: String) throws -> Handle {
      var dir = NodeIPC.NodeClient(channel: try u.channel())
      return try dir.open(name).takeChannel()
    }
    let device = VolumeDevice(try NodeDevice(try open("data"), ctl: try open("ctl")))
    let fs = try FileSystem.format(device, label: Array("data".utf8), uuid: Array(1...16), now: 1)
    let fsDispatcher = try IPCDispatcher()
    service = try FsService(fs, device: "/dev/sdZ0/data", dispatcher: fsDispatcher)
    fsRunning = Running(fsDispatcher)
    try ns.mount(try service.root(), at: "/data", create: true)
  }

  func stop() {
    fsRunning.stop()
    diskRunning.stop()
  }

  deinit { stop() }
}

/// An RcSystem whose `attr` calls go to `/data` in `ns`, as CroiSystem's do.
final class VolumeSystem: RcSystem {
  let ns: Namespace
  var cwd = "/data/Settings"

  init(_ ns: Namespace) { self.ns = ns }

  func absolute(_ p: String) -> String { p.hasPrefix("/") ? p : (cwd == "/" ? "/" + p : cwd + "/" + p) }

  func attributes(_ path: String) -> [(name: String, value: AttributeText)]? {
    guard let ch = try? ns.connect(absolute(path)) else { return nil }
    var n = NodeIPC.NodeClient(channel: ch)
    guard let st = try? n.stat(fields: NodeIPC.Fields.attributes) else { return nil }
    return st.attributes.map { a in
      func integer() -> Int64 { Int64(bitPattern: a.value.prefix(8).reversed().reduce(0) { $0 << 8 | UInt64($1) }) }
      switch a.kind {
      case 1, 9: return (a.name, .string(String(decoding: a.value, as: UTF8.self)))
      case 2 where a.value.count == 8: return (a.name, .int(integer()))
      case 6 where a.value.count == 1: return (a.name, .bool(a.value[0] != 0))
      default: return (a.name, .other("(\(a.value.count) bytes, kind \(a.kind))"))
      }
    }
  }

  func setAttribute(_ path: String, _ name: String, _ value: AttributeText?) -> Bool {
    guard let ch = try? ns.connect(absolute(path)) else { return false }
    var f = FsIPC.FileClient(channel: ch)
    guard let value else { return (try? f.removeAttribute(name)) != nil }
    let attribute: FsIPC.Attribute
    switch value {
    case .int(let v): attribute = SettingValue.int(v).attribute(name)
    case .bool(let b): attribute = SettingValue.bool(b).attribute(name)
    case .string(let s), .other(let s): attribute = SettingValue.string(s).attribute(name)
    }
    return (try? f.setAttribute(attribute)) != nil
  }

  func open(_ path: String, _ mode: RcOpen) -> RcStream? { nil }
  func pipe() -> (RcStream, RcStream) {
    let m = MemoryStream()
    return (m, m)
  }
  func executable(_ path: String) -> Bool { false }
  func start(_ path: String, _ argv: [String], fds: [Int32: RcStream], environment: [String]) -> RcJob? { nil }
  func changeDirectory(_ path: String) -> Bool {
    cwd = absolute(path)
    return true
  }
  var directory: String { cwd }
  func list(_ directory: String) -> [String]? { (try? ns.list(absolute(directory), fields: 0))?.map(\.name) }
}

func runRc(_ script: String, _ ns: Namespace) -> (out: String, err: String, status: String) {
  let shell = Rc(system: VolumeSystem(ns), arguments: [])
  let out = MemoryStream(), err = MemoryStream()
  shell.run(script, fds: [0: MemoryStream(), 1: out, 2: err])
  return (out.text, err.text, shell.status)
}

@Test func settingsAreFilesWithAttributes() throws {
  let rig = try Rig()
  // Nothing set: the defaults.
  #expect(Settings.value(Settings.repeatDelay, rig.ns) == .int(500))
  #expect(Settings.value(Settings.theme, rig.ns) == .string("platinum-indigo"))
  #expect(Settings.areas == ["Appearance", "Keyboard", "Mouse", "Deskbar"])
  // Set: the folder and the area's file made.
  #expect(Settings.set(Settings.repeatDelay, .int(250), rig.ns))
  #expect(Settings.set(Settings.theme, .string("neon-tab"), rig.ns))
  #expect(Settings.value(Settings.repeatDelay, rig.ns) == .int(250))
  #expect(Settings.value(Settings.theme, rig.ns) == .string("neon-tab"))
  #expect(Settings.read("Keyboard", rig.ns).map(\.name) == ["Keyboard:RepeatDelay"])
  // Out of range, or another kind: the default.
  #expect(Settings.set(Settings.repeatRate, .int(500), rig.ns))
  #expect(Settings.value(Settings.repeatRate, rig.ns) == .int(30))
  #expect(Settings.repeatRate.accept(.string("fast")) == .int(30)
            && Settings.theme.accept(.string("Pink")) == .string("platinum-indigo"))
}

@Test func theFoldersWatchNamesTheAreaChanged() throws {
  let rig = try Rig()
  guard var watch = Settings.watch(rig.ns) else {
    Issue.record("no watch")
    return
  }
  // Heard for an area: until a change touches it.
  func heard(_ area: String) -> Bool {
    for _ in 0..<40 {
      if case .changed(let c)? = try? watch.nextEvent(deadline: Clock.monotonic() + 100_000_000),
        Settings.touches(c, area)
      {
        return true
      }
    }
    return false
  }
  // The area's file made: the change names the area.
  #expect(Settings.set(Settings.pointerSpeed, .int(8), rig.ns))
  #expect(heard("Mouse"))
  // A setting changed in a file that's there: the change names the
  // attribute.
  #expect(Settings.set(Settings.pointerSpeed, .int(3), rig.ns))
  #expect(heard("Mouse"))
  #expect(Settings.set(Settings.clock24, .bool(false), rig.ns))
  #expect(Settings.set(Settings.clock24, .bool(true), rig.ns))
  #expect(heard("Deskbar"))
  #expect(Settings.touches(NodeIPC.Change(seq: 1, node: 0, kind: .modified, name: "Deskbar:Clock24"), "Deskbar"))
  #expect(!Settings.touches(NodeIPC.Change(seq: 1, node: 0, kind: .modified, name: "Deskbar:Clock24"), "Desk"))
  #expect(!Settings.touches(NodeIPC.Change(seq: 1, node: 0, kind: .modified, name: "Mouse:Speed"), "Keyboard"))
}

@Test func grantsAreRecordedListedAndRevoked() throws {
  let rig = try Rig()
  guard var watch = Settings.watch(rig.ns) else {
    Issue.record("no watch")
    return
  }
  // Heard: the attribute's own change, or changes missed.
  func heard(_ name: String) -> Bool {
    for _ in 0..<40 {
      if case .changed(let c)? = try? watch.nextEvent(deadline: Clock.monotonic() + 100_000_000),
        c.kind == .overflow || c.name == name
      {
        return true
      }
    }
    return false
  }
  // Every change waiting, taken.
  func drain() {
    while case .changed? = try? watch.nextEvent(deadline: Clock.monotonic() + 200_000_000) {}
  }
  #expect(Grants.recorded("recorder", "capture", rig.ns) == nil)
  #expect(Grants.list(rig.ns).isEmpty)
  #expect(Grants.record("recorder", "capture", true, rig.ns))
  #expect(Grants.record("clicker", "inject", false, rig.ns))
  #expect(Grants.recorded("recorder", "capture", rig.ns) == true)
  #expect(Grants.recorded("clicker", "inject", rig.ns) == false)
  #expect(Grants.recorded("recorder", "inject", rig.ns) == nil)
  #expect(Grants.list(rig.ns).sorted { $0.app < $1.app } == [
    Grants.Entry(app: "clicker", service: "inject", allowed: false),
    Grants.Entry(app: "recorder", service: "capture", allowed: true),
  ])
  // Revoked: the watch hears the attribute's removal, not a recording's
  // change still waiting, and the attribute is gone.
  #expect(heard("Grants:clicker.inject"))
  drain()
  #expect(Grants.revoke("recorder", "capture", rig.ns))
  #expect(!Grants.revoke("recorder", "capture", rig.ns))
  #expect(Grants.recorded("recorder", "capture", rig.ns) == nil)
  #expect(Grants.list(rig.ns) == [Grants.Entry(app: "clicker", service: "inject", allowed: false)])
  #expect(heard("Grants:recorder.capture"))
}

/// rc's `attr` on `/data/Settings`: reads, sets, lists and removes
/// settings and D111's recorded grants on the volume.
@Test func rcAttrReadsSetsAndRevokesSettingsAndGrants() throws {
  let rig = try Rig()
  #expect(Settings.set(Settings.repeatDelay, .int(400), rig.ns))
  #expect(Grants.record("tile", "shortcuts", true, rig.ns))
  let read = runRc("attr Keyboard Keyboard:RepeatDelay; attr Grants", rig.ns)
  #expect(read.err.isEmpty && read.status.isEmpty)
  #expect(read.out == "400\nGrants:tile.shortcuts true\n")
  let wrote = runRc("attr Keyboard Keyboard:RepeatDelay 250; attr Keyboard Keyboard:RepeatRate 45; attr Grants Grants:master-stack.windows true; attr -d Grants Grants:tile.shortcuts",
                    rig.ns)
  #expect(wrote.err.isEmpty && wrote.status.isEmpty)
  #expect(Settings.value(Settings.repeatDelay, rig.ns) == .int(250))
  #expect(Settings.value(Settings.repeatRate, rig.ns) == .int(45))
  #expect(Grants.recorded("tile", "shortcuts", rig.ns) == nil)
  #expect(Grants.recorded("master-stack", "windows", rig.ns) == true)
  #expect(Grants.list(rig.ns) == [Grants.Entry(app: "master-stack", service: "windows", allowed: true)])
}

/// The Recent lists: newest first, once each, ten kept.
@Test func recentListsKeepTheNewestTen() throws {
  let rig = try Rig()
  let ns = rig.ns
  #expect(Recent.list(Recent.folders, ns).isEmpty)
  for i in 0..<12 { Recent.note(Recent.folders, "/data/f\(i)", ns) }
  Recent.note(Recent.folders, "/data/f5", ns)
  let l = Recent.list(Recent.folders, ns)
  #expect(l.count == 10 && l.first == "/data/f5" && l.filter { $0 == "/data/f5" }.count == 1 && !l.contains("/data/f0"))
}
