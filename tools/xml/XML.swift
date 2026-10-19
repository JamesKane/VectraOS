// SPDX-License-Identifier: BSD-3-Clause

// A small XML reader: enough for protocol and API registries (elements,
// attributes, the five predefined entities and character references,
// comments, the XML declaration). Written from the XML 1.0 specification
// (W3C, fifth edition); text content is kept but not interpreted further.

public struct XMLElement: Sendable {
  public var name: String
  public var attributes: [String: String]
  public var children: [XMLElement]
  /// The element's own text, concatenated (child elements' text excluded).
  public var text: String
  /// Text and child elements in document order: what mixed content such
  /// as `const <type>char</type>* <name>p</name>` needs.
  public var content: [XMLContent] = []

  public func attribute(_ name: String) -> String? { attributes[name] }
  public func elements(_ name: String) -> [XMLElement] { children.filter { $0.name == name } }
  public func element(_ name: String) -> XMLElement? { children.first { $0.name == name } }

  /// All the text inside, in order, through child elements, skipping any
  /// element named in `skipping`.
  public func innerText(skipping: Set<String> = []) -> String {
    var out = ""
    for c in content {
      switch c {
      case .text(let t): out += t
      case .element(let e) where !skipping.contains(e.name): out += e.innerText(skipping: skipping)
      case .element: break
      }
    }
    return out
  }
}

public indirect enum XMLContent: Sendable {
  case text(String)
  case element(XMLElement)
}

public struct XMLError: Error, CustomStringConvertible {
  public let description: String
  public init(description: String) { self.description = description }
}

/// Parses `text` and returns its root element.
public func parseXML(_ text: String) throws(XMLError) -> XMLElement {
  var p = XMLParser(Array(text.utf8))
  return try p.document()
}

struct XMLParser {
  let s: [UInt8]
  var i = 0

  init(_ bytes: [UInt8]) { s = bytes }

  func fail(_ what: String) -> XMLError {
    let line = s[..<min(i, s.count)].reduce(1) { $1 == 0x0a ? $0 + 1 : $0 }
    return XMLError(description: "XML line \(line): \(what)")
  }

  func peek(_ literal: String) -> Bool {
    let b = Array(literal.utf8)
    return i + b.count <= s.count && Array(s[i..<(i + b.count)]) == b
  }

  mutating func skip(until literal: String) throws(XMLError) {
    while i < s.count && !peek(literal) { i += 1 }
    guard i < s.count else { throw fail("expected \(literal)") }
    i += literal.utf8.count
  }

  mutating func skipSpace() { while i < s.count, [0x20, 0x09, 0x0a, 0x0d].contains(s[i]) { i += 1 } }

  /// Skips declarations, comments and whitespace between markup.
  mutating func skipMisc() throws(XMLError) {
    while true {
      skipSpace()
      if peek("<?") { try skip(until: "?>") } else if peek("<!--") { try skip(until: "-->") }
      else if peek("<!DOCTYPE") { try skip(until: ">") } else { return }
    }
  }

  mutating func document() throws(XMLError) -> XMLElement {
    try skipMisc()
    let root = try element()
    try skipMisc()
    guard i == s.count else { throw fail("content after the root element") }
    return root
  }

  mutating func name() throws(XMLError) -> String {
    let start = i
    while i < s.count, !([0x20, 0x09, 0x0a, 0x0d, 0x3d, 0x3e, 0x2f].contains(s[i])) { i += 1 }
    guard i > start else { throw fail("expected a name") }
    return String(decoding: s[start..<i], as: UTF8.self)
  }

  mutating func element() throws(XMLError) -> XMLElement {
    guard i < s.count, s[i] == 0x3c else { throw fail("expected <") }
    i += 1
    var e = XMLElement(name: try name(), attributes: [:], children: [], text: "")
    while true {
      skipSpace()
      guard i < s.count else { throw fail("unterminated tag <\(e.name)>") }
      if peek("/>") {
        i += 2
        return e
      }
      if s[i] == 0x3e {
        i += 1
        break
      }
      let key = try name()
      skipSpace()
      guard i < s.count, s[i] == 0x3d else { throw fail("expected = after \(key)") }
      i += 1
      skipSpace()
      guard i < s.count, s[i] == 0x22 || s[i] == 0x27 else { throw fail("expected a quoted value for \(key)") }
      let quote = s[i]
      i += 1
      let start = i
      while i < s.count && s[i] != quote { i += 1 }
      guard i < s.count else { throw fail("unterminated value for \(key)") }
      e.attributes[key] = try decodeEntities(s[start..<i])
      i += 1
    }
    // Content: text, comments, child elements, then the end tag.
    var text: [UInt8] = []
    var run: [UInt8] = []  // text since the last child, for `content`
    func flushRun(_ e: inout XMLElement, _ run: inout [UInt8], _ p: XMLParser) throws(XMLError) {
      if !run.isEmpty { e.content.append(.text(try p.decodeEntities(run[...]))) }
      run.removeAll()
    }
    while true {
      guard i < s.count else { throw fail("missing </\(e.name)>") }
      if peek("</") {
        i += 2
        let closing = try name()
        guard closing == e.name else { throw fail("</\(closing)> closes <\(e.name)>") }
        skipSpace()
        guard i < s.count, s[i] == 0x3e else { throw fail("expected >") }
        i += 1
        try flushRun(&e, &run, self)
        e.text = try decodeEntities(text[...])
        return e
      }
      if peek("<!--") { try skip(until: "-->"); continue }
      if peek("<![CDATA[") {
        i += 9
        let start = i
        try skip(until: "]]>")
        text += s[start..<(i - 3)]
        run += s[start..<(i - 3)]
        continue
      }
      if s[i] == 0x3c {
        try flushRun(&e, &run, self)
        let child = try element()
        e.children.append(child)
        e.content.append(.element(child))
        continue
      }
      text.append(s[i])
      run.append(s[i])
      i += 1
    }
  }

  func decodeEntities(_ bytes: ArraySlice<UInt8>) throws(XMLError) -> String {
    let raw = String(decoding: bytes, as: UTF8.self)
    guard raw.contains("&") else { return raw }
    var out = ""
    var rest = Substring(raw)
    while let amp = rest.firstIndex(of: "&") {
      out += rest[..<amp]
      guard let semi = rest[amp...].firstIndex(of: ";") else { throw fail("unterminated entity") }
      let entity = rest[rest.index(after: amp)..<semi]
      switch entity {
      case "amp": out += "&"
      case "lt": out += "<"
      case "gt": out += ">"
      case "quot": out += "\""
      case "apos": out += "'"
      default:
        var code: UInt32?
        if entity.hasPrefix("#x") { code = UInt32(entity.dropFirst(2), radix: 16) }
        else if entity.hasPrefix("#") { code = UInt32(entity.dropFirst()) }
        guard let code, let scalar = Unicode.Scalar(code) else { throw fail("unknown entity &\(entity);") }
        out.unicodeScalars.append(scalar)
      }
      rest = rest[rest.index(after: semi)...]
    }
    return out + rest
  }
}
