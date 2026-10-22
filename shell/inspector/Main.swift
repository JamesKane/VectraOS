// SPDX-License-Identifier: BSD-3-Clause

// bin/inspector (inspector(4), D115): the Inspector on croi, an app in
// Deskbar's menu (its manifest's `app Inspector`). A thread reads /proc
// (proc(4): each process's status line) once a second while someone is at
// the desktop and hands the lines to the window. While nobody is
// (Radharc's `idle`, D114), it waits on a counter the idle file's thread
// rings, so an empty desk wakes it for nothing.
//
// Its tree's `status` says what it shows, for its boot test: `ready`,
// `processes N`, `reads N`, `desktop idle` or `active`, a line a process
// (`process PID NAME`), and `wakeups N`, its loop's. With INSPECTOR_TEST
// in its environment it logs `processes` and `desktop` as they change.

import IPC
import InspectorApp
import Kit
import KitPlatform
import Node
import Synchronization
import Sys
import VX
import VectraOSLibc

func fail(_ what: String) -> Never {
  print("inspector: FAILED: \(what)")
  Process.exit(code: 1)
}

/// What the threads bring the main thread, and what `status` says.
final class Inbox: Sendable {
  let lines = Mutex<([ProcLine], Int64)?>(nil)
  let idle = Mutex<Bool?>(nil)
  let status = Mutex("")
}

/// Every process's status line under /proc.
func readProc(_ ns: Namespace) -> [ProcLine] {
  guard let entries = try? ns.list("/proc") else { return [] }
  var out: [ProcLine] = []
  for e in entries {
    guard let pid = UInt64(e.name), var f = try? ns.open("/proc/\(pid)/status"), let text = try? f.readText(),
      let p = ProcLine.parse(pid: pid, text)
    else { continue }
    out.append(p)
  }
  return out
}

@main struct InspectorMain {
  @MainActor static func main() async {
    let start = Startup.current
    guard let ns = processNamespace() else { fail("no namespace") }
    let testing = ns.getenv("INSPECTOR_TEST") != nil
    let inbox = Inbox()
    if let export = start.export(), let dispatcher = try? IPCDispatcher() {
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { inbox.status.withLock { $0 } })
      if (try? tree.serve(export)) != nil { _ = try? Thread.spawn { try? dispatcher.run() }.release() }
    }
    guard (try? ns.list("/proc")) != nil else { fail("no /proc (its manifest's `mount /proc proc`)") }
    guard let bell = try? Counter.create(), let bellCopy = try? bell.duplicate() else { fail("no counter") }
    let session: Session
    do { session = try Session() } catch { fail("no session: \(error)") }
    session.appName = "Inspector"
    let app = Inspector()
    app.onQuit = { session.stop() }
    do { _ = try session.open(app, width: 640, height: 420) } catch { fail("no window: \(error)") }
    let wake = session.waker
    // Whether someone is at the desktop: each change rings the reader's bell.
    let idle = Atomic(false)
    if let f = try? ns.open("/svc/windows/idle") {
      let raw = f.takeChannel().release(), bellRaw = bellCopy.release()
      _ = try? Thread.spawn {
        var file = NodeIPC.NodeClient(channel: Handle(raw: raw))
        let bell = Handle(raw: bellRaw)
        while let bytes = try? file.read(offset: 0, max: 64), !bytes.isEmpty {
          let now = bytes.starts(with: Array("idle".utf8))
          idle.store(now, ordering: .sequentiallyConsistent)
          try? Counter.add(bell, 1)
          inbox.idle.withLock { $0 = now }
          wake()
        }
      }.release()
    }
    // /proc, once a second while someone is there.
    let bellRaw = bell.release()
    _ = try? Thread.spawn {
      let bell = Handle(raw: bellRaw)
      var seen = (try? Counter.read(bell)) ?? 0
      while true {
        if idle.load(ordering: .sequentiallyConsistent) {
          try? Counter.wait(bell, until: seen + 1)
        } else {
          inbox.lines.withLock { $0 = (readProc(ns), Clock.monotonic()) }
          wake()
          try? Counter.wait(bell, until: seen + 1, deadline: Clock.monotonic() + 1_000_000_000)
        }
        seen = (try? Counter.read(bell)) ?? seen
      }
    }.release()
    var ready = false, reads = 0, desktopIdle = false
    var said = ""
    func report() {
      var lines: [String] = []
      if ready { lines.append("ready") }
      lines.append("processes \(app.processes.count)")
      lines.append("desktop " + (desktopIdle ? "idle" : "active"))
      let logged = lines.joined(separator: "\n")
      if testing, logged != said {
        let before = said.split(separator: "\n")
        for l in logged.split(separator: "\n") where !before.contains(l) { print("inspector: " + l) }
      }
      said = logged
      lines.append("reads \(reads)")
      for p in app.processes { lines.append("process \(p.pid) \(p.name)") }
      let wakeups = session.wakeups
      inbox.status.withLock { $0 = lines.joined(separator: "\n") + "\nwakeups \(wakeups)\n" }
    }
    session.beforeFrame = { _ in
      if let i = inbox.idle.withLock({ i in defer { i = nil }; return i }) {
        desktopIdle = i
        app.paused = i
      }
      if let (lines, at) = inbox.lines.withLock({ x in defer { x = nil }; return x }) {
        app.update(lines, at: at)
        reads += 1
      }
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
