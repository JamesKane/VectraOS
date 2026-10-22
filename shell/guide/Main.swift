// SPDX-License-Identifier: BSD-3-Clause

// bin/guide (guide(4)): the manual as hypertext, a Kit app. It reads every
// page under /lib/man once, opens its window at the Contents, and listens
// on the plumber's `man` port: `name(N)` plumbed from anywhere opens that
// page (the plumber's rule). Its tree's `status` says where it is (`place
// contents`, `place index` or `page NAME(N)`, `history N`, `pages N`, and
// `port man` once it listens), and `ctl`
// moves it as its buttons do: `go NAME(N)`, `contents`, `index`, `retrace`,
// `next`, `previous`.

import Guide
import GuideApp
import GuideViewer
import IPC
import Kit
import KitPlatform
import Radharc
import Node
import Synchronization
import Sys
import VX
import VectraOSLibc

func fail(_ what: String) -> Never {
  print("guide: FAILED: \(what)")
  Process.exit(code: 1)
}

/// What the tree's thread brings the main one, and what it reads back.
final class Inbox: Sendable {
  let commands = Mutex<[String]>([])
  let status = Mutex("")
}

@MainActor final class NativeHost: GuideHost {
  let ns: Namespace
  init(ns: Namespace) { self.ns = ns }
  func read(_ entry: ManualEntry) -> [UInt8]? {
    guard var f = try? ns.open("/lib/man/" + entry.path) else { return nil }
    return try? f.readAll()
  }

  /// Every page's bytes, as `section/name` paths.
  func pages() -> [(path: String, bytes: [UInt8])] {
    var out: [(path: String, bytes: [UInt8])] = []
    for s in 1...8 {
      for e in (try? ns.list("/lib/man/\(s)")) ?? [] {
        if var f = try? ns.open("/lib/man/\(s)/\(e.name)"), let b = try? f.readAll() { out.append(("\(s)/\(e.name)", b)) }
      }
    }
    return out
  }
}

@main struct GuideMain {
  @MainActor static func main() async {
    let start = Startup.current
    guard let ns = processNamespace() else { fail("no namespace") }
    let session: Session
    do { session = try Session() } catch { fail("no session: \(error)") }
    session.appName = "Guide"
    let host = NativeHost(ns: ns)
    let app = GuideApp(library: ManualLibrary(pages: host.pages()), host: host)
    let inbox = Inbox()
    func report() {
      var lines: [String] = []
      switch app.viewer.place {
      case .contents: lines.append("place contents")
      case .index: lines.append("place index")
      case .page(let e): lines.append("page \(e.title)")
      }
      lines.append("history \(app.viewer.history.count)")
      lines.append("pages \(app.library.entries.count)")
      lines.append(listening ? "port man" : "no port")
      inbox.status.withLock { $0 = lines.joined(separator: "\n") + "\n" }
    }
    func command(_ text: String) {
      let w = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
      switch (w.first, w.count) {
      case ("go", 2): if let l = ManualLinks.parse(w[1]) { app.follow(l.name, section: l.section) }
      case ("contents", 1): app.viewer.go(.contents)
      case ("index", 1): app.viewer.go(.index)
      case ("retrace", 1): app.viewer.retrace()
      case ("next", 1): app.viewer.browse(forward: true, in: app.library)
      case ("previous", 1): app.viewer.browse(forward: false, in: app.library)
      default: print("guide: ctl: \(text)")
      }
    }
    if let export = start.export(), let dispatcher = try? IPCDispatcher() {
      let tree = NodeTree(dispatcher: dispatcher)
      let wake = session.waker
      tree.text("status", read: { inbox.status.withLock { $0 } })
      tree.text("ctl", read: { "" }, write: { (text: String) throws(NodeError) in
        inbox.commands.withLock { $0.append(text) }
        wake()
      })
      if (try? tree.serve(export)) != nil { _ = try? Thread.spawn { try? dispatcher.run() }.release() }
    }
    // `name(N)` plumbed: that page.
    let listening = (try? session.listen(port: "man")) != nil
    session.onRouted = { _, m in
      if let l = ManualLinks.parse(m.data) { app.follow(l.name, section: l.section) }
      report()
    }
    session.onWake = {
      for c in inbox.commands.withLock({ c in defer { c = [] }; return c }) { command(c) }
      report()
    }
    session.beforeFrame = { _ in report() }
    // As big as it reads well, but no bigger than the screen.
    var size = (width: Int32(760), height: Int32(640))
    if let ch = try? ns.connect("/svc/windows/compositor") {
      var compositor = RadharcIPC.CompositorClient(channel: ch)
      if let screen = try? compositor.screen() {
        size = (min(size.width, Int32(screen.width) - 40), min(size.height, Int32(screen.height) - 80))
      }
    }
    do { try session.open(app, width: size.width, height: size.height) } catch { fail("no window: \(error)") }
    report()
    await session.run()
    Process.exit(code: 0)
  }
}
