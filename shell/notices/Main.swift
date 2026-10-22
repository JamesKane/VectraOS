// SPDX-License-Identifier: BSD-3-Clause

// bin/notices (notices(4), D117): the slips apps post and the drawer, the
// history of notices and of the clipboard, as a Kit app. Each client of
// /svc/notices has its own tree (`export per-client`), so a notice names
// the app that posted it: `post` takes a notice a line, `ctl` the drawer's
// verbs, `status` what it shows. A thread reads Radharc's `clipboard`
// (its manifest's `grant windows clipboard`) and keeps each entry as a
// file in /data/Clips with its Clip: attributes, within the limits in
// Settings' `Drawer`. The slips' panel is open only while there are
// slips, and a slip's life is the one deadline it waits for: an empty
// desk wakes it never.
//
// `status`: `ready`, `slips N`, `slip ID APP LAMP TITLE` each, `waiting
// N`, `history N`, `clips N`, `clip N SOURCE TYPES` each, `drawer open`
// or `closed`, `clipboard open` or `none`, `wakeups N`. With NOTICES_TEST
// in its environment it logs each change.

import Fs
import IPC
import Kit
import KitPlatform
import Node
import Notices
import NoticesApp
import Radharc
import Settings
import Sys
import UICore
import VX
import VectraOSLibc

func fail(_ what: String) -> Never {
  print("notices: FAILED: \(what)")
  Process.exit(code: 1)
}

/// What the notices and clips are, shared by the tree's thread, the
/// clipboard's and the main one.
final class Model: @unchecked Sendable {
  let lock = Lock()
  let ns: Namespace
  var board = NoticeBoard()
  var shelf = ClipShelf()
  /// The newest clip's entry: one equal to it isn't kept twice.
  var newest: [UInt8] = []
  /// Clips' entries, when there is no volume to keep them in.
  var memory: [(number: Int, bytes: [UInt8])] = []
  var volume = false
  var feedOpen = false
  /// The drawer's open or close asked, and whether it is open.
  var drawerAsked = false
  var drawerOpen = false
  var status = ""
  var wake: @Sendable () -> Void = {}

  init(ns: Namespace) { self.ns = ns }

  /// /data/Clips, made if need be.
  func folder() -> FsIPC.DirectoryClient? {
    guard let ch = try? ns.connect("/data") else { return nil }
    var data = FsIPC.DirectoryClient(channel: ch)
    if (try? data.directory("Clips")) == nil { _ = try? data.makeDirectory("Clips") }
    return try? data.directory("Clips")
  }

  /// The limits in Settings' `Drawer`, and the clips kept.
  func load() {
    let settings = Settings.read("Drawer", ns)
    func limit(_ name: String, _ fallback: Int) -> Int {
      guard case .int(let v)? = settings.first(where: { $0.name == name })?.value, v > 0 else { return fallback }
      return Int(v)
    }
    var found: [Clip] = []
    var dir = folder()
    volume = dir != nil
    let names = ["Clip:Source", "Clip:Origin", "Clip:Time", "Clip:Types"]
    for e in (try? dir?.listAll(attributes: names)) ?? [] {
      guard let number = Int(e.name) else { continue }
      func attr(_ n: String) -> FsIPC.Attribute? { e.attributes.first { $0.name == n } }
      let types = (attr("Clip:Types")?.stringValue ?? "").split(separator: ",").map(String.init)
      var head: [UInt8] = []
      if var f = try? dir?.file(e.name), let all = try? f.readAll() { head = Array(all.prefix(4096)) }
      found.append(Clip(number: number, source: attr("Clip:Source")?.stringValue ?? "",
                        origin: attr("Clip:Origin")?.stringValue ?? "", time: attr("Clip:Time")?.int64Value ?? 0,
                        types: types, size: Int(e.size),
                        preview: Clip.preview(text: ClipFeedParser.text(head), types: types)))
    }
    lock.withLock {
      shelf.maxCount = limit("Drawer:Clips", 50)
      shelf.maxDays = limit("Drawer:Days", 30)
      shelf.maxMiB = limit("Drawer:MiB", 64)
      shelf.load(found)
    }
    if let last = shelf.clips.last, var f = try? dir?.file(String(last.number)), let all = try? f.readAll() {
      lock.withLock { newest = all }
    }
    discard(lock.withLock { shelf.prune(now: Clock.realtime() / 1_000_000_000) })
  }

  /// An entry the clipboard gave: kept, unless it is the newest again.
  func keep(_ e: FedEntry) {
    let now = Clock.realtime() / 1_000_000_000
    let clip: Clip? = lock.withLock {
      guard e.bytes != newest else { return nil }
      newest = e.bytes
      return Clip(number: shelf.nextNumber, source: e.source, origin: e.origin, time: now, types: e.types,
                  size: e.bytes.count, preview: Clip.preview(text: ClipFeedParser.text(e.bytes), types: e.types))
    }
    guard let clip else { return }
    if volume, var dir = folder(), var f = try? dir.makeFile(String(clip.number)) {
      _ = try? f.write(e.bytes)
      _ = try? f.setAttribute(.string("Clip:Source", clip.source))
      _ = try? f.setAttribute(.string("Clip:Origin", clip.origin))
      _ = try? f.setAttribute(.int64("Clip:Time", clip.time))
      _ = try? f.setAttribute(.string("Clip:Types", clip.types.joined(separator: ",")))
    } else {
      lock.withLock { memory.append((clip.number, e.bytes)) }
    }
    discard(lock.withLock { shelf.add(clip, now: now) })
    wake()
  }

  /// Clips gone from the shelf: their files too.
  func discard(_ numbers: [Int]) {
    guard !numbers.isEmpty else { return }
    lock.withLock { memory.removeAll { numbers.contains($0.number) } }
    if volume {
      for n in numbers {
        if var node = try? ns.open("/data/Clips/\(n)") { _ = try? node.remove() }
      }
    }
  }

  /// Clip `number`'s entry.
  func bytes(_ number: Int) -> [UInt8]? {
    if let m = lock.withLock({ memory.first { $0.number == number }?.bytes }) { return m }
    guard volume, var f = try? ns.open("/data/Clips/\(number)") else { return nil }
    return try? f.readAll()
  }

  /// Clip `number` committed to the clipboard again.
  func paste(_ number: Int) -> Bool {
    guard lock.withLock({ shelf.clip(number) }) != nil, let b = bytes(number),
      var f = try? ns.open("/svc/windows/clip/new")
    else { return false }
    var done = 0
    while done < b.count {
      guard let n = try? f.write(offset: 0, Array(b[done..<min(b.count, done + NodeIPC.maxIO)])), n > 0 else {
        return false
      }
      done += Int(n)
    }
    return true
  }

  func forget(_ number: Int) -> Bool {
    guard lock.withLock({ shelf.remove(number) }) else { return false }
    discard([number])
    wake()
    return true
  }

  func clear() {
    discard(lock.withLock { () -> [Int] in
      newest = []
      return shelf.removeAll()
    })
    wake()
  }

  /// A `ctl` line.
  func command(_ text: String) -> Bool {
    let w = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    guard let verb = w.first else { return false }
    let n = w.count == 2 ? Int(w[1]) : nil
    switch (verb, n) {
    case ("drawer", nil) where w.count == 1:
      lock.withLock { drawerAsked = true }
      wake()
      return true
    case ("dismiss", let n?):
      let ok = lock.withLock { board.dismiss(n, now: Clock.monotonic()) }
      wake()
      return ok
    case ("paste", let n?): return paste(n)
    case ("forget", let n?): return forget(n)
    case ("clear", nil) where w.count == 1:
      clear()
      return true
    default: return false
    }
  }
}

/// Reads Radharc's `clipboard` for good, keeping each entry.
func followClipboard(_ model: Model) {
  guard let f = try? model.ns.open("/svc/windows/clipboard") else {
    print("notices: no clipboard (Radharc's, granted `windows clipboard`)")
    return
  }
  let raw = f.takeChannel().release()
  model.lock.withLock { model.feedOpen = true }
  _ = (try? Thread.spawn {
    var file = NodeIPC.NodeClient(channel: Handle(raw: raw))
    var parser = ClipFeedParser()
    while let bytes = try? file.read(offset: 0, max: UInt32(NodeIPC.maxIO)), !bytes.isEmpty {
      for e in parser.feed(bytes) { model.keep(e) }
      if parser.broken {
        print("notices: the clipboard's stream broke its form")
        break
      }
    }
    model.lock.withLock { model.feedOpen = false }
    model.wake()
  })?.release()
}

struct NoticesClients: LaunchIPC.ClientsHandler {
  let dispatcher: IPCDispatcher
  let model: Model
  func open(client: String, grants: [String], node: consuming Handle) throws(LaunchIPC.ClientsError) {
    guard grants.isEmpty else { throw .refused }
    let tree = NodeTree(dispatcher: dispatcher)
    let model = self.model
    tree.text("post", read: { "" }, write: { (text: String) throws(NodeError) in
      for line in text.split(separator: "\n") {
        do throws(NoticeRefusal) {
          _ = try model.lock.withLock { () throws(NoticeRefusal) in
            try model.board.post(String(line), app: client, now: Clock.monotonic())
          }
        } catch {
          print("notices: \(client): \(error.reason)")
          throw .invalid
        }
      }
      model.wake()
    })
    tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
      guard model.command(text) else { throw .invalid }
    })
    tree.text("status", read: { model.lock.withLock { model.status } })
    do throws(Status) { try tree.serve(node) } catch { throw .refused }
  }
}

@MainActor final class NativeHost: NoticesHost {
  let model: Model
  let session: Session
  let testing: Bool
  let slips: Slips
  let drawer: Drawer
  var windows: RadharcIPC.WindowsClient?
  var screenWidth: Int32 = 1280
  var slipsWindow: KitWindow?
  var drawerWindow: KitWindow?
  /// The slip deadline a sleeper waits for.
  var armed: Int64?
  var ready = false
  var said = ""

  init(model: Model, session: Session, testing: Bool) {
    self.model = model
    self.session = session
    self.testing = testing
    slips = Slips(host: nil)
    drawer = Drawer(host: nil)
    slips.host = self
    drawer.host = self
  }

  func say(_ line: String) { if testing { print("notices: " + line) } }

  // (A click is inside a frame: windows open and close at the wake.)
  func dismiss(_ id: Int) {
    model.lock.withLock { _ = model.board.dismiss(id, now: Clock.monotonic()) }
    model.wake()
  }
  func paste(_ number: Int) { say(model.paste(number) ? "pasted \(number)" : "paste \(number): refused") }
  func forget(_ number: Int) { _ = model.forget(number) }
  func clear() { model.clear() }

  /// Before each frame: the apps fed what they show.
  func update() {
    let (shown, history, clips) = model.lock.withLock { (model.board.shown, model.board.history, model.shelf.clips) }
    slips.notices = shown
    drawer.notices = history.reversed()
    drawer.clips = clips.reversed()
  }

  /// At each wake: slips gone, the windows opened or closed.
  func refresh() {
    let now = Clock.monotonic()
    let (shown, toggle, next) = model.lock.withLock {
      model.board.expire(now: now)
      defer { model.drawerAsked = false }
      return (model.board.shown, model.drawerAsked, model.board.nextExpiry)
    }
    update()
    // The next slip's life: one sleeper for it.
    if let next, armed != next {
      armed = next
      let wake = model.wake
      _ = (try? Thread.spawn {
        sleep(until: next)
        wake()
      })?.release()
    } else if next == nil {
      armed = nil
    }
    if shown.isEmpty, let w = slipsWindow {
      session.close(w)
      slipsWindow = nil
    } else if !shown.isEmpty, slipsWindow == nil {
      let width = Int32(Slips.width), margin = Int32(Theme.cqw(1.2))
      slipsWindow = try? session.open(slips, width: width, height: 60,
                                      at: (screenWidth - Int32(Theme.cqw(15)) - width - 2 * margin, margin), panel: true)
    }
    if toggle {
      if let w = drawerWindow {
        session.close(w)
        drawerWindow = nil
      } else {
        drawerWindow = try? session.open(drawer, width: Int32(Theme.cqw(28)), height: Int32(Theme.cqw(34)),
                                         at: (Int32(Theme.cqw(30)), Int32(Theme.cqw(8))))
      }
    }
    model.lock.withLock { model.drawerOpen = drawerWindow != nil }
    report()
  }

  /// `status`, and in a test each line that changed.
  func report() {
    var lines: [String] = []
    if ready { lines.append("ready") }
    let (board, shelf, feed, open) = model.lock.withLock { (model.board, model.shelf, model.feedOpen, model.drawerOpen) }
    lines.append("slips \(board.slips.count)")
    for n in board.shown { lines.append("slip \(n.id) \(n.app) \(n.lamp.rawValue) \(n.title)") }
    lines.append("waiting \(board.waiting.count)")
    lines.append("history \(board.history.count)")
    lines.append("clips \(shelf.clips.count)")
    for c in shelf.clips { lines.append("clip \(c.number) \(c.source) \(c.types.joined(separator: ","))") }
    lines.append("drawer " + (open ? "open" : "closed"))
    lines.append("clipboard " + (feed ? "open" : "none"))
    let text = lines.joined(separator: "\n") + "\n"
    if testing, text != said {
      let before = said.split(separator: "\n")
      for l in text.split(separator: "\n") where !before.contains(l) { say(String(l)) }
    }
    said = text
    let wakeups = session.wakeups
    model.lock.withLock { model.status = text + "wakeups \(wakeups)\n" }
  }

  /// After a frame: the slips' panel sized to them.
  func fit(_ w: KitWindow) {
    guard w === slipsWindow else { return }
    let h = Int32(slips.height(w.runner.ui.painter).rounded(.up))
    if Int32(w.runner.ui.height) != h,
      let me = try? windows?.entries().first(where: { $0.app == "Notices" && $0.panel })
    {
      _ = try? windows?.resize(id: me.id, width: UInt32(Slips.width), height: UInt32(max(h, 1)))
    }
  }

  func run() throws {
    guard let cch = try? ns().connect("/svc/windows/compositor"), let wch = try? ns().connect("/svc/windows/windows")
    else { throw Status.notFound }
    var compositor = RadharcIPC.CompositorClient(channel: cch)
    screenWidth = (try? compositor.screen()).map { Int32($0.width) } ?? 1280
    windows = RadharcIPC.WindowsClient(channel: wch)
    model.load()
    followClipboard(model)
    ready = true
    refresh()
  }

  func ns() -> Namespace { model.ns }
}

@main struct NoticesMain {
  @MainActor static func main() async {
    let start = Startup.current
    guard let ns = processNamespace() else { fail("no namespace") }
    let session: Session
    do { session = try Session() } catch { fail("no session: \(error)") }
    session.appName = "Notices"
    session.stayOpen = true
    let model = Model(ns: ns)
    model.wake = session.waker
    let host = NativeHost(model: model, session: session, testing: ns.getenv("NOTICES_TEST") != nil)
    // Its tree: `clients`, each client's own.
    guard let export = start.export(), let dispatcher = try? IPCDispatcher() else {
      fail("no export (its manifest's `export per-client`)")
    }
    let root = NodeTree(dispatcher: dispatcher)
    root.service("clients") { (channel: consuming Handle) throws(Status) in
      try dispatcher.add(LaunchIPC.ClientsServer(channel: channel, impl: NoticesClients(dispatcher: dispatcher, model: model)))
    }
    do throws(Status) { try root.serve(export) } catch { fail("can't serve: \(error.rawValue)") }
    _ = try? Thread.spawn { try? dispatcher.run() }.release()
    session.beforeFrame = { _ in host.update() }
    session.onWake = { host.refresh() }
    session.afterFrame = { w in
      host.fit(w)
      return false
    }
    do { try host.run() } catch { fail("can't start: \(error)") }
    await session.run()
    print("notices: ended")
    Process.exit(code: 0)
  }
}
