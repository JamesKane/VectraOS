// SPDX-License-Identifier: BSD-3-Clause

// The network database, Plan 9's ndb(6): entries of attribute=value
// pairs, each beginning at a line's left margin and going on over the
// indented lines after it. A value with white space is quoted ("a b"); an
// attribute may have no value; `#` begins a comment. A `database` entry's
// `file=` pairs name the files that make the database, in order.
//
//     sys=gate ip=10.0.2.2
//     ipnet=lab ip=10.0.2.0 ipmask=255.255.255.0
//         ipgw=10.0.2.2 dns=10.0.2.3
//
// `search` finds the entries holding a pair, `value` one attribute of the
// first that has it (on the matching line first, as ndbgetvalue), and
// `ipinfo` an address's attributes, those its entry lacks taken from the
// most specific network holding it (as ndbipinfo).

import Net

/// One attribute=value pair, and which of its entry's lines it is on.
public struct NdbPair: Equatable, Sendable {
  public var attr: String
  public var value: String
  public var line: Int

  public init(_ attr: String, _ value: String, line: Int = 0) {
    self.attr = attr
    self.value = value
    self.line = line
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
      let text = p.attr + "=" + quoted(p.value)
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
    for raw in text.split(separator: 0x0A, omittingEmptySubsequences: false) {
      let bytes = Array(raw)
      // A line at the margin begins an entry; a comment there doesn't.
      if let first = bytes.first, !white(first), first != 0x23, !current.isEmpty {
        entries.append(NdbEntry(current))
        current = []
        line = 0
      }
      let pairs = parseLine(bytes)
      guard !pairs.isEmpty else { continue }
      current += pairs.map { NdbPair($0.attr, $0.value, line: line) }
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

  /// `attrs`' values for `address` (an IPv4 or IPv6 address): from its
  /// own entries (`ip=address`), then each attribute none of those has
  /// from the most specific network (`ipnet`, `ip`, `ipmask`) holding
  /// the address that has it. Each attribute's values, in order.
  public func ipinfo(_ address: String, _ attrs: [String]) -> [NdbPair] {
    guard let ip = parseIP(address) else { return [] }
    var found: [NdbPair] = []
    var missing = attrs
    func take(_ e: NdbEntry) {
      var got: [String] = []
      for a in missing where !e.values(a).isEmpty {
        found += e.values(a).map { NdbPair(a, $0) }
        got.append(a)
      }
      missing.removeAll { a in got.contains { same($0, a) } }
    }
    for e in entries where e.has("ip", address) { take(e) }
    // The networks holding it, the longest prefix first.
    var networks: [(prefix: Int, entry: NdbEntry)] = []
    for e in entries where e.value("ipnet") != nil {
      guard let netText = e.value("ip"), let net = parseIP(netText) else { continue }
      let prefix = e.value("ipmask").flatMap { maskPrefix($0, v4: net.mappedIPv4 != nil) }
        ?? defaultPrefix(net)
      if ip.hasPrefix(net, length: prefix) { networks.append((prefix, e)) }
    }
    networks.sort { $0.prefix > $1.prefix }
    for n in networks where !missing.isEmpty { take(n.entry) }
    return found
  }
}

/// An address as IPv6 (IPv4 mapped), or nil.
public func parseIP(_ text: String) -> IPv6Address? {
  if let v4 = IPv4Address(text) { return IPv6Address(mapping: v4) }
  return IPv6Address(text)
}

/// An address as Plan 9 prints it: IPv4 dotted, IPv6 as RFC 5952 has it.
public func addressText(_ a: IPv6Address) -> String { a.mappedIPv4.map { $0.text } ?? a.text }

/// A mask's prefix over IPv6's 128 bits: dotted (`255.255.255.0`, IPv4's,
/// so 96 more) or `/n` (IPv6's bits, or IPv4's if `v4` and n <= 32).
func maskPrefix(_ text: String, v4: Bool) -> Int? {
  if text.utf8.first == 0x2F {
    guard let n = Int(String(decoding: text.utf8.dropFirst(), as: UTF8.self)), n >= 0, n <= 128 else { return nil }
    return v4 && n <= 32 ? 96 + n : n
  }
  guard let m = IPv4Address(text) else { return nil }
  return 96 + (~m.value).leadingZeroBitCount  // its leading ones
}

/// A network's default prefix: IPv4's class (A /8, B /16, C /24), or
/// IPv6's /64.
func defaultPrefix(_ net: IPv6Address) -> Int {
  guard let v4 = net.mappedIPv4 else { return 64 }
  let top = v4.value >> 24
  return 96 + (top < 128 ? 8 : top < 192 ? 16 : 24)
}

/// Plan 9's ipattr: what kind of name `name` is, `ip` (an address), `dom`
/// (a domain name, with a dot) or `sys`.
public func ipattr(_ name: String) -> String {
  var dot = false, alpha = false, colon = false, hex = false
  for c in name.utf8 {
    switch c {
    case 0x30...0x39: continue
    case 0x61...0x66, 0x41...0x46: hex = true
    case 0x67...0x7A, 0x47...0x5A, 0x2D: alpha = true
    case 0x2E: dot = true
    case 0x3A: colon = true
    default: return "sys"
    }
  }
  if alpha { return dot ? "dom" : "sys" }
  if colon { return "ip" }
  return dot && !hex ? "ip" : "sys"
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

func white(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D }

func quoted(_ value: String) -> String {
  value.utf8.contains { white($0) || $0 == 0x23 } ? "\"" + value + "\"" : value
}

func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
