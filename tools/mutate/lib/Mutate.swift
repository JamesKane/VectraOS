// SPDX-License-Identifier: BSD-3-Clause

// vx mutate's rules: a suite's mutants file, the edit a mutant makes, and
// how a run ends. Pure, so tested hosted (MutateTests); the command that
// runs them is tools/vx/MutateCommand.swift.

import HostSystem

/// One named edit that removes a safeguard.
public struct Mutant: Equatable, Sendable {
  public var name: String
  /// The path from the repository's root.
  public var path: String
  public var find: String
  public var with: String
  /// The safeguard the edit removes.
  public var why: String
  /// Why the edit is expected to survive, for one that is.
  public var survives: String?
  public var line: Int

  public init(name: String, path: String, find: String, with: String, why: String, survives: String? = nil, line: Int = 0) {
    self.name = name
    self.path = path
    self.find = find
    self.with = with
    self.why = why
    self.survives = survives
    self.line = line
  }
}

/// A suite's mutants file.
public struct MutantsFile: Equatable, Sendable {
  /// The SwiftPM test target that runs.
  public var suite: String
  /// The prefix of the output lines that measure a run, if it has any.
  public var measure: String?
  public var mutants: [Mutant]
}

/// `\n`, `\t` and `\\` in `text` as the characters they spell; another
/// escape, or a lone backslash, is nil.
public func unescape(_ text: Substring) -> String? {
  var out = ""
  var escaped = false
  for c in text {
    if escaped {
      switch c {
      case "n": out.append("\n")
      case "t": out.append("\t")
      case "\\": out.append("\\")
      default: return nil
      }
      escaped = false
    } else if c == "\\" {
      escaped = true
    } else {
      out.append(c)
    }
  }
  return escaped ? nil : out
}

/// The mutants file `text` is, and what is wrong with it (each as
/// `file:line: why`). Lines start with a keyword, then a space and its
/// text; blank lines and `#` lines are skipped.
public func parseMutants(_ text: String, file: String = "mutants") -> (MutantsFile?, [String]) {
  var problems: [String] = []
  var suite: String?
  var measure: String?
  var mutants: [Mutant] = []
  // The mutant being read, and which of its fields it has.
  var name: String?
  var started = 0
  var path: String?, find: String?, with: String?, why: String?, survives: String?

  func finish() {
    guard let n = name else { return }
    defer { name = nil }
    func need(_ v: String?, _ key: String) -> String? {
      if v == nil { problems.append("\(file):\(started): mutant \(n) has no `\(key)`") }
      return v
    }
    let p = need(path, "in"), f = need(find, "find"), w = need(with, "with"), y = need(why, "why")
    guard let p, let f, let w, let y else { return }
    if f.isEmpty { problems.append("\(file):\(started): mutant \(n) has an empty `find`") }
    if mutants.contains(where: { $0.name == n }) { problems.append("\(file):\(started): mutant \(n) listed twice") }
    mutants.append(Mutant(name: n, path: p, find: f, with: w, why: y, survives: survives, line: started))
  }

  for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
    let lineNumber = i + 1
    let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
    if line.allSatisfy({ $0 == " " || $0 == "\t" }) || line.hasPrefix("#") { continue }
    let keyword = line.prefix { $0 != " " }
    let rest = line.dropFirst(keyword.count).dropFirst()
    func field() -> String? {
      guard let v = unescape(rest) else {
        problems.append("\(file):\(lineNumber): `\(keyword)` has an escape other than \\n, \\t and \\\\")
        return nil
      }
      return v
    }
    func once(_ current: String?) -> Bool {
      guard let n = name else {
        problems.append("\(file):\(lineNumber): `\(keyword)` outside a mutant")
        return false
      }
      if current != nil {
        problems.append("\(file):\(lineNumber): `\(keyword)` twice in mutant \(n)")
        return false
      }
      return true
    }
    switch keyword {
    case "suite":
      if suite != nil || !mutants.isEmpty || name != nil {
        problems.append("\(file):\(lineNumber): `suite` once, before the mutants")
      } else if rest.isEmpty {
        problems.append("\(file):\(lineNumber): `suite` needs a name")
      } else {
        suite = String(rest)
      }
    case "measure":
      if measure != nil || !mutants.isEmpty || name != nil {
        problems.append("\(file):\(lineNumber): `measure` once, before the mutants")
      } else if rest.isEmpty {
        problems.append("\(file):\(lineNumber): `measure` needs a prefix")
      } else {
        measure = String(rest)
      }
    case "mutant":
      finish()
      if rest.isEmpty || rest.contains(" ") {
        problems.append("\(file):\(lineNumber): `mutant` needs a name of one word")
      }
      name = String(rest)
      started = lineNumber
      (path, find, with, why, survives) = (nil, nil, nil, nil, nil)
    case "in": if once(path) { path = String(rest) }
    case "find": if once(find), let v = field() { find = v }
    case "with": if once(with), let v = field() { with = v }
    case "why": if once(why) { why = String(rest) }
    case "survives": if once(survives) { survives = String(rest) }
    default: problems.append("\(file):\(lineNumber): unknown keyword `\(keyword)`")
    }
  }
  finish()
  if suite == nil { problems.append("\(file):1: no `suite`") }
  guard problems.isEmpty, let suite else { return (nil, problems) }
  return (MutantsFile(suite: suite, measure: measure, mutants: mutants), problems)
}

/// Why an edit can't be made: `find` must occur in the text exactly once.
public enum EditError: Error, Equatable {
  case missing
  case ambiguous(Int)
}

/// `text` with its one `find` replaced.
public func applyEdit(_ text: String, find: String, with replacement: String) -> Result<String, EditError> {
  precondition(!find.isEmpty)
  var found: [Range<String.Index>] = []
  var from = text.startIndex
  while let r = text.range(of: find, range: from..<text.endIndex) {
    found.append(r)
    from = r.upperBound
  }
  switch found.count {
  case 0: return .failure(.missing)
  case 1: return .success(text.replacingCharacters(in: found[0], with: replacement))
  default: return .failure(.ambiguous(found.count))
  }
}

/// How a mutant's run ended.
public enum Ending: String, Equatable, Sendable {
  case caught
  case survivedExplained = "survived, explained"
  case survived
  case didNothing = "did nothing"

  /// Whether the step may still pass with it.
  public var acceptable: Bool { self == .caught || self == .survivedExplained }
}

/// The lines of `output` that start with `prefix` (after leading spaces).
public func measureLines(_ output: String, prefix: String?) -> [String] {
  guard let prefix else { return [] }
  return output.split(whereSeparator: \.isNewline).map { $0.drop { $0 == " " } }.filter { $0.hasPrefix(prefix) }.map(String.init)
}

/// How a run ended: it failed (caught); it passed, and either its measure
/// lines are the control's (did nothing, only where the suite has a
/// measure), or its mutant says it survives, or not.
public func classify(
  passed: Bool, measure: [String], control: [String], measured: Bool, survives: String?
) -> Ending {
  if !passed { return .caught }
  if measured && measure == control { return .didNothing }
  return survives == nil ? .survived : .survivedExplained
}

/// `text` without terminal colour escapes (`ESC [ ... m`).
public func plain(_ text: String) -> String {
  var out = String.UnicodeScalarView()
  var inEscape = false
  for u in text.unicodeScalars {
    if inEscape {
      if (0x40...0x7E).contains(u.value) && u != "[" { inEscape = false }
    } else if u.value == 0x1B {
      inEscape = true
    } else {
      out.append(u)
    }
  }
  return String(out)
}

/// The line of a failing run's output that says why: the first that
/// reports an error or a failed check, else the last that isn't blank.
public func firstFailure(_ output: String) -> String {
  let lines = output.split(whereSeparator: \.isNewline).map { $0.drop { $0 == " " || $0 == "\t" } }.filter { !$0.isEmpty }
  let marks = ["error:", "✘", "Expectation failed", "Issue recorded", "failed", "FAILED"]
  if let l = lines.first(where: { line in marks.contains { line.contains($0) } }) { return String(l.prefix(200)) }
  return String(lines.last?.prefix(200) ?? "no output")
}
