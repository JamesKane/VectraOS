// SPDX-License-Identifier: BSD-3-Clause

// Risk-based testing (D88): docs/risk.tsv maps the tree's paths to the
// tests a change under them puts at risk, and `vx test --changed` runs only
// those. Pure, so the rules are tested hosted (RiskTests).

/// The checks vx runs besides tests, which a row may name.
public let riskChecks = ["man", "loc", "hardware", "rc-oracle", "risk"]

public let riskColumns = ["path", "arches", "host", "boots", "checks"]

/// One row of risk.tsv: what a change under `path` risks.
public struct RiskRow: Equatable, Sendable {
  public var line: Int
  /// A directory (ending in /) or a file; the longest that matches wins.
  public var path: String
  /// Nil for every tested arch (`all`); empty for none (`-`).
  public var arches: [String]?
  /// SwiftPM test targets; nil for all of them (`all`).
  public var host: [String]?
  /// ctest names; nil for each arch's whole suite (`all`).
  public var boots: [String]?
  public var checks: [String]

  public init(line: Int = 0, path: String, arches: [String]?, host: [String]?, boots: [String]?, checks: [String]) {
    self.line = line
    self.path = path
    self.arches = arches
    self.host = host
    self.boots = boots
    self.checks = checks
  }

  public func matches(_ file: String) -> Bool {
    path.hasSuffix("/") ? file.hasPrefix(path) : file == path
  }
}

/// A comma list, `-` for none.
private func list(_ field: Substring) -> [String] {
  field == "-" ? [] : field.split(separator: ",").map(String.init)
}

/// The rows of risk.tsv, and what's wrong with any that aren't rows. Its
/// first line names the columns; `#` starts a comment line.
public func parseRisk(_ text: String, file: String = "docs/risk.tsv") -> ([RiskRow], [String]) {
  var rows: [RiskRow] = []
  var problems: [String] = []
  var sawHeader = false
  for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
    let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
    if line.isEmpty || line.hasPrefix("#") { continue }
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
    if !sawHeader {
      sawHeader = true
      if fields.map(String.init) != riskColumns {
        problems.append("\(file):\(i + 1): the header is \(riskColumns.joined(separator: " "))")
      }
      continue
    }
    guard fields.count == riskColumns.count, fields.allSatisfy({ !$0.isEmpty }) else {
      problems.append("\(file):\(i + 1): a row has \(riskColumns.count) fields, - for none")
      continue
    }
    let path = String(fields[0])
    if rows.contains(where: { $0.path == path }) {
      problems.append("\(file):\(i + 1): \(path) listed twice")
      continue
    }
    rows.append(RiskRow(
      line: i + 1, path: path,
      arches: fields[1] == "all" ? nil : list(fields[1]),
      host: fields[2] == "all" ? nil : list(fields[2]),
      boots: fields[3] == "all" ? nil : list(fields[3]),
      checks: list(fields[4])))
  }
  return (rows, problems)
}

/// What to run: the union over the changed files' rows.
public struct RiskPlan: Equatable, Sendable {
  /// SwiftPM test targets, sorted; nil for all of `swift test`.
  public var host: [String]?
  /// Each arch to build, in `arches` order, with its ctest names (sorted;
  /// nil for its whole suite, empty to build only).
  public var arches: [(arch: String, boots: [String]?)]
  public var checks: [String]
  /// Changed files no row maps, for which everything runs.
  public var unmapped: [String]

  public static func == (a: RiskPlan, b: RiskPlan) -> Bool {
    a.host == b.host && a.checks == b.checks && a.unmapped == b.unmapped
      && a.arches.map(\.arch) == b.arches.map(\.arch) && a.arches.map(\.boots) == b.arches.map(\.boots)
  }

  public var isEmpty: Bool { host == [] && arches.isEmpty && checks.isEmpty }
}

/// The row that maps `file`: the longest path that matches it.
public func row(for file: String, in rows: [RiskRow]) -> RiskRow? {
  rows.filter { $0.matches(file) }.max { $0.path.count < $1.path.count }
}

/// The tests `changed` puts at risk, on `tested` arches (another arch a
/// row names is only built). A file no row maps risks everything: the
/// full suite, every check.
public func plan(_ rows: [RiskRow], changed: [String], tested: [String]) -> RiskPlan {
  var host: [String]? = []
  var boots: [String: [String]?] = [:]
  var checks: [String] = []
  var unmapped: [String] = []
  for file in changed {
    guard let r = row(for: file, in: rows) else {
      unmapped.append(file)
      host = nil
      for a in tested { boots[a] = .some(nil) }
      checks = riskChecks
      continue
    }
    if let more = r.host { host = host.map { $0 + more } } else { host = nil }
    for a in r.arches ?? tested {
      // An arch whose suite is off by default is built, not tested.
      let more: [String]? = tested.contains(a) ? r.boots : []
      switch (boots[a], more) {
      case (.some(.none), _): break  // already the whole suite
      case (_, .none): boots[a] = .some(nil)
      case (.some(.some(let have)), .some(let names)): boots[a] = .some(have + names)
      case (.none, .some(let names)): boots[a] = .some(names)
      }
    }
    checks += r.checks
  }
  let order = tested + boots.keys.filter { !tested.contains($0) }.sorted()
  return RiskPlan(
    host: host.map { Array(Set($0)).sorted() },
    arches: order.compactMap { a in boots[a].map { (a, $0.map { Array(Set($0)).sorted() }) } },
    checks: riskChecks.filter(checks.contains),
    unmapped: unmapped)
}

/// What the map is checked against.
public struct RiskFacts: Sendable {
  /// Every arch, and the ones whose suites run by default.
  public var arches: [String]
  public var tested: [String]
  /// Package.swift's test targets.
  public var hostTargets: [String]
  /// An arch's ctest names; nil if its tree isn't configured.
  public var ctest: @Sendable (String) -> [String]?
  /// Whether a tracked path starts with this one (or is it).
  public var exists: @Sendable (String) -> Bool

  public init(arches: [String], tested: [String], hostTargets: [String],
              ctest: @escaping @Sendable (String) -> [String]?, exists: @escaping @Sendable (String) -> Bool) {
    self.arches = arches
    self.tested = tested
    self.hostTargets = hostTargets
    self.ctest = ctest
    self.exists = exists
  }
}

/// What's wrong with the map: names that don't exist, and tests no row
/// names, so a new test or target can't be missed by every selection.
public func check(_ rows: [RiskRow], facts: RiskFacts, file: String = "docs/risk.tsv") -> [String] {
  var problems: [String] = []
  var named: [String] = []
  for r in rows {
    let at = "\(file):\(r.line): \(r.path)"
    if !facts.exists(r.path) { problems.append("\(at): no such path in the tree") }
    for a in r.arches ?? [] where !facts.arches.contains(a) { problems.append("\(at): unknown arch \(a)") }
    for h in r.host ?? [] where !facts.hostTargets.contains(h) { problems.append("\(at): no test target \(h)") }
    for c in r.checks where !riskChecks.contains(c) { problems.append("\(at): unknown check \(c)") }
    if r.arches == [] && r.boots != [] { problems.append("\(at): boots without an arch") }
    let arches = r.arches ?? facts.tested
    if let boots = r.boots {
      let known = arches.map { facts.ctest($0) }
      if !arches.isEmpty, known.allSatisfy({ $0 != nil }) {
        for b in boots where !known.contains(where: { $0!.contains(b) }) {
          problems.append("\(at): no test \(b) on \(arches.joined(separator: ", "))")
        }
      }
      named += boots
    }
  }
  // A row that runs everything (`all`) names nothing: each test is named
  // by some row, so a new one gets a place in the map.
  let hostNamed = Set(rows.flatMap { $0.host ?? [] })
  for t in facts.hostTargets where !hostNamed.contains(t) { problems.append("\(file): no row names test target \(t)") }
  let bootNamed = Set(named)
  for a in facts.tested {
    for t in facts.ctest(a) ?? [] where !bootNamed.contains(t) {
      problems.append("\(file): no row names \(a)'s test \(t)")
    }
  }
  return problems
}

/// A ctest -R pattern for exactly these names.
public func ctestPattern(_ names: [String]) -> String {
  "^(" + names.map(escape).joined(separator: "|") + ")$"
}

/// A swift test --filter pattern for these test targets.
public func hostPattern(_ targets: [String]) -> String {
  "^(" + targets.map(escape).joined(separator: "|") + ")\\."
}

private func escape(_ s: String) -> String {
  var out = ""
  for c in s {
    if "\\^$.|?*+()[]{}".contains(c) { out.append("\\") }
    out.append(c)
  }
  return out
}
