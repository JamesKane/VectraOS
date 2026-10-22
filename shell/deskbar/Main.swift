// SPDX-License-Identifier: BSD-3-Clause

// bin/deskbar (deskbar(4), D114): Deskbar on croi, in full Swift, a panel
// at the screen's top right sized to what it shows. It wakes only when
// something it shows changes: each of its threads waits in one read or
// event, for Radharc's window list (`windows`: each change, then its
// entries), whether someone is at the desktop (`/svc/windows/idle`), the
// CPU gauge (`/proc/cpu`, open only while someone is, so proc samples
// nothing for an empty desk), the pacing gauge (`/svc/windows/pacing`),
// and Deskbar's settings (a watch on /data/Settings). The launcher's apps
// are read again with each change of the list (/svc/launcher/apps) and
// started through its `ctl`; a window is raised, hidden, shown or closed
// through `windows`. Radharc draws the clock in the place the panel leaves
// for it, so no thread here wakes for the time.
//
// Its tree's `status` says what it shows, for its boot test: `ready`,
// `clock X Y W H`, `apps N`, `running NAME N` an app, `desktop idle` or
// `active`, `cpu open` or `closed`, the gauges' readings, and `wakeups N`,
// its loop's. With DESKBAR_TEST in its environment it logs each change.

import DeskbarApp
import IPC
import Kit
import KitPlatform
import Node
import Radharc
import Settings
import Synchronization
import Sys
import UICore
import VX
import VectraOSLibc

func fail(_ what: String) -> Never {
  print("deskbar: FAILED: \(what)")
  Process.exit(code: 1)
}

/// What the threads bring the main thread.
final class Inbox: Sendable {
  let list = Mutex<[WindowItem]?>(nil)
  let spaces = Mutex<[WorkspaceItem]?>(nil)
  let cpu = Mutex<String?>(nil)
  let pacing = Mutex<String?>(nil)
  let idle = Mutex<Bool?>(nil)
  let settings = Mutex(false)
  /// What `status` says, made by the main thread.
  let status = Mutex("")
}

/// Reads a file answered on change (D114) for good on a thread of its own,
/// giving each answer to `body`; ends when the file does.
func follow(_ ns: Namespace, _ path: String, _ body: @escaping @Sendable (String) -> Void) -> Bool {
  guard var f = try? ns.open(path) else { return false }
  let raw = f.takeChannel().release()
  return (try? Thread.spawn {
    var file = NodeIPC.NodeClient(channel: Handle(raw: raw))
    while let bytes = try? file.read(offset: 0, max: 256), !bytes.isEmpty {
      body(String(decoding: bytes, as: UTF8.self))
    }
  })?.release() != nil
}

/// /proc/cpu, open only while someone is at the desktop and the gauges are
/// on (D114). It is opened and closed here; a thread of its own reads it
/// while it is open, and never closes it: closing it here ends that read.
final class CPUFile: @unchecked Sendable {
  let ns: Namespace
  let deliver: @Sendable (String) -> Void
  let lock = Lock()
  var raw: UInt32 = 0
  var active = false
  var on = true

  init(_ ns: Namespace, deliver: @escaping @Sendable (String) -> Void) {
    self.ns = ns
    self.deliver = deliver
  }

  var isOpen: Bool { lock.withLock { raw != 0 } }

  func set(active a: Bool? = nil, on o: Bool? = nil) {
    lock.withLock {
      if let a { active = a }
      if let o { on = o }
      let want = active && on
      if !want, raw != 0 {
        _ = Handle(raw: raw)  // closed: its reader's wait ends
        raw = 0
      } else if want, raw == 0, var f = try? ns.open("/proc/cpu") {
        let r = f.takeChannel().release()
        raw = r
        let deliver = deliver
        _ = (try? Thread.spawn {
          var file = NodeIPC.NodeClient(channel: Handle(raw: r))
          while let bytes = try? file.read(offset: 0, max: 64), !bytes.isEmpty {
            deliver(String(decoding: bytes, as: UTF8.self))
          }
          _ = file.takeChannel().release()  // ours to close, not the reader's
        })?.release()
      }
    }
  }
}

@MainActor final class NativeHost: DeskbarHost {
  let ns: Namespace
  let session: Session
  let bar: Deskbar
  let testing: Bool
  let inbox = Inbox()
  var windows: RadharcIPC.WindowsClient?
  var panel: KitWindow?
  var cpuFile: CPUFile?
  /// Deskbar's settings: the clock's hours, the gauges.
  var clock24 = true
  var showGauges = true
  var cpuText = "", pacingText = ""
  var idle = false
  var clockAt: (x: Int32, y: Int32, width: Int32, height: Int32)?
  var ready = false
  var said = ""

  init(ns: Namespace, session: Session, testing: Bool) {
    self.ns = ns
    self.session = session
    self.testing = testing
    bar = Deskbar(host: nil)
    bar.host = self
  }

  func say(_ line: String) { if testing { print("deskbar: " + line) } }

  func start(_ service: String) {
    guard var ctl = try? ns.open("/svc/launcher/ctl"), (try? ctl.writeText("start \(service)")) != nil else {
      say("start \(service): refused")
      return
    }
    Recent.note(Recent.apps, service, ns)
    say("started \(service)")
  }

  /// Tracker's Find: a query window, through the plumber (its `find`).
  func find() {
    let routed = (try? session.route(Route(type: "tracker/find", data: "find"))) != nil
    say(routed ? "find" : "find: nothing listens")
  }

  /// A recent item opened: a document routed by its type, a folder to
  /// Tracker (the plumber's folder rule), an app started.
  func open(recent item: String, kind: RecentKind) {
    switch kind {
    case .apps:
      start(item)
    case .folders:
      _ = try? session.route(Route(wdir: item, type: "text", data: item))
    case .documents:
      let f = item.split(separator: "\t", maxSplits: 1).map(String.init)
      guard f.count == 2 else { return }
      let folder = f[1].split(separator: "/").dropLast().joined(separator: "/")
      _ = try? session.route(Route(wdir: "/" + folder, type: f[0], data: f[1]))
    }
    say("recent \(kind.rawValue) \(item)")
  }

  func top(_ window: UInt32) { _ = try? windows?.top(id: window) }
  func hide(_ window: UInt32) { _ = try? windows?.hide(id: window) }
  func show(_ window: UInt32) { _ = try? windows?.show(id: window) }
  func close(_ window: UInt32) { _ = try? windows?.close(id: window) }
  func workspace(_ n: Int) { _ = try? windows?.workspace(UInt32(n)) }

  /// The drawer, notices' (D117), where the image has notices.
  func drawer() {
    guard var ctl = try? ns.open("/svc/notices/ctl"), (try? ctl.writeText("drawer")) != nil else {
      say("drawer: no notices")
      return
    }
    say("drawer")
  }

  func readApps() {
    guard var f = try? ns.open("/svc/launcher/apps"), let text = try? f.readText() else { return }
    bar.apps = AppEntry.parse(text)
  }

  func readSettings() {
    clock24 = Settings.value(Settings.clock24, ns).bool ?? true
    showGauges = Settings.value(Settings.gauges, ns).bool ?? true
    cpuFile?.set(on: showGauges)
    clockAt = nil  // given to Radharc again, with its hours
    say("settings clock \(clock24 ? 24 : 12) gauges \(showGauges ? "on" : "off")")
  }

  /// The Recent lists, read when the menu opens.
  var recentRead = false
  func readRecent() {
    bar.recent = [.documents: Recent.list(Recent.documents, ns), .folders: Recent.list(Recent.folders, ns),
                  .apps: Recent.list(Recent.apps, ns)]
  }

  nonisolated static func items(_ spaces: [RadharcIPC.WorkspaceInfo]) -> [WorkspaceItem] {
    spaces.map { WorkspaceItem(number: Int($0.number), tiled: $0.mode == .tile, current: $0.current) }
  }

  nonisolated static func items(_ entries: [RadharcIPC.WindowEntry], hidden: [UInt32]) -> [WindowItem] {
    entries.map {
      WindowItem(id: $0.id, title: $0.title, app: $0.app, focused: $0.focused, furniture: $0.desktop || $0.panel,
                 desktop: $0.desktop, hidden: hidden.contains($0.id))
    }
  }

  /// Before each frame: what the threads brought.
  func refresh() {
    if bar.open == .apps {
      if !recentRead { readRecent() }
      recentRead = true
    } else if bar.open == nil {
      recentRead = false
    }
    if let l = inbox.list.withLock({ l in defer { l = nil }; return l }) {
      bar.update(l)
      readApps()
    }
    if let s = inbox.spaces.withLock({ s in defer { s = nil }; return s }) { bar.workspaces = s }
    if inbox.settings.withLock({ c in defer { c = false }; return c }) { readSettings() }
    if let t = inbox.cpu.withLock({ t in defer { t = nil }; return t }) { cpuText = t }
    if let t = inbox.pacing.withLock({ t in defer { t = nil }; return t }) { pacingText = t }
    if let i = inbox.idle.withLock({ i in defer { i = nil }; return i }) { idle = i }
    bar.gauges = showGauges ? [Gauges.cpu(cpuText), Gauges.pacing(pacingText)] : []
    report()
  }

  /// `status`, and in a test each line that changed.
  func report() {
    var lines: [String] = []
    if ready { lines.append("ready") }
    if let c = clockAt { lines.append("clock \(c.x) \(c.y) \(c.width) \(c.height) \(clock24 ? 24 : 12)") }
    lines.append("apps \(bar.apps.count)")
    if !bar.workspaces.isEmpty {
      lines.append("workspaces " + bar.workspaces.map { ($0.tiled ? "T" : "S") + ($0.current ? "*" : "") }.joined(separator: " "))
    }
    for a in bar.running { lines.append("running \(a.name) \(a.windows.count)") }
    lines.append("desktop " + (idle ? "idle" : "active"))
    lines.append("gauges " + (showGauges ? "on" : "off"))
    lines.append("cpu " + (cpuFile?.isOpen == true ? "open" : "closed"))
    for g in bar.gauges { lines.append("gauge \(g.name) \(g.reading)") }
    let text = lines.joined(separator: "\n") + "\n"
    if testing, text != said {
      let before = said.split(separator: "\n")
      for l in text.split(separator: "\n") where !before.contains(l) { say(String(l)) }
    }
    said = text
    let wakeups = session.wakeups
    inbox.status.withLock { $0 = text + "wakeups \(wakeups)\n" }
  }

  /// After a frame: the panel sized to what it shows, and the clock's
  /// place given to Radharc.
  func fit(_ w: KitWindow) {
    guard w === panel else { return }
    let h = Int32(bar.height(w.runner.ui.painter).rounded(.up))
    if Int32(w.runner.ui.height) != h, let me = try? windows?.entries().first(where: { $0.app == "Deskbar" && $0.panel }) {
      _ = try? windows?.resize(id: me.id, width: UInt32(Theme.cqw(15)), height: UInt32(h))
    }
    if let n = w.runner.ui.access.first(where: { $0.label == "Clock" }) {
      let at = (x: Int32(n.x.rounded()), y: Int32(n.y.rounded()), width: Int32(n.width.rounded()),
                height: Int32(n.height.rounded()))
      if clockAt.map({ $0 != at }) ?? true {
        clockAt = at
        session.showClock(w, x: at.x, y: at.y, width: at.width, height: at.height, hours24: clock24)
      }
    }
    if !ready {
      ready = true
      report()
    }
  }

  func run() throws {
    guard let cch = try? ns.connect("/svc/windows/compositor"), let wch = try? ns.connect("/svc/windows/windows"),
      let feed = try? ns.connect("/svc/windows/windows")
    else { throw Status.notFound }
    var compositor = RadharcIPC.CompositorClient(channel: cch)
    let screenWidth = (try? compositor.screen()).map { Int32($0.width) } ?? 1280
    windows = RadharcIPC.WindowsClient(channel: wch)
    readApps()
    let width = Int32(Theme.cqw(15)), margin = Int32(Theme.cqw(1.2))
    panel = try session.open(bar, width: width, height: 80, at: (screenWidth - width - margin, margin), panel: true)
    let wake = session.waker, inbox = self.inbox
    // The window list, as it changes.
    let feedRaw = feed.release()
    _ = try Thread.spawn {
      var w = RadharcIPC.WindowsClient(channel: Handle(raw: feedRaw))
      if let e = try? w.entries() { inbox.list.withLock { $0 = NativeHost.items(e, hidden: (try? w.hidden()) ?? []) } }
      if let s = try? w.workspaces() { inbox.spaces.withLock { $0 = NativeHost.items(s) } }
      wake()
      while let event = try? w.nextEvent() {
        guard case .changed = event, let e = try? w.entries() else { continue }
        let hidden = (try? w.hidden()) ?? []
        inbox.list.withLock { $0 = NativeHost.items(e, hidden: hidden) }
        if let s = try? w.workspaces() { inbox.spaces.withLock { $0 = NativeHost.items(s) } }
        wake()
      }
    }.release()
    // The gauges: the CPU's while someone is at the desktop, the pacing's.
    let cpu = CPUFile(ns) { text in
      inbox.cpu.withLock { $0 = text }
      wake()
    }
    cpuFile = cpu
    _ = follow(ns, "/svc/windows/idle") { text in
      let idle = text.hasPrefix("idle")
      cpu.set(active: !idle)
      inbox.idle.withLock { $0 = idle }
      wake()
    }
    _ = follow(ns, "/svc/windows/pacing") { text in
      inbox.pacing.withLock { $0 = text }
      wake()
    }
    // Deskbar's settings, at start and as they change.
    readSettings()
    if let watch = Settings.watch(ns) {
      let raw = watch.takeChannel().release()
      _ = try Thread.spawn {
        var w = NodeIPC.NodeClient(channel: Handle(raw: raw))
        while let e = try? w.nextEvent() {
          guard case .changed(let c) = e, Settings.touches(c, "Deskbar") else { continue }
          inbox.settings.withLock { $0 = true }
          wake()
        }
      }.release()
    }
  }
}

@main struct DeskbarMain {
  @MainActor static func main() async {
    let start = Startup.current
    guard let ns = processNamespace() else { fail("no namespace") }
    let session: Session
    do { session = try Session() } catch { fail("no session: \(error)") }
    session.appName = "Deskbar"
    let host = NativeHost(ns: ns, session: session, testing: ns.getenv("DESKBAR_TEST") != nil)
    // Its tree: `status`, for its test and for rc.
    if let export = start.export(), let dispatcher = try? IPCDispatcher() {
      let tree = NodeTree(dispatcher: dispatcher)
      let inbox = host.inbox
      tree.text("status", read: { inbox.status.withLock { $0 } })
      if (try? tree.serve(export)) != nil { _ = try? Thread.spawn { try? dispatcher.run() }.release() }
    }
    session.beforeFrame = { _ in host.refresh() }
    // (A wake that draws nothing still counts in `status`.)
    session.onWake = { host.report() }
    session.afterFrame = { w in
      host.fit(w)
      return false
    }
    do { try host.run() } catch { fail("can't start: \(error)") }
    await session.run()
    print("deskbar: ended")
    Process.exit(code: 0)
  }
}
