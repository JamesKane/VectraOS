// SPDX-License-Identifier: BSD-3-Clause

// vx hardware: the hardware support list (D66, docs/hardware/README.md).
//
//   vx hardware           the list, each platform with its components,
//                         and each level with its health
//   vx hardware --check   also fails if the list breaks a rule: a decision
//                         or milestone that doesn't exist, a level without
//                         its evidence, a stale board, a platform above a
//                         required component, a gate not passed

import FoundationEssentials
import Glibc
import Hardware

private let supportPath = "docs/hardware/support.tsv"
private let runsPath = "docs/hardware/runs.tsv"

/// Decision names from docs/decisions' files: D066-... is D66.
private func decisionNames() -> [String] {
  let files = (try? FileManager.default.contentsOfDirectory(atPath: "docs/decisions")) ?? []
  return files.compactMap { file in
    guard file.hasPrefix("D"), let n = Int(file.dropFirst().prefix { $0.isNumber }) else { return nil }
    return "D\(n)"
  }
}

/// Milestones from the roadmap's headings: "## V4b. Orange Pi RV2" is V4b.
private func milestoneNames() -> [String] {
  let text = (try? String(contentsOfFile: "docs/roadmap.md", encoding: .utf8)) ?? ""
  return text.split(separator: "\n").compactMap { line in
    guard line.hasPrefix("## V") else { return nil }
    return String(line.dropFirst(3).prefix { $0 != "." && $0 != " " })
  }
}

/// An arch's ctest names, from its configured tree.
func ctestNames(_ arch: String) -> [String]? {
  guard FileManager.default.fileExists(atPath: "build/\(arch)/CTestTestfile.cmake"),
        let listing = capture(["ctest", "-N", "--test-dir", "build/\(arch)"]) else { return nil }
  return listing.split(whereSeparator: \.isNewline).compactMap { line in
    guard let r = line.firstRange(of: ": "), line.contains("Test") && line.contains("#") else { return nil }
    return trimmed(line[r.upperBound...])
  }
}

/// Whether `commit` is at or after the last commit touching `paths`.
private func isFresh(_ commit: String, _ paths: [String]) -> Bool? {
  guard let last = capture(["git", "log", "-1", "--format=%H", "--"] + paths), !last.isEmpty else { return nil }
  return run(["git", "merge-base", "--is-ancestor", last, commit], log: "/dev/null").ok
}

private func describe(_ row: Row, _ health: Health) -> String {
  switch health {
  case .unjudged, .ci, .fresh: row.level.rawValue
  case .stale: "\(row.level.rawValue) (stale)"
  case .failing(let since): "\(row.level.rawValue) (failing since \(since))"
  case .unrecorded: "\(row.level.rawValue) (no pass recorded)"
  }
}

private func pad(_ s: String, _ width: Int) -> String {
  s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
}

func hardwareCommand(_ args: [String]) -> Bool {
  var checking = false
  for a in args {
    switch a {
    case "--check": checking = true
    default: fail("unknown option \(a)")
    }
  }
  guard let text = try? String(contentsOfFile: supportPath, encoding: .utf8) else { fail("can't read \(supportPath)") }
  let runs = parseRuns((try? String(contentsOfFile: runsPath, encoding: .utf8)) ?? "")
  let facts = Facts(
    decisions: decisionNames(), milestones: milestoneNames(), ctest: ctestNames,
    exists: { FileManager.default.fileExists(atPath: $0) }, fresh: isFresh)
  let (rows, malformed) = parseSupport(text)

  if !checking {
    let lines = rows.map { row -> (row: Row, level: String) in
      (row, describe(row, health(of: row, in: rows, runs: runs, facts: facts)))
    }
    func show(_ row: Row, _ level: String, indent: String) {
      say(indent + pad(row.id, 28 - indent.count) + pad(level, 34) + pad(row.arch, 7) + pad(row.milestone, 6) + row.notes)
    }
    say(pad("id", 28) + pad("level", 34) + pad("arch", 7) + pad("when", 6) + "notes")
    for (platform, level) in lines where platform.kind == .platform {
      show(platform, level, indent: "")
      for (c, l) in lines where c.parents == [platform.id] { show(c, l, indent: "  ") }
    }
    let shared = lines.filter { $0.row.kind == .component && $0.row.parents.count != 1 }
    if !shared.isEmpty {
      say("shared and standalone components")
      for (c, l) in shared { show(c, l, indent: "  ") }
    }
  }

  let problems = malformed + check(rows, runs: runs, facts: facts)
  for p in problems { complain(p) }
  if checking { say(problems.isEmpty ? "vx: hardware: \(rows.count) rows, all hold" : "vx: hardware: \(problems.count) problems") }
  return problems.isEmpty
}
