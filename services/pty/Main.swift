// SPDX-License-Identifier: BSD-3-Clause

// bin/pty (todhchai's M6j part 2b, on rings: D46): the pty service. Its
// tree: `status`, and `pty` (PtyIPC.Factory: a terminal opens a pty
// there). The ptys, their line disciplines and their rings are
// services/pty/lib's.

import IPC
import Node
import Sys

func fail(_ what: String) -> Never {
  print("pty: \(what)")
  Process.exit(code: 2)
}

@main struct PtyMain {
  static func main() {
    let start = Startup.current
    do throws(Status) {
      let dispatcher = try IPCDispatcher()
      let tree = NodeTree(dispatcher: dispatcher)
      tree.text("status", read: { "serving\n" })
      tree.service("pty") { (channel: consuming Handle) throws(Status) in try PtyService.serve(channel, on: dispatcher) }
      guard let export = start.export() else { fail("no export (its manifest's `export`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      fail("can't serve")
    }
  }
}
