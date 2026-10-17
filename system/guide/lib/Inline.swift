// SPDX-License-Identifier: BSD-3-Clause

// Text inside a line (guide(6), "inline"): four things are special in
// headings, paragraphs, items, definitions and table cells, and nothing
// else is:
//
//     `literal`         what is typed; opened by n backticks, closed by n
//     <param>           `<`, a letter, then letters, digits, `.`, `_`, `-`, then `>`
//     name(N)           a link to a page, N from 1 to 8
//     {label|target}    a link with words of its own; {target} without
//
// A target is `name(N)`, `name(N)#node`, `#node`, or a URL whose scheme
// is `https:`, `gemini:` or `gopher:`.

/// A span refused, without its line (Page adds it).
public struct InlineError: Error, Sendable {
  public let message: String
}

public struct Span: Sendable {
  public enum Kind: Sendable, Equatable {
    /// `text`: a word, never whitespace.
    case text
    /// `text`: a run of whitespace, newlines and continuation indents included.
    case space
    /// `text`: between the backticks.
    case literal
    /// `text`: `<name>`, brackets included.
    case parameter
    /// `text`: `name(N)` as written; `name` and `section`.
    case reference
    /// `{label|target}` or `{target}`: `label` (the target when none) and `target`.
    case link
  }

  public var kind: Kind
  public var text: [UInt8]
  public var name: [UInt8] = []
  public var section = 0
  public var label: [UInt8] = []
  public var target: [UInt8] = []
  /// A link's label is its own words, not its target.
  public var labelled = false
}

public enum Inline {
  /// `s`'s spans, in order.
  public static func spans(_ s: [UInt8]) throws(InlineError) -> [Span] {
    var out: [Span] = []
    var i = 0
    while i < s.count {
      let c = s[i]
      if isSpace(c) {
        var j = i
        while j < s.count && isSpace(s[j]) { j += 1 }
        out.append(Span(kind: .space, text: Array(s[i..<j])))
        i = j
      } else if c == 0x60 {  // `
        let n = ticks(s, i)
        guard let end = literalEnd(s, i, n) else { throw InlineError(message: "a literal that is never closed") }
        var inside = Array(s[(i + n)..<end])
        // One space just inside each end is dropped, so a literal may start with a backtick.
        if inside.count >= 2, inside.first == 0x20, inside.last == 0x20, !blank(inside) {
          inside = Array(inside.dropFirst().dropLast())
        }
        out.append(Span(kind: .literal, text: inside))
        i = end + n
      } else if let n = parameter(s, i) {
        out.append(Span(kind: .parameter, text: Array(s[i..<(i + n)])))
        i += n
      } else if c == 0x7B {  // {
        var j = i + 1
        while j < s.count && s[j] != 0x7D && s[j] != 0x7B { j += 1 }
        guard j < s.count, s[j] == 0x7D else { throw InlineError(message: "a { link } that is never closed") }
        let inside = Array(s[(i + 1)..<j])
        var span = Span(kind: .link, text: Array(s[i...j]))
        if let bar = inside.firstIndex(of: 0x7C) {
          span.label = trim(Array(inside[..<bar]))
          span.target = Array(inside[(bar + 1)...])
          span.labelled = true
        } else {
          span.label = inside
          span.target = inside
        }
        guard !span.label.isEmpty, isTarget(span.target) else {
          throw InlineError(message: "a link to no target guide knows")
        }
        out.append(span)
        i = j + 1
      } else if let r = reference(s, i) {
        out.append(Span(kind: .reference, text: Array(s[i..<(i + r.length)]), name: Array(s[i..<(i + r.length - 3)]),
                        section: r.section))
        i += r.length
      } else {
        // A word: up to a space or the next span's start.
        var j = i + 1
        while j < s.count && !isSpace(s[j]) && s[j] != 0x60 && s[j] != 0x7B && parameter(s, j) == nil
          && reference(s, j) == nil {
          j += 1
        }
        out.append(Span(kind: .text, text: Array(s[i..<j])))
        i = j
      }
    }
    return out
  }

  /// A row's cells (a block's `text`, after its first `|`), trimmed. A `|`
  /// inside a literal is its cell's, and the row's last `|` may be left off.
  public static func cells(_ row: [UInt8]) -> [[UInt8]] {
    guard !blank(row) else { return [] }
    var out: [[UInt8]] = []
    var start = 0, i = 0
    while i <= row.count {
      if i == row.count || row[i] == 0x7C {
        let cell = trim(Array(row[start..<i]))
        if !(i == row.count && cell.isEmpty && !out.isEmpty) { out.append(cell) }
        start = i + 1
        i += 1
        continue
      }
      let n = ticks(row, i)
      if n > 0, let end = literalEnd(row, i, n) {
        i = end + n
      } else {
        i += max(n, 1)
      }
    }
    return out
  }

  /// The length and section of a reference `name(N)` at `s[i]`, or nil.
  static func reference(_ s: [UInt8], _ i: Int) -> (length: Int, section: Int)? {
    guard isNameStart(s[i]), i == 0 || !isNameChar(s[i - 1]) else { return nil }
    var j = i
    while j < s.count && isNameChar(s[j]) { j += 1 }
    guard j + 3 <= s.count, s[j] == 0x28, s[j + 1] >= 0x31, s[j + 1] <= 0x38, s[j + 2] == 0x29 else { return nil }
    return (j + 3 - i, Int(s[j + 1] - 0x30))
  }

  /// The length of a parameter `<name>` at `s[i]`, or nil.
  static func parameter(_ s: [UInt8], _ i: Int) -> Int? {
    guard s[i] == 0x3C, i + 1 < s.count, isAlpha(s[i + 1]) else { return nil }
    var j = i + 2
    while j < s.count && (isAlnum(s[j]) || s[j] == 0x2E || s[j] == 0x5F || s[j] == 0x2D) { j += 1 }
    return j < s.count && s[j] == 0x3E ? j + 1 - i : nil
  }

  static func isTarget(_ t: [UInt8]) -> Bool {
    guard let first = t.first else { return false }
    if first == 0x23 { return isNodeId(Array(t.dropFirst())) }
    for scheme: StaticString in ["https:", "gemini:", "gopher:"] where starts(t, scheme) {
      return t.count > scheme.utf8CodeUnitCount + 2 && !t.contains(where: isSpace)
    }
    guard let n = reference(t, 0)?.length else { return false }
    return n == t.count || (t[n] == 0x23 && isNodeId(Array(t[(n + 1)...])))
  }

  /// How many backticks in the run at `s[i]`.
  static func ticks(_ s: [UInt8], _ i: Int) -> Int {
    var n = 0
    while i + n < s.count && s[i + n] == 0x60 { n += 1 }
    return n
  }

  /// Where a literal opened at `s[i]` by `n` backticks closes (the closing
  /// run's start), or nil if it never does.
  static func literalEnd(_ s: [UInt8], _ i: Int, _ n: Int) -> Int? {
    var k = i + n
    while k < s.count {
      let run = ticks(s, k)
      if run == n { return k }
      k += max(run, 1)
    }
    return nil
  }
}
