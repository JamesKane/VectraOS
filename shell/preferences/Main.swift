// SPDX-License-Identifier: BSD-3-Clause

// bin/preferences (preferences(4), D115): a preference app on croi, one
// program for every area (as Be had them): PREFS_AREA names it
// (Appearance, Keyboard, Mouse, Deskbar or Grants), its manifest making it
// an app of Deskbar's Preferences submenu. Its settings are the volume's
// (/data/Settings/AREA); a thread waits on the folder's watch and reloads
// it when another changes them (rc's `attr`), so it wakes for nothing
// else.
//
// Its tree's `status` says what it shows: `area NAME`, a line a setting
// (`NAME VALUE`) or a recorded grant (`grant APP.SERVICE allowed|refused`),
// `ready` once drawn, and `wakeups N`, its loop's. With PREFS_TEST in its
// environment it starts from the area's defaults and logs each change.

import IPC
import Kit
import KitPlatform
import Node
import PreferencesApp
import Settings
import Synchronization
import Sys
import VX
import VectraOSLibc

func fail(_ what: String) -> Never {
  print("preferences: FAILED: \(what)")
  Process.exit(code: 1)
}

@MainActor final class VolumeStore: SettingsStore {
  let ns: Namespace
  let testing: Bool
  init(ns: Namespace, testing: Bool) {
    self.ns = ns
    self.testing = testing
  }
  func value(_ s: Setting) -> SettingValue { Settings.value(s, ns) }
  func set(_ s: Setting, _ v: SettingValue) { _ = Settings.set(s, v, ns) }
  func grants() -> [Grants.Entry] { Grants.list(ns) }
  func revoke(_ g: Grants.Entry) {
    let done = Grants.revoke(g.app, g.service, ns)
    if testing { print("preferences: revoke \(g.app).\(g.service) " + (done ? "done" : "refused")) }
  }
}

/// What the watch's thread brings the main thread, and what `status` says.
final class Inbox: Sendable {
  let changed = Mutex(false)
  let status = Mutex("")
}

func text(_ v: SettingValue) -> String {
  switch v {
  case .int(let n): return "\(n)"
  case .bool(let b): return b ? "true" : "false"
  case .string(let t): return t
  }
}

@main struct PreferencesMain {
  @MainActor static func main() async {
    let start = Startup.current
    guard let ns = processNamespace() else { fail("no namespace") }
    let area = ns.getenv("PREFS_AREA") ?? "Keyboard"
    guard Settings.areas.contains(area) || area == Grants.area else { fail("no area \(area)") }
    let testing = ns.getenv("PREFS_TEST") != nil
    // A test starts from the defaults (the volume keeps what a run left).
    if testing { for s in Settings.all where s.area == area { _ = Settings.set(s, s.fallback, ns) } }
    let inbox = Inbox()
    if let export = start.export(), let dispatcher = try? IPCDispatcher() {
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { inbox.status.withLock { $0 } })
      if (try? tree.serve(export)) != nil { _ = try? Thread.spawn { try? dispatcher.run() }.release() }
    }
    let session: Session
    do { session = try Session() } catch { fail("no session: \(error)") }
    session.appName = area
    let app = PreferenceApp(area: area, store: VolumeStore(ns: ns, testing: testing))
    app.onClose = { session.stop() }
    let rows = Float(app.isGrants ? max(app.grants.count, 4) : app.settings.count)
    let height = Int32(Theme.cqw(2) + rows * Theme.cqw(3.2) + Theme.cqw(6))
    do {
      _ = try session.open(app, width: 420, height: height, at: testing ? (300, 200) : nil)
    } catch {
      fail("no window: \(error)")
    }
    // Another's changes: read again.
    if let watch = Settings.watch(ns) {
      let raw = watch.takeChannel().release()
      let wake = session.waker
      _ = try? Thread.spawn {
        var w = NodeIPC.NodeClient(channel: Handle(raw: raw))
        while let e = try? w.nextEvent() {
          guard case .changed(let c) = e, Settings.touches(c, area) else { continue }
          inbox.changed.withLock { $0 = true }
          wake()
        }
      }.release()
    }
    var ready = false
    var said = ""
    func report() {
      var lines = ["area " + area]
      if ready { lines.append("ready") }
      for (s, v) in zip(app.settings, app.values) { lines.append(s.name + " " + text(v)) }
      for g in app.grants { lines.append("grant \(g.app).\(g.service) " + (g.allowed ? "allowed" : "refused")) }
      let now = lines.joined(separator: "\n") + "\n"
      if testing, now != said {
        let before = said.split(separator: "\n")
        for l in now.split(separator: "\n") where !before.contains(l) { print("preferences: " + l) }
      }
      said = now
      let wakeups = session.wakeups
      inbox.status.withLock { $0 = now + "wakeups \(wakeups)\n" }
    }
    session.beforeFrame = { _ in
      if inbox.changed.withLock({ c in defer { c = false }; return c }) { app.reload() }
    }
    session.afterFrame = { _ in
      ready = true
      report()
      return false
    }
    session.onWake = { report() }
    await session.run()
    Process.exit(code: 0)
  }
}
