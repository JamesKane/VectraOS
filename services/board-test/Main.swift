// SPDX-License-Identifier: BSD-3-Clause

// bin/board-test: what a board boot must show to be stable, run by the
// board image (bootfs-board.img, launcher.until=board-test) on the board
// and, as boot-board, in QEMU. It waits for devmgr to bind, and checks
// that every device it bound has its driver running, a PCI function's
// with its DMA on an IOMMU, every IOMMU the kernel's, and every disk
// answering with its geometry, a MiB written to /data reading back, and
// every USB bus looked at (in QEMU, a keyboard plugged in and a key typed
// on it reaching kbdfs), the SCMI agent answering and each GPU powered up
// and probed, the display engine firmware lit flipped to a test
// pattern and back, and every CPU with CPPC asked for its highest level
// and every thermal zone read (power(8)); then that /net/ether0's link comes up and net
// takes an IPv4 address on it (DHCP, so frames went both ways). It prints devmgr's status and IOMMUs, each driver's status
// and the interface's, and exits 0 if every check passed, within a
// minute and a half however the board behaves, so a board left to
// itself always comes back.

import DisplayDevice
import IPC
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
    // A platform device firmware puts behind no IOMMU (the Sky1's USB
    // hosts) DMAs straight to memory; a PCI function never may.
    if f[0].utf8.starts(with: "acpi-".utf8) {
      check(same(f[4], "running") && !holds(l, "dma none"), "\(f[3]) runs")
    } else {
      check(same(f[4], "running") && !holds(l, "dma passthrough") && !holds(l, "dma none"),
            "\(f[3]) runs, its DMA on an IOMMU")
    }
  }
  check(!hosts.isEmpty, "devmgr bound a device")
  let iommus = readText(ns, "/svc/devmgr/iommus") ?? ""
  for l in lines(iommus) { print("board-test: iommu: \(l)") }
  check(!lines(iommus).isEmpty && lines(iommus).allSatisfy { holds($0, " ok") }, "every IOMMU is the kernel's")
  return hosts
}

/// Each disk devmgr serves (/dev/sd*): its ctl answers with its geometry
/// and partitions, which the driver read from the disk.
func disks(_ ns: Namespace) {
  let names = ((try? ns.list("/dev")) ?? []).map { $0.name }.filter { $0.utf8.starts(with: "sd".utf8) }
  for d in names {
    let ctl = readText(ns, "/dev/\(d)/ctl") ?? ""
    for l in lines(ctl) { print("board-test: \(d): \(l)") }
    check(lines(ctl).contains { $0.utf8.starts(with: "geometry ".utf8) }, "\(d) answers with its geometry")
  }
}

/// The volume: a MiB written to /data, fs(4)'s, read back the same.
func volume(_ ns: Namespace) {
  var seed = UInt64(truncatingIfNeeded: Clock.monotonic()) | 1
  var bytes = [UInt8](repeating: 0, count: 1 << 20)
  for i in 0..<bytes.count {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    bytes[i] = UInt8(truncatingIfNeeded: seed)
  }
  var written = false
  // The last run's file first, which create won't make again.
  if var old = try? ns.open("/data/board-test") { _ = try? old.remove() }
  // fs waits up to 10 s for its partition (fs(4)), devmgr's to bind.
  let deadline = Clock.monotonic() + 10_000_000_000
  var made = try? ns.create("/data/board-test", kind: .file)
  while made == nil, Clock.monotonic() < deadline {
    sleep(until: Clock.monotonic() + 100_000_000)
    made = try? ns.create("/data/board-test", kind: .file)
  }
  if made == nil { print("board-test: /data/board-test can't be made") }
  if var f = made {
    written = true
    var at = 0
    while written, at < bytes.count {
      let n = min(32768, bytes.count - at)
      written = (try? f.write(offset: UInt64(at), Array(bytes[at..<(at + n)]))) == UInt32(n)
      at += n
    }
  }
  var back: [UInt8] = []
  if var f = try? ns.open("/data/board-test") {
    while back.count < bytes.count, let part = try? f.read(offset: UInt64(back.count), max: 32768), !part.isEmpty {
      back += part
    }
  }
  check(written && back == bytes, "a MiB written to /data reads back the same")
}

/// The network: ether0's link up, then an IPv4 address on it.
func network(_ ns: Namespace, until deadline: Int64) {
  let stats = waitFor(ns, "/net/ether0/stats", until: deadline) { holds($0, "link: 1\n") }
  check(holds(stats, "link: 1\n"), "/net/ether0's link comes up")
  let local = waitFor(ns, "/net/ipifc/0/local", until: deadline) { t in lines(t).contains { holds($0, ".") } }
  for l in lines(readText(ns, "/net/ipifc/0/status") ?? "") { print("board-test: ipifc: \(l)") }
  check(lines(local).contains { holds($0, ".") }, "net takes an IPv4 address on /net/ether0")
}

/// Each USB host controller: running, its devices listed. In QEMU (its
/// HID devices are 0627's), a keyboard plugged into the hub there, then a
/// key typed on it reaching kbdfs.
func usb(_ ns: Namespace, _ hosts: [String], until deadline: Int64) {
  for h in hosts where h.utf8.starts(with: "xhci-".utf8) {
    let path = "/svc/devmgr/drivers/\(h)/status"
    let status = waitFor(ns, path, until: deadline) { holds($0, "bus ready") || holds($0, "FAILED") }
    check(holds(status, "bus ready") && !holds(status, "FAILED"), "\(h) runs its bus")
    guard holds(status, " 0627:") else { continue }
    print("qemu: device_add usb-kbd,bus=usb.0,port=1.2")
    let plugged = waitFor(ns, path, until: deadline) { holds($0, "keyboard") }
    check(holds(plugged, "keyboard") && holds(plugged, "mouse") && holds(plugged, "hub, "),
          "\(h) finds the hub, the mouse on it and a keyboard plugged in")
    print("qemu: sendkey a")
    let typed = waitFor(ns, path, until: deadline) { holds($0, "keys to kbdfs 2,") }
    check(holds(typed, "keys to kbdfs 2,"), "a key typed on it reaches kbdfs, pressed and released")
  }
}

/// Each GPU's first probe (mali(3)): powered up in its order, its GPU_ID
/// read; and the SCMI agent it went through answering.
func gpus(_ ns: Namespace, _ hosts: [String], until deadline: Int64) {
  for h in hosts where h.utf8.starts(with: "scmi-".utf8) {
    let status = readText(ns, "/svc/devmgr/drivers/\(h)/status") ?? ""
    check(holds(status, "SCMI ") && !holds(status, "FAILED"), "\(h) talks to the platform")
  }
  for h in hosts where h.utf8.starts(with: "mali-".utf8) {
    let status = waitFor(ns, "/svc/devmgr/drivers/\(h)/status", until: deadline) { holds($0, "probed") || holds($0, "FAILED") }
    check(holds(status, "probed"), "\(h) powers the GPU up and reads its GPU_ID")
  }
}

/// Each display engine (linlon(3)): probed, or left alone where firmware
/// didn't light it; one lit, and that one flipped to a test pattern, held
/// two seconds to be seen on the monitor, and back to firmware's buffer,
/// each flip latched at a frame.
func displays(_ ns: Namespace, _ hosts: [String], until deadline: Int64) {
  var lit: [String] = []
  for h in hosts where h.utf8.starts(with: "linlon-".utf8) {
    let status = waitFor(ns, "/svc/devmgr/drivers/\(h)/status", until: deadline) {
      holds($0, "ready") || holds($0, "off:") || holds($0, "idle:") || holds($0, "FAILED")
    }
    check(!holds(status, "FAILED") && !status.utf8.isEmpty, "\(h) probes its engine or leaves it unlit")
    if holds(status, "ready") { lit.append(h) }
  }
  guard hosts.contains(where: { $0.utf8.starts(with: "linlon-".utf8) }) else { return }
  check(lit.count == 1, "firmware lit one display engine (\(lit.count))")
  guard let h = lit.first, let ch = try? ns.connect("/svc/devmgr/drivers/\(h)/display") else { return }
  var client = DisplayDeviceIPC.DisplayClient(channel: ch)
  guard let o = (try? client.outputs())?.first, o.enabled else {
    check(false, "\(h) has an output")
    return
  }
  // Eight bars, white to black through the primaries, as a monitor shows them.
  let w = Int(o.width), hgt = Int(o.height), bytes = (w * hgt * 4 + 4095) & ~4095
  let colors: [UInt32] = [0xFFFFFF, 0xFFFF00, 0x00FFFF, 0x00FF00, 0xFF00FF, 0xFF0000, 0x0000FF, 0x000000]
  var shown = false
  if let vmo = try? VMO.create(size: bytes), let m = try? VMO.map(vmo, length: bytes) {
    for y in 0..<hgt {
      for x in 0..<w { m.store(colors[x * 8 / w], at: (y * w + x) * 4) }
    }
    if let dup = try? vmo.duplicate(), let image = try? client.attach(vmo: dup, width: o.width, height: o.height),
      (try? client.show(output: o.id, image: image)) != nil
    {
      shown = (try? client.flush(image: image, damage: [])) != nil
      sleep(until: Clock.monotonic() + 2_000_000_000)
      shown = shown && (try? client.show(output: o.id, image: 0)) != nil
      _ = try? client.detach(image: image)
    }
  }
  let status = readText(ns, "/svc/devmgr/drivers/\(h)/status") ?? ""
  check(shown && holds(status, "timeouts 0"), "\(h) flips to a test pattern and back, each flip latched")
}

/// power(8): every CPU whose _CPC names a SystemMemory register asked for
/// its highest level, and every thermal zone read, its temperature short
/// of its passive trip; where there is no CPPC (QEMU), power says so.
func power(_ ns: Namespace, until deadline: Int64) {
  let cpus = lines(readText(ns, "/svc/devmgr/cpus") ?? "")
  let writable = cpus.filter { holds($0, " desired 0 0x") }.count
  let status = waitFor(ns, "/svc/power/status", until: deadline) { holds($0, "steps taken") }
  if writable > 0 {
    check(holds(status, "cppc \(writable) of \(cpus.count) CPUs") && holds(status, "step 8 of 8"),
          "power asked \(writable) CPUs for their highest level")
  } else {
    check(holds(status, "no CPPC") || holds(status, "none with a register"), "power says there is no CPPC to set")
  }
  let zones = lines(readText(ns, "/svc/devmgr/thermal") ?? "")
  if !zones.isEmpty {
    check(!zones.contains { holds($0, " - passive") }, "every one of \(zones.count) thermal zones reads")
  }
  for l in lines(status) { print("board-test: power: \(l)") }
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
    disks(ns)
    volume(ns)
    usb(ns, hosts, until: Clock.monotonic() + 20_000_000_000)
    gpus(ns, hosts, until: Clock.monotonic() + 10_000_000_000)
    displays(ns, hosts, until: Clock.monotonic() + 10_000_000_000)
    power(ns, until: Clock.monotonic() + 10_000_000_000)
    network(ns, until: start + 90_000_000_000)
    for h in hosts {
      for l in lines(readText(ns, "/svc/devmgr/drivers/\(h)/status") ?? "") { print("board-test: \(h): \(l)") }
    }
    print("board-test: \(failures == 0 ? "passed" : "FAILED, \(failures) checks")")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
