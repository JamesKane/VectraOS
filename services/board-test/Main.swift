// SPDX-License-Identifier: BSD-3-Clause

// bin/board-test: what a board boot must show to be stable, run by the
// board image (bootfs-board.img, launcher.until=board-test) on the board
// and, as boot-board, in QEMU. It waits for devmgr to bind, and checks
// that every device it bound has its driver running with its DMA on an
// IOMMU, and that every IOMMU is the kernel's; then that /net/ether0's
// link comes up and net takes an IPv4 address on it (DHCP, so frames went
// both ways). It prints devmgr's status and IOMMUs, each driver's status
// and the interface's, and exits 0 if every check passed, within a
// minute and a half however the board behaves, so a board left to
// itself always comes back.

import Node
import Sys

nonisolated(unsafe) var failures = 0

func check(_ condition: Bool, _ name: String) {
  print("board-test: \(condition ? "ok" : "FAILED"): \(name)")
  if !condition { failures += 1 }
}

func readText(_ ns: Namespace, _ path: String) -> String? {
  guard var c = try? ns.open(path) else { return nil }
  return try? c.readText()
}

/// Whether two strings' bytes are the same.
func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

func lines(_ text: String) -> [String] { text.utf8.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) } }

/// Whether `text` holds `part` (bytes: Embedded String has no contains).
func holds(_ text: String, _ part: String) -> Bool {
  let t = Array(text.utf8), p = Array(part.utf8)
  guard !p.isEmpty, p.count <= t.count else { return p.isEmpty }
  for i in 0...(t.count - p.count) where Array(t[i..<i + p.count]) == p { return true }
  return false
}

/// Waits, until `deadline`, for `ready` to say the text at `path` is.
func waitFor(_ ns: Namespace, _ path: String, until deadline: Int64, _ ready: (String) -> Bool) -> String {
  var text = ""
  while Clock.monotonic() < deadline {
    text = readText(ns, path) ?? ""
    if ready(text) { break }
    sleep(until: Clock.monotonic() + 100_000_000)
  }
  return text
}

/// devmgr: bound, every bound device's driver running with its DMA on an
/// IOMMU, every IOMMU named to the kernel; the drivers' services.
func devices(_ ns: Namespace, until deadline: Int64) -> [String] {
  let status = waitFor(ns, "/svc/devmgr/status", until: deadline) { t in lines(t).contains { $0.utf8.starts(with: "bound ".utf8) } }
  check(lines(status).contains { $0.utf8.starts(with: "bound ".utf8) }, "devmgr binds its drivers")
  var hosts: [String] = []
  for l in lines(status) {
    let f = l.utf8.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
    guard f.count >= 6, !same(f[3], "-") else { continue }
    hosts.append(f[3])
    print("board-test: devmgr: \(l)")
    check(same(f[4], "running") && !holds(l, "dma passthrough") && !holds(l, "dma none"),
          "\(f[3]) runs, its DMA on an IOMMU")
  }
  check(!hosts.isEmpty, "devmgr bound a device")
  let iommus = readText(ns, "/svc/devmgr/iommus") ?? ""
  for l in lines(iommus) { print("board-test: iommu: \(l)") }
  check(!lines(iommus).isEmpty && lines(iommus).allSatisfy { holds($0, " ok") }, "every IOMMU is the kernel's")
  return hosts
}

/// The network: ether0's link up, then an IPv4 address on it.
func network(_ ns: Namespace, until deadline: Int64) {
  let stats = waitFor(ns, "/net/ether0/stats", until: deadline) { holds($0, "link: 1\n") }
  check(holds(stats, "link: 1\n"), "/net/ether0's link comes up")
  let local = waitFor(ns, "/net/ipifc/0/local", until: deadline) { t in lines(t).contains { holds($0, ".") } }
  for l in lines(readText(ns, "/net/ipifc/0/status") ?? "") { print("board-test: ipifc: \(l)") }
  check(lines(local).contains { holds($0, ".") }, "net takes an IPv4 address on /net/ether0")
}

@main struct BoardTest {
  static func main() {
    let ns: Namespace
    do throws(NamespaceError) {
      ns = try Namespace(Startup.current)
    } catch {
      print("board-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    let start = Clock.monotonic()
    let hosts = devices(ns, until: start + 30_000_000_000)
    network(ns, until: start + 90_000_000_000)
    for h in hosts {
      for l in lines(readText(ns, "/svc/devmgr/drivers/\(h)/status") ?? "") { print("board-test: \(h): \(l)") }
    }
    print("board-test: \(failures == 0 ? "passed" : "FAILED, \(failures) checks")")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
