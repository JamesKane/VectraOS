// SPDX-License-Identifier: BSD-3-Clause

// The hardware support list (D66, docs/hardware/README.md): parsing
// support.tsv and runs.tsv, and judging the list against the facts vx
// gathers. Pure, so the rules are tested hosted (HardwareTests).

/// A support level, in the order a row climbs them.
public enum Level: String, CaseIterable, Sendable {
  case research, planned, development, experimental, supported, deprecated, retired

  /// The rung on the ladder from research to supported; nil for the two
  /// levels on the way out, which the caps don't judge.
  public var rank: Int? {
    switch self {
    case .research: 0
    case .planned: 1
    case .development: 2
    case .experimental: 3
    case .supported: 4
    case .deprecated, .retired: nil
    }
  }
}

/// One row of support.tsv.
public struct Row: Equatable, Sendable {
  public enum Kind: String, Sendable { case platform, component }

  public var line: Int
  public var id: String
  public var kind: Kind
  public var parents: [String]
  public var arch: String
  public var level: Level
  public var required: Bool
  public var milestone: String
  public var decisions: [String]
  public var tier1: String
  public var gates: [String]
  public var evidence: [String]
  public var lastPass: String?
  public var notes: String

  /// Evidence entries that name code: anything with a slash.
  public var paths: [String] { evidence.filter { $0.contains("/") && !$0.hasPrefix("vx ") } }
  /// Evidence entries that name tests: ctest names, or `vx test ARCH`.
  public var tests: [String] { evidence.filter { !$0.contains("/") || $0.hasPrefix("vx ") } }
}

public let supportColumns = [
  "id", "kind", "parent", "arch", "level", "required", "milestone", "decision", "tier1", "gates",
  "evidence", "last_pass", "notes",
]

private let arches = ["amd64", "arm64", "rv64", "all"]

/// `-` as none, otherwise a comma-separated list.
private func list(_ field: Substring) -> [String] {
  field == "-" ? [] : field.split(separator: ",").map { String($0.drop { $0 == " " }) }
}

/// Every row of support.tsv's text, and a problem for each line that isn't
/// one. The first line is the header.
public func parseSupport(_ text: String) -> (rows: [Row], problems: [String]) {
  var rows: [Row] = []
  var problems: [String] = []
  let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
  guard let header = lines.first, header.split(separator: "\t").map(String.init) == supportColumns else {
    return ([], ["support.tsv:1: the header must be \(supportColumns.joined(separator: " "))"])
  }
  for (n, line) in lines.enumerated().dropFirst() where !line.isEmpty {
    let at = "support.tsv:\(n + 1)"
    let f = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard f.count == supportColumns.count else {
      problems.append("\(at): \(f.count) fields, not \(supportColumns.count)")
      continue
    }
    guard let kind = Row.Kind(rawValue: String(f[1])) else {
      problems.append("\(at): kind \(f[1]) is not platform or component")
      continue
    }
    guard let level = Level(rawValue: String(f[4])) else {
      problems.append("\(at): level \(f[4]) is not one of \(Level.allCases.map(\.rawValue).joined(separator: ", "))")
      continue
    }
    if !arches.contains(String(f[3])) { problems.append("\(at): arch \(f[3]) is not one of \(arches.joined(separator: ", "))") }
    let required: Bool
    switch (kind, f[5]) {
    case (.platform, "-"): required = false
    case (.component, "yes"): required = true
    case (.component, "no"): required = false
    default:
      problems.append("\(at): required is - for a platform, yes or no for a component, not \(f[5])")
      required = false
    }
    switch (kind, f[8]) {
    case (.platform, "yes"), (.platform, "no"), (.platform, "deferred"), (.component, "-"): break
    default: problems.append("\(at): tier1 is yes, no or deferred for a platform, - for a component, not \(f[8])")
    }
    if kind == .platform && f[2] != "-" { problems.append("\(at): a platform has no parent") }
    rows.append(Row(
      line: n + 1, id: String(f[0]), kind: kind, parents: list(f[2]), arch: String(f[3]), level: level,
      required: required, milestone: String(f[6]), decisions: list(f[7]), tier1: String(f[8]),
      gates: list(f[9]), evidence: list(f[10]), lastPass: f[11] == "-" ? nil : String(f[11]),
      notes: String(f[12])))
  }
  return (rows, problems)
}

/// One run of a board's tests, as `vx remote test BOARD --record` writes
/// it to runs.tsv: date, commit, platform, pass or fail, and the tests
/// (gates included) that passed.
public struct Run: Equatable, Sendable {
  public var date: String
  public var commit: String
  public var platform: String
  public var passed: Bool
  public var tests: [String]

  public init(date: String, commit: String, platform: String, passed: Bool, tests: [String]) {
    self.date = date
    self.commit = commit
    self.platform = platform
    self.passed = passed
    self.tests = tests
  }

  public var line: String {
    "\(date)\t\(commit)\t\(platform)\t\(passed ? "pass" : "fail")\t\(tests.isEmpty ? "-" : tests.joined(separator: ","))"
  }

  public init?(line: Substring) {
    let f = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard f.count == 5, f[3] == "pass" || f[3] == "fail" else { return nil }
    self.init(date: String(f[0]), commit: String(f[1]), platform: String(f[2]), passed: f[3] == "pass", tests: list(f[4]))
  }
}

/// Every run in runs.tsv's text, oldest first; # lines are comments.
public func parseRuns(_ text: String) -> [Run] {
  text.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap(Run.init(line:))
}

/// What vx knows about the tree, for judging the list.
public struct Facts {
  /// Decision names that exist, such as "D66".
  public var decisions: [String]
  /// Roadmap milestones, such as "V4b".
  public var milestones: [String]
  /// Each arch's ctest names, or nil where its tree isn't configured.
  public var ctest: (String) -> [String]?
  /// Whether a path exists in the tree.
  public var exists: (String) -> Bool
  /// Whether a pass at `commit` is at or after the last commit touching
  /// `paths`; nil if git can't tell.
  public var fresh: (_ commit: String, _ paths: [String]) -> Bool?

  public init(
    decisions: [String], milestones: [String], ctest: @escaping (String) -> [String]?,
    exists: @escaping (String) -> Bool, fresh: @escaping (String, [String]) -> Bool?
  ) {
    self.decisions = decisions
    self.milestones = milestones
    self.ctest = ctest
    self.exists = exists
    self.fresh = fresh
  }
}

/// The paths whose change makes a board's pass stale: the kernel and what
/// boots it, and the code its components name.
public func freshnessPaths(of platform: Row, in rows: [Row]) -> [String] {
  ["boot/", "kernel/", "lib/"] + rows.filter { $0.parents.contains(platform.id) }.flatMap(\.paths)
}

/// A row's health beside its level: what the evidence says now.
public enum Health: Equatable, Sendable {
  /// No running check stands behind it (research to development, and the
  /// levels on the way out).
  case unjudged
  /// Checked by `vx ci`: its tests are in its arch's ctest.
  case ci
  /// A board's last run passed and is fresh.
  case fresh
  /// The last pass is older than a change it depends on.
  case stale
  /// The board's last run failed.
  case failing(since: String)
  /// No pass recorded yet.
  case unrecorded
}

/// The platforms a row stands on: itself, or a component's parents.
private func platforms(of row: Row, in rows: [Row]) -> [Row] {
  row.kind == .platform ? [row] : row.parents.compactMap { p in rows.first { $0.id == p } }
}

/// Whether a row runs on QEMU, judged by `vx ci`. QEMU platforms' ids
/// start with `qemu-`; every other platform is judged by its recorded runs.
public func onQemu(_ row: Row, in rows: [Row]) -> Bool {
  let on = platforms(of: row, in: rows)
  return !on.isEmpty && on.allSatisfy { $0.id.hasPrefix("qemu-") }
}

/// Whether a row's tests all run under `vx ci`, in each of its arches; nil
/// if an arch's tree isn't configured.
private func ciChecked(_ row: Row, _ rows: [Row], _ facts: Facts) -> Bool? {
  guard !row.tests.isEmpty else { return false }
  for arch in platforms(of: row, in: rows).map(\.arch) {
    guard let names = facts.ctest(arch) else { return nil }
    for t in row.tests where t != "vx test \(arch)" && !names.contains(t) { return false }
  }
  return true
}

/// A row's health: by `vx ci` on QEMU, and by runs.tsv on a board (a
/// component goes by its platform's runs).
public func health(of row: Row, in rows: [Row], runs: [Run], facts: Facts) -> Health {
  guard row.level == .experimental || row.level == .supported else { return .unjudged }
  if onQemu(row, in: rows) { return ciChecked(row, rows, facts) == true ? .ci : .unrecorded }
  guard let platform = platforms(of: row, in: rows).first else { return .unrecorded }
  let mine = runs.filter { $0.platform == platform.id }
  guard let last = mine.last else { return .unrecorded }
  if !last.passed {
    let since = mine.reversed().prefix { !$0.passed }.last!
    return .failing(since: since.commit)
  }
  return facts.fresh(last.commit, freshnessPaths(of: platform, in: rows)) == false ? .stale : .fresh
}

/// Everything wrong with the list: the rules `vx hardware --check` holds
/// it to (docs/hardware/README.md, "The tools").
public func check(_ rows: [Row], runs: [Run], facts: Facts) -> [String] {
  var problems: [String] = []
  var seen: [String] = []
  for row in rows {
    func problem(_ text: String) { problems.append("support.tsv:\(row.line): \(row.id): \(text)") }

    if seen.contains(row.id) { problem("id appears twice") }
    seen.append(row.id)
    for p in row.parents where rows.first(where: { $0.id == p && $0.kind == .platform }) == nil {
      problem("parent \(p) is not a platform in the list")
    }

    // Decisions and milestones (research may cite a roadmap track instead).
    for d in row.decisions where !facts.decisions.contains(d) { problem("decision \(d) doesn't exist") }
    if row.decisions.isEmpty && row.level != .research { problem("\(row.level.rawValue) needs a decision") }
    switch row.milestone {
    case "-": if row.level != .research { problem("\(row.level.rawValue) needs a milestone, or open") }
    case "open": break
    default: if !facts.milestones.contains(row.milestone) { problem("milestone \(row.milestone) isn't in the roadmap") }
    }

    // Evidence by level.
    let qemu = onQemu(row, in: rows)
    for path in row.paths where !facts.exists(path) { problem("evidence \(path) doesn't exist") }
    switch row.level {
    case .development:
      if row.paths.isEmpty { problem("development needs its code's paths as evidence") }
    case .experimental where qemu, .supported where qemu:
      switch ciChecked(row, rows, facts) {
      case nil: problem("its arch's tree isn't configured, so its tests can't be found: vx build first")
      case false?: problem("\(row.level.rawValue) on QEMU needs tests, all in its arch's ctest")
      case true?: break
      }
    case .experimental, .supported:
      guard let platform = platforms(of: row, in: rows).first else {
        problem("\(row.level.rawValue) needs a platform: QEMU's, or a board with recorded runs")
        break
      }
      if row.kind == .platform {
        let commit = row.lastPass.map { String($0.split(separator: " ").first ?? "") }
        if commit == nil {
          problem("\(row.level.rawValue) needs last_pass, a recorded run's commit and date")
        } else if !runs.contains(where: { $0.platform == row.id && $0.passed && $0.commit == commit }) {
          problem("last_pass \(commit!) isn't a pass in runs.tsv")
        }
      }
      if row.level == .supported {
        switch health(of: row, in: rows, runs: runs, facts: facts) {
        case .stale: problem("supported, but its last pass is stale: vx remote test \(platform.id) --record")
        case .unrecorded: problem("supported, but no pass is recorded")
        default: break
        }
      }
    case .research, .planned, .deprecated, .retired:
      break
    }

    // Caps: a platform no higher than a required component, nothing past a gate.
    if row.kind == .platform, let rank = row.level.rank {
      for c in rows where c.required && c.parents.contains(row.id) {
        if let r = c.level.rank, r < rank {
          problem("\(row.level.rawValue), above its required component \(c.id) (\(c.level.rawValue))")
        }
      }
    }
    if let rank = row.level.rank, rank > Level.development.rank!, let platform = platforms(of: row, in: rows).first {
      for g in row.gates where !runs.contains(where: { $0.platform == platform.id && $0.passed && $0.tests.contains(g) }) {
        problem("\(row.level.rawValue), but gate \(g) hasn't passed")
      }
    }
  }
  return problems
}
