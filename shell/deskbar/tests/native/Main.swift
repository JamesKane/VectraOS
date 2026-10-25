// SPDX-License-Identifier: BSD-3-Clause

// deskbar-test (boot-deskbar): Deskbar on the desktop (D114). Its panel
// shows and gives Radharc the clock's place; the launcher lists an app
// (minimal, `app Minimal`) and starts it, and Deskbar lists it running
// until its window closes. With no input the desktop goes idle: Deskbar
// closes /proc/cpu and its loop doesn't wake at all; a key makes it active
// again, and the CPU gauge reads. Gauges turned off in Settings close the
// CPU file.

import IPC
import Node
import Radharc
import Settings
import Sys
import VX
import VectraOSLibc

/// Deskbar's status lines.
func status(_ ns: Namespace) -> [String] {
  (ns.readText("/svc/deskbar/status") ?? "").split(separator: "\n").map(String.init)
}

func says(_ ns: Namespace, _ line: String) -> Bool { status(ns).contains(line) }

func line(_ ns: Namespace, _ word: String) -> [String]? {
  status(ns).first { $0.hasPrefix(word + " ") }.map { $0.split(separator: " ").map(String.init) }
}

@main struct DeskbarTest {
  static func main() {
    guard let ns = processNamespace() else {
      print("deskbar-test: FAILED: no namespace")
      Process.exit(code: 1)
    }
    check(within(60) { says(ns, "ready") && line(ns, "clock") != nil }, "Deskbar shows its panel and places its clock")
    if let c = line(ns, "clock"), c.count == 6 {
      check((Int(c[3]) ?? 0) > 0 && (Int(c[4]) ?? 0) > 0 && c[5] == "24", "the clock's place has a size, in 24 hours")
    }
    let radharc = { (ns.readText("/svc/windows/status") ?? "").split(separator: "\n").map(String.init) }
    check(within(10) { radharc().contains { $0.hasPrefix("clocks 1 ") } }, "Radharc draws one clock")
    check((ns.readText("/svc/launcher/apps") ?? "") == "minimal\tMinimal\tstopped\tapp\n",
          "the launcher lists minimal as an app, stopped")
    check(within(10) { says(ns, "apps 1") }, "Deskbar reads the launcher's apps")

    // Nobody at the desktop: idle, and the CPU file closed.
    check(within(40) { says(ns, "desktop idle") && says(ns, "cpu closed") },
          "with no input the desktop goes idle and Deskbar closes /proc/cpu")

    // Someone comes: active, the CPU file open, its gauge read.
    print("qemu: sendkey shift")
    check(within(15) { says(ns, "desktop active") && says(ns, "cpu open") }, "a key makes the desktop active and opens /proc/cpu")
    check(within(15) { line(ns, "gauge CPU").map { $0.count == 3 && $0[2].hasSuffix("%") } ?? false },
          "the CPU gauge reads a percentage")
    check(line(ns, "gauge PACING") != nil, "the pacing gauge is shown")

    // An app started: listed running while its window is open.
    if var ctl = try? ns.open("/svc/launcher/ctl") { _ = try? ctl.writeText("start minimal") }
    check(within(30) { says(ns, "running minimal 1") }, "minimal, started, is listed running with its window")
    check((ns.readText("/svc/launcher/apps") ?? "").hasPrefix("minimal\tMinimal\trunning\t"), "the launcher says it runs")
    let id = (ns.readText("/svc/windows/list") ?? "").split(separator: "\n")
      .first { $0.hasSuffix(" minimal") }.flatMap { $0.split(separator: " ").first.flatMap { UInt32($0) } }
    if let id, let wch = try? ns.connect("/svc/windows/windows") {
      var windows = RadharcIPC.WindowsClient(channel: wch)
      _ = try? windows.close(id: id)
      check(within(20) { !status(ns).contains { $0.hasPrefix("running minimal") } }, "closed, it's gone from Deskbar")
    } else {
      check(false, "minimal's window in the list")
    }

    // The gauges off: the CPU file closed.
    check(Settings.set(Settings.gauges, .bool(false), ns), "Deskbar:Gauges set off")
    check(within(15) { says(ns, "gauges off") && says(ns, "cpu closed") && line(ns, "gauge CPU") == nil },
          "with the gauges off, Deskbar closes /proc/cpu and shows none")
    _ = Settings.set(Settings.gauges, .bool(true), ns)

    print(failures == 0 ? "deskbar-test: all passed" : "deskbar-test: \(failures) FAILED")
    Process.exit(code: failures == 0 ? 0 : 1)
  }
}
