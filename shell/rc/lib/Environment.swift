// SPDX-License-Identifier: BSD-3-Clause

// rc's environment, as 9front's unix rc keeps it (mkenv, Vinit, finit): a
// variable with a value is `name=` its words joined by ^A (\u{1}), a
// function `#()fn name {body}` (its text as whatis prints it), sorted. The
// one encoding on every system, the device's and Linux's: a system passes
// the strings to a program as they are, and an rc it starts reads them
// back as lists and functions.

extension Rc {
  /// The environment for a program rc starts: every variable that has a
  /// value, and every function.
  public var environmentStrings: [String] {
    var out = variables.filter { !$0.value.isEmpty }.map { $0.key + "=" + $0.value.joined(separator: "\u{1}") }
    out += functions.map { "#()fn " + $0.key + " " + Rc.brace($0.value, 0) }
    return out.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
  }

  /// Takes an environment's variables (Vinit: a name before the first =,
  /// with no `(` in it) and its functions (finit), but not functions with
  /// -p, and not what rc sets itself ($*, $0, $pid, $status). Call it
  /// after `take(_:name:)`, which sets -p.
  public func take(environment: [String]) {
    for e in environment {
      if e.hasPrefix("#()fn ") {
        guard !flags.contains("p"), case .function(let name, let body)? = try? Parser.parse(String(e.dropFirst(3)))
        else { continue }
        functions[name] = body
        continue
      }
      guard let eq = e.firstIndex(of: "="), !e[..<eq].contains("("), eq != e.startIndex else { continue }
      let name = String(e[..<eq])
      if ["*", "0", "pid", "status"].contains(name) { continue }
      variables[name] = e[e.index(after: eq)...].split(separator: "\u{1}", omittingEmptySubsequences: false)
        .map(String.init)
    }
  }
}
