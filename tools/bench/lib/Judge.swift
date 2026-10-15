// SPDX-License-Identifier: BSD-3-Clause

// Judging a run against its history (docs/performance.md §5): once a
// budget is met, a rise beyond its noise margin fails even while it is
// still under target, so the margin isn't spent silently.

/// The rule a measurement is judged by. Most are costs (seconds, counts),
/// where higher is worse; a rate (`Unit.rate`: MB/s, megapixels a
/// second, a ratio to the host's library) is the other way round, so for
/// one a fall is what fails, and its limit is a floor.
public struct Rule: Sendable {
  /// A worsening from the baseline by more than this fraction fails (a
  /// rise, or for a rate a fall)...
  public var tolerance: Double
  /// ...but only if it is also larger than this much, in the unit (noise).
  public var floor: Double
  /// How many recent recorded runs form the baseline (their median).
  public var window: Int
  /// A hard target: worse than it fails whatever the history says (above
  /// it, or for a rate below it).
  public var limit: Double? = nil
  /// What the values are: seconds, a count of something, or a rate.
  public var unit: Unit = .seconds

  public enum Unit: Sendable, Equatable {
    case seconds, count
    /// Higher is better; the name it's shown with ("MB/s").
    case rate(String)
  }

  public init(tolerance: Double, floor: Double, window: Int, limit: Double? = nil, unit: Unit = .seconds) {
    self.tolerance = tolerance
    self.floor = floor
    self.window = window
    self.limit = limit
    self.unit = unit
  }

  /// Whether higher values are better (a rate).
  public var higherIsBetter: Bool { if case .rate = unit { true } else { false } }

  /// Incremental and no-change builds: a few seconds, steady to ±4%.
  public static let buildTime = Rule(tolerance: 0.10, floor: 0.25, window: 5)
  /// Clean builds: steady only to about ±6% on a shared machine (15.9 to
  /// 17.9 s measured for the same tree on 2026-10-09), so 10% fails on
  /// noise. 20% still catches what matters, such as swift-syntax no
  /// longer arriving prebuilt (more than double).
  public static let cleanBuild = Rule(tolerance: 0.20, floor: 2.0, window: 5)

  /// The tracer's own costs (docs/performance.md): an enabled zone under
  /// 20 ns, a disabled one about a load and a branch.
  public static let traceZoneEnabled = Rule(tolerance: 0.25, floor: 2e-9, window: 5, limit: 20e-9)
  public static let traceZoneDisabled = Rule(tolerance: 0.25, floor: 0.5e-9, window: 5, limit: 1e-9)

  /// Nothing to do means none at all.
  public static let zero = Rule(tolerance: 0, floor: 0.5, window: 5, limit: 0, unit: .count)

  /// A value in this rule's unit.
  public func format(_ v: Double) -> String {
    switch unit {
    case .seconds: formatValue(v)
    case .count: v == v.rounded() ? String(Int(v)) : String(Double(Int(v * 10)) / 10)
    case .rate(let name):
      // Three significant figures or so: "412 MB/s", "41.2", "0.65".
      (v >= 100 ? String(Int(v.rounded())) : v >= 10 ? String(Double(Int((v * 10).rounded())) / 10)
        : String(Double(Int((v * 100).rounded())) / 100)) + " " + name
    }
  }

  /// "+10%, 0.25 s", and the limit if there is one; "-15%, 1 Mpx/s" and
  /// "≥" for a rate.
  public var summary: String {
    let sign = higherIsBetter ? "-" : "+"
    let rise = tolerance == 0 ? (higherIsBetter ? "any fall" : "any rise")
      : "\(sign)\(Int((tolerance * 100).rounded()))%, \(format(floor))"
    return rise + (limit.map { "; \(higherIsBetter ? "≥" : "≤") \(format($0))" } ?? "")
  }
}

public enum Verdict: Equatable {
  /// No history yet on this machine: recorded, not judged.
  case new
  case ok
  /// Slower than the baseline by more than the rule allows.
  case regressed
  /// Above the rule's hard limit.
  case overLimit
}

/// A measurement's judgement.
public struct Judgement: Equatable {
  public var name: String
  public var seconds: Double
  public var baseline: Double?
  public var verdict: Verdict
  public var rule: String
  public var unit: Rule.Unit = .seconds
  /// The budget proper, where it is tighter than the limit that fails
  /// today (croi's `target=`): shown, never judged.
  public var target: Double? = nil

  /// The change from the baseline, as a fraction.
  public var change: Double? { baseline.map { $0 > 0 ? (seconds - $0) / $0 : 0 } }
}

public func judge(_ name: String, seconds: Double, history: [Sample], rule: Rule) -> Judgement {
  let past = history.filter { $0.name == name }.suffix(rule.window).map(\.seconds)
  // A rate is judged as its negation: higher is better.
  let worse = { (a: Double, b: Double) in rule.higherIsBetter ? a < b : a > b }
  if let limit = rule.limit, worse(seconds, limit) {
    return Judgement(name: name, seconds: seconds, baseline: past.isEmpty ? nil : median(Array(past)),
                     verdict: .overLimit, rule: rule.summary, unit: rule.unit)
  }
  guard !past.isEmpty else {
    return Judgement(name: name, seconds: seconds, baseline: nil, verdict: .new, rule: rule.summary, unit: rule.unit)
  }
  let baseline = median(Array(past))
  let regressed = rule.higherIsBetter
    ? seconds < baseline * (1 - rule.tolerance) && baseline - seconds > rule.floor
    : seconds > baseline * (1 + rule.tolerance) && seconds - baseline > rule.floor
  return Judgement(name: name, seconds: seconds, baseline: baseline, verdict: regressed ? .regressed : .ok,
                   rule: rule.summary, unit: rule.unit)
}

/// The budget report, in Markdown.
public func report(_ judgements: [Judgement], machine: String, commit: String, date: String) -> String {
  var out = """
    # Budget report

    Machine `\(machine)`, commit `\(commit)`, \(date). A measurement fails if it is worse
    than the median of the last 5 recorded runs on this machine by more than both parts of its
    rule (docs/performance.md): slower, or for a rate lower. Times are medians of this run's repeats.

    | Budget | This run | Baseline | Change | Rule | Target | Verdict |
    |---|---:|---:|---:|---|---:|---|

    """
  for j in judgements {
    let change = j.change.map { (($0 >= 0 ? "+" : "") + String(Int(($0 * 100).rounded()))) + "%" } ?? "—"
    let verdict = switch j.verdict {
    case .new: "new"
    case .ok: "ok"
    case .regressed: "**OVER**"
    case .overLimit: "**OVER LIMIT**"
    }
    let show = { (v: Double) in Rule(tolerance: 0, floor: 0, window: 0, unit: j.unit).format(v) }
    out += "| `\(j.name)` | \(show(j.seconds)) | \(j.baseline.map(show) ?? "—") | \(change) | \(j.rule) | \(j.target.map(show) ?? "—") | \(verdict) |\n"
  }
  return out
}
