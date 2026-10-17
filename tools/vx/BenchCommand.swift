// SPDX-License-Identifier: BSD-3-Clause

// vx bench: the boot budgets (croi's tools/bench.py, K9f, now judged by
// todhchai's Judge; docs/performance.md).
//
// Boots the amd64 build under KVM several times in two profiles: "full"
// (the command line as built: every self-test runs) and "lean" (plus
// croi.selftest=off). Each boot prints `budget name=... value=...
// unit=ns|count [limit=...] [target=...]` lines (Budgets.swift, m2). The
// bench takes each budget's median and judges it against this machine's
// history, bench/history/<host>.tsv (values in seconds, or the count).
//
// On a shared machine the bench reports and fails nothing; --record
// refuses while the machine is busy (load average above a quarter of the
// CPUs, before or after), with a dirty tree, or with a regression unless
// --accept (a decision made in the open). Only a quiet, dedicated machine
// runs --enforce. --compare REF builds REF in a worktree
// (bench/out/compare/) and alternates boots of the two, so both see the
// same machine.

import Bench
import FoundationEssentials
import Glibc

private let out = "bench/out"
private let historyDir = "bench/history"
private let done = "userboot: bin/m2 exited with"

private func edk2Dir(_ build: String) -> String {
  guard let cache = try? String(contentsOfFile: "\(build)/CMakeCache.txt", encoding: .utf8) else { return "/usr/share/edk2" }
  for line in cache.split(separator: "\n") where line.hasPrefix("CROI_EDK2_DIR:") {
    if let eq = line.firstIndex(of: "=") { return String(line[line.index(after: eq)...]) }
  }
  return "/usr/share/edk2"
}

/// One boot of `tree`'s amd64 build in `profile`; its budgets.
private func boot(tree: String, profile: String, label: String, index: Int, anyExit: Bool = false) -> [String: Reported] {
  let build = "\(tree)/build/amd64"
  let esp = "\(out)/esp/\(label)-\(profile)"
  removeTree(esp)
  makeDirectory("\(out)/esp")
  do { try FileManager.default.copyItem(atPath: "\(build)/esp", toPath: esp) } catch { fail("can't copy \(build)/esp: \(error)") }
  let cmdlinePath = "\(esp)/croi/cmdline"
  guard let cmdline = try? String(contentsOfFile: cmdlinePath, encoding: .utf8) else { fail("no \(cmdlinePath)") }
  var words = cmdline.split(whereSeparator: \.isWhitespace).map(String.init)
  if profile == "lean" { words.append("croi.selftest=off") }
  _ = try? words.joined(separator: " ").write(toFile: cmdlinePath, atomically: true, encoding: .utf8)
  let work = "\(out)/work/\(label)"
  makeDirectory(work)
  makeDirectory("\(out)/logs")
  let log = "\(out)/logs/\(label)-\(profile)-\(index).log"
  removeTree(log)
  let exits = words.contains { $0.hasPrefix("userboot.shutdown=") } ? ["--exits"] : []
  let r = run(["\(tree)/tools/qemu.sh", "--test", done] + exits
              + ["amd64", esp, work, edk2Dir(build), "-accel", "kvm", "-cpu", "host"], log: log)
  let console = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
  if !r.ok || (!anyExit && !console.contains("\(done) 0")) {
    fail("\(label) \(profile) boot \(index) didn't finish; see \(log)")
  }
  return parseBudgets(console)
}

private func collect(tree: String, label: String, runs: Int, into values: inout [String: [Double]],
                     meta: inout [String: Reported], index: Int? = nil, anyExit: Bool = false) {
  for i in index.map({ [$0] }) ?? Array(0..<runs) {
    for profile in ["full", "lean"] {
      for (name, b) in boot(tree: tree, profile: profile, label: label, index: i, anyExit: anyExit) {
        values[name, default: []].append(b.value)
        meta[name] = b
      }
    }
  }
}

private func loadAverage() -> Double {
  var load = [0.0, 0.0, 0.0]
  _ = getloadavg(&load, 3)
  return load[0]
}

private func cpuCount() -> Int { Int(sysconf(Int32(_SC_NPROCESSORS_ONLN))) }

private func isBusy(_ load: Double) -> Bool { load > Double(cpuCount()) / 4 }

private func machine() -> (host: String, description: String) {
  var name = [CChar](repeating: 0, count: 256)
  gethostname(&name, name.count)
  let host = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    .split(separator: ".").first.map(String.init) ?? "unknown"
  var model = "unknown CPU"
  if let info = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8),
     let line = info.split(separator: "\n").first(where: { $0.hasPrefix("model name") }),
     let colon = line.firstIndex(of: ":") {
    model = trimmed(line[line.index(after: colon)...])
  }
  return (host, "\(host), \(model), \(cpuCount()) CPUs")
}

private func commit(_ tree: String = ".") -> String {
  let sha = capture(["git", "-C", tree, "rev-parse", "--short", "HEAD"]) ?? "unknown"
  let dirty = capture(["git", "-C", tree, "status", "--porcelain", "--untracked-files=no"]) ?? ""
  return sha + (dirty.isEmpty ? "" : "-dirty")
}

private func utcNow() -> String {
  var t = time(nil)
  var tm = tm()
  gmtime_r(&t, &tm)
  func two(_ v: Int32) -> String { v < 10 ? "0\(v)" : "\(v)" }
  return "\(tm.tm_year + 1900)-\(two(tm.tm_mon + 1))-\(two(tm.tm_mday))T\(two(tm.tm_hour)):\(two(tm.tm_min))Z"
}

func benchCommand(_ args: [String]) -> Bool {
  if args.first == "--zircon" { return zirconCompare(Array(args.dropFirst())) }
  var runs = 5
  var record = false, accept = false, enforce = false
  var compareRef: String?
  var i = 0
  while i < args.count {
    switch args[i] {
    case "--runs":
      i += 1
      guard i < args.count, let n = Int(args[i]), n >= 1 else { fail("--runs needs a number ≥ 1") }
      runs = n
    case "--record": record = true
    case "--accept": accept = true
    case "--enforce": enforce = true
    case "--compare":
      i += 1
      guard i < args.count else { fail("--compare needs a commit") }
      compareRef = args[i]
    default: fail("unknown option \(args[i])")
    }
    i += 1
  }
  guard FileManager.default.fileExists(atPath: "/dev/kvm") else { fail("needs KVM (/dev/kvm): TCG timings aren't judged") }
  guard build("amd64") else { return false }
  let loadBefore = loadAverage()
  if let compareRef { return compare(compareRef, runs: runs, loadBefore: loadBefore) }

  say("vx bench: \(runs) runs × (full, lean) boots of build/amd64 under KVM")
  var values: [String: [Double]] = [:]
  var meta: [String: Reported] = [:]
  collect(tree: ".", label: "this", runs: runs, into: &values, meta: &meta)
  let loadAfter = loadAverage()
  let busy = isBusy(loadBefore) || isBusy(loadAfter)

  let (host, description) = machine()
  let historyPath = "\(historyDir)/\(host).tsv"
  let history = parseHistory((try? String(contentsOfFile: historyPath, encoding: .utf8)) ?? "")
  let sha = commit()
  var judgements: [Judgement] = []
  for name in values.keys.sorted() {
    let b = meta[name]!
    var rule = Rule.for(name)
    rule.unit = b.unit
    rule.limit = b.limit
    var j = judge(name, seconds: median(values[name]!), history: history, rule: rule)
    j.target = b.target
    judgements.append(j)
  }
  let bad = judgements.contains { $0.verdict == .regressed || $0.verdict == .overLimit }
  let date = utcNow()
  var text = report(judgements, machine: description, commit: sha, date: date)
  text += "\nMedian of \(runs) boots per profile. Load average \(oneDecimal(loadBefore)) before, "
    + "\(oneDecimal(loadAfter)) after\(busy ? " (busy: a regression may be noise)" : "").\n\n"
    + (enforce ? "Enforced: a regression or a missed limit fails.\n"
       : "Advisory: nothing fails here (a shared machine's timings are noisy).\n")
  makeDirectory(out)
  _ = try? text.write(toFile: "\(out)/report.md", atomically: true, encoding: .utf8)
  say(text)

  if record {
    if busy && !accept {
      say("not recorded: the machine was busy, and a noisy run would skew the baseline. Rerun when it is quiet.")
    } else if sha.hasSuffix("-dirty") && !accept {
      say("not recorded: the tree has uncommitted changes; record a commit.")
    } else if bad && !accept {
      say("not recorded: a budget regressed. Fix it, or re-decide with --accept (in the open).")
    } else {
      makeDirectory(historyDir)
      var lines = FileManager.default.fileExists(atPath: historyPath) ? ""
        : "# Budget history for \(description). Appended by vx bench --record.\n"
      for j in judgements { lines += Sample(date: date, commit: sha, name: j.name, seconds: j.seconds).line + "\n" }
      append(lines, to: historyPath)
      say("recorded in \(historyPath)")
    }
  }
  return !(enforce && bad)
}

private func oneDecimal(_ v: Double) -> String { String(Double(Int((v * 10).rounded())) / 10) }

private func append(_ text: String, to path: String) {
  let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
  guard fd >= 0 else { fail("can't write \(path)") }
  let bytes = Array(text.utf8)
  _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
  close(fd)
}

/// This tree against `ref`, boots alternating so both see the same machine.
private func compare(_ ref: String, runs: Int, loadBefore: Double) -> Bool {
  guard let sha = capture(["git", "rev-parse", "--short", ref]) else { fail("no such commit: \(ref)") }
  let tree = "\(out)/compare/\(sha)"
  if !FileManager.default.fileExists(atPath: tree) {
    makeDirectory("\(out)/compare")
    guard step("compare-worktree", ["git", "worktree", "add", "--detach", tree, sha]) else { return false }
  }
  // This tree's SwiftPM configuration (its swift-syntax mirror), which git
  // doesn't track: without it, the worktree's build clones from GitHub, and
  // offline it waits for good.
  let config = ".swiftpm/configuration"
  if FileManager.default.fileExists(atPath: config) {
    makeDirectory("\(tree)/.swiftpm")
    try? FileManager.default.removeItem(atPath: "\(tree)/\(config)")
    do {
      try FileManager.default.copyItem(atPath: config, toPath: "\(tree)/\(config)")
    } catch {
      fail("can't copy \(config) to \(tree): \(error)")
    }
  }
  say("vx bench: building \(sha) in \(tree)")
  if !FileManager.default.fileExists(atPath: "\(tree)/build/amd64/build.ninja") {
    guard step("compare-\(sha)-configure", ["cmake", "-S", tree, "--preset", "amd64"]) else { return false }
  }
  guard step("compare-\(sha)-build", ["cmake", "--build", "\(tree)/build/amd64"]) else { return false }

  say("vx bench: \(runs) interleaved runs, this tree (\(commit())) and \(sha)")
  var here: [String: [Double]] = [:], there: [String: [Double]] = [:]
  var meta: [String: Reported] = [:]
  for i in 0..<runs {
    collect(tree: ".", label: "this", runs: runs, into: &here, meta: &meta, index: i, anyExit: true)
    collect(tree: tree, label: sha, runs: runs, into: &there, meta: &meta, index: i, anyExit: true)
  }
  var text = "# Comparison: this tree (\(commit())) against \(sha)\n\n"
    + "Median of \(runs) interleaved boots per profile. Load average \(oneDecimal(loadBefore)) before, "
    + "\(oneDecimal(loadAverage())) after.\n\n"
    + "| Budget | This tree | \(sha) | Change | Spread here (min-max) |\n|---|---:|---:|---:|---|\n"
  for name in Set(here.keys).union(there.keys).sorted() {
    let show = { (v: Double) in Rule(tolerance: 0, floor: 0, window: 0, unit: meta[name]?.unit ?? .seconds).format(v) }
    let a = here[name].map { median($0) }, b = there[name].map { median($0) }
    let change = a.flatMap { a in b.flatMap { b in b > 0 ? "\(a >= b ? "+" : "")\(Int(((a - b) / b * 100).rounded()))%" : nil } } ?? "—"
    let spread = here[name].map { "\(show($0.min()!))-\(show($0.max()!))" } ?? "—"
    text += "| `\(name)` | \(a.map(show) ?? "—") | \(b.map(show) ?? "—") | \(change) | \(spread) |\n"
  }
  makeDirectory(out)
  _ = try? text.write(toFile: "\(out)/compare.md", atomically: true, encoding: .utf8)
  say(text)
  return true
}
