// SPDX-License-Identifier: BSD-3-Clause

// Directives (D86): the one text format for records, in the style of Plan 9's
// namespace files. One directive a line: its name, then its words, split at
// spaces and tabs; `#` and what follows it are a comment; blank lines are
// skipped. A format names the directives it accepts, and any other stops
// the read with its file and line, never skipped: Plan 9 ignores errors in
// namespace files, and sandboxes come out quietly wrong.
//
// The launcher's manifests, drivers' `driver.manifest` and the manual's page
// headers (guide(6)) are read here; what each directive means is the
// format's. A format's table of names is what its section 6 page is checked
// against.
//
// Read as bytes: String's comparisons and splits need Unicode tables tier 0
// doesn't link.

/// A read that stopped: "file:line: message".
public struct DirectiveError: Error, Equatable, CustomStringConvertible, Sendable {
  public let description: String
  public init(_ description: String) { self.description = description }

  public static func == (a: DirectiveError, b: DirectiveError) -> Bool { a.description.utf8.elementsEqual(b.description.utf8) }
}

public struct Directive: Sendable {
  /// 1-based, in the file.
  public let line: Int
  public let name: String
  public let arguments: [String]

  /// Whether this is directive `name`.
  public func `is`(_ name: StaticString) -> Bool { Directives.same(self.name, name) }
  /// The arguments as one text, single spaces between them.
  public var text: String { Directives.join(arguments[...]) }
}

public enum Directives {
  /// `text`'s directives, in order. `known` holds every name the format
  /// accepts; `firstLine` numbers the text's first line, for a format
  /// whose directives start part way into a file.
  public static func read(_ text: [UInt8], file: String, known: [StaticString],
                          firstLine: Int = 1) throws(DirectiveError) -> [Directive] {
    var out: [Directive] = []
    var line = firstLine - 1
    for raw in lines(text) {
      line += 1
      let words = words(raw)
      guard let name = words.first else { continue }
      guard known.contains(where: { same(name, $0) }) else {
        throw DirectiveError("\(file):\(line): unknown directive '\(name)'")
      }
      out.append(Directive(line: line, name: name, arguments: Array(words.dropFirst())))
    }
    return out
  }

  /// `bytes`' lines, a CR before each LF dropped, the last even without
  /// a newline.
  public static func lines(_ bytes: [UInt8]) -> [[UInt8]] {
    var out: [[UInt8]] = [], line: [UInt8] = []
    for b in bytes {
      if b == 0x0A {
        if line.last == 0x0D { line.removeLast() }
        out.append(line)
        line = []
      } else {
        line.append(b)
      }
    }
    if !line.isEmpty { out.append(line) }
    return out
  }

  /// `text`'s lines as text (bytes: String's split needs Unicode's tables).
  public static func lines(_ text: String) -> [String] {
    lines(Array(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
  }

  /// A line's words: split at spaces and tabs, a `#` and what follows dropped.
  public static func words(_ line: [UInt8]) -> [String] {
    var out: [String] = [], word: [UInt8] = []
    for b in line {
      if b == 0x23 { break }  // #
      if b == 0x20 || b == 0x09 {
        if !word.isEmpty { out.append(String(decoding: word, as: UTF8.self)) }
        word = []
      } else {
        word.append(b)
      }
    }
    if !word.isEmpty { out.append(String(decoding: word, as: UTF8.self)) }
    return out
  }

  /// rc's words: split at blanks (space, tab, CR, LF), a quoted word
  /// ('a b') taken whole and two quotes in it one; nil if a quote is left
  /// open.
  public static func quotedWords(_ bytes: [UInt8]) -> [[UInt8]]? {
    var out: [[UInt8]] = [], word: [UInt8] = []
    var inWord = false, quoting = false
    var i = 0
    while i < bytes.count {
      let c = bytes[i]
      if quoting {
        if c == UInt8(ascii: "'") {
          if i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "'") {
            word.append(c)
            i += 1
          } else {
            quoting = false
          }
        } else {
          word.append(c)
        }
      } else if c == UInt8(ascii: "'") {
        quoting = true
        inWord = true
      } else if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
        if inWord { out.append(word) }
        word = []
        inWord = false
      } else {
        word.append(c)
        inWord = true
      }
      i += 1
    }
    if quoting { return nil }
    if inWord { out.append(word) }
    return out
  }

  /// `words` as one text, single spaces between them.
  public static func join(_ words: ArraySlice<String>) -> String {
    var out: [UInt8] = []
    for w in words {
      if !out.isEmpty { out.append(0x20) }
      out += w.utf8
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// Whether `s` is `literal`, as bytes.
  public static func same(_ s: String, _ literal: StaticString) -> Bool {
    unsafe s.utf8.elementsEqual(UnsafeBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount))
  }
}
