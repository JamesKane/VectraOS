// SPDX-License-Identifier: BSD-3-Clause

// The network database, Plan 9's ndb(6), over NdbFile's entries (its
// format, system/ndb): a `database` entry's `file=` pairs name the files
// that make the database, in order. `ipinfo` gives an address's
// attributes, those its entry lacks taken from the most specific network
// holding it (as ndbipinfo).

@_exported import NdbFile
import Net

extension NdbDatabase {
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

func quoted(_ value: String) -> String { ndbQuoted(value) }

func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
