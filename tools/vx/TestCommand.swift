// SPDX-License-Identifier: BSD-3-Clause

// vx test: each arch's QEMU suite, a named part of it, or only what a
// change puts at risk (D88, docs/risk.tsv).
//
//   vx test [ARCH...]                     build, then each arch's whole suite
//   vx test [ARCH...] --only TEST,...     build, then just these ctest names
//   vx test --changed [REF] [--plan]      what the change since REF (main by
//                                         default) risks: its host tests, its
//                                         boots, its checks; --plan only says
//   vx test --check                       the map against the tree (vx ci)

import FoundationEssentials
import Glibc
import Risk

private let riskPath = "docs/risk.tsv"

func testCommand(_ args: [String]) -> Bool {
  var named: [String] = []
  var only: [String]?
  var changed: String?
  var planOnly = false
  var i = 0
  while i < args.count {
    switch args[i] {
    case "--only":
      i += 1
      guard i < args.count else { fail("--only needs test names") }
      only = args[i].split(separator: ",").map(String.init)
    case "--changed":
      changed = "main"
      if i + 1 < args.count, !args[i + 1].hasPrefix("-"), !allArches.contains(args[i + 1]) {
        i += 1
        changed = args[i]
      }
    case "--plan": planOnly = true
    case "--check": return riskCheck()
    case let a where a.hasPrefix("-"): fail("unknown option \(a)")
    default: named.append(args[i])
    }
    i += 1
  }
  if let ref = changed {
    guard named.isEmpty, only == nil else { fail("--changed picks the arches and tests itself") }
    return testChanged(since: ref, planOnly: planOnly)
  }
  if planOnly { fail("--plan goes with --changed") }
  let list = named.isEmpty ? testedArches : arches(named)
  return list.allSatisfy { arch in build(arch) && (only.map { testOnly(arch, $0) } ?? test(arch)) }
}

/// Just these of an arch's tests; the ones it doesn't have are skipped.
private func testOnly(_ arch: String, _ names: [String]) -> Bool {
  let have = ctestNames(arch) ?? []
  let run = names.filter(have.contains)
  for n in names where !have.contains(n) { say("vx: \(arch) has no test \(n)") }
  guard !run.isEmpty else { return true }
  return step("\(arch)-test", ["ctest", "--preset", arch, "-R", ctestPattern(run)])
}

/// The tree's files that differ from where it left `ref`: committed,
/// staged, unstaged and untracked.
func changedFiles(since ref: String) -> [String] {
  guard let base = capture(["git", "merge-base", ref, "HEAD"]) else { fail("no merge base with \(ref)") }
  let diff = capture(["git", "diff", "--name-only", base]) ?? ""
  let untracked = capture(["git", "ls-files", "--others", "--exclude-standard"]) ?? ""
  var files: [String] = []
  for line in (diff + "\n" + untracked).split(whereSeparator: \.isNewline) where !files.contains(String(line)) {
    files.append(String(line))
  }
  return files
}

func loadRisk() -> [RiskRow] {
  guard let text = try? String(contentsOfFile: riskPath, encoding: .utf8) else { fail("no \(riskPath)") }
  let (rows, problems) = parseRisk(text, file: riskPath)
  for p in problems { complain(p) }
  if !problems.isEmpty { exit(1) }
  return rows
}

private func describe(_ p: RiskPlan) {
  for f in p.unmapped { say("vx: \(f) has no row in \(riskPath): everything runs") }
  say("vx: host: " + (p.host.map { $0.isEmpty ? "none" : $0.joined(separator: " ") } ?? "all"))
  for (arch, boots) in p.arches {
    say("vx: \(arch): " + (boots.map { $0.isEmpty ? "build only" : $0.joined(separator: " ") } ?? "the whole suite"))
  }
  if p.checks.isEmpty == false { say("vx: checks: " + p.checks.joined(separator: " ")) }
  if p.isEmpty { say("vx: nothing at risk") }
}

private func testChanged(since ref: String, planOnly: Bool) -> Bool {
  let files = changedFiles(since: ref)
  say("vx: \(files.count) files changed since \(ref)")
  let p = plan(loadRisk(), changed: files, tested: testedArches)
  describe(p)
  if planOnly { return true }
  var ok = true
  switch p.host {
  case nil: ok = step("host-test", ["swift", "test"]) && ok
  case let targets? where !targets.isEmpty:
    ok = step("host-test", ["swift", "test", "--filter", hostPattern(targets)]) && ok
  default: break
  }
  for (arch, boots) in p.arches {
    guard build(arch) else {
      ok = false
      continue
    }
    switch boots {
    case nil: ok = test(arch) && ok
    case let names? where !names.isEmpty: ok = testOnly(arch, names) && ok
    default: break
    }
  }
  for c in p.checks { ok = runCheck(c) && ok }
  say(ok ? "vx: what the change risks passed (the full suite is the milestone's exit)" : "vx: test FAILED")
  return ok
}

private func runCheck(_ name: String) -> Bool {
  switch name {
  case "man": manCommand(["--check"])
  case "loc": locCommand(["--check"])
  case "hardware": hardwareCommand(["--check"])
  case "rc-oracle": rcOracleCommand([])
  case "risk": riskCheck()
  default: fail("unknown check \(name)")
  }
}

/// Package.swift's test targets.
private func hostTargets() -> [String] {
  let text = (try? String(contentsOfFile: "Package.swift", encoding: .utf8)) ?? ""
  var names: [String] = []
  var rest = Substring(text)
  while let r = rest.firstRange(of: ".testTarget(name: \"") {
    rest = rest[r.upperBound...]
    names.append(String(rest.prefix { $0 != "\"" }))
  }
  return names
}

/// The map against the tree: every path exists, every name is a test,
/// and every test has a row (vx ci).
func riskCheck() -> Bool {
  let files = (capture(["git", "ls-files", "--cached", "--others", "--exclude-standard"]) ?? "").split(whereSeparator: \.isNewline).map(String.init)
  let names = Dictionary(uniqueKeysWithValues: allArches.map { ($0, ctestNames($0)) })
  let facts = RiskFacts(
    arches: allArches, tested: testedArches, hostTargets: hostTargets(),
    ctest: { names[$0] ?? nil },
    exists: { path in files.contains { path.hasSuffix("/") ? $0.hasPrefix(path) : $0 == path } })
  let problems = check(loadRisk(), facts: facts, file: riskPath)
  for p in problems { complain(p) }
  for a in testedArches where names[a] == nil { say("vx: risk: \(a) isn't configured; its test names weren't checked") }
  say("vx: risk: \(problems.isEmpty ? "ok" : "\(problems.count) problems")")
  return problems.isEmpty
}
