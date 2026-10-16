// SPDX-License-Identifier: BSD-3-Clause

// bin/launch-test: the launcher natively (V2's item 4). bin/launcher
// starts it from its manifest (manifests/launch-test.manifest) beside
// services a and b (bin/launch-service), and exits with its code
// (launcher.until=launch-test, the boot-launch test). It reads its
// namespace from its Startup (D65), reads every /svc/*/status, reaches a
// through b, kills a through /svc/launcher/ctl and reaches its next
// instance by the same paths. It exits 0 if every check passed.

import Node
import Sys

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ name: StaticString) {
  checks += 1
  if !condition {
    failures += 1
    print("launch-test: FAILED: \(name)")
  }
}

/// A String's bytes are `text`'s.
func same(_ string: String, _ text: StaticString) -> Bool {
  unsafe string.utf8.elementsEqual(UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount))
}

/// The text at `path`, if it can be read.
func readText(_ ns: Namespace, _ path: String) -> String? {
  guard var c = try? ns.open(path) else { return nil }
  return try? c.readText()
}

/// Whether `text` has the line `line` (bytes).
func hasLine(_ text: String, _ line: StaticString) -> Bool {
  var current: [UInt8] = []
  for b in text.utf8 {
    if b == 0x0A {
      if same(String(decoding: current, as: UTF8.self), line) { return true }
      current = []
    } else {
      current.append(b)
    }
  }
  return false
}

@main struct LaunchTest {
  static func main() {
    let start = Startup.current
    let ns: Namespace
    do throws(NamespaceError) {
      ns = try Namespace(start)
    } catch {
      print("launch-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    check(ns.mountPoints.count == 1 && same(ns.mountPoints[0], "/svc"), "the namespace is /svc alone")

    // cat /svc/*/status
    let names = ((try? ns.list("/svc")) ?? []).map { $0.name }
    check(names.count == 3 && names.contains { same($0, "a") } && names.contains { same($0, "b") }
            && names.contains { same($0, "launcher") }, "/svc holds what the manifest uses")
    for name in names {
      let status = readText(ns, "/svc/" + name + "/status")
      check(status != nil, "each /svc/*/status reads")
      if let status { print("launch-test: /svc/\(name)/status: \(status)") }
    }
    check(readText(ns, "/svc/a/status").map { same($0, "a first\n") } ?? false, "a's status")
    check(readText(ns, "/svc/b/peer").map { same($0, "a first\n") } ?? false, "b reaches a through its own /svc")
    let status = readText(ns, "/svc/launcher/status") ?? ""
    check(hasLine(status, "a running restarts 0") && hasLine(status, "b running restarts 0")
            && hasLine(status, "launch-test running restarts 0"), "the launcher's status")

    // A crash, as the launcher's ctl makes one: a restarts (`restart always`).
    if var ctl = try? ns.open("/svc/launcher/ctl") {
      check((try? ctl.writeText("kill a")) != nil, "ctl kills a")
    } else {
      check(false, "ctl kills a")
    }
    var restarted = false
    let deadline = Clock.monotonic() + 5_000_000_000
    while !restarted && Clock.monotonic() < deadline {
      restarted = hasLine(readText(ns, "/svc/launcher/status") ?? "", "a running restarts 1")
      if !restarted { sleep(until: Clock.monotonic() + 10_000_000) }
    }
    check(restarted, "a restarted")
    check(readText(ns, "/svc/a/status").map { same($0, "a first\n") } ?? false, "the new a, by the same path")
    check(readText(ns, "/svc/b/peer").map { same($0, "a first\n") } ?? false, "and through b")

    print("launch-test: \(checks - failures) of \(checks) checks passed")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
