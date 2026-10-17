// SPDX-License-Identifier: BSD-3-Clause

// guide (D86, guide(6)): the manual's page format, after NeoVectra's
// (its docs/12-manual.md §4). The one parser: vx, man, lookman, sig and
// idlc read pages through it, and nothing else parses one.
//
// A page is UTF-8: an optional `@guide 1` line, a header of directives
// (Directives: `page`, `summary`, `names`, `src`, `keys`, `lang`, `host`)
// ended by the first blank line, then a body whose lines are typed by how
// they begin. Page reads all of it, inline spans included, so a page that
// parses is a page every reader can show.
//
// The parser is strict: what it doesn't know it refuses, with the line,
// and it never guesses.
//
// Read as bytes: String's comparisons and splits need Unicode tables tier 0
// doesn't link.

import Directives

/// A page refused: "file:line: message".
public struct GuideError: Error, Equatable, CustomStringConvertible, Sendable {
  public let description: String
  public init(_ description: String) { self.description = description }

  public static func == (a: GuideError, b: GuideError) -> Bool { a.description.utf8.elementsEqual(b.description.utf8) }
}

public struct Header: Sendable {
  public enum Language: Sendable, Equatable {
    case swift, c, rc
  }

  /// The directives a header takes (guide(6)).
  public static let directives: [StaticString] = ["page", "summary", "names", "src", "keys", "lang", "host"]

  public var page = ""
  /// 1 to 8.
  public var section = 0
  public var summary = ""
  /// Every name the page documents: an index entry and a link target
  /// each. The page's own name when it gives none.
  public var names: [String] = []
  /// The repository paths SOURCE lists.
  public var sources: [String] = []
  /// More words for lookman.
  public var keys: [String] = []
  /// A section 2 page's interface.
  public var language: Language?
  /// A program that runs on the dev machine, not on VectraOS.
  public var host = false
}

public enum FenceKind: Sendable, Equatable {
  /// Plain text; also a fence with no kind.
  case text
  /// A command's synopsis, Plan 9's notation; its program's usage message.
  case usage
  case swift
  case c
  /// A transcript or a script: lines starting `% ` are typed.
  case rc
}

public struct Block: Sendable {
  public enum Kind: Sendable, Equatable {
    /// `@node ID TITLE`: `node`, `title`.
    case node
    /// `# `: `text`.
    case heading
    /// `## `: `text`.
    case subheading
    /// `text`: its lines, newlines and all.
    case paragraph
    /// `- `: `text`, with its continuation lines.
    case item
    /// `: `: `text` is the term, `body` its description.
    case definition
    /// `|`: `text` is the row after the first `|` (Inline.cells).
    case row
    /// `text`: the lines inside, each with its newline; `fence` its kind.
    case fence
  }

  public var kind: Kind
  /// Where it starts, 1-based.
  public var line: Int
  public var text: [UInt8] = []
  public var body: [UInt8] = []
  public var fence = FenceKind.text
  public var node: [UInt8] = []
  public var title: [UInt8] = []
}

public struct Page: Sendable {
  public var header = Header()
  public var blocks: [Block] = []

  /// Reads a page. `file` names it in errors.
  public init(_ bytes: [UInt8], file: String) throws(GuideError) {
    func fail(_ line: Int, _ message: String) -> GuideError { GuideError("\(file):\(line): \(message)") }
    if let bad = invalidUTF8(bytes) { throw fail(bad, "not UTF-8") }
    var lines = Directives.lines(bytes)
    var first = 0
    if let l = lines.first, l.first == 0x40 {  // @
      let w = Directives.words(Array(l.dropFirst()))
      guard w.count == 2, Directives.same(w[0], "guide") else { throw fail(1, "a directive before the header") }
      guard Directives.same(w[1], "1") else { throw fail(1, "a version of guide this parser doesn't know") }
      first = 1
    }
    var end = first
    while end < lines.count && !blank(lines[end]) { end += 1 }
    var headerText: [UInt8] = []
    for l in lines[first..<end] { headerText += l + [0x0A] }
    let read: [Directive]
    do throws(DirectiveError) {
      read = try Directives.read(headerText, file: file, known: Header.directives, firstLine: first + 1)
    } catch {
      throw GuideError(error.description)
    }
    header = try Self.header(read, file: file, line: first + 1)
    lines.removeSubrange(0..<end)
    var body = Body(lines: lines, number: end + 1)
    var nodes: [[UInt8]] = []
    while let b = try body.next(file: file) {
      if b.kind == .node {
        guard !nodes.contains(b.node) else { throw fail(b.line, "a node id used twice") }
        nodes.append(b.node)
      }
      do throws(InlineError) {
        switch b.kind {
        case .heading, .subheading, .paragraph, .item:
          _ = try Inline.spans(b.text)
        case .definition:
          _ = try Inline.spans(b.text)
          _ = try Inline.spans(b.body)
        case .row:
          for cell in Inline.cells(b.text) { _ = try Inline.spans(cell) }
        case .node, .fence:
          break
        }
      } catch {
        throw fail(b.line, error.message)
      }
      blocks.append(b)
    }
  }

  static func header(_ read: [Directive], file: String, line: Int) throws(GuideError) -> Header {
    var h = Header()
    var seen: [String] = []
    for d in read {
      func fail(_ message: String) -> GuideError { GuideError("\(file):\(d.line): \(message)") }
      if h.page.isEmpty && !d.is("page") { throw fail("'page' must come first") }
      let once = d.is("page") || d.is("summary") || d.is("lang") || d.is("host")
      if once && seen.contains(where: { $0.utf8.elementsEqual(d.name.utf8) }) { throw fail("a second '\(d.name)'") }
      seen.append(d.name)
      let a = d.arguments
      if d.is("page") {
        guard a.count == 2, isPageName(Array(a[0].utf8)) else { throw fail("'page' takes a name and a section") }
        guard a[1].utf8.count == 1, let s = a[1].utf8.first, s >= 0x31, s <= 0x38 else {
          throw fail("a section is 1 to 8")
        }
        h.page = a[0]
        h.section = Int(s - 0x30)
      } else if d.is("summary") {
        guard !a.isEmpty else { throw fail("'summary' takes a line") }
        h.summary = d.text
        guard h.summary.utf8.last != 0x2E else { throw fail("a summary has no full stop") }
      } else if d.is("names") || d.is("keys") {
        guard !a.isEmpty else { throw fail("'\(d.name)' takes words") }
        for w in a where !isName(Array(w.utf8)) { throw fail("bad name '\(w)'") }
        if d.is("names") { h.names += a } else { h.keys += a }
      } else if d.is("src") {
        guard !a.isEmpty else { throw fail("'src' takes paths") }
        h.sources += a
      } else if d.is("lang") {
        guard a.count == 1 else { throw fail("'lang' takes swift, c or rc") }
        if Directives.same(a[0], "swift") {
          h.language = .swift
        } else if Directives.same(a[0], "c") {
          h.language = .c
        } else if Directives.same(a[0], "rc") {
          h.language = .rc
        } else {
          throw fail("'lang' takes swift, c or rc")
        }
      } else if d.is("host") {
        guard a.isEmpty else { throw fail("'host' takes 0 arguments") }
        h.host = true
      }
    }
    guard !h.page.isEmpty else { throw GuideError("\(file):\(line): no 'page'") }
    guard !h.summary.isEmpty else { throw GuideError("\(file):\(line): no 'summary'") }
    if h.names.isEmpty { h.names = [h.page] }
    return h
  }
}

/// The body, a block at a time.
struct Body {
  let lines: [[UInt8]]
  /// The first line's number in the file.
  let number: Int
  var at = 0

  init(lines: [[UInt8]], number: Int) {
    self.lines = lines
    self.number = number
  }

  /// Continuation lines (two spaces, not blank) after line `at`, which is
  /// consumed with them; their text, each line after a newline.
  mutating func continuation() -> [UInt8] {
    var out: [UInt8] = []
    at += 1
    while at < lines.count, starts(lines[at], "  "), !blank(lines[at]) {
      if !out.isEmpty { out.append(0x0A) }
      out += lines[at]
      at += 1
    }
    return out
  }

  mutating func next(file: String) throws(GuideError) -> Block? {
    while at < lines.count && blank(lines[at]) { at += 1 }
    guard at < lines.count else { return nil }
    let l = lines[at], line = number + at
    func fail(_ message: String) -> GuideError { GuideError("\(file):\(line): \(message)") }
    var b = Block(kind: .paragraph, line: line)
    if starts(l, "```") {
      b.kind = .fence
      let kind = Array(l.dropFirst(3))
      if kind.isEmpty || kind == Array("text".utf8) {
        b.fence = .text
      } else if kind == Array("usage".utf8) {
        b.fence = .usage
      } else if kind == Array("swift".utf8) {
        b.fence = .swift
      } else if kind == Array("c".utf8) {
        b.fence = .c
      } else if kind == Array("rc".utf8) {
        b.fence = .rc
      } else {
        throw fail("a fence kind guide doesn't know")
      }
      at += 1
      while at < lines.count {
        if lines[at] == Array("```".utf8) {
          at += 1
          return b
        }
        b.text += lines[at] + [0x0A]
        at += 1
      }
      throw fail("a fence that is never closed")
    }
    if l.first == 0x40 {  // @
      let w = Directives.words(Array(l.dropFirst()))
      guard let d = w.first, Directives.same(d, "node") else {
        throw fail(w.first.map { Directives.same($0, "guide") } == true
                   ? "'@guide' comes first, before the header" : "a directive guide doesn't know")
      }
      guard w.count >= 2, isNodeId(Array(w[1].utf8)) else { throw fail("'@node' takes an id: a-z, 0-9 and -") }
      b.kind = .node
      b.node = Array(w[1].utf8)
      b.title = w.count > 2 ? Array(Directives.join(w.dropFirst(2)).utf8) : b.node
      at += 1
      return b
    }
    if l.first == 0x23 {  // #
      let sub = starts(l, "## ")
      guard sub || starts(l, "# ") else { throw fail("a heading is # or ##, then a space") }
      b.kind = sub ? .subheading : .heading
      b.text = trim(Array(l.dropFirst(sub ? 3 : 2)))
      guard !b.text.isEmpty else { throw fail("an empty heading") }
      if !sub && (b.text == Array("NAME".utf8) || b.text == Array("SOURCE".utf8)) {
        throw fail("NAME and SOURCE are made from the header")
      }
      at += 1
      return b
    }
    if starts(l, "  ") { throw fail("a continuation line with nothing to continue") }
    if l.first == 0x7C {  // |
      b.kind = .row
      b.text = Array(l.dropFirst())
      at += 1
      return b
    }
    if starts(l, "- ") {
      b.kind = .item
      b.text = Array(l.dropFirst(2))
      let more = continuation()
      if !more.isEmpty { b.text += [0x0A] + more }
      return b
    }
    if starts(l, ": ") {
      b.kind = .definition
      b.text = trim(Array(l.dropFirst(2)))
      guard !b.text.isEmpty else { throw fail("a definition with no term") }
      b.body = continuation()
      return b
    }
    // A paragraph: lines up to a blank one or another block's start.
    b.text = l
    at += 1
    while at < lines.count && !startsBlock(lines[at]) {
      b.text += [0x0A] + lines[at]
      at += 1
    }
    return b
  }

  /// Whether a line starts a block of its own rather than going on with a paragraph.
  func startsBlock(_ l: [UInt8]) -> Bool {
    guard let c = l.first else { return true }
    return blank(l) || c == 0x40 || c == 0x23 || c == 0x7C || starts(l, "```") || starts(l, "- ")
      || starts(l, ": ") || starts(l, "  ")
  }
}

// --- Bytes ---

func isAlpha(_ c: UInt8) -> Bool { (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) }
func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
func isAlnum(_ c: UInt8) -> Bool { isAlpha(c) || isDigit(c) }
func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A }
/// What a reference's name starts with, and goes on with: a page's or an
/// indexed name's (`Process.start`, `td_wire_init`).
func isNameStart(_ c: UInt8) -> Bool { isAlnum(c) || c == 0x5F }
func isNameChar(_ c: UInt8) -> Bool { isAlnum(c) || c == 0x5F || c == 0x2E || c == 0x2B || c == 0x2D }

func isName(_ s: [UInt8]) -> Bool {
  guard let c = s.first, isNameStart(c) else { return false }
  return s.allSatisfy(isNameChar)
}

/// A page's name: lower case, a letter or digit, then letters, digits, `.`, `_`, `+` or `-`.
func isPageName(_ s: [UInt8]) -> Bool {
  guard let c = s.first, (c >= 0x61 && c <= 0x7A) || isDigit(c) else { return false }
  return s.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || isDigit($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2B || $0 == 0x2D }
}

/// A node's id: lower-case letters, digits and `-`.
func isNodeId(_ s: [UInt8]) -> Bool {
  !s.isEmpty && s.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || isDigit($0) || $0 == 0x2D }
}

func blank(_ l: [UInt8]) -> Bool { l.allSatisfy { $0 == 0x20 || $0 == 0x09 } }

func starts(_ l: [UInt8], _ prefix: StaticString) -> Bool {
  let n = prefix.utf8CodeUnitCount
  guard l.count >= n else { return false }
  return unsafe l.prefix(n).elementsEqual(UnsafeBufferPointer(start: prefix.utf8Start, count: n))
}

func trim(_ s: [UInt8]) -> [UInt8] {
  var lo = 0, hi = s.count
  while lo < hi && isSpace(s[lo]) { lo += 1 }
  while hi > lo && isSpace(s[hi - 1]) { hi -= 1 }
  return Array(s[lo..<hi])
}

/// The line of the first byte that isn't part of well-formed UTF-8, or nil.
func invalidUTF8(_ s: [UInt8]) -> Int? {
  var i = 0, line = 1
  while i < s.count {
    let c = s[i]
    if c == 0x0A { line += 1 }
    if c < 0x80 {
      i += 1
      continue
    }
    let n = c >= 0xF0 && c <= 0xF4 ? 4 : c >= 0xE0 ? (c <= 0xEF ? 3 : 0) : c >= 0xC2 ? 2 : 0
    guard n > 0, i + n <= s.count else { return line }
    for k in 1..<n where s[i + k] & 0xC0 != 0x80 { return line }
    let second = s[i + 1]
    // Overlong forms, surrogates and past U+10FFFF.
    if (c == 0xE0 && second < 0xA0) || (c == 0xED && second > 0x9F) || (c == 0xF0 && second < 0x90)
      || (c == 0xF4 && second > 0x8F) {
      return line
    }
    i += n
  }
  return nil
}
