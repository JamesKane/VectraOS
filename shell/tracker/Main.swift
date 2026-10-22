// SPDX-License-Identifier: BSD-3-Clause

// bin/tracker (D107, after todhchai's M6j): Tracker on croi, in full Swift:
// the desktop (the volume's root at /data, its icons over the storyboard's
// grid, beneath every window), a window per folder or query opened from it
// (each at its `Tracker:Frame`, fed by a thread of its own in Feed.swift),
// its plumber ports (`folder` and `find`), and the file chooser view
// (`ChooserView`) registered with Radharc at `/svc/windows/chooser` for the
// trusted prompt (D111).
//
// With TRACKER_TEST in its environment, it seeds board 01's desktop (home,
// a query "Notes" for Markdown files, the Trash, down the screen's right)
// and logs "tracker: ready", "opened PATH at X Y", "moved PATH X Y",
// "closed PATH", "query PATH N matches", "query PATH added NAME"; when
// Notes is first current it writes home/arrival.md, which must arrive;
// Control-Q ends it.

import Fs
import IPC
import Kit
import KitPlatform
import Node
import Radharc
import Settings
import Synchronization
import Sys
import Tracker
import TrackerApp
import UICore
import VX
import VectraOSLibc

func fail(_ what: String) -> Never {
  print("tracker: FAILED: \(what)")
  Process.exit(code: 1)
}

/// A pending chooser request from Radharc (`Chooser.begin`), holding its
/// noncopyable `Opened` view until the main loop adopts it.
final class PendingBegin: @unchecked Sendable {
  let id: UInt64
  var view: RadharcIPC.Opened?
  let save: Bool
  let types: [String]
  let name: String
  let app: String

  init(id: UInt64, view: consuming RadharcIPC.Opened, save: Bool, types: [String], name: String, app: String) {
    self.id = id
    self.view = consume view
    self.save = save
    self.types = types
    self.name = name
    self.app = app
  }
}

/// Shared state between the `ChooserServer` thread and `@MainActor`.
final class ChooserBridge: @unchecked Sendable {
  struct Inner {
    var begins: [PendingBegin] = []
    var cancels: [UInt64] = []
    var confirmID: UInt64?
    var confirmResult: Result<UInt32, RadharcIPC.WindowError>?
    var bellSeq: Int64 = 0
    var ready = false
    var activeChoosers: [UInt64] = []
  }
  let state = Mutex(Inner())
  let bell: UInt32
  var waker: (@Sendable () -> Void)?

  init() throws(Status) {
    bell = try Counter.create().release()
  }

  deinit { _ = Handle(raw: bell) }

  func enqueueBegin(_ b: PendingBegin) {
    state.withLock { $0.begins.append(b) }
    waker?()
  }

  func enqueueCancel(_ id: UInt64) {
    state.withLock { $0.cancels.append(id) }
    waker?()
  }

  func confirm(_ id: UInt64) throws(RadharcIPC.WindowError) -> Handle {
    let target = state.withLock { s -> Int64 in
      s.confirmID = id
      s.confirmResult = nil
      return s.bellSeq + 1
    }
    waker?()
    let c = Handle(raw: bell)
    _ = try? Counter.wait(c, until: target)
    _ = c.release()
    let res = state.withLock { s -> Result<UInt32, RadharcIPC.WindowError> in
      defer { s.confirmResult = nil }
      return s.confirmResult ?? .failure(.invalid)
    }
    switch res {
    case .success(let raw): return Handle(raw: raw)
    case .failure(let err): throw err
    }
  }

  func finishConfirm(_ result: Result<UInt32, RadharcIPC.WindowError>) {
    state.withLock { s in
      s.confirmID = nil
      s.confirmResult = result
      s.bellSeq += 1
    }
    let c = Handle(raw: bell)
    try? Counter.add(c, 1)
    _ = c.release()
  }
}

struct ChooserHandler: RadharcIPC.ChooserHandler {
  let bridge: ChooserBridge

  func begin(id: UInt64, view: consuming RadharcIPC.Opened, mode: RadharcIPC.ChooseMode, types: [String], name: String,
             app: String)
  {
    bridge.enqueueBegin(PendingBegin(id: id, view: view, save: mode == .save, types: types, name: name, app: app))
  }

  func cancel(id: UInt64) {
    bridge.enqueueCancel(id)
  }

  func confirm(id: UInt64) throws(RadharcIPC.WindowError) -> Handle {
    try bridge.confirm(id)
  }
}

@MainActor final class NativeHost: TrackerHost {
  let session: Session
  let ns: Namespace
  let bridge: ChooserBridge
  let testing: Bool
  var folders: [(path: String, window: KitWindow, app: FolderWindow, feed: Feed)] = []
  var queries: [(path: String, window: KitWindow, app: QueryWindow, feed: Feed)] = []
  var choosers: [(id: UInt64, window: KitWindow, app: ChooserView, clientApp: String)] = []
  var desktop: (window: KitWindow, app: FolderWindow, feed: Feed)?
  var said: Set<String> = []
  var wrote = false

  init(session: Session, ns: Namespace, bridge: ChooserBridge, testing: Bool) {
    self.session = session
    self.ns = ns
    self.bridge = bridge
    self.testing = testing
  }

  func say(_ line: String) { print("tracker: " + line) }

  /// A Volume of its own over /data (one a window, one a feed).
  func volume() -> Volume? {
    guard let ch = try? ns.connect("/data") else { return nil }
    return Volume(root: FsIPC.DirectoryClient(channel: ch))
  }

  func openDesktop() throws {
    guard let v = volume(), let fv = volume() else { throw TrackerError.failed }
    let app = try FolderWindow(path: "", volume: v, host: self, desktop: true)
    if var f = try? ns.open("/svc/fs/status"), let text = try? f.readText(),
      let info = VolumeInfo.parse(fsStatus: text, boot: true)
    {
      app.volumes = [info]
      say("volume \(info.name)")
    }
    let w = try session.open(app, width: 320, height: 200, desktop: true)
    desktop = (w, app, try Feed.folder("", volume: fv, window: app, wake: session.waker))
  }

  /// Where a window opens: its kept frame, else board 01's place for a
  /// folder (12cqw, 6cqw; 40 by 24) cascaded by the windows open.
  func frame(_ state: FolderState, query: Bool) -> (x: Int32, y: Int32, width: Int32, height: Int32) {
    if let f = state.frame, f.width >= 64, f.height >= 64 { return f }
    let n = Int32(folders.count + queries.count)
    let c = Theme.cqw
    return (Int32(c(12)) + 24 * n, Int32(c(6)) + 24 * n, Int32(query ? c(56) : c(40)), Int32(query ? c(32) : c(24)))
  }

  func open(folder path: String) {
    guard !folders.contains(where: { $0.path == path }) else { return }
    guard let v = volume(), let fv = volume(), let app = try? FolderWindow(path: path, volume: v, host: self) else {
      say("can't open \(path)")
      return
    }
    let f = frame(app.state, query: false)
    guard let w = try? session.open(app, width: f.width, height: f.height, at: (f.x, f.y)),
      let feed = try? Feed.folder(path, volume: fv, window: app, wake: session.waker)
    else { return }
    folders.append((path, w, app, feed))
    say("opened \(path) at \(f.x) \(f.y)")
    Recent.note(Recent.folders, Self.absolute(path), ns)
  }

  static let queries = "Queries"

  /// A routed message: to `folder`, its folder opened (a path in /data);
  /// to `find`, a new query window (Be's Find).
  func routed(find: Bool, _ m: RouteMessage) {
    if find {
      guard let v = volume() else { return }
      if (try? v.stat(Self.queries)) == nil { _ = try? v.makeFolder(in: "", named: Self.queries) }
      guard let q = try? v.makeQuery(in: Self.queries, named: "Find", text: "name == \"*\"") else { return }
      say("find \(q)")
      open(query: q)
      return
    }
    let p = m.data
    let path = p == "/data" ? "" : p.hasPrefix("/data/") ? String(p.dropFirst(6)) : p
    if path.isEmpty {
      openDesktopFolder()
    } else {
      open(folder: path)
    }
  }

  func openDesktopFolder() { open(folder: "") }

  func open(query path: String) {
    guard !queries.contains(where: { $0.path == path }) else { return }
    guard let v = volume(), let fv = volume(),
      let app = try? QueryWindow(path: path, volume: v, host: self, clock: { Clock.monotonic() })
    else {
      say("can't open \(path)")
      return
    }
    let f = frame(app.state, query: true)
    guard let w = try? session.open(app, width: f.width, height: f.height, at: (f.x, f.y)),
      let feed = try? Feed.query(volume: fv, window: app, wake: session.waker)
    else { return }
    queries.append((path, w, app, feed))
    feed.run(app.text, generation: app.generation)
    say("opened \(path) at \(f.x) \(f.y)")
  }

  func run(_ query: QueryWindow) {
    queries.first { $0.app === query }?.feed.run(query.text, generation: query.generation)
  }

  func close(_ window: any App) {
    if let i = folders.firstIndex(where: { $0.app === window }) {
      let f = folders.remove(at: i)
      f.feed.stop()
      session.close(f.window)
      say("closed \(f.path)")
    } else if let i = queries.firstIndex(where: { $0.app === window }) {
      let q = queries.remove(at: i)
      q.feed.stop()
      session.close(q.window)
      say("closed \(q.path)")
    } else if let i = choosers.firstIndex(where: { $0.app === window }) {
      let c = choosers.remove(at: i)
      session.close(c.window)
    }
  }

  func quit() { if testing { session.stop() } }

  static func absolute(_ path: String) -> String { path.isEmpty ? "/data" : "/data/" + path }

  func route(_ path: String, type: String) -> String? {
    let r = Route(wdir: Self.absolute(Path.split(path).folder), type: type, data: Self.absolute(path))
    do throws(RouteError) {
      try session.route(r)
      if type != "text" { Recent.note(Recent.documents, type + "\t" + Self.absolute(path), ns) }
      say("routed \(path)")
      return nil
    } catch {
      say("route \(path): \(error)")
      return error == .refused ? "Nothing opens \(type)" : "Can't route: \(error)"
    }
  }

  func addOns() -> [AddOn] {
    guard var f = try? ns.open("/svc/launcher/apps"), let text = try? f.readText() else { return [] }
    return AddOn.parse(text)
  }

  func run(addOn service: String, paths: [String]) -> String? {
    guard var ctl = try? ns.open("/svc/launcher/ctl"),
      (try? ctl.writeText(AddOn.start(service, paths.map(Self.absolute)))) != nil
    else {
      say("add-on \(service): can't start it")
      return "Can't start \(service)"
    }
    say("add-on \(service) " + paths.map(Self.absolute).joined(separator: " "))
    return nil
  }

  func moved(_ w: KitWindow, _ x: Int32, _ y: Int32) {
    if let f = folders.first(where: { $0.window === w }) {
      f.app.moved(x: x, y: y)
      say("moved \(f.path) \(x) \(y)")
    } else if let q = queries.first(where: { $0.window === w }) {
      q.app.moved(x: x, y: y)
      say("moved \(q.path) \(x) \(y)")
    }
  }

  /// Processes queued chooser requests (`begin`, `cancel`, `confirm`) on
  /// `@MainActor`.
  func woken() {
    let (begins, cancels, confirmID) = bridge.state.withLock { s -> ([PendingBegin], [UInt64], UInt64?) in
      let b = s.begins
      let c = s.cancels
      s.begins = []
      s.cancels = []
      return (b, c, s.confirmID)
    }
    for b in begins {
      guard let opened = b.view.take(), let v = volume(),
        let app = try? ChooserView(path: "", volume: v, save: b.save, types: b.types, name: b.name),
        let w = try? session.adoptView(app, opened: opened)
      else { continue }
      choosers.append((b.id, w, app, b.app))
      say("chooser \(b.id) \(b.save ? "save" : "open")")
    }
    for id in cancels {
      if let i = choosers.firstIndex(where: { $0.id == id }) {
        let c = choosers.remove(at: i)
        bridge.state.withLock { $0.activeChoosers.removeAll { $0 == id } }
        session.close(c.window)
      }
    }
    if let id = confirmID {
      guard let i = choosers.firstIndex(where: { $0.id == id }) else {
        bridge.finishConfirm(.failure(.unavailable))
        return
      }
      let c = choosers[i]
      do {
        guard let chosen = try c.app.confirm() else {
          bridge.finishConfirm(.failure(.invalid))
          return
        }
        let path = chosen.path
        let abs = Self.absolute(path)
        let mime = (try? c.app.volume.type(path)) ?? "application/octet-stream"
        Recent.note(Recent.documents, mime + "\t" + abs, ns)
        choosers.remove(at: i)
        bridge.state.withLock { $0.activeChoosers.removeAll { $0 == id } }
        say("chose \(path)")
        bridge.finishConfirm(.success(chosen.handle.release()))
        session.close(c.window)
      } catch {
        bridge.finishConfirm(.failure(.invalid))
      }
    }
  }

  func afterFrame(_ w: KitWindow) {
    if let d = desktop, w === d.window, d.app.loaded {
      bridge.state.withLock { $0.ready = true }
      if testing { once("ready") }
    }
    for c in choosers where c.window === w {
      bridge.state.withLock { s in
        if !s.activeChoosers.contains(c.id) { s.activeChoosers.append(c.id) }
      }
    }
    guard testing else { return }
    for q in queries where q.window === w {
      guard q.app.results.current else { continue }
      once("query \(q.path) \(q.app.results.folder.entries.count) matches")
      if !wrote, let v = volume() {
        wrote = true
        _ = try? v.makeFile(in: "home", named: "arrival.md", contents: Array("# arrived\n".utf8))
      }
      if let a = q.app.results.lastAdded { once("query \(q.path) added \(a.name)") }
    }
  }

  func once(_ line: String) {
    guard !said.contains(line) else { return }
    said.insert(line)
    say(line)
  }

  func seed() {
    guard let v = volume() else { return }
    if (try? v.stat("home")) == nil { _ = try? v.makeFolder(in: "", named: "home") }
    for d in ["Music", "Projects", "People"] where (try? v.stat("home/" + d)) == nil {
      _ = try? v.makeFolder(in: "home", named: d)
    }
    if (try? v.stat("home/render-notes.md")) == nil {
      _ = try? v.makeFile(in: "home", named: "render-notes.md", contents: Array("# render notes\n".utf8))
    }
    if (try? v.stat("Notes")) == nil { _ = try? v.makeQuery(in: "", named: "Notes", text: #"name == "*.md""#) }
    if (try? v.stat("Trash")) == nil { _ = try? v.makeFolder(in: "", named: "Trash") }
    if (try? v.stat("home/arrival.md")) != nil { _ = try? v.trash(["home/arrival.md"]) }
    try? v.removeAttribute("home", FolderState.frameAttribute)
    for (name, y) in [("home", Float(100)), ("Notes", 200), ("Trash", 300)] { try? v.place(name, x: 1150, y: y) }
  }
}

@main struct TrackerMain {
  @MainActor static func main() async {
    let start = Startup.current
    guard let ns = processNamespace() else { fail("no namespace") }
    let bridge: ChooserBridge
    do throws(Status) { bridge = try ChooserBridge() } catch { fail("no chooser bridge: \(error.rawValue)") }
    let session: Session
    do { session = try Session() } catch { fail("no session: \(error)") }
    session.appName = "Tracker"
    bridge.waker = session.waker

    if let export = start.export(), let dispatcher = try? IPCDispatcher() {
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: {
        let (ready, ids) = bridge.state.withLock { ($0.ready, $0.activeChoosers) }
        var out = "tracker\n"
        if ready { out += "ready\n" }
        for id in ids { out += "chooser \(id)\n" }
        return out
      })
      if (try? tree.serve(export)) != nil {
        _ = try? Thread.spawn { try? dispatcher.run() }.release()
      }
    }

    let host = NativeHost(session: session, ns: ns, bridge: bridge, testing: ns.getenv("TRACKER_TEST") != nil)
    if host.testing { host.seed() }
    session.onWake = { host.woken() }
    session.onMoved = { w, x, y in host.moved(w, x, y) }
    if var rules = try? ns.open("/mnt/plumb/rules"), let current = try? rules.readText(),
      !current.contains("plumb to folder")
    {
      try? rules.writeText(
        "type is folder\nplumb to folder\n\ntype is text\ndata matches '/data(/[^.]*)?'\nplumb to folder\n\n"
          + "type is tracker/find\nplumb to find\n")
    }
    let findPort = try? session.listen(port: "find")
    _ = try? session.listen(port: "folder")
    session.onRouted = { id, m in host.routed(find: id == findPort, m) }
    session.onClose = { w in host.close(w.app) }
    session.afterFrame = { w in
      host.afterFrame(w)
      return false
    }
    // Register the file chooser with Radharc (`/svc/windows/chooser`).
    if let ch = try? ns.connect("/svc/windows/chooser"), let pair = try? Channel.create() {
      var provider = RadharcIPC.ChooserProviderClient(channel: ch)
      try? provider.register(chooser: pair.a)
      let serverRaw = pair.b.release()
      _ = try? Thread.spawn {
        var server = RadharcIPC.ChooserServer(channel: Handle(raw: serverRaw), impl: ChooserHandler(bridge: bridge))
        try? server.serve()
      }.release()
    }

    do { try host.openDesktop() } catch { fail("no desktop: \(error)") }

    await session.run()
    print("tracker: ended")
    Process.exit(code: 0)
  }
}
