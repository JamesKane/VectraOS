// SPDX-License-Identifier: BSD-3-Clause

// Devicetree source (devicetree specification §6), after the C
// preprocessor: its line markers (`# 12 "file"`) say where each line came
// from. What `vx dtc` reads (D154): `/dts-v1/`, nodes and properties with
// labels, `&label { }` and `&{/path} { }` overrides, `/delete-node/`,
// `/delete-property/`, `/omit-if-no-ref/`, `/include/`, strings, cells
// with C expressions and references, `/bits/` 8, 16, 32 and 64, and byte
// strings. `/memreserve/` and `/plugin/` are refused.

/// Reads `/include/`d files.
public typealias IncludeReader = (_ path: String, _ from: String) -> (contents: String, path: String)?

public struct DtsParser {
  var bytes: [UInt8]
  var at = 0
  var file: String
  var line = 1
  let tree: DtTree
  let include: IncludeReader
  /// Files `/include/` is reading, outermost first, to refuse a loop.
  var including: [String]

  public static func parse(_ source: String, file: String, include: @escaping IncludeReader = { _, _ in nil })
    throws(DtcError) -> DtTree
  {
    var parser = DtsParser(bytes: Array(source.utf8), file: file, tree: DtTree(), include: include, including: [file])
    try parser.parseFile()
    return parser.tree
  }

  var location: SourceLocation { SourceLocation(file: file, line: line) }

  func error(_ message: String) -> DtcError { DtcError(at: location, message: message) }

  // MARK: The file

  mutating func parseFile() throws(DtcError) {
    var sawVersion = false
    while true {
      skipSpace()
      guard at < bytes.count else { break }
      if take("/dts-v1/") {
        try expect(";")
        sawVersion = true
      } else if take("/plugin/") || take("/memreserve/") {
        throw error("/plugin/ and /memreserve/ aren't supported")
      } else if take("/include/") {
        try includeFile()
      } else if take("/delete-node/") {
        skipSpace()
        guard take("&") else { throw error("/delete-node/ at the top level takes a reference") }
        let reference = try parseReference()
        let node = try tree.resolve(reference)
        guard let parent = node.parent else { throw error("can't delete the root") }
        parent.children.removeAll { $0 === node }
        try expect(";")
      } else if take("/omit-if-no-ref/") {
        skipSpace()
        guard take("&") else { throw error("/omit-if-no-ref/ at the top level takes a reference") }
        try tree.resolve(try parseReference()).omitIfNoRef = true
        try expect(";")
      } else if take("/") {
        try parseBody(of: tree.root)
        try expect(";")
      } else if take("&") {
        let node = try tree.resolve(try parseReference())
        try parseBody(of: node)
        try expect(";")
      } else {
        throw error("expected a node, an override or a directive")
      }
    }
    guard sawVersion || including.count > 1 else { throw DtcError(at: nil, message: "\(file): no /dts-v1/") }
  }

  mutating func includeFile() throws(DtcError) {
    skipSpace()
    let name = try parseString()
    try expect(";", optional: true)
    guard let (contents, path) = include(String(decoding: name, as: UTF8.self), file) else {
      throw error("can't read /include/ \"\(String(decoding: name, as: UTF8.self))\"")
    }
    guard !including.contains(path) else { throw error("\(path) includes itself") }
    var inner = DtsParser(bytes: Array(contents.utf8), file: path, tree: tree, include: include,
                          including: including + [path])
    try inner.parseFile()
  }

  // MARK: Nodes

  /// `{ properties and children }` into `node`.
  mutating func parseBody(of node: DtNode) throws(DtcError) {
    try expect("{")
    while true {
      skipSpace()
      if take("}") { return }
      guard at < bytes.count else { throw error("unclosed node '\(node.path)'") }
      if take("/delete-property/") {
        skipSpace()
        let name = try parseName()
        node.properties.removeAll { $0.name == name }
        try expect(";")
        continue
      }
      if take("/delete-node/") {
        skipSpace()
        let name = try parseName()
        node.children.removeAll { $0.name == name }
        try expect(";")
        continue
      }
      if take("/include/") {
        throw error("/include/ inside a node isn't supported")
      }
      var omit = false
      var labels: [String] = []
      while true {
        skipSpace()
        if take("/omit-if-no-ref/") {
          omit = true
          continue
        }
        let mark = (at, line)
        let word = try parseName()
        skipSpace()
        if peek() == UInt8(ascii: ":") {
          at += 1
          guard Self.isLabel(word) else { throw error("bad label '\(word)'") }
          labels.append(word)
          continue
        }
        (at, line) = mark
        break
      }
      let name = try parseName()
      skipSpace()
      if peek() == UInt8(ascii: "{") {
        let child = node.child(making: name)
        child.labels += labels.filter { !child.labels.contains($0) }
        if omit { child.omitIfNoRef = true }
        try parseBody(of: child)
        try expect(";")
      } else {
        guard !omit else { throw error("/omit-if-no-ref/ applies to nodes") }
        var property = DtProperty(name: name)
        if take("=") {
          try parseValue(into: &property)
          while take(",") { try parseValue(into: &property) }
        }
        try expect(";")
        node.set(property)
      }
    }
  }

  // MARK: Values

  mutating func parseValue(into property: inout DtProperty) throws(DtcError) {
    skipLabels()
    skipSpace()
    if peek() == UInt8(ascii: "\"") {
      property.chunks.append(.bytes(try parseString() + [0]))
    } else if take("[") {
      property.chunks.append(.bytes(try parseByteString()))
    } else if take("/bits/") {
      skipSpace()
      let bits = try parseNumber()
      guard [8, 16, 32, 64].contains(bits) else { throw error("/bits/ takes 8, 16, 32 or 64") }
      try expect("<")
      try parseCells(bits: Int(bits), into: &property)
    } else if take("<") {
      try parseCells(bits: 32, into: &property)
    } else if take("&") {
      property.chunks.append(.path(try parseReference()))
    } else {
      throw error("expected a value")
    }
    skipLabels()
  }

  /// Cells up to `>`, already past `<`.
  mutating func parseCells(bits: Int, into property: inout DtProperty) throws(DtcError) {
    var bytes: [UInt8] = []
    func flush() {
      if !bytes.isEmpty { property.chunks.append(.bytes(bytes)) }
      bytes = []
    }
    while true {
      skipLabels()
      skipSpace()
      if take(">") { break }
      if take("&") {
        guard bits == 32 else { throw error("a reference in /bits/ \(bits) cells") }
        flush()
        property.chunks.append(.phandle(try parseReference()))
        continue
      }
      let value: UInt64
      if take("(") {
        value = try parseExpression()
        try expect(")")
      } else if peek() == UInt8(ascii: "'") {
        value = try parseCharacter()
      } else {
        value = try parseNumber()
      }
      let width = bits / 8
      if bits < 64, value >> UInt64(bits) != 0, value >> UInt64(bits - 1) != (UInt64.max >> UInt64(bits - 1)) {
        throw error("\(value) doesn't fit in \(bits) bits")
      }
      for i in (0..<width).reversed() { bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(i * 8))) }
    }
    flush()
  }

  mutating func parseByteString() throws(DtcError) -> [UInt8] {
    var out: [UInt8] = []
    while true {
      skipSpace()
      if take("]") { return out }
      guard let high = hexDigit(peek()), let low = hexDigit(peek(1)) else { throw error("bad byte string") }
      out.append(UInt8(high << 4 | low))
      at += 2
    }
  }

  /// After `&`: a label, or `{/path}`.
  mutating func parseReference() throws(DtcError) -> Reference {
    let where_ = location
    if take("{") {
      let start = at
      while at < bytes.count, bytes[at] != UInt8(ascii: "}") { at += 1 }
      guard at < bytes.count else { throw error("unclosed &{") }
      let path = String(decoding: bytes[start..<at], as: UTF8.self)
      at += 1
      return Reference(target: path, isPath: true, at: where_)
    }
    let start = at
    while at < bytes.count, Self.isLabelByte(bytes[at]) { at += 1 }
    guard at > start else { throw error("expected a label after &") }
    return Reference(target: String(decoding: bytes[start..<at], as: UTF8.self), isPath: false, at: where_)
  }

  mutating func parseString() throws(DtcError) -> [UInt8] {
    try expect("\"")
    var out: [UInt8] = []
    while at < bytes.count {
      let c = bytes[at]
      at += 1
      if c == UInt8(ascii: "\"") { return out }
      if c == UInt8(ascii: "\n") { throw error("unterminated string") }
      if c == UInt8(ascii: "\\") { out.append(try parseEscape()) } else { out.append(c) }
    }
    throw error("unterminated string")
  }

  mutating func parseCharacter() throws(DtcError) -> UInt64 {
    try expect("'")
    guard at < bytes.count else { throw error("unterminated character") }
    let c = bytes[at]
    at += 1
    let value = c == UInt8(ascii: "\\") ? try parseEscape() : c
    try expect("'")
    return UInt64(value)
  }

  mutating func parseEscape() throws(DtcError) -> UInt8 {
    guard at < bytes.count else { throw error("bad escape") }
    let c = bytes[at]
    at += 1
    switch c {
    case UInt8(ascii: "n"): return 10
    case UInt8(ascii: "t"): return 9
    case UInt8(ascii: "r"): return 13
    case UInt8(ascii: "a"): return 7
    case UInt8(ascii: "b"): return 8
    case UInt8(ascii: "v"): return 11
    case UInt8(ascii: "f"): return 12
    case UInt8(ascii: "x"):
      var value = 0, digits = 0
      while digits < 2, let d = hexDigit(peek()) {
        value = value << 4 | d
        at += 1
        digits += 1
      }
      guard digits > 0 else { throw error("bad \\x escape") }
      return UInt8(value)
    case UInt8(ascii: "0")...UInt8(ascii: "7"):
      var value = Int(c - UInt8(ascii: "0")), digits = 1
      while digits < 3, let d = peek(), d >= UInt8(ascii: "0"), d <= UInt8(ascii: "7") {
        value = value << 3 | Int(d - UInt8(ascii: "0"))
        at += 1
        digits += 1
      }
      guard value <= 255 else { throw error("bad octal escape") }
      return UInt8(value)
    default:
      return c
    }
  }

  // MARK: Expressions (C's, on 64-bit unsigned values, as dtc has them)

  mutating func parseExpression() throws(DtcError) -> UInt64 {
    let condition = try parseBinary(0)
    skipSpace()
    guard take("?") else { return condition }
    let yes = try parseExpression()
    try expect(":")
    let no = try parseExpression()
    return condition != 0 ? yes : no
  }

  static let operators: [(String, Int)] = [
    ("||", 1), ("&&", 2), ("|", 3), ("^", 4), ("&", 5), ("==", 6), ("!=", 6), ("<=", 7), (">=", 7),
    ("<<", 8), (">>", 8), ("<", 7), (">", 7), ("+", 9), ("-", 9), ("*", 10), ("/", 10), ("%", 10),
  ]

  /// Operators binding tighter than `minimum`, left to right.
  mutating func parseBinary(_ minimum: Int) throws(DtcError) -> UInt64 {
    var left = try parseUnary()
    while true {
      skipSpace()
      guard let (op, precedence) = Self.operators.first(where: { matches($0.0) }), precedence > minimum,
            !(op == "|" && matches("||")), !(op == "&" && matches("&&")),
            !(op == "<" && matches("<<")), !(op == ">" && matches(">>"))
      else { return left }
      at += op.utf8.count
      let right = try parseBinary(precedence)
      left = try apply(op, left, right)
    }
  }

  func apply(_ op: String, _ a: UInt64, _ b: UInt64) throws(DtcError) -> UInt64 {
    switch op {
    case "||": return a != 0 || b != 0 ? 1 : 0
    case "&&": return a != 0 && b != 0 ? 1 : 0
    case "|": return a | b
    case "^": return a ^ b
    case "&": return a & b
    case "==": return a == b ? 1 : 0
    case "!=": return a != b ? 1 : 0
    case "<": return a < b ? 1 : 0
    case ">": return a > b ? 1 : 0
    case "<=": return a <= b ? 1 : 0
    case ">=": return a >= b ? 1 : 0
    case "<<": return b >= 64 ? 0 : a << b
    case ">>": return b >= 64 ? 0 : a >> b
    case "+": return a &+ b
    case "-": return a &- b
    case "*": return a &* b
    case "/":
      guard b != 0 else { throw error("division by zero") }
      return a / b
    case "%":
      guard b != 0 else { throw error("division by zero") }
      return a % b
    default: throw error("unknown operator \(op)")
    }
  }

  mutating func parseUnary() throws(DtcError) -> UInt64 {
    skipSpace()
    if take("-") { return 0 &- (try parseUnary()) }
    if take("~") { return ~(try parseUnary()) }
    if take("!") { return try parseUnary() == 0 ? 1 : 0 }
    if take("+") { return try parseUnary() }
    if take("(") {
      let value = try parseExpression()
      try expect(")")
      return value
    }
    if peek() == UInt8(ascii: "'") { return try parseCharacter() }
    return try parseNumber()
  }

  /// A C integer: decimal, 0x hex, 0 octal or 0b binary, any U/L suffix.
  mutating func parseNumber() throws(DtcError) -> UInt64 {
    skipSpace()
    let start = at
    while at < bytes.count, Self.isWordByte(bytes[at]) { at += 1 }
    var text = String(decoding: bytes[start..<at], as: UTF8.self).lowercased()
    while text.hasSuffix("u") || text.hasSuffix("l") { text.removeLast() }
    let value: UInt64?
    if text.hasPrefix("0x") {
      value = UInt64(text.dropFirst(2), radix: 16)
    } else if text.hasPrefix("0b") {
      value = UInt64(text.dropFirst(2), radix: 2)
    } else if text.count > 1, text.hasPrefix("0") {
      value = UInt64(text.dropFirst(), radix: 8)
    } else {
      value = UInt64(text, radix: 10)
    }
    guard let value else { throw error(text.isEmpty ? "expected a number" : "bad number '\(text)'") }
    return value
  }

  // MARK: Names and labels

  /// A node or property name: letters, digits and , . _ + * # ? @ -.
  mutating func parseName() throws(DtcError) -> String {
    skipSpace()
    let start = at
    while at < bytes.count, Self.isNameByte(bytes[at]) { at += 1 }
    guard at > start else { throw error("expected a name") }
    return String(decoding: bytes[start..<at], as: UTF8.self)
  }

  /// Labels on values (`label: <1>`), which nothing here keeps.
  mutating func skipLabels() {
    while true {
      skipSpace()
      let mark = (at, line)
      let start = at
      while at < bytes.count, Self.isLabelByte(bytes[at]) { at += 1 }
      if at > start, peek() == UInt8(ascii: ":"), !Self.isDigit(bytes[start]) {
        at += 1
        continue
      }
      (at, line) = mark
      return
    }
  }

  static func isNameByte(_ c: UInt8) -> Bool {
    isLabelByte(c) || ",.+*#?@-".utf8.contains(c)
  }

  static func isLabelByte(_ c: UInt8) -> Bool {
    (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
      || isDigit(c) || c == UInt8(ascii: "_")
  }

  static func isWordByte(_ c: UInt8) -> Bool { isLabelByte(c) }

  static func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }

  static func isLabel(_ word: String) -> Bool {
    guard let first = word.utf8.first, !isDigit(first) else { return false }
    return word.utf8.allSatisfy(isLabelByte)
  }

  func hexDigit(_ c: UInt8?) -> Int? {
    guard let c else { return nil }
    switch c {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(c - UInt8(ascii: "0"))
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(c - UInt8(ascii: "a")) + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(c - UInt8(ascii: "A")) + 10
    default: return nil
    }
  }

  // MARK: Scanning

  func peek(_ ahead: Int = 0) -> UInt8? { at + ahead < bytes.count ? bytes[at + ahead] : nil }

  func matches(_ text: String) -> Bool {
    let t = Array(text.utf8)
    guard at + t.count <= bytes.count else { return false }
    for i in 0..<t.count where bytes[at + i] != t[i] { return false }
    return true
  }

  /// Skips space, then takes `text` if it comes next.
  mutating func take(_ text: String) -> Bool {
    skipSpace()
    guard matches(text) else { return false }
    at += text.utf8.count
    return true
  }

  mutating func expect(_ text: String, optional: Bool = false) throws(DtcError) {
    guard take(text) || optional else { throw error("expected '\(text)'") }
  }

  /// Space, comments and line markers.
  mutating func skipSpace() {
    while at < bytes.count {
      let c = bytes[at]
      if c == UInt8(ascii: "\n") {
        line += 1
        at += 1
        if peek() == UInt8(ascii: "#"), peek(1) == UInt8(ascii: " "), let d = peek(2), Self.isDigit(d) { lineMarker() }
      } else if c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\r") {
        at += 1
      } else if matches("/*") {
        at += 2
        while at < bytes.count, !matches("*/") {
          if bytes[at] == UInt8(ascii: "\n") { line += 1 }
          at += 1
        }
        at = min(at + 2, bytes.count)
      } else if matches("//") {
        while at < bytes.count, bytes[at] != UInt8(ascii: "\n") { at += 1 }
      } else if at == 0, c == UInt8(ascii: "#"), peek(1) == UInt8(ascii: " ") {
        lineMarker()
      } else {
        return
      }
    }
  }

  /// `# LINE "FILE" FLAGS...`: the next line is LINE of FILE.
  mutating func lineMarker() {
    at += 2
    var number = 0
    while let d = peek(), Self.isDigit(d) {
      number = number * 10 + Int(d - UInt8(ascii: "0"))
      at += 1
    }
    if take("\""), case let start = at {
      while at < bytes.count, bytes[at] != UInt8(ascii: "\"") { at += 1 }
      file = String(decoding: bytes[start..<at], as: UTF8.self)
    }
    while at < bytes.count, bytes[at] != UInt8(ascii: "\n") { at += 1 }
    line = number - 1  // the newline ahead counts it
  }
}
