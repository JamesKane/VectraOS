// SPDX-License-Identifier: BSD-3-Clause

// A machine's measurement history: one line per measurement per recorded
// run, tab-separated, so it diffs and appends cleanly:
//
//   date<TAB>commit<TAB>name<TAB>seconds
//
// Lines starting with # are comments (the machine's description).

/// One recorded measurement.
public struct Sample: Equatable {
  public var date: String
  public var commit: String
  public var name: String
  public var seconds: Double

  public init(date: String, commit: String, name: String, seconds: Double) {
    self.date = date
    self.commit = commit
    self.name = name
    self.seconds = seconds
  }

  /// Three decimals for seconds; full precision below a millisecond, where
  /// three decimals would round to nothing.
  public var line: String { "\(date)\t\(commit)\t\(name)\t\(seconds < 1e-3 ? String(seconds) : format(seconds))" }

  public init?(line: Substring) {
    let f = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard f.count == 4, let seconds = Double(f[3]) else { return nil }
    self.init(date: String(f[0]), commit: String(f[1]), name: String(f[2]), seconds: seconds)
  }
}

/// Every sample in a history file's text; malformed lines are skipped.
public func parseHistory(_ text: String) -> [Sample] {
  text.split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap(Sample.init(line:))
}

/// Seconds with three decimals.
public func format(_ seconds: Double) -> String {
  let ms = Int((seconds * 1000).rounded())
  let frac = String(ms % 1000)
  return "\(ms / 1000).\(String(repeating: "0", count: 3 - frac.count))\(frac)"
}

/// A time in the unit that suits it: "16.004 s", "2.5 ms", "14.0 ns".
public func formatValue(_ seconds: Double) -> String {
  func one(_ v: Double) -> String {
    let tenths = Int((v * 10).rounded())
    return "\(tenths / 10).\(tenths % 10)"
  }
  if seconds >= 1 { return "\(format(seconds)) s" }
  if seconds >= 1e-3 { return "\(one(seconds * 1e3)) ms" }
  if seconds >= 1e-6 { return "\(one(seconds * 1e6)) µs" }
  return "\(one(seconds * 1e9)) ns"
}

public func median(_ values: [Double]) -> Double {
  let s = values.sorted()
  guard !s.isEmpty else { return 0 }
  return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}
