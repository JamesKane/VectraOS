// SPDX-License-Identifier: BSD-3-Clause

// bin/dt-test: devmgr on a devicetree machine (D154), run by the
// launcher (launcher.until=dt-test) in rv64's boot-devicetree-bus, where
// QEMU's firmware gives only a tree, and on a board. It waits for devmgr
// to bind, and checks that devmgr read the tree the boot data carries,
// that each of the tree's devices has its line in devmgr's status, and
// that one has both registers and an interrupt (a range translated
// through its buses, an interrupt resolved to the kernel's controller).
// It prints devmgr's devicetree and status, and exits 0 if every check
// passed.

import Node
import Sys

nonisolated(unsafe) var failures = 0

func check(_ condition: Bool, _ name: String) {
  print("dt-test: \(condition ? "ok" : "FAILED"): \(name)")
  if !condition { failures += 1 }
}

func lines(_ text: String) -> [String] { text.utf8.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) } }

func fields(_ line: String) -> [String] { line.utf8.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) } }

func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

@main struct DTTest {
  static func main() {
    let ns: Namespace
    do throws(NamespaceError) {
      ns = try Namespace(Startup.current)
    } catch {
      print("dt-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    let deadline = Clock.monotonic() + 30_000_000_000
    var status = ""
    while Clock.monotonic() < deadline {
      status = ns.readText("/svc/devmgr/status") ?? ""
      if lines(status).contains(where: { $0.utf8.starts(with: "bound ".utf8) }) { break }
      sleep(until: Clock.monotonic() + 100_000_000)
    }
    check(lines(status).contains { $0.utf8.starts(with: "bound ".utf8) }, "devmgr binds its drivers")
    let tree = ns.readText("/svc/devmgr/devicetree") ?? ""
    for l in lines(tree) { print("dt-test: devicetree: \(l)") }
    for l in lines(status) { print("dt-test: status: \(l)") }
    // A device's line starts with its path; its notes are indented.
    let devices = lines(tree).filter { $0.utf8.first == UInt8(ascii: "/") }
    check(!devices.isEmpty, "devmgr read the tree's devices")
    let named = lines(status).filter { $0.utf8.starts(with: "dt-".utf8) }
    check(named.count == devices.count, "each of the tree's devices is in devmgr's status")
    check(named.allSatisfy { l in
      let f = fields(l)
      return f.count >= 5 && (same(f[4], "unbound") || same(f[4], "running"))
    }, "each is bound and running, or unbound")
    check(devices.contains { l in
      let f = fields(l)
      return f.contains { same($0, "mmio") } && f.contains { same($0, "irq") }
    }, "a device has registers and an interrupt")
    print("dt-test: \(failures == 0 ? "passed" : "FAILED, \(failures) checks")")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
