// SPDX-License-Identifier: BSD-3-Clause

// A theme file (D109): ndb(6)'s entries, read as records. A record begins
// at a head pair (theme, role, typeface, part, knob, parts, textscale,
// variant) and takes the pairs after it, up to the next head; a
// `variant=NAME` makes the rest of its entry that variant's. Each record's
// attributes are checked here, so a misspelt one is named with its line.

import NdbFile

/// What went wrong, and where: a file (a theme's name, or a layer's
/// label) and its line, from 1 (0: the file as a whole).
public struct ThemeError: Error, Equatable, Sendable {
  public var file: String
  public var line: Int
  public var message: String

  public init(_ file: String, _ line: Int, _ message: String) {
    self.file = file
    self.line = line
    self.message = message
  }

  /// `file:line: message`, as a compiler gives it.
  public var text: String { line > 0 ? file + ":" + String(line) + ": " + message : file + ": " + message }

  public static func == (a: ThemeError, b: ThemeError) -> Bool {
    a.file.utf8.elementsEqual(b.file.utf8) && a.line == b.line && a.message.utf8.elementsEqual(b.message.utf8)
  }
}

public enum RecordKind: UInt8, Sendable {
  case theme, role, typeface, part, knob, parts, textscale, variant
}

/// One record: its kind, the head's value (a name, mostly), the pairs
/// after the head, and the variant it belongs to, if any.
public struct Record: Sendable {
  public var kind: RecordKind
  public var name: String
  public var pairs: [NdbPair]
  public var line: Int
  public var variant: String?

  /// The last value of `attr`, if it has one.
  public func value(_ attr: String) -> String? {
    pairs.last { $0.attr.utf8.elementsEqual(attr.utf8) }?.value
  }

  /// The line `attr` is on, or the record's.
  public func line(of attr: String) -> Int {
    pairs.last { $0.attr.utf8.elementsEqual(attr.utf8) }?.source ?? line
  }
}

public struct ThemeFile: Sendable {
  /// The file's label in messages: its theme's name, or a layer's.
  public var label: String
  public var records: [Record]

  /// The theme record's name, if the file has one (a layer needn't).
  public var name: String? { records.first { $0.kind == .theme }?.name }
  public var inherits: String? { records.first { $0.kind == .theme }?.value("inherits") }
  public var title: String? { records.first { $0.kind == .theme }?.value("title") }
  /// The variants it names, in order.
  public var variants: [String] {
    var out: [String] = []
    for r in records where r.kind == .variant && !out.contains(where: { same($0, r.name) }) { out.append(r.name) }
    return out
  }

  public init(label: String, records: [Record]) {
    self.label = label
    self.records = records
  }

  public init(parsing text: [UInt8], label: String) throws(ThemeError) {
    self.label = label
    var records: [Record] = []
    for entry in NdbDatabase(parsing: text).entries {
      var variant: String? = nil
      for p in entry.pairs {
        if let kind = headKind(p.attr) {
          if kind == .variant {
            guard ThemeFile.isName(p.value) else { throw ThemeError(label, p.source, "a variant needs a name") }
            variant = p.value
          }
          if kind == .theme, !records.isEmpty || variant != nil {
            throw ThemeError(label, p.source, "theme= must be the file's first record")
          }
          records.append(Record(kind: kind, name: p.value, pairs: [], line: p.source, variant: variant))
          continue
        }
        guard !records.isEmpty else { throw ThemeError(label, p.source, "\(p.attr)= before any record") }
        let r = records[records.count - 1]
        guard ThemeFile.allowed(r.kind).contains(where: { same($0, p.attr) }) else {
          throw ThemeError(label, p.source, "\(kindName(r.kind))=\(r.name) has no attribute \(p.attr)")
        }
        records[records.count - 1].pairs.append(p)
      }
    }
    for r in records {
      switch r.kind {
      case .role, .part, .knob, .parts:
        guard ThemeFile.isName(r.name) || (r.kind == .parts && ThemeFile.isPattern(r.name)) else {
          throw ThemeError(label, r.line, "\(kindName(r.kind))= needs a name, dotted words: not \"\(r.name)\"")
        }
      case .typeface:
        guard fontRole(r.name) != nil else {
          throw ThemeError(label, r.line, "typeface=\(r.name): the roles are display, body, mono and ui")
        }
        guard r.value("family") != nil else { throw ThemeError(label, r.line, "typeface=\(r.name) needs family=") }
      case .theme:
        guard ThemeFile.isName(r.name) else { throw ThemeError(label, r.line, "theme= needs a name") }
      case .textscale, .variant: break
      }
      if r.kind == .role, r.value("color") == nil { throw ThemeError(label, r.line, "role=\(r.name) needs color=") }
      if r.kind == .parts, r.value("from") == nil { throw ThemeError(label, r.line, "parts=\(r.name) needs from=") }
    }
    self.records = records
  }

  /// Roles, parts and knobs are named in dotted words of letters, digits
  /// and hyphens.
  static func isName(_ s: String) -> Bool {
    var last: UInt8 = UInt8(ascii: ".")
    for c in s.utf8 {
      let word = (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
        || c == UInt8(ascii: "-")
      guard word || (c == UInt8(ascii: ".") && last != UInt8(ascii: ".")) else { return false }
      last = c
    }
    return !s.isEmpty && last != UInt8(ascii: ".")
  }

  /// A family of parts: a name, a name and `.*`, or `*`.
  static func isPattern(_ s: String) -> Bool {
    if same(s, "*") { return true }
    guard s.utf8.count > 2, s.utf8.suffix(2).elementsEqual(".*".utf8) else { return false }
    return isName(String(decoding: s.utf8.dropLast(2), as: UTF8.self))
  }

  static func allowed(_ kind: RecordKind) -> [String] {
    switch kind {
    case .theme: ["title", "inherits", "version", "author", "licence"]
    case .role: ["color"]
    case .typeface: ["family", "weight", "width"]
    case .part: partAttributes
    case .knob: ["type", "default", "suggest", "choices", "min", "max", "label", "value"]
    case .parts: ["from"]
    case .textscale: []
    case .variant: ["title"]
    }
  }

  static let partAttributes = [
    "fill", "stroke", "ink", "glowcolor", "border", "radius", "glow", "cuts", "font", "weight", "size",
    "lineheight", "tracking", "case", "padding", "gradient", "angle", "bevel", "bevelwidth", "pattern",
    "patterncolors", "pitch", "shadow", "shadowoffset", "blur",
  ]
}

// Names are compared by their bytes: an Embedded String's == normalizes,
// which needs Unicode's tables.
let heads: [(String, RecordKind)] = [
  ("theme", .theme), ("role", .role), ("typeface", .typeface), ("part", .part), ("knob", .knob),
  ("parts", .parts), ("textscale", .textscale), ("variant", .variant),
]

func headKind(_ attr: String) -> RecordKind? { heads.first { same($0.0, attr) }?.1 }

func kindName(_ kind: RecordKind) -> String {
  switch kind {
  case .theme: "theme"
  case .role: "role"
  case .typeface: "typeface"
  case .part: "part"
  case .knob: "knob"
  case .parts: "parts"
  case .textscale: "textscale"
  case .variant: "variant"
  }
}

let fontRoles: [(String, FontRole)] = [("display", .display), ("body", .body), ("mono", .mono), ("ui", .ui)]

func fontRole(_ name: String) -> FontRole? { fontRoles.first { same($0.0, name) }?.1 }

func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

/// A decimal number (`-12.5`, `0.08`, `3`), or nil.
func parseNumber(_ s: Substring) -> Double? {
  var mantissa: Int64 = 0, scale = 0, digits = 0, negative = false, point = false
  for (i, c) in s.utf8.enumerated() {
    if i == 0, c == UInt8(ascii: "-") {
      negative = true
    } else if c == UInt8(ascii: "."), !point {
      point = true
    } else if c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") {
      guard digits < 18 else { return nil }
      mantissa = mantissa * 10 + Int64(c - UInt8(ascii: "0"))
      digits += 1
      if point { scale += 1 }
    } else {
      return nil
    }
  }
  guard digits > 0 else { return nil }
  // One division, by a power of ten Double holds exactly: correctly rounded.
  var power = 1.0
  for _ in 0..<scale { power *= 10 }
  let v = Double(mantissa) / power
  return negative ? -v : v
}
