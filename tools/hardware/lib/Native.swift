// SPDX-License-Identifier: BSD-3-Clause

// The native suite on a board (D66, vx remote test): what boot-smoke runs
// in QEMU, the kernel's self-tests, m2 and every Swift suite
// (`croi.test=all`), judged from the board's console as qemu.sh judges
// QEMU's, with the budget lines scraped as vx bench reads them.

/// A `budget name=N value=V unit=U [limit=L] [target=T]` line.
public struct Budget: Equatable, Sendable {
  public var name: String
  public var value: Int64
  public var unit: String
  public var limit: Int64?

  public init(name: String, value: Int64, unit: String, limit: Int64?) {
    self.name = name
    self.value = value
    self.unit = unit
    self.limit = limit
  }

  /// Over its limit (budgets are reported, not enforced: vx bench judges).
  public var over: Bool { limit.map { value > $0 } ?? false }

  /// The budget on a console line, wherever it starts on it.
  public init?(line: String) {
    let words = line.split(separator: " ")
    guard let at = words.firstIndex(where: { $0.hasPrefix("budget") }), words[at] == "budget" else { return nil }
    var fields: [Substring: Substring] = [:]
    for w in words[(at + 1)...] {
      guard let eq = w.firstIndex(of: "=") else { continue }
      fields[w[..<eq]] = w[w.index(after: eq)...]
    }
    guard let name = fields["name"], let value = fields["value"].flatMap({ Int64($0) }), let unit = fields["unit"] else {
      return nil
    }
    self.init(name: String(name), value: value, unit: String(unit), limit: fields["limit"].flatMap { Int64($0) })
  }
}

/// A native run, fed the console a line at a time.
public struct NativeRun: Sendable {
  public enum Verdict: Equatable, Sendable {
    case running
    case passed
    case failed(String)
  }

  /// The program the suite's boot runs, and the line that ends it well.
  public static let program = "bin/m2"
  public static let options = ["userboot.next=bin/m2", "croi.test=all", "userboot.shutdown=reboot",
                               "croi.halt_on_panic=false"]

  public private(set) var verdict = Verdict.running
  public private(set) var budgets: [Budget] = []
  /// Lines seen since the new kernel started (`croi kernel (`).
  public private(set) var lines = 0
  /// The new kernel's banner has been seen: earlier lines are the old
  /// boot's, warm-booting.
  public private(set) var started = false

  public init() {}

  /// One console line. The verdict once it is decided.
  public mutating func feed(_ line: String) -> Verdict {
    guard verdict == .running else { return verdict }
    if !started {
      guard line.contains("croi kernel (") else { return verdict }
      started = true
    }
    lines += 1
    if let b = Budget(line: line) { budgets.append(b) }
    if line.contains("croi kernel: PANIC") {
      verdict = .failed(String(line.drop { $0 == " " || $0 == "\n" }))
    } else if let rest = Self.after("userboot: \(Self.program) exited with ", in: line) {
      let code = rest.prefix { !$0.isWhitespace }
      verdict = code == "0" ? .passed : .failed("\(Self.program) exited with \(code)")
    }
    return verdict
  }

  /// What follows `marker`'s first appearance in `line`.
  static func after(_ marker: String, in line: String) -> Substring? {
    var i = line.startIndex
    while i < line.endIndex {
      if line[i...].hasPrefix(marker) { return line[line.index(i, offsetBy: marker.count)...] }
      i = line.index(after: i)
    }
    return nil
  }
}
