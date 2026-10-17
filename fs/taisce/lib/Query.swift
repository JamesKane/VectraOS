// SPDX-License-Identifier: BSD-3-Clause

// Query language v2 (filesystem.md §6): a superset of BFS's infix syntax.
//
//   query   := expr ["order by" attr ["asc" | "desc"]] ["limit" int]
//   expr    := and ("||" and)*
//   and     := not ("&&" not)*
//   not     := "!" not | "(" expr ")" | term
//   term    := attr op literal | attr "in" range | attr "in" "[" literal ("," literal)* "]"
//   op      := "==" | "!=" | "<" | "<=" | ">" | ">=" | "~="
//   range   := literal "..<" literal | literal "..." literal
//   literal := "string" | integer [unit] | decimal | time | true | false
//
// Attributes are names such as `size`, `name`, `MAIL:status` or
// `Audio:Artist`. In a string, `*` and `?` are wildcards (`\*` is a star);
// `~=` compares ignoring case. Units: KiB MiB GiB TiB (1024) and KB MB GB
// TB (1000). Times: `2026-10-09`, `2026-10-09T14:00`, `2026-10-09T14:00:30Z`,
// all UTC.

import TDUnicode

public enum QueryLiteral: Equatable, Sendable {
  case string([UInt8])  // NFC
  /// A string with wildcards.
  case pattern([PatternPiece])
  case int(Int64)
  case double(Double)
  /// Nanoseconds since 1970, UTC.
  case time(Int64)
  case bool(Bool)
}

public enum PatternPiece: Equatable, Sendable {
  case text([UInt8])
  case one  // ?
  case any  // *
}

public enum QueryOp: Equatable, Sendable {
  case equal, notEqual, less, lessOrEqual, greater, greaterOrEqual
  case caseless
  /// `lo..<hi` (or `lo...hi` when `inclusive`).
  case range(inclusive: Bool)
  case list
}

public struct QueryTerm: Equatable, Sendable {
  public var attribute: [UInt8]
  public var op: QueryOp
  public var values: [QueryLiteral]

  public init(attribute: [UInt8], op: QueryOp, values: [QueryLiteral]) {
    self.attribute = attribute
    self.op = op
    self.values = values
  }
}

public indirect enum QueryExpr: Equatable, Sendable {
  case term(QueryTerm)
  case and([QueryExpr])
  case or([QueryExpr])
  case not(QueryExpr)
}

public struct Query: Equatable, Sendable {
  public var expr: QueryExpr
  public var orderBy: [UInt8]?
  public var descending = false
  public var limit: Int?

  /// Parses `text`; a syntax error says at which byte.
  public init(_ text: [UInt8]) throws(TaisceError) {
    var p = QueryParser(text)
    self = try p.query()
  }

  init(expr: QueryExpr, orderBy: [UInt8]?, descending: Bool, limit: Int?) {
    self.expr = expr
    self.orderBy = orderBy
    self.descending = descending
    self.limit = limit
  }
}

struct QueryParser {
  let s: [UInt8]
  var at = 0

  init(_ s: [UInt8]) { self.s = s }

  func fail() -> TaisceError { .badQuery(UInt32(at)) }

  mutating func space() { while at < s.count, s[at] == 0x20 || s[at] == 0x09 || s[at] == 0x0A { at += 1 } }

  mutating func eat(_ token: String) -> Bool {
    space()
    let t = Array(token.utf8)
    guard at + t.count <= s.count, Array(s[at..<(at + t.count)]) == t else { return false }
    // A word must end where the word ends.
    if let last = t.last, Self.isWord(last), at + t.count < s.count, Self.isWord(s[at + t.count]) { return false }
    at += t.count
    return true
  }

  static func isWord(_ b: UInt8) -> Bool {
    (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
  }
  static func isAttribute(_ b: UInt8) -> Bool { isWord(b) || b == 0x3A || b == 0x2D || b == 0x2E }

  mutating func query() throws(TaisceError) -> Query {
    let e = try or()
    var q = Query(expr: e, orderBy: nil, descending: false, limit: nil)
    if eat("order") {
      guard eat("by") else { throw fail() }
      q.orderBy = try attribute()
      if eat("desc") { q.descending = true } else { _ = eat("asc") }
    }
    if eat("limit") {
      guard case .int(let n) = try literal(), n >= 0 else { throw fail() }
      q.limit = Int(n)
    }
    space()
    guard at == s.count else { throw fail() }
    return q
  }

  mutating func or() throws(TaisceError) -> QueryExpr {
    var parts = [try and()]
    while eat("||") { parts.append(try and()) }
    return parts.count == 1 ? parts[0] : .or(parts)
  }

  mutating func and() throws(TaisceError) -> QueryExpr {
    var parts = [try not()]
    while eat("&&") { parts.append(try not()) }
    return parts.count == 1 ? parts[0] : .and(parts)
  }

  mutating func not() throws(TaisceError) -> QueryExpr {
    space()
    if at < s.count, s[at] == 0x21, !(at + 1 < s.count && s[at + 1] == 0x3D) {  // "!" but not "!="
      at += 1
      return .not(try not())
    }
    if eat("(") {
      let e = try or()
      guard eat(")") else { throw fail() }
      return e
    }
    return .term(try term())
  }

  mutating func attribute() throws(TaisceError) -> [UInt8] {
    space()
    let start = at
    while at < s.count, Self.isAttribute(s[at]) { at += 1 }
    guard at > start else { throw fail() }
    return Array(s[start..<at])
  }

  mutating func term() throws(TaisceError) -> QueryTerm {
    let attribute = try attribute()
    if eat("in") {
      if eat("[") {
        var values = [try literal()]
        while eat(",") { values.append(try literal()) }
        guard eat("]") else { throw fail() }
        return QueryTerm(attribute: attribute, op: .list, values: values)
      }
      let lo = try literal()
      let inclusive: Bool
      if eat("..<") { inclusive = false } else if eat("...") { inclusive = true } else { throw fail() }
      return QueryTerm(attribute: attribute, op: .range(inclusive: inclusive), values: [lo, try literal()])
    }
    let op: QueryOp
    if eat("==") { op = .equal } else if eat("!=") { op = .notEqual } else if eat("~=") { op = .caseless }
    else if eat("<=") { op = .lessOrEqual } else if eat(">=") { op = .greaterOrEqual }
    else if eat("<") { op = .less } else if eat(">") { op = .greater }
    else { throw fail() }
    return QueryTerm(attribute: attribute, op: op, values: [try literal()])
  }

  mutating func literal() throws(TaisceError) -> QueryLiteral {
    space()
    guard at < s.count else { throw fail() }
    if s[at] == 0x22 { return try string() }
    if eat("true") { return .bool(true) }
    if eat("false") { return .bool(false) }
    // A date: four digits and a dash.
    if at + 4 < s.count, (at..<(at + 4)).allSatisfy({ s[$0] >= 0x30 && s[$0] <= 0x39 }), s[at + 4] == 0x2D {
      return try time()
    }
    return try number()
  }

  mutating func string() throws(TaisceError) -> QueryLiteral {
    at += 1  // the quote
    var pieces: [PatternPiece] = []
    var text: [UInt8] = []
    var wild = false
    while true {
      guard at < s.count else { throw fail() }
      let b = s[at]
      at += 1
      switch b {
      case 0x22:  // the end
        if !text.isEmpty { pieces.append(.text(text)) }
        if !wild {
          guard let n = TDUnicodeBridge.normalized(text) else { throw fail() }
          return .string(n)
        }
        var normalized: [PatternPiece] = []
        for p in pieces {
          if case .text(let t) = p {
            guard let n = TDUnicodeBridge.normalized(t) else { throw fail() }
            normalized.append(.text(n))
          } else {
            normalized.append(p)
          }
        }
        return .pattern(normalized)
      case 0x5C:  // a backslash: the next byte as itself
        guard at < s.count else { throw fail() }
        text.append(s[at])
        at += 1
      case 0x2A, 0x3F:  // * and ?
        wild = true
        if !text.isEmpty {
          pieces.append(.text(text))
          text = []
        }
        pieces.append(b == 0x2A ? .any : .one)
      default:
        text.append(b)
      }
    }
  }

  mutating func number() throws(TaisceError) -> QueryLiteral {
    let start = at
    var negative = false
    if at < s.count, s[at] == 0x2D {
      negative = true
      at += 1
    }
    var whole: Int64 = 0
    var digits = 0
    while at < s.count, s[at] >= 0x30, s[at] <= 0x39 {
      let (m, o1) = whole.multipliedReportingOverflow(by: 10)
      let (a, o2) = m.addingReportingOverflow(Int64(s[at] - 0x30))
      guard !o1, !o2 else { throw fail() }
      whole = a
      digits += 1
      at += 1
    }
    guard digits > 0 else {
      at = start
      throw fail()
    }
    var fraction = 0.0
    var decimal = false
    if at + 1 < s.count, s[at] == 0x2E, s[at + 1] >= 0x30, s[at + 1] <= 0x39 {  // a decimal
      decimal = true
      at += 1
      var scale = 0.1
      while at < s.count, s[at] >= 0x30, s[at] <= 0x39 {
        fraction += Double(s[at] - 0x30) * scale
        scale /= 10
        at += 1
      }
    }
    // A unit, on a whole number or a decimal ("4.5MB").
    let units: [(String, Int64)] = [("KiB", 1 << 10), ("MiB", 1 << 20), ("GiB", 1 << 30), ("TiB", 1 << 40),
                                    ("KB", 1000), ("MB", 1_000_000), ("GB", 1_000_000_000), ("TB", 1_000_000_000_000)]
    var factor: Int64 = 1
    for (name, f) in units where eat(name) {
      factor = f
      break
    }
    if decimal {
      let v = (Double(whole) + fraction) * Double(factor)
      let signed = negative ? -v : v
      // A whole product is an integer: 4.5MB is 4,500,000 bytes.
      if factor > 1, signed == Double(Int64(signed)) { return .int(Int64(signed)) }
      return .double(signed)
    }
    let (v, o) = whole.multipliedReportingOverflow(by: factor)
    guard !o else { throw fail() }
    whole = v
    return .int(negative ? -whole : whole)
  }

  mutating func digits(_ n: Int) throws(TaisceError) -> Int64 {
    guard at + n <= s.count else { throw fail() }
    var v: Int64 = 0
    for _ in 0..<n {
      guard s[at] >= 0x30, s[at] <= 0x39 else { throw fail() }
      v = v * 10 + Int64(s[at] - 0x30)
      at += 1
    }
    return v
  }
  mutating func expect(_ b: UInt8) throws(TaisceError) {
    guard at < s.count, s[at] == b else { throw fail() }
    at += 1
  }

  /// `YYYY-MM-DD[THH:MM[:SS]][Z]`, UTC, as nanoseconds since 1970.
  mutating func time() throws(TaisceError) -> QueryLiteral {
    let y = try digits(4)
    try expect(0x2D)
    let m = try digits(2)
    try expect(0x2D)
    let d = try digits(2)
    var hh: Int64 = 0, mm: Int64 = 0, ss: Int64 = 0
    if at < s.count, s[at] == 0x54 {  // T
      at += 1
      hh = try digits(2)
      try expect(0x3A)
      mm = try digits(2)
      if at < s.count, s[at] == 0x3A {
        at += 1
        ss = try digits(2)
      }
    }
    if at < s.count, s[at] == 0x5A { at += 1 }  // Z
    guard (1...12).contains(m), (1...31).contains(d), hh < 24, mm < 60, ss < 61 else { throw fail() }
    // Days from the civil date (Howard Hinnant's algorithm).
    let yy = m <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146_097 + doe - 719_468
    return .time(((days * 24 + hh) * 60 + mm) * 60_000_000_000 + ss * 1_000_000_000)
  }
}

/// TDUnicode through one door, so the parser reads plainly.
enum TDUnicodeBridge {
  static func normalized(_ s: [UInt8]) -> [UInt8]? { TDUnicode.Text.normalized(s) }
}
