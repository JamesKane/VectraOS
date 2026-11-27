// SPDX-License-Identifier: BSD-3-Clause

// The GLSL ES 1.00 lexer (the Khronos specification, revision 17, chapter 3): the source's bytes into preprocessing
// tokens (identifiers, pp-numbers, operators and punctuators, and the ends of lines, which the preprocessor's
// directives need), comments replaced by a space. The preprocessor (Preprocessor.swift) turns the stream into the
// parser's.

/// A position in the source, as an info log reports it: the source string, the line and the column (1-based).
struct SourceLocation: Sendable, Equatable {
  var source: Int = 0
  var line: Int = 1
  var column: Int = 1
}

/// What a compile or a link has to say: GL's info log, one line a message, `ERROR: 0:12:5: message`.
struct Diagnostics: Sendable {
  var log = ""
  var errors = 0

  mutating func error(_ at: SourceLocation, _ message: String) {
    errors += 1
    log += "ERROR: \(at.source):\(at.line):\(at.column): \(message)\n"
  }

  mutating func warning(_ at: SourceLocation, _ message: String) {
    log += "WARNING: \(at.source):\(at.line):\(at.column): \(message)\n"
  }

  /// A message with no place in a source (a link's).
  mutating func error(_ message: String) {
    errors += 1
    log += "ERROR: \(message)\n"
  }

  mutating func warning(_ message: String) { log += "WARNING: \(message)\n" }
}

enum TokenKind: UInt8, Sendable {
  case identifier
  /// A preprocessing number: the parser decides whether it is an integer or a float constant, or neither.
  case number
  case punct
  case newline
  case end
}

struct Token: Sendable {
  var kind: TokenKind
  var text: String
  var at: SourceLocation
  /// White space (or a comment) comes before it on its line.
  var space: Bool
  /// The macros whose expansion made it (the preprocessor's hide set).
  var hide: [String] = []

  func `is`(_ s: String) -> Bool { kind == .punct && text == s }
}

/// Splits source bytes into preprocessing tokens. Errors (a character outside the language's set, an unterminated
/// comment) go to `diags`; the offending character is skipped.
struct Lexer {
  private let src: [UInt8]
  private var i = 0
  private var line = 1
  private var lineStart = 0
  private var diags: Diagnostics

  init(_ source: [UInt8], diags: Diagnostics) {
    src = source
    self.diags = diags
  }

  static func isIdentStart(_ c: UInt8) -> Bool { (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95 }
  static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
  static func isIdent(_ c: UInt8) -> Bool { isIdentStart(c) || isDigit(c) }

  private func peek(_ k: Int = 0) -> UInt8 { i + k < src.count ? src[i + k] : 0 }
  private var here: SourceLocation { SourceLocation(source: 0, line: line, column: i - lineStart + 1) }

  private static let threes = [">>=", "<<="]
  private static let twos = [
    "++", "--", "<=", ">=", "==", "!=", "&&", "||", "^^", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<", ">>",
  ]

  /// The tokens, a newline token at each line's end and an end token last; and what was found wrong.
  mutating func run() -> ([Token], Diagnostics) {
    var out: [Token] = []
    var space = false
    while i < src.count {
      let c = src[i]
      // A backslash before a newline continues the line (not in the language's set, but common in programs).
      if c == 92 && (peek(1) == 10 || (peek(1) == 13 && peek(2) == 10)) {
        i += peek(1) == 13 ? 3 : 2
        line += 1
        lineStart = i
        continue
      }
      if c == 10 || c == 13 {
        out.append(Token(kind: .newline, text: "", at: here, space: false))
        i += (c == 13 && peek(1) == 10) ? 2 : 1
        line += 1
        lineStart = i
        space = false
        continue
      }
      if c == 32 || c == 9 || c == 11 || c == 12 {
        i += 1
        space = true
        continue
      }
      if c == 47 && peek(1) == 47 {
        while i < src.count && src[i] != 10 && src[i] != 13 { i += 1 }
        space = true
        continue
      }
      if c == 47 && peek(1) == 42 {
        let start = here
        i += 2
        var closed = false
        while i < src.count {
          if src[i] == 42 && peek(1) == 47 {
            i += 2
            closed = true
            break
          }
          if src[i] == 10 || (src[i] == 13 && peek(1) != 10) {
            line += 1
            lineStart = i + 1
          }
          i += 1
        }
        if !closed { diags.error(start, "unterminated comment") }
        space = true
        continue
      }
      let at = here
      if Lexer.isIdentStart(c) {
        let s = i
        while i < src.count && Lexer.isIdent(src[i]) { i += 1 }
        out.append(Token(kind: .identifier, text: String(decoding: src[s..<i], as: UTF8.self), at: at, space: space))
      } else if Lexer.isDigit(c) || (c == 46 && Lexer.isDigit(peek(1))) {
        // A pp-number: digits, letters, underscores and dots, and a sign after an exponent's e.
        let s = i
        i += 1
        while i < src.count {
          let d = src[i]
          if (d == 43 || d == 45) && (src[i - 1] == 101 || src[i - 1] == 69) && !isHex(s) {
            i += 1
          } else if Lexer.isIdent(d) || d == 46 {
            i += 1
          } else {
            break
          }
        }
        out.append(Token(kind: .number, text: String(decoding: src[s..<i], as: UTF8.self), at: at, space: space))
      } else {
        var text = ""
        for cand in Lexer.threes where matches(cand) { text = cand }
        if text.isEmpty { for cand in Lexer.twos where matches(cand) { text = cand } }
        if text.isEmpty {
          let one: [UInt8] = Array("+-*/%<>=!&|^~?:;,.()[]{}#".utf8)
          if one.contains(c) {
            text = String(decoding: [c], as: UTF8.self)
          } else {
            diags.error(at, c >= 32 && c < 127
              ? "'\(String(decoding: [c], as: UTF8.self))' is not a character of the language" : "character \(c) is not in the language's character set")
            i += 1
            space = true
            continue
          }
        }
        i += text.utf8.count
        out.append(Token(kind: .punct, text: text, at: at, space: space))
      }
      space = false
    }
    out.append(Token(kind: .newline, text: "", at: here, space: false))
    out.append(Token(kind: .end, text: "", at: here, space: false))
    return (out, diags)
  }

  private func isHex(_ s: Int) -> Bool { s + 1 < src.count && src[s] == 48 && (src[s + 1] == 120 || src[s + 1] == 88) }

  private func matches(_ t: String) -> Bool {
    var k = 0
    for b in t.utf8 {
      if peek(k) != b { return false }
      k += 1
    }
    return true
  }
}
