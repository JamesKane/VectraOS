// SPDX-License-Identifier: BSD-3-Clause

// bin/twenty: twenty windows on the shown workspace, held open until the
// launcher ends it (`kill twenty` on its ctl), so drive(1)'s `modeswitch`
// can time desktop.mode_switch (D116: tile <-> space, 20 windows) on a
// board, where workspaces-test, which revokes chords' recorded grant,
// isn't run. An app in the board's desktop image; its windows are
// workspaces-test's, `w0` to `w19`, 160 by 100, drawing nothing.

import IPC
import Node
import Radharc
import Sys

/// A window held open (its client is noncopyable; an Array holds this).
final class Held {
  var client: RadharcIPC.WindowClient
  init(_ client: consuming RadharcIPC.WindowClient) { self.client = client }
}

/// The windows, for good: a local would end at its last use, before the
/// sleep, and close them.
nonisolated(unsafe) var held: [Held] = []

@main struct Twenty {
  static func main() {
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(Startup.current) } catch {
      print("twenty: no namespace")
      Process.exit(code: 1)
    }
    guard let ch = try? ns.connect("/svc/windows/compositor") else {
      print("twenty: no /svc/windows/compositor")
      Process.exit(code: 1)
    }
    var compositor = RadharcIPC.CompositorClient(channel: ch)
    for i in 0..<20 {
      guard let opened = try? compositor.open(title: "w\(i)", width: 160, height: 100) else { continue }
      held.append(Held(RadharcIPC.WindowClient(channel: opened.takeWindow())))
    }
    print("twenty: \(held.count) windows open")
    while true { sleep(until: Clock.monotonic() + 3_600_000_000_000) }
  }
}
