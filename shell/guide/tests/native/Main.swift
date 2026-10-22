// SPDX-License-Identifier: BSD-3-Clause

// guide-test (boot-guide): the manual as hypertext on the desktop.
// guide reads the manual and shows its Contents;
// `rc(1)` plumbed opens that page (the plumber's `man` rule); Browse goes
// to the next page of section 1, Retrace comes back, the Index shows, and
// `ctl`'s `go` follows a link.

import IPC
import Node
import Sys

nonisolated(unsafe) var failures = 0

func check(_ ok: Bool, _ what: String) {
  print(ok ? "guide-test: ok: \(what)" : "guide-test: FAILED: \(what)")
  if !ok { failures += 1 }
}

func within(_ seconds: Int, _ ok: () -> Bool) -> Bool {
  let end = Clock.monotonic() + Int64(seconds) * 1_000_000_000
  while Clock.monotonic() < end {
    if ok() { return true }
    sleep(until: Clock.monotonic() + 50_000_000)
  }
  return ok()
}

func lines(_ ns: Namespace, _ path: String) -> [[UInt8]] {
  guard var f = try? ns.open(path), let b = try? f.readAll() else { return [] }
  return b.split(separator: 0x0A).map(Array.init)
}

func says(_ ns: Namespace, _ line: String) -> Bool {
  lines(ns, "/svc/guide/status").contains { $0.elementsEqual(line.utf8) }
}

func line(_ ns: Namespace, _ word: String) -> [UInt8]? {
  lines(ns, "/svc/guide/status").first { $0.starts(with: Array((word + " ").utf8)) }
}

func write(_ ns: Namespace, _ path: String, _ bytes: [UInt8]) -> Bool {
  guard var f = try? ns.open(path) else { return false }
  return (try? f.write(offset: 0, bytes)) != nil
}

@main struct GuideTest {
  static func main() {
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(Startup.current) } catch {
      print("guide-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    check(within(60) { says(ns, "place contents") && says(ns, "port man") }, "guide shows the Contents, listening on man")
    let pages = line(ns, "pages").map { String(decoding: $0.dropFirst(6), as: UTF8.self) } ?? "0"
    check((Int(pages) ?? 0) > 100, "it has read the manual (\(pages) pages)")

    // rc(1) plumbed from anywhere: its page.
    let data = "rc(1)"
    let message = Array("guide-test\n\n/\ntext\n\n\(data.utf8.count)\n\(data)".utf8)
    check(write(ns, "/mnt/plumb/send", message), "rc(1) is plumbed")
    check(within(10) { says(ns, "page rc(1)") }, "guide opens rc(1)")

    // Browse, Retrace, the Index, a link followed.
    check(write(ns, "/svc/guide/ctl", Array("next".utf8)), "Browse ▶")
    check(within(10) { !says(ns, "page rc(1)") && line(ns, "page").map { $0.last == UInt8(ascii: ")") } ?? false },
          "the next page of section 1")
    check(write(ns, "/svc/guide/ctl", Array("retrace".utf8)) && within(10) { says(ns, "page rc(1)") }, "Retrace: rc(1) again")
    check(write(ns, "/svc/guide/ctl", Array("index".utf8)) && within(10) { says(ns, "place index") }, "the Index")
    check(write(ns, "/svc/guide/ctl", Array("go radharc(4)".utf8)) && within(10) { says(ns, "page radharc(4)") },
          "a link followed: radharc(4)")
    check(within(5) { line(ns, "history").map { !$0.elementsEqual("history 0".utf8) } ?? false }, "with a history to retrace")

    print(failures == 0 ? "guide-test: all passed" : "guide-test: \(failures) FAILED")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
