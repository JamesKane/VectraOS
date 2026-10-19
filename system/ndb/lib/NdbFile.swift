// SPDX-License-Identifier: BSD-3-Clause

// ndb(6)'s format, the system's one rules syntax (D109): entries of
// attribute=value pairs, each beginning at a line's left margin and going
// on over the indented lines after it. A value with white space is quoted
// ("a b"); an attribute may have no value; `#` begins a comment. The
// network database (services/ndb) and the themes (ui/theme) read it.
//
//     sys=gate ip=10.0.2.2 vendor="QEMU user network"
//     ipnet=lab ip=10.0.2.0 ipmask=255.255.255.0
//         ipgw=10.0.2.2 dns=10.0.2.3
//     theme=neon-tab title="Neon Tab" inherits=base
//     typeface=body family="IBM Plex Sans" weight=400
//
// A quoted value ends at its closing quote and has no escapes, so it
// can't hold a quote itself.
//
// `search` finds the entries holding a pair, and `value` one attribute
// of the first that has it (on the matching line first, as ndbgetvalue).

/// One attribute=value pair, which of its entry's lines it is on, and
/// which line of its file (from 1), for a reader's messages.
public struct NdbPair: Equatable, Sendable {
  public var attr: String
  public var value: String
  public var line: Int
  public var source: Int

  public init(_ attr: String, _ value: String, line: Int = 0, source: Int = 0) {
    self.attr = attr
    self.value = value
    self.line = line
    self.source = source
  }

  /// The same attribute, value and line; where it came from doesn't count.
  public static func == (a: NdbPair, b: NdbPair) -> Bool {
    same(a.attr, b.attr) && same(a.value, b.value) && a.line == b.line
  }
}

/// An entry: its pairs, in order.
public struct NdbEntry: Equatable, Sendable {
  public var pairs: [NdbPair]

  public init(_ pairs: [NdbPair]) { self.pairs = pairs }

  /// Whether it holds `attr=value`.
  public func has(_ attr: String, _ value: String) -> Bool {
    pairs.contains { same($0.attr, attr) && same($0.value, value) }
  }

  /// `attr`'s first value, on `line` if it is there.
  public func value(_ attr: String, preferring line: Int? = nil) -> String? {
    if let line, let p = pairs.first(where: { $0.line == line && same($0.attr, attr) }) { return p.value }
    return pairs.first { same($0.attr, attr) }?.value
  }

  /// All of `attr`'s values.
  public func values(_ attr: String) -> [String] { pairs.filter { same($0.attr, attr) }.map { $0.value } }

  /// Its lines, each as `attr=value` pairs a space apart (a value with
  /// white space or `#` quoted), as cs gives them.
  public var lines: [String] {
    var out: [String] = []
    var line = -1
    for p in pairs {
      let text = p.attr + "=" + ndbQuoted(p.value)
      if p.line != line {
        out.append(text)
        line = p.line
      } else {
        out[out.count - 1] += " " + text
      }
    }
    return out
  }
}

/// A database: the entries of its files, in order.
public struct NdbDatabase: Sendable {
  public var entries: [NdbEntry]

  public init(_ entries: [NdbEntry] = []) { self.entries = entries }

  /// The entries in `text`.
  public init(parsing text: [UInt8]) {
    var entries: [NdbEntry] = []
    var current: [NdbPair] = []
    var line = 0
    for (n, raw) in text.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
      let bytes = Array(raw)
      // A line at the margin begins an entry; a comment there doesn't.
      if let first = bytes.first, !white(first), first != 0x23, !current.isEmpty {
        entries.append(NdbEntry(current))
        current = []
        line = 0
      }
      let pairs = parseLine(bytes)
      guard !pairs.isEmpty else { continue }
      current += pairs.map { NdbPair($0.attr, $0.value, line: line, source: n + 1) }
      line += 1
    }
    if !current.isEmpty { entries.append(NdbEntry(current)) }
    self.entries = entries
  }

  /// The files a `database` entry names, if one does.
  public var files: [String] {
    entries.first { $0.pairs.first.map { same($0.attr, "database") } ?? false }?.values("file") ?? []
  }

  public static func + (a: NdbDatabase, b: NdbDatabase) -> NdbDatabase { NdbDatabase(a.entries + b.entries) }

  /// The entries holding `attr=value`.
  public func search(_ attr: String, _ value: String) -> [NdbEntry] { entries.filter { $0.has(attr, value) } }

  /// `want`'s value in the first entry holding `attr=value` that has one,
  /// from the line `attr=value` is on if it is there.
  public func value(_ attr: String, _ value: String, want: String) -> String? {
    for e in entries {
      guard let match = e.pairs.first(where: { same($0.attr, attr) && same($0.value, value) }) else { continue }
      if let v = e.value(want, preferring: match.line) { return v }
    }
    return nil
  }
}

/// The pairs on one line, a comment and all after it dropped.
public func parseLine(_ line: [UInt8]) -> [NdbPair] {
  var pairs: [NdbPair] = []
  var i = 0
  let n = line.count
  while true {
    while i < n, white(line[i]) { i += 1 }
    guard i < n, line[i] != 0x23 else { break }
    let start = i
    while i < n, line[i] != 0x3D, !white(line[i]) { i += 1 }
    let attr = String(decoding: line[start..<i], as: UTF8.self)
    while i < n, white(line[i]) { i += 1 }
    var value = ""
    if i < n, line[i] == 0x3D {
      i += 1
      if i < n, line[i] == 0x22 {  // "quoted"
        i += 1
        let s = i
        while i < n, line[i] != 0x22 { i += 1 }
        value = String(decoding: line[s..<i], as: UTF8.self)
        if i < n { i += 1 }
      } else if i < n, line[i] != 0x23 {
        let s = i
        while i < n, !white(line[i]) { i += 1 }
        value = String(decoding: line[s..<i], as: UTF8.self)
      }
    }
    pairs.append(NdbPair(attr, value))
  }
  return pairs
}

/// A value as it is written: quoted if it holds white space or `#`.
public func ndbQuoted(_ value: String) -> String {
  value.utf8.contains { white($0) || $0 == 0x23 } ? "\"" + value + "\"" : value
}

func white(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D }

func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
