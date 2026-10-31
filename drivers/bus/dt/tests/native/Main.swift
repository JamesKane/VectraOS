// SPDX-License-Identifier: BSD-3-Clause

// bin/dt-test: devmgr on a devicetree machine (D154), run by the
// launcher (launcher.until=dt-test) in rv64's boot-devicetree-bus, where
// QEMU's firmware gives only a tree, and on a board. It waits for devmgr
// to bind, and checks that devmgr read the tree the boot data carries,
// that each of the tree's devices has its line in devmgr's status,
// that one has both registers and an interrupt (a range translated
// through its buses, an interrupt resolved to the kernel's controller),
// that each provider its devices' links name runs where it has a driver,
// and, where one runs (the K1's APBC and APMU), that a clock a device
// names turns on through its ctl; and that each K1 Ethernet MAC's driver
// that runs set its MAC up (and, reported, whether a link comes up and
// what it receives).
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

/// The names devmgr may give the device at `path`: `dt-` and its node's
/// name, or where another's node shares it, its path's components joined
/// by dots.
func names(_ path: String) -> [String] {
  let parts = path.utf8.split(separator: UInt8(ascii: "/")).map { String(decoding: $0, as: UTF8.self) }
  return ["dt-" + (parts.last ?? ""), "dt-" + parts.joined(separator: ".")]
}

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

    // Links: each provider a link names that has a driver runs it; where
    // one runs, a clock a device names turns on through its ctl.
    let links = lines(tree).filter { $0.utf8.starts(with: "  ".utf8) }.map { fields($0) }
    var providers: [String] = []
    for l in links where l.count >= 3 && l[2].utf8.first == UInt8(ascii: "/") && !providers.contains(where: { same($0, l[2]) }) {
      providers.append(l[2])
    }
    let hosts = providers.compactMap { p -> (path: String, fields: [String])? in
      guard let line = named.first(where: { l in names(p).contains { same($0, fields(l)[0]) } }) else { return nil }
      let f = fields(line)
      return f.count >= 5 && !same(f[3], "-") ? (p, f) : nil
    }
    check(hosts.allSatisfy { same($0.fields[4], "running") }, "each provider with a driver runs it (\(hosts.count))")
    let clock = links.first { l in
      l.count == 4 && same(l[0], "clock") && hosts.contains { same($0.path, l[2]) && same($0.fields[4], "running") }
    }
    if let clock, let host = hosts.first(where: { same($0.path, clock[2]) }) {
      let base = "/svc/devmgr/drivers/\(host.fields[3])"
      let wrote = ns.writeText(base + "/ctl", "clock \(clock[3]) on\n")
      let state = lines(ns.readText(base + "/status") ?? "").first { l in
        let f = fields(l)
        return f.count == 4 && same(f[0], "clock") && same(f[1], clock[3])
      }
      print("dt-test: \(host.fields[3]): clock \(clock[3]) on: \(state ?? "no state")")
      check(wrote && state.map { same(fields($0)[3], "on") || same(fields($0)[3], "ungated") } == true,
            "clock \(clock[3]) of \(clock[2]) turns on through its provider")
    } else {
      print("dt-test: no provider runs: no clock to turn on")
    }

    // Each Ethernet MAC's driver that runs set its device up: its status
    // has no FAILED line (its link may be down: no cable).
    let macs = named.map { fields($0) }.filter { f in
      f.count >= 5 && f[3].utf8.starts(with: "k1-emac-".utf8) && same(f[4], "running")
    }
    for f in macs {
      for l in lines(ns.readText("/svc/devmgr/drivers/\(f[3])/status") ?? "FAILED: no status") {
        print("dt-test: \(f[3]): \(l)")
      }
    }
    if !macs.isEmpty {
      // A link is up only once its PHY has negotiated, seconds after its
      // driver starts: up to 10 s for one, then 5 s of whatever the LAN
      // sends, reported (a board may have no cable).
      let status = { (f: [String]) in ns.readText("/svc/devmgr/drivers/\(f[3])/status") ?? "" }
      let linked = { macs.filter { f in lines(status(f)).contains { $0.utf8.starts(with: "link up".utf8) } } }
      let wait = Clock.monotonic() + 10_000_000_000
      while linked().isEmpty, Clock.monotonic() < wait { sleep(until: Clock.monotonic() + 200_000_000) }
      if !linked().isEmpty { sleep(until: Clock.monotonic() + 5_000_000_000) }
      for f in macs {
        let report = lines(status(f)).filter { $0.utf8.starts(with: "link".utf8) || $0.utf8.starts(with: "received".utf8) }
        print("dt-test: \(f[3]): after waiting: \(report.joined(separator: "; "))")
      }
      check(macs.allSatisfy { f in
        !lines(ns.readText("/svc/devmgr/drivers/\(f[3])/status") ?? "FAILED").contains { $0.utf8.starts(with: "FAILED".utf8) }
      }, "each Ethernet MAC's driver set it up (\(macs.count))")
    }
    print("dt-test: \(failures == 0 ? "passed" : "FAILED, \(failures) checks")")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
