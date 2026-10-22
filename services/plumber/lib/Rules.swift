// SPDX-License-Identifier: BSD-3-Clause

// The plumber's rules (V2 item 8, D85): Plan 9's plumb(6) format, after
// todhchai's router (M6k), read as bytes for tier 0 (String's comparisons
// and splits need Unicode tables tier 0 doesn't link). A ruleset is lines
// up to a blank one: patterns, then actions; a message takes the first
// ruleset whose patterns all hold, rewritten as it says.
//
//     # a Swift compiler's file:line, opened in the editor
//     type is text
//     data matches '([a-zA-Z0-9_./-]+\.swift):([0-9]+)(:[0-9]+)?'
//     arg isfile $1
//     data set $file
//     attr add line=$2
//     plumb to edit
//     plumb client edit $file
//
// Objects: src, dst, wdir, type, data, attr, arg. Verbs: `is` (equal; a
// type's `*` is a wildcard: `type is image/*`), `matches` (a regular
// expression over the whole field; its groups are $1-$9, the whole $0),
// `isfile` and `isdir` (the argument, against the message's wdir if
// relative, names one: $file or $dir), `set` (the field gets the
// argument), `add` and `delete` (attributes: `attr add name=value`,
// `attr delete name`; `attr is name=value` holds if the message has it).
// Actions: `plumb to PORT` (deliver there); with no one reading the port,
// `plumb client APP ARG...` starts the app and holds the message until it
// opens the port, `plumb start APP ARG...` starts it and drops the message
// (plumber(4)); never a shell. Arguments may be quoted with '...'; $0-$9,
// $src, $dst, $wdir, $type, $data, $file and $dir are expanded. A line
// `NAME=value` outside a ruleset defines $NAME for those after it.

/// Whether two strings have the same bytes.
func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

/// A message to route.
public struct RouteMessage: Equatable, Sendable {
  public var src: String
  public var dst: String
  public var wdir: String
  public var type: String
  public var data: String
  public var attrs: [(name: String, value: String)]

  public init(src: String = "", dst: String = "", wdir: String = "/", type: String = "text", data: String,
              attrs: [(name: String, value: String)] = [])
  {
    self.src = src
    self.dst = dst
    self.wdir = wdir
    self.type = type
    self.data = data
    self.attrs = attrs
  }

  public func attr(_ name: String) -> String? { attrs.first { same($0.name, name) }?.value }

  public static func == (a: RouteMessage, b: RouteMessage) -> Bool {
    same(a.src, b.src) && same(a.dst, b.dst) && same(a.wdir, b.wdir) && same(a.type, b.type) && same(a.data, b.data)
      && a.attrs.count == b.attrs.count && zip(a.attrs, b.attrs).allSatisfy { same($0.name, $1.name) && same($0.value, $1.value) }
  }
}

/// What routing decided: the message as rewritten, where it goes, and
/// what to start if no one reads the port.
public struct Routed: Equatable, Sendable {
  public var message: RouteMessage
  public var port: String?
  /// `plumb client`: started, the message held until it reads the port.
  public var client: [String]?
  /// `plumb start`: started, the message dropped.
  public var start: [String]?
  /// The ruleset that matched (its first line's number).
  public var line: Int

  public static func == (a: Routed, b: Routed) -> Bool {
    func eq(_ x: [String]?, _ y: [String]?) -> Bool {
      switch (x, y) {
      case (nil, nil): true
      case (let x?, let y?): x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
      default: false
      }
    }
    return a.message == b.message && a.line == b.line && eq(a.client, b.client) && eq(a.start, b.start)
      && eq(a.port.map { [$0] }, b.port.map { [$0] })
  }
}

public struct RuleError: Error, Equatable, CustomStringConvertible, Sendable {
  public let line: Int
  public let message: String
  public init(line: Int, message: String) {
    self.line = line
    self.message = message
  }
  public var description: String { "rules:\(line): \(message)" }
  public static func == (a: Self, b: Self) -> Bool { a.line == b.line && same(a.message, b.message) }
}

/// A rules file, parsed.
public struct Rules: Sendable {
  enum Object: Sendable { case src, dst, wdir, type, data, attr, arg }
  enum Verb: Sendable { case `is`, matches, isfile, isdir, set, add, delete }

  struct Pattern: Sendable {
    var object: Object
    var verb: Verb
    var argument: String
    var regex: Regex?
  }

  struct Ruleset: Sendable {
    var line: Int
    var patterns: [Pattern] = []
    var port: String?
    var client: [String]?
    var start: [String]?
    /// Variables as they stood where it began.
    var variables: [(String, String)]
  }

  var rulesets: [Ruleset] = []

  /// The ports the rules name (`plumb to`), each once, in order.
  public var ports: [String] {
    var out: [String] = []
    for r in rulesets { if let p = r.port, !out.contains(where: { same($0, p) }) { out.append(p) } }
    return out
  }

  public init(_ text: String) throws(RuleError) {
    var variables: [(String, String)] = []
    var current: Ruleset? = nil
    var number = 0
    func finish() {
      if let r = current, !r.patterns.isEmpty || r.port != nil || r.start != nil || r.client != nil {
        rulesets.append(r)
      }
      current = nil
    }
    for raw in Self.lines(Array(text.utf8)) {
      number += 1
      let line = Self.strip(raw)
      if line.isEmpty {
        finish()
        continue
      }
      let words = try Self.words(line, number)
      // NAME=value, outside a ruleset.
      if current == nil, words.count == 1, let eq = words[0].firstIndex(of: UInt8(ascii: "=")), eq != 0 {
        variables.append((Self.text(words[0][..<eq]), Self.text(words[0][(eq + 1)...])))
        continue
      }
      if current == nil { current = Ruleset(line: number, variables: variables) }
      guard words.count >= 2 else { throw RuleError(line: number, message: "a rule needs an object and a verb") }
      let first = Self.text(words[0][...]), second = Self.text(words[1][...])
      if same(first, "plumb") {
        if same(second, "to") {
          guard words.count == 3 else { throw RuleError(line: number, message: "plumb to PORT") }
          current!.port = Self.text(words[2][...])
        } else if same(second, "client") || same(second, "start") {
          guard words.count >= 3 else { throw RuleError(line: number, message: "plumb \(second) APP ARG...") }
          let argv = words.dropFirst(2).map { Self.text($0[...]) }
          if same(second, "client") { current!.client = argv } else { current!.start = argv }
        } else {
          throw RuleError(line: number, message: "plumb what? \(second)")
        }
        continue
      }
      guard let object = Self.object(first) else { throw RuleError(line: number, message: "no object \(first)") }
      guard let verb = Self.verb(second) else { throw RuleError(line: number, message: "no verb \(second)") }
      guard words.count == 3 else { throw RuleError(line: number, message: "\(first) \(second) takes one argument") }
      let argument = Self.text(words[2][...])
      var p = Pattern(object: object, verb: verb, argument: argument, regex: nil)
      if case .matches = verb {
        guard let re = Regex(argument) else { throw RuleError(line: number, message: "a bad expression: \(argument)") }
        p.regex = re
      }
      current!.patterns.append(p)
    }
    finish()
  }

  static func text(_ bytes: ArraySlice<UInt8>) -> String { String(decoding: bytes, as: UTF8.self) }

  static func object(_ s: String) -> Object? {
    let all: [(String, Object)] = [("src", .src), ("dst", .dst), ("wdir", .wdir), ("type", .type), ("data", .data),
                                   ("attr", .attr), ("arg", .arg)]
    return all.first { same($0.0, s) }?.1
  }

  static func verb(_ s: String) -> Verb? {
    let all: [(String, Verb)] = [("is", .is), ("matches", .matches), ("isfile", .isfile), ("isdir", .isdir),
                                 ("set", .set), ("add", .add), ("delete", .delete)]
    return all.first { same($0.0, s) }?.1
  }

  static func lines(_ bytes: [UInt8]) -> [[UInt8]] {
    var out: [[UInt8]] = [], line: [UInt8] = []
    for b in bytes {
      if b == 0x0A {
        out.append(line)
        line = []
      } else {
        line.append(b)
      }
    }
    out.append(line)
    return out
  }

  /// A line without its comment (a `#` not inside quotes), its blanks at
  /// either end gone.
  static func strip(_ line: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var quoted = false
    for b in line {
      if b == UInt8(ascii: "'") { quoted.toggle() }
      if b == UInt8(ascii: "#") && !quoted { break }
      out.append(b)
    }
    while out.last == 0x20 || out.last == 0x09 { out.removeLast() }
    while out.first == 0x20 || out.first == 0x09 { out.removeFirst() }
    return out
  }

  /// Words apart by blanks; '...' quotes (two quotes for one inside).
  static func words(_ line: [UInt8], _ number: Int) throws(RuleError) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var word: [UInt8] = []
    var inWord = false
    var quoted = false
    let chars = line + [0x20]
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if quoted {
        if c == UInt8(ascii: "'") {
          if i + 1 < chars.count && chars[i + 1] == UInt8(ascii: "'") {
            word.append(c)
            i += 1
          } else {
            quoted = false
          }
        } else {
          word.append(c)
        }
      } else if c == UInt8(ascii: "'") {
        quoted = true
        inWord = true
      } else if c == 0x20 || c == 0x09 {
        if inWord { out.append(word) }
        word = []
        inWord = false
      } else {
        word.append(c)
        inWord = true
      }
      i += 1
    }
    if quoted { throw RuleError(line: number, message: "an unclosed quote") }
    return out
  }

  /// Where files are: `kind` says whether a path is a file, a directory,
  /// or nothing (nil).
  public enum FileKind: Sendable { case file, directory }

  /// The message routed by the first ruleset that takes it, nil if none.
  public func route(_ m: RouteMessage, files: (String) -> FileKind? = { _ in nil }) -> Routed? {
    for r in rulesets {
      if let routed = apply(r, m, files) { return routed }
    }
    return nil
  }

  func apply(_ r: Ruleset, _ original: RouteMessage, _ files: (String) -> FileKind?) -> Routed? {
    var m = original
    var groups: [String?] = []
    var file: String?, dir: String?
    func expand(_ s: String) -> String {
      var out: [UInt8] = []
      let chars = Array(s.utf8) + [0]
      var i = 0
      while i < chars.count - 1 {
        guard chars[i] == UInt8(ascii: "$") else {
          out.append(chars[i])
          i += 1
          continue
        }
        var name: [UInt8] = []
        var j = i + 1
        if Self.digit(chars[j]) {
          name.append(chars[j])
          j += 1
        } else {
          while Self.letter(chars[j]) || Self.digit(chars[j]) || chars[j] == UInt8(ascii: "_") {
            name.append(chars[j])
            j += 1
          }
        }
        if name.isEmpty {
          out.append(UInt8(ascii: "$"))
          i += 1
          continue
        }
        let n = Self.text(name[...])
        var value = ""
        if name.count == 1, Self.digit(name[0]) {
          let g = Int(name[0] - UInt8(ascii: "0"))
          value = g < groups.count ? groups[g] ?? "" : ""
        } else if same(n, "src") {
          value = m.src
        } else if same(n, "dst") {
          value = m.dst
        } else if same(n, "wdir") {
          value = m.wdir
        } else if same(n, "type") {
          value = m.type
        } else if same(n, "data") {
          value = m.data
        } else if same(n, "file") {
          value = file ?? ""
        } else if same(n, "dir") {
          value = dir ?? ""
        } else {
          value = r.variables.last { same($0.0, n) }?.1 ?? ""
        }
        out += Array(value.utf8)
        i = j
      }
      return Self.text(out[...])
    }
    func absolute(_ path: String) -> String {
      if path.utf8.first == UInt8(ascii: "/") { return path }
      return m.wdir.utf8.last == UInt8(ascii: "/") ? m.wdir + path : m.wdir + "/" + path
    }
    for p in r.patterns {
      let arg = p.verb == .matches ? p.argument : expand(p.argument)
      switch p.verb {
      case .is:
        if p.object == .attr {
          let a = Array(arg.utf8)
          guard let eq = a.firstIndex(of: UInt8(ascii: "=")), let have = m.attr(Self.text(a[..<eq])),
            same(have, Self.text(a[(eq + 1)...]))
          else { return nil }
        } else if p.object == .type, arg.utf8.last == UInt8(ascii: "*") {
          guard Self.field(m, .type).utf8.starts(with: arg.utf8.dropLast()) else { return nil }
        } else {
          guard same(Self.field(m, p.object), arg) else { return nil }
        }
      case .matches:
        // (Read into a local first: matched straight from the nested
        // function this was, a short `data` arrived corrupt on arm64.)
        let text = Self.field(m, p.object)
        guard let regex = p.regex, let g = regex.matchWhole(text) else { return nil }
        groups = g
      case .isfile:
        let path = absolute(p.object == .arg ? arg : Self.field(m, p.object))
        guard files(path) == .file else { return nil }
        file = path
      case .isdir:
        let path = absolute(p.object == .arg ? arg : Self.field(m, p.object))
        guard files(path) == .directory else { return nil }
        dir = path
      case .set:
        switch p.object {
        case .src: m.src = arg
        case .dst: m.dst = arg
        case .wdir: m.wdir = arg
        case .type: m.type = arg
        case .data, .arg: m.data = arg
        case .attr: m.attrs = Self.pairs(arg)
        }
      case .add:
        guard p.object == .attr else { return nil }
        for pair in Self.pairs(arg) {
          m.attrs.removeAll { same($0.name, pair.name) }
          m.attrs.append(pair)
        }
      case .delete:
        guard p.object == .attr else { return nil }
        m.attrs.removeAll { same($0.name, arg) }
      }
    }
    let port = r.port.map { expand($0) }
    if let port { m.dst = port }
    return Routed(message: m, port: port, client: r.client.map { $0.map { expand($0) } },
                  start: r.start.map { $0.map { expand($0) } }, line: r.line)
  }

  /// The message's field a pattern names (`arg`'s is the data's).
  static func field(_ m: RouteMessage, _ o: Object) -> String {
    switch o {
    case .src: m.src
    case .dst: m.dst
    case .wdir: m.wdir
    case .type: m.type
    case .data, .arg: m.data
    case .attr: ""
    }
  }

  // ASCII only (tier 0 has no Unicode property tables).
  static func digit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
  static func letter(_ c: UInt8) -> Bool {
    (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
  }

  /// `name=value name2=value2`.
  static func pairs(_ s: String) -> [(name: String, value: String)] {
    var out: [(name: String, value: String)] = []
    var word: [UInt8] = []
    for b in Array(s.utf8) + [0x20] {
      guard b == 0x20 || b == 0x09 else {
        word.append(b)
        continue
      }
      if let eq = word.firstIndex(of: UInt8(ascii: "=")) {
        out.append((name: text(word[..<eq]), value: text(word[(eq + 1)...])))
      }
      word = []
    }
    return out
  }
}
