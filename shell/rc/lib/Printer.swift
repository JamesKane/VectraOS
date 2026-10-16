// SPDX-License-Identifier: BSD-3-Clause

// rc's commands as text, after 9front's pcmd (its `%t`), for `whatis` to
// print a function: braces open a line, their commands a tab deeper; two
// commands on a line are joined by `; `, on two lines by a newline; `|`,
// `if(c)`, `for(i in l)` and `while (c)` take no spaces where pcmd puts
// none, and a redirection before the words it wraps. A here document's
// tag, which the tree doesn't keep, comes out as EOF.

extension Rc {
  /// 9front's pwrd: a word bare if it can be, quoted otherwise.
  static func quote(_ s: String) -> String {
    let special = Set("`^#*[]=|\\?${}()'<>&;".unicodeScalars)
    if !s.isEmpty && s.unicodeScalars.allSatisfy({ $0.value > 0x20 && !special.contains($0) }) { return s }
    return quoted(s)
  }

  /// 9front's pquo: in quotes, a quote doubled.
  static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences("'", "''") + "'" }

  static func text(_ w: Word, _ depth: Int = 0) -> String {
    switch w {
    case .literal(let s, let isQuoted): return isQuoted ? quoted(s) : s
    case .variable(let name, nil): return "$" + text(name, depth)
    case .variable(let name, let index?):
      return "$" + text(name, depth) + "(" + index.map { text($0, depth) }.joined(separator: " ") + ")"
    case .count(let name): return "$#" + text(name, depth)
    case .joined(let name): return "$\"" + text(name, depth)
    case .concat(let pieces): return pieces.map { text($0, depth) }.joined(separator: "^")
    case .list(let items): return "(" + items.map { text($0, depth) }.joined(separator: " ") + ")"
    case .backquote(let c, let split): return "`" + (split.map { text($0, depth) } ?? "") + brace(c, depth)
    // pcmd's PIPEFD, as a redirection: a space before it.
    case .pipe(let c, let output): return (output ? " >" : " <") + brace(c, depth)
    }
  }

  static func tabs(_ depth: Int) -> String { String(repeating: "\t", count: depth % 8) }

  static func brace(_ c: Command, _ depth: Int) -> String {
    "{\n" + tabs(depth + 1) + text(c, depth + 1) + "\n" + tabs(depth) + "}"
  }

  static func text(_ r: Redirection) -> String {
    let target = r.target.map { text($0) } ?? ""
    switch r.kind {
    case .read(let fd): return " <" + (fd != 0 ? "[\(fd)]" : "") + target
    case .write(let fd): return " >" + (fd != 1 ? "[\(fd)]" : "") + target
    case .append(let fd): return " >>" + (fd != 1 ? "[\(fd)]" : "") + target
    case .readWrite(let fd): return " <>" + (fd != 0 ? "[\(fd)]" : "") + target
    case .duplicate(let fd, let to): return ">[\(fd)=\(to)]"
    case .close(let fd): return ">[\(fd)=]"
    case .here(let fd, _):
      let body = if case .literal(let s, _)? = r.target { s } else { "" }
      return " <<" + (fd != 0 ? "[\(fd)]" : "") + "EOF\n" + body + "EOF\n"
    }
  }

  /// A command as pcmd prints it, `depth` tabs in.
  static func text(_ c: Command, _ depth: Int) -> String {
    switch c {
    case .simple(let words, let redirs):
      // Each redirection wraps the command (its c1): `>[2=1]` runs into
      // what follows, ` >f` has a space after it too.
      let rest = words.map { text($0, depth) }.joined(separator: " ")
      return redirs.map { r in
        switch r.kind {
        case .duplicate, .close: return text(r)
        default: return text(r) + " "
        }
      }.joined() + rest
    case .assign(let name, let value, let body):
      return text(name) + "=" + text(value) + (body.map { " " + text($0, depth) } ?? "")
    case .pipeline(let stages, let fds):
      var s = text(stages[0], depth)
      for (k, fd) in fds.enumerated() { s += "|" + (fd != 1 ? "[\(fd)]" : "") + text(stages[k + 1], depth) }
      return s
    case .not(let c): return "! " + text(c, depth)
    case .subshell(let c): return "@ " + text(c, depth)
    case .and(let a, let b): return text(a, depth) + " && " + text(b, depth)
    case .or(let a, let b): return text(a, depth) + " || " + text(b, depth)
    case .sequence(let cs, let newlines):
      var s = text(cs[0], depth)
      for k in 1..<cs.count { s += (newlines[k - 1] ? "\n" + tabs(depth) : "; ") + text(cs[k], depth) }
      return s
    case .background(let c): return text(c, depth) + "&"
    case .brace(let c, let redirs): return brace(c, depth) + redirs.map(text).joined()
    case .ifThen(let condition, let body): return "if(" + text(condition, depth) + ")" + text(body, depth)
    case .ifNot(let body): return "if not " + text(body, depth)
    case .forIn(let name, let list, let body):
      return "for(" + name + (list.map { " in " + $0.map { text($0) }.joined(separator: " ") } ?? "") + ")" + text(body, depth)
    case .whileDo(let condition, let body): return "while (" + text(condition, depth) + ")" + text(body, depth)
    case .switchOn(let subject, let cases):
      // Its body a brace of `case` commands and theirs (pcmd's SWITCH:
      // `switch (subject) {...}`).
      let inner = tabs(depth + 1)
      var s = ""
      for (n, k) in cases.enumerated() {
        s += (n == 0 ? "" : "\n" + inner) + (["case"] + k.patterns.map { text($0) }).joined(separator: " ")
        for (c, newline) in zip(k.body, k.newlines) { s += (newline ? "\n" + inner : "; ") + text(c, depth + 1) }
      }
      return "switch (" + text(subject) + ") {\n" + inner + s + "\n" + tabs(depth) + "}"
    case .match(let subject, let patterns): return (["~", text(subject)] + patterns.map { text($0) }).joined(separator: " ")
    case .function(let name, let body): return "fn " + quote(name) + (body.map { " " + brace($0, depth) } ?? "")
    case .empty: return ""
    }
  }
}
