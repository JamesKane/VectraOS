// SPDX-License-Identifier: BSD-3-Clause

// A native test program's checks, compiled into each that boots on the
// desktop (kernel/CMakeLists.txt, cmake/Tier1.cmake): each check a line
// after the program's name, `ok:` or `FAILED:`, which the boot's log
// keeps; the program counts the second and exits with it.

import Sys

nonisolated(unsafe) var failures = 0

/// The program's name, as the launcher started it: its first argument's
/// last element (bytes: tier 0 has no grapheme tables).
let program: String = {
  let path = Array((Startup.current.args.first ?? "test").utf8)
  return String(decoding: path[(path.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 } ?? 0)...], as: UTF8.self)
}()

func check(_ ok: Bool, _ what: String) {
  print(ok ? "\(program): ok: \(what)" : "\(program): FAILED: \(what)")
  if !ok { failures += 1 }
}

/// Until `ok`, or `seconds`: whether it came, looked at every 50 ms.
func within(_ seconds: Int, _ ok: () -> Bool) -> Bool {
  let end = Clock.monotonic() + Int64(seconds) * 1_000_000_000
  while Clock.monotonic() < end {
    if ok() { return true }
    sleep(until: Clock.monotonic() + 50_000_000)
  }
  return ok()
}
