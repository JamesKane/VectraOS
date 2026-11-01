// SPDX-License-Identifier: BSD-3-Clause

// bin/sd-test: SD cards and eMMC through bin/sdhci, run by the launcher
// (launcher.until=sd-test) in boot-sdhci, where QEMU's sdhci-pci hosts
// hold a card and an eMMC, each made by `vx disk` with a taisce
// partition. It waits for each controller's driver to bring its device
// up, checks that there is an SD card and an eMMC, and for each disk at
// /dev/sdM<n>: that it answers with its geometry and the device's
// partition, that 160 KiB (two pieces of the driver's bounce buffer)
// written past the partition table read back the same, and a short
// piece at an offset no sector starts at. It prints each driver's
// status, and exits 0 if every check passed.

import Node
import Sys

nonisolated(unsafe) var failures = 0

func check(_ condition: Bool, _ name: String) {
  print("sd-test: \(condition ? "ok" : "FAILED"): \(name)")
  if !condition { failures += 1 }
}

func lines(_ text: String) -> [String] { text.utf8.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) } }

func holds(_ text: String, _ part: String) -> Bool {
  let t = Array(text.utf8), p = Array(part.utf8)
  guard p.count <= t.count else { return false }
  for i in 0...(t.count - p.count) where Array(t[i..<(i + p.count)]) == p { return true }
  return false
}

/// Each sdhci driver's status, once each has brought its device up or
/// failed, or `deadline` passes.
func statuses(_ ns: Namespace, until deadline: Int64) -> [(String, String)] {
  var out: [(String, String)] = []
  while Clock.monotonic() < deadline {
    let drivers = ((try? ns.list("/svc/devmgr/drivers")) ?? []).map { $0.name }
      .filter { $0.utf8.starts(with: "sdhci".utf8) }
    out = drivers.map { ($0, ns.readText("/svc/devmgr/drivers/\($0)/status") ?? "") }
    if out.count >= 2, out.allSatisfy({ holds($0.1, "sectors ") || holds($0.1, "FAILED") }) { break }
    sleep(until: Clock.monotonic() + 100_000_000)
  }
  return out
}

/// The disk at /dev/`name`: its geometry and partition, 160 KiB written
/// and read back, and 100 bytes read at an odd offset.
func disk(_ ns: Namespace, _ name: String) {
  let ctl = ns.readText("/dev/\(name)/ctl") ?? ""
  for l in lines(ctl) { print("sd-test: \(name): \(l)") }
  check(lines(ctl).contains { $0.utf8.starts(with: "geometry ".utf8) }, "/dev/\(name) answers with its geometry")
  check(lines(ctl).contains { $0.utf8.starts(with: "part taisce ".utf8) }, "\(name)'s GPT's taisce partition is read")

  var seed = UInt64(truncatingIfNeeded: Clock.monotonic()) | 1
  var bytes = [UInt8](repeating: 0, count: 160 * 1024)
  for i in 0..<bytes.count {
    seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
    bytes[i] = UInt8(truncatingIfNeeded: seed)
  }
  let at: UInt64 = 64 * 1024
  let path = "/dev/\(name)/data"
  var written = false
  if var f = try? ns.open(path) {
    written = true
    var done = 0
    while written, done < bytes.count {
      let n = min(32768, bytes.count - done)
      written = (try? f.write(offset: at + UInt64(done), Array(bytes[done..<(done + n)]))) == UInt32(n)
      done += n
    }
  }
  var back: [UInt8] = []
  if var f = try? ns.open(path) {
    while back.count < bytes.count,
      let part = try? f.read(offset: at + UInt64(back.count), max: UInt32(min(32768, bytes.count - back.count))),
      !part.isEmpty
    {
      back += part
    }
  }
  check(written && back == bytes, "160 KiB written to \(path) reads back the same")
  var short: [UInt8] = []
  if var f = try? ns.open(path), let part = try? f.read(offset: at + 70_001, max: 100) { short = part }
  check(short == Array(bytes[70_001..<70_101]), "100 bytes of \(name) at an offset no sector starts at read back the same")
}

@main struct SDTest {
  static func main() {
    let ns: Namespace
    do throws(NamespaceError) {
      ns = try Namespace(Startup.current)
    } catch {
      print("sd-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    let deadline = Clock.monotonic() + 30_000_000_000
    let found = statuses(ns, until: deadline)
    for (d, s) in found {
      for l in lines(s) { print("sd-test: \(d): \(l)") }
      check(holds(s, "sectors ") && !holds(s, "FAILED"), "\(d) brings its device up")
    }
    check(found.contains { holds($0.1, "kind sd\n") }, "an SD card comes up")
    check(found.contains { holds($0.1, "kind emmc\n") }, "an eMMC comes up")

    var names: [String] = []
    while Clock.monotonic() < deadline {
      names = ((try? ns.list("/dev")) ?? []).map { $0.name }.filter { $0.utf8.starts(with: "sdM".utf8) }
      if names.count >= 2 { break }
      sleep(until: Clock.monotonic() + 100_000_000)
    }
    check(names.count == 2, "devmgr binds two disks at /dev/sdM*")
    for n in names { disk(ns, n) }

    print("sd-test: \(failures == 0 ? "passed" : "\(failures) failed")")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
