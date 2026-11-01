// SPDX-License-Identifier: BSD-3-Clause

// bin/sd-test: an SD card through bin/sdhci, run by the launcher
// (launcher.until=sd-test) in boot-sdhci, where QEMU's sdhci-pci holds a
// card made by `vx disk` with a taisce partition. It waits for the
// driver to bring the card up, checks that its disk answers at
// /dev/sdM0 with its geometry and the card's partition, writes 160 KiB
// (two pieces of the driver's bounce buffer) past the partition table
// and reads them back the same, and reads a short piece at an offset no
// sector starts at. It prints the driver's status, and exits 0 if every
// check passed.

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

@main struct SDTest {
  static func main() {
    let ns: Namespace
    do throws(NamespaceError) {
      ns = try Namespace(Startup.current)
    } catch {
      print("sd-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    // The driver's status, once it has brought the card up or failed.
    let deadline = Clock.monotonic() + 30_000_000_000
    var status = ""
    while Clock.monotonic() < deadline {
      let drivers = ((try? ns.list("/svc/devmgr/drivers")) ?? []).map { $0.name }
      if let d = drivers.first(where: { $0.utf8.starts(with: "sdhci".utf8) }) {
        status = ns.readText("/svc/devmgr/drivers/\(d)/status") ?? ""
        if holds(status, "sectors ") || holds(status, "FAILED") { break }
      }
      sleep(until: Clock.monotonic() + 100_000_000)
    }
    for l in lines(status) { print("sd-test: sdhci: \(l)") }
    check(holds(status, "sectors ") && !holds(status, "FAILED"), "sdhci brings the card up")

    var ctl = ""
    while Clock.monotonic() < deadline {
      ctl = ns.readText("/dev/sdM0/ctl") ?? ""
      if !ctl.isEmpty { break }
      sleep(until: Clock.monotonic() + 100_000_000)
    }
    for l in lines(ctl) { print("sd-test: sdM0: \(l)") }
    check(lines(ctl).contains { $0.utf8.starts(with: "geometry ".utf8) }, "/dev/sdM0 answers with its geometry")
    check(lines(ctl).contains { $0.utf8.starts(with: "part taisce ".utf8) }, "its GPT's taisce partition is read")

    var seed = UInt64(truncatingIfNeeded: Clock.monotonic()) | 1
    var bytes = [UInt8](repeating: 0, count: 160 * 1024)
    for i in 0..<bytes.count {
      seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
      bytes[i] = UInt8(truncatingIfNeeded: seed)
    }
    let at: UInt64 = 64 * 1024
    var written = false
    if var f = try? ns.open("/dev/sdM0/data") {
      written = true
      var done = 0
      while written, done < bytes.count {
        let n = min(32768, bytes.count - done)
        written = (try? f.write(offset: at + UInt64(done), Array(bytes[done..<(done + n)]))) == UInt32(n)
        done += n
      }
    }
    var back: [UInt8] = []
    if var f = try? ns.open("/dev/sdM0/data") {
      while back.count < bytes.count,
        let part = try? f.read(offset: at + UInt64(back.count), max: UInt32(min(32768, bytes.count - back.count))),
        !part.isEmpty
      {
        back += part
      }
    }
    check(written && back == bytes, "160 KiB written to /dev/sdM0/data reads back the same")
    var short: [UInt8] = []
    if var f = try? ns.open("/dev/sdM0/data"), let part = try? f.read(offset: at + 70_001, max: 100) { short = part }
    check(short == Array(bytes[70_001..<70_101]), "100 bytes at an offset no sector starts at read back the same")

    print("sd-test: \(failures == 0 ? "passed" : "\(failures) failed")")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
