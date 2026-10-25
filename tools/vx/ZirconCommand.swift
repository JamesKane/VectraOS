// SPDX-License-Identifier: BSD-3-Clause

// vx bench --zircon [--rounds N] [--only CONFIG,...] [--logs DIR] (croi's
// tools/zircon-bench/compare.py, in Swift): the kernel's m2 budgets against
// Zircon's, on this machine, interleaved.
//
// Each round boots every configuration once, in a rotating order, so all
// of them see the same machine (vx bench --compare's rule). A budget's
// result is its median over the rounds, with the range beside it.
//
// Configurations:
//   croi            the amd64 build's ESP as built, without croi.test=
//                   (vx bench's "lean" profile, as Todhchai boots)
//   croi-nopoll     ... plus croi.idle_poll_us=0: idle CPUs halt at once,
//                   so a cross-core wake needs an IPI, as on Zircon
//   zircon          the parity bench (tools/zircon-bench/run.sh), Zircon's
//                   default options
//   zircon-nomitig  ... plus kernel.x86.disable_spec_mitigations=true
//                   (croi has no speculative-execution mitigations)
//
// The ESP is copied once at the start, so a rebuild during the run changes
// nothing. A load average above a quarter of the CPUs marks the round as
// taken on a busy machine. Needs a Fuchsia tree (tools/zircon-bench/README.md).

import Bench
import FoundationEssentials
import Glibc

private let budgetNames = ["syscall.null", "ipc.channel_call", "port.wake_median", "port.wake_p99",
                           "timer.wake_error_p99", "vdso.clock_monotonic"]
private let configs = ["croi", "croi-nopoll", "zircon", "zircon-nomitig"]

private func bootCroi(work: String, extra: [String], log: String) -> Bool {
  let esp = "\(work)/esp-boot"
  removeTree(esp)
  do { try FileManager.default.copyItem(atPath: "\(work)/esp", toPath: esp) } catch { fail("can't copy the ESP: \(error)") }
  let cmdline = "\(esp)/croi/cmdline"
  let words = ((try? String(contentsOfFile: cmdline, encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    .filter { !$0.hasPrefix("croi.test=") }
  _ = try? ((words + extra).joined(separator: " ") + "\n").write(toFile: cmdline, atomically: true, encoding: .utf8)
  makeDirectory("\(work)/qemu")
  removeTree(log)
  return run(["tools/qemu.sh", "--test", "userboot: bin/m2 exited with", "amd64", esp, "\(work)/qemu",
              "/usr/share/edk2", "-accel", "kvm", "-cpu", "host"], log: log).ok
}

private func bootZircon(extra: [String], log: String) -> Bool {
  run(["tools/zircon-bench/run.sh", "--log", log] + extra, log: "/dev/null").ok
}

private func boot(_ config: String, work: String, log: String) -> Bool {
  switch config {
  case "croi": bootCroi(work: work, extra: [], log: log)
  case "croi-nopoll": bootCroi(work: work, extra: ["croi.idle_poll_us=0"], log: log)
  case "zircon": bootZircon(extra: [], log: log)
  default: bootZircon(extra: ["kernel.x86.disable_spec_mitigations=true"], log: log)
  }
}

private func nanoseconds(_ seconds: Double) -> String {
  let ns = Int(seconds * 1e9 + 0.5)
  return ns < 10_000 ? "\(ns) ns" : "\(Double(ns / 100) / 10) us"
}

private func pad(_ s: String, _ width: Int, left: Bool = false) -> String {
  s.count >= width ? s : (left ? s + String(repeating: " ", count: width - s.count) : String(repeating: " ", count: width - s.count) + s)
}

func zirconCompare(_ args: [String]) -> Bool {
  var rounds = 6, only: [String]?, logs: String?
  var i = 0
  while i < args.count {
    switch args[i] {
    case "--rounds":
      i += 1
      guard i < args.count, let n = Int(args[i]), n >= 1 else { fail("--rounds needs a number ≥ 1") }
      rounds = n
    case "--only":
      i += 1
      guard i < args.count else { fail("--only needs configurations") }
      only = args[i].split(separator: ",").map(String.init)
    case "--logs":
      i += 1
      guard i < args.count else { fail("--logs needs a directory") }
      logs = args[i]
    default: fail("unknown option \(args[i])")
    }
    i += 1
  }
  let chosen = only ?? configs
  for c in chosen where !configs.contains(c) { fail("unknown configuration \(c); there are \(configs.joined(separator: ", "))") }
  guard build("amd64") else { return false }

  let work = "bench/out/zircon"
  removeTree(work)
  makeDirectory(work)
  let logDir = logs ?? work
  makeDirectory(logDir)
  do { try FileManager.default.copyItem(atPath: "build/amd64/esp", toPath: "\(work)/esp") } catch { fail("can't copy the ESP: \(error)") }
  let head = capture(["git", "describe", "--always", "--dirty"]) ?? "?"
  say("kernel \(head) (ESP copied to \(work)/esp), \(rounds) rounds, logs in \(logDir)")

  var results: [String: [String: [Double]]] = [:]
  var busyRounds = 0
  for r in 0..<rounds {
    let before = loadAverage()
    let order = Array(chosen[(r % chosen.count)...] + chosen[..<(r % chosen.count)])
    var line: [String] = []
    for c in order {
      let log = "\(logDir)/\(c)-\(r).log"
      let ok = boot(c, work: work, log: log)
      let values = parseBudgets((try? String(contentsOfFile: log, encoding: .utf8)) ?? "")
      guard ok, !values.isEmpty else {
        line.append("\(c) FAILED (\(log))")
        continue
      }
      for (name, b) in values { results[c, default: [:]][name, default: []].append(b.value) }
      line.append("\(c) ok")
    }
    let l = max(before, loadAverage())
    let busy = isBusy(l)
    if busy { busyRounds += 1 }
    say("round \(r + 1): \(line.joined(separator: ", ")); load \(Double(Int(l * 10)) / 10)\(busy ? " (busy)" : "")")
  }

  let width = max(chosen.map(\.count).max() ?? 0, 26)
  var table = "\n" + pad("budget", 22, left: true) + chosen.map { "  " + pad($0, width) }.joined() + "\n"
  for name in budgetNames {
    table += pad(name, 22, left: true)
    for c in chosen {
      let cell = results[c]?[name].map { v in
        "\(nanoseconds(median(v))) [\(nanoseconds(v.min()!))-\(nanoseconds(v.max()!))]"
      } ?? "-"
      table += "  " + pad(cell, width)
    }
    table += "\n"
  }
  table += "\nmedian over rounds [min-max]"
  if busyRounds > 0 {
    table += "\n\(busyRounds) of \(rounds) rounds ran with load above \(cpuCount() / 4): treat the figures as a shared machine's"
  }
  say(table)
  removeTree("\(work)/esp")
  removeTree("\(work)/esp-boot")
  return true
}
