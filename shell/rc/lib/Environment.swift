// SPDX-License-Identifier: BSD-3-Clause

// rc's environment, as 9front's unix rc keeps it (mkenv, Vinit, finit): a
// variable with a value is `name=` its words joined by ^A (\u{1}), a
// function `#()fn name {body}` (its text as whatis prints it), sorted. The
// one encoding on every system, the device's and Linux's: a system passes
// the strings to a program as they are, and an rc it starts reads them
// back as lists and functions.
//
// `rfork E` empties Plan 9's /env, and rc writes there only what changed
// since it last did (Updenv, before each fork). So what was given to the
// last program started (or taken at start) and hasn't changed since is
// hidden from programs from then on, until it's set to something else.

extension Rc {
  /// The environment for a program rc starts: every variable that has a
  /// value, and every function, but those `rfork E` hid.
  public var environmentStrings: [String] {
    var out = variables.filter { !$0.value.isEmpty && hidden.variables[$0.key] != $0.value }
      .map { $0.key + "=" + $0.value.joined(separator: "\u{1}") }
    out += functions.filter { hidden.functions[$0.key] != $0.value }
      .map { "#()fn " + $0.key + " " + Rc.brace($0.value, 0) }
    return out.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
  }

  /// The environment for a program about to start (Updenv): as
  /// environmentStrings, and what it holds now published.
  func environmentForStart() -> [String] {
    hidden.variables = hidden.variables.filter { variables[$0.key] == $0.value }
    hidden.functions = hidden.functions.filter { functions[$0.key] == $0.value }
    published = (variables, functions)
    return environmentStrings
  }

  /// rfork E: what's published and unchanged hidden.
  func hideEnvironment() {
    for (name, v) in variables where published.variables[name] == v { hidden.variables[name] = v }
    for (name, f) in functions where published.functions[name] == f { hidden.functions[name] = f }
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
        published.functions[name] = body
        if flags.contains("e") { definedUnderE.insert(name) }  // read now (finit)
        continue
      }
      guard let eq = e.firstIndex(of: "="), !e[..<eq].contains("("), eq != e.startIndex else { continue }
      let name = String(e[..<eq])
      if ["*", "0", "pid", "status"].contains(name) { continue }
      variables[name] = e[e.index(after: eq)...].split(separator: "\u{1}", omittingEmptySubsequences: false)
        .map(String.init)
      published.variables[name] = variables[name]
    }
  }
}
