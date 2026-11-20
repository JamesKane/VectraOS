// SPDX-License-Identifier: BSD-3-Clause

// bin/wedge: a process that never ends, to wedge a run on purpose and see
// the kernel's stuck report (croi.watchdog_limit=) name its waiters: the
// process "wedge", whose thread "wedge-port" waits on a port that nothing
// queues to, with no timeout, while its main thread waits for that thread
// to end. It prints a line once both are waiting.

import Sys

@main struct Wedge {
  static func main() {
    do throws(Status) {
      let me = try Process.current()
      try me.setName("wedge")
      let port = try Port.create()
      let waiter = try Thread.spawn {
        do throws(Status) { _ = try Port.wait(port) } catch {}
      }
      try waiter.setName("wedge-port")
      sleep(until: Clock.monotonic() + 200_000_000)
      print("wedge: waiting for nothing")
      try Thread.join(waiter)
    } catch {
      print("wedge: FAILED: \(error.rawValue)")
      Process.exit(code: 1)
    }
  }
}
