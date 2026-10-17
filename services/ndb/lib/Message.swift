// SPDX-License-Identifier: BSD-3-Clause

// DNS messages (RFC 1035 §4): a header, the questions, and the answer,
// authority and additional records, each record's data decoded for the
// types dns(8) prints and kept as bytes for the rest. Names decode with
// compression (§4.1.4: a pointer must point back, so none loops) and
// encode without it. A name is its labels joined by dots, with no final
// dot; the root is empty.

import Net

/// Record types, and their names as dns(8) reads and writes them
/// (Plan 9's: `ip` is A, `ipv6` AAAA).
public enum DNSType {
  public static let a: UInt16 = 1
  public static let ns: UInt16 = 2
  public static let cname: UInt16 = 5
  public static let soa: UInt16 = 6
  public static let ptr: UInt16 = 12
  public static let hinfo: UInt16 = 13
  public static let mx: UInt16 = 15
  public static let txt: UInt16 = 16
  public static let aaaa: UInt16 = 28
  public static let srv: UInt16 = 33
  public static let all: UInt16 = 255

  static let names: [(UInt16, String)] = [
    (a, "ip"), (ns, "ns"), (cname, "cname"), (soa, "soa"), (ptr, "ptr"), (hinfo, "hinfo"), (mx, "mx"),
    (txt, "txt"), (aaaa, "ipv6"), (srv, "srv"), (all, "all"),
  ]

  /// A type's name, or its number.
  public static func name(_ type: UInt16) -> String {
    names.first { $0.0 == type }?.1 ?? "\(type)"
  }

  /// The type a name (or a number) gives; `any` is `all`.
  public static func parse(_ name: String) -> UInt16? {
    if same(name, "any") { return all }
    if let t = names.first(where: { same($0.1, name) }) { return t.0 }
    return UInt16(name)
  }
}

/// A record's data.
public enum DNSData: Equatable, Sendable {
  /// A or AAAA.
  case address(IPv6Address)
  /// NS, CNAME, PTR: a name.
  case name(String)
  case mx(preference: UInt16, exchange: String)
  case soa(mname: String, rname: String, serial: UInt32, refresh: UInt32, retry: UInt32, expire: UInt32,
           minimum: UInt32)
  case srv(priority: UInt16, weight: UInt16, port: UInt16, target: String)
  /// TXT's strings; HINFO's two.
  case strings([[UInt8]])
  /// Any other type's bytes.
  case raw([UInt8])
}

/// A resource record.
public struct DNSRecord: Equatable, Sendable {
  public var owner: String
  public var type: UInt16
  public var ttl: UInt32
  public var data: DNSData

  public init(_ owner: String, _ type: UInt16, ttl: UInt32, _ data: DNSData) {
    self.owner = owner
    self.type = type
    self.ttl = ttl
    self.data = data
  }

  /// As dns(8) reads it: owner, type, a tab, the data.
  public var text: String {
    let value: String
    switch data {
    case .address(let a): value = addressText(a)
    case .name(let n): value = n
    case .mx(let p, let x): value = "\(p) \(x)"
    case .soa(let m, let r, let serial, let refresh, let retry, let expire, let minimum):
      value = "\(m) \(r) \(serial) \(refresh) \(retry) \(expire) \(minimum)"
    case .srv(let p, let w, let port, let t): value = "\(p) \(w) \(port) \(t)"
    case .strings(let s): value = s.map { String(decoding: $0, as: UTF8.self) }.joined(separator: type == DNSType.hinfo ? " " : "")
    case .raw(let b): value = b.map { hex($0) }.joined()
    }
    return owner + " " + DNSType.name(type) + "\t" + value
  }

  /// As ndb pairs, which cs reads: `dom=owner` (`ptr=owner` for PTR),
  /// then the data's.
  public var pairs: String {
    var s = (type == DNSType.ptr ? "ptr=" : "dom=") + owner
    switch data {
    case .address(let a): s += " ip=" + addressText(a)
    case .name(let n):
      let attr = type == DNSType.ns ? "ns" : type == DNSType.cname ? "cname" : type == DNSType.ptr ? "dom" : "mbox"
      s += " \(attr)=\(n)"
    case .mx(let p, let x): s += " pref=\(p) mx=\(x)"
    case .soa(let m, let r, let serial, let refresh, let retry, let expire, let minimum):
      s += " ns=\(m) mbox=\(r) serial=\(serial) refresh=\(refresh) retry=\(retry) expire=\(expire) ttl=\(minimum)"
    case .srv(let p, let w, let port, let t): s += " pri=\(p) weight=\(w) port=\(port) srv=\(t)"
    case .strings(let strings):
      if type == DNSType.hinfo, strings.count == 2 {
        s += " cpu=\(String(decoding: strings[0], as: UTF8.self)) os=\(String(decoding: strings[1], as: UTF8.self))"
      } else {
        s += " txt=" + quoted(strings.map { String(decoding: $0, as: UTF8.self) }.joined())
      }
    case .raw(let b): s += " " + DNSType.name(type) + "=" + b.map { hex($0) }.joined()
    }
    return s
  }
}

/// A question: a name and a type, class IN.
public struct DNSQuestion: Equatable, Sendable {
  public var name: String
  public var type: UInt16

  public init(_ name: String, _ type: UInt16) {
    self.name = name
    self.type = type
  }
}

/// A message.
public struct DNSMessage: Equatable, Sendable {
  public var id: UInt16
  /// QR, the opcode, AA, TC, RD, RA and the rcode, as on the wire.
  public var flags: UInt16
  public var questions: [DNSQuestion] = []
  public var answers: [DNSRecord] = []
  public var authority: [DNSRecord] = []
  public var additional: [DNSRecord] = []

  public static let response: UInt16 = 0x8000
  public static let authoritative: UInt16 = 0x0400
  public static let truncated: UInt16 = 0x0200
  public static let recursionDesired: UInt16 = 0x0100
  public static let recursionAvailable: UInt16 = 0x0080

  /// Rcodes (RFC 1035 §4.1.1).
  public static let ok: UInt16 = 0
  public static let formatError: UInt16 = 1
  public static let serverFailure: UInt16 = 2
  public static let nameError: UInt16 = 3
  public static let refused: UInt16 = 5

  public init(id: UInt16, flags: UInt16) {
    self.id = id
    self.flags = flags
  }

  /// A recursive query for `name`'s `type`.
  public static func query(id: UInt16, _ name: String, _ type: UInt16) -> DNSMessage {
    var m = DNSMessage(id: id, flags: recursionDesired)
    m.questions = [DNSQuestion(name, type)]
    return m
  }

  public var rcode: UInt16 { flags & 0xF }
  public var isResponse: Bool { flags & DNSMessage.response != 0 }
  public var isTruncated: Bool { flags & DNSMessage.truncated != 0 }

  /// The message on the wire, or nil if a name can't be encoded (a label
  /// empty or over 63 bytes, the name over 255).
  public func encode() -> [UInt8]? {
    var b: [UInt8] = []
    put16(&b, id)
    put16(&b, flags)
    for n in [questions.count, answers.count, authority.count, additional.count] { put16(&b, UInt16(n)) }
    for q in questions {
      guard putName(&b, q.name) else { return nil }
      put16(&b, q.type)
      put16(&b, 1)
    }
    for r in answers + authority + additional {
      guard putName(&b, r.owner) else { return nil }
      put16(&b, r.type)
      put16(&b, 1)
      put32(&b, r.ttl)
      var d: [UInt8] = []
      switch r.data {
      case .address(let a):
        if let v4 = a.mappedIPv4, r.type == DNSType.a {
          put32(&d, v4.value)
        } else {
          var bytes = [UInt8](repeating: 0, count: 16)
          a.write(&bytes, at: 0)
          d = bytes
        }
      case .name(let n):
        guard putName(&d, n) else { return nil }
      case .mx(let p, let x):
        put16(&d, p)
        guard putName(&d, x) else { return nil }
      case .soa(let m, let rn, let serial, let refresh, let retry, let expire, let minimum):
        guard putName(&d, m), putName(&d, rn) else { return nil }
        for v in [serial, refresh, retry, expire, minimum] { put32(&d, v) }
      case .srv(let p, let w, let port, let t):
        put16(&d, p)
        put16(&d, w)
        put16(&d, port)
        guard putName(&d, t) else { return nil }
      case .strings(let strings):
        for s in strings {
          guard s.count < 256 else { return nil }
          d.append(UInt8(s.count))
          d += s
        }
      case .raw(let bytes):
        d = bytes
      }
      guard d.count <= 0xFFFF else { return nil }
      put16(&b, UInt16(d.count))
      b += d
    }
    return b
  }

  /// The message in `bytes`, or nil if it is malformed. Records of
  /// classes other than IN are dropped.
  public init?(decoding bytes: [UInt8]) {
    var r = Reader(bytes)
    guard let id = r.u16(), let flags = r.u16(), let qd = r.u16(), let an = r.u16(), let ns = r.u16(),
      let ar = r.u16()
    else { return nil }
    self.id = id
    self.flags = flags
    for _ in 0..<qd {
      guard let name = r.name(), let type = r.u16(), r.u16() != nil else { return nil }
      questions.append(DNSQuestion(name, type))
    }
    func records(_ n: UInt16) -> [DNSRecord]? {
      var out: [DNSRecord] = []
      for _ in 0..<n {
        guard let owner = r.name(), let type = r.u16(), let klass = r.u16(), let ttl = r.u32(),
          let length = r.u16(), r.at + Int(length) <= r.bytes.count
        else { return nil }
        let end = r.at + Int(length)
        guard let data = r.data(type, end: end), r.at == end else { return nil }
        // A TTL with its top bit set is 0 (RFC 2181 §8).
        if klass == 1 { out.append(DNSRecord(owner, type, ttl: ttl > 0x7FFF_FFFF ? 0 : ttl, data)) }
      }
      return out
    }
    guard let a = records(an), let au = records(ns), let ad = records(ar) else { return nil }
    answers = a
    authority = au
    additional = ad
  }
}

/// Reads a message's fields in order.
struct Reader {
  let bytes: [UInt8]
  var at = 0

  init(_ bytes: [UInt8]) { self.bytes = bytes }

  mutating func u8() -> UInt8? {
    guard at < bytes.count else { return nil }
    defer { at += 1 }
    return bytes[at]
  }

  mutating func u16() -> UInt16? {
    guard at + 2 <= bytes.count else { return nil }
    defer { at += 2 }
    return UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
  }

  mutating func u32() -> UInt32? {
    guard let hi = u16(), let lo = u16() else { return nil }
    return UInt32(hi) << 16 | UInt32(lo)
  }

  /// A name at `at`, following pointers back; `at` ends after it.
  mutating func name() -> String? {
    var labels: [String] = []
    var length = 0
    var p = at
    var jumped = false
    while true {
      guard p < bytes.count else { return nil }
      let n = Int(bytes[p])
      if n & 0xC0 == 0xC0 {
        guard p + 1 < bytes.count else { return nil }
        let target = (n & 0x3F) << 8 | Int(bytes[p + 1])
        // Only back, so it ends.
        guard target < p else { return nil }
        if !jumped { at = p + 2 }
        jumped = true
        p = target
        continue
      }
      guard n & 0xC0 == 0 else { return nil }
      p += 1
      if n == 0 { break }
      guard p + n <= bytes.count else { return nil }
      let label = bytes[p..<p + n]
      // A dot inside a label would read as two.
      guard !label.contains(0x2E) else { return nil }
      length += n + 1
      guard length <= 255 else { return nil }
      labels.append(String(decoding: label, as: UTF8.self))
      p += n
    }
    if !jumped { at = p }
    return labels.joined(separator: ".")
  }

  /// A record's data of `type`, ending at `end`.
  mutating func data(_ type: UInt16, end: Int) -> DNSData? {
    switch type {
    case DNSType.a:
      guard end - at == 4, let v = u32() else { return nil }
      return .address(IPv6Address(mapping: IPv4Address(v)))
    case DNSType.aaaa:
      guard end - at == 16 else { return nil }
      defer { at += 16 }
      return .address(IPv6Address(bytes, at: at))
    case DNSType.ns, DNSType.cname, DNSType.ptr:
      return name().map { .name($0) }
    case DNSType.mx:
      guard let p = u16(), let x = name() else { return nil }
      return .mx(preference: p, exchange: x)
    case DNSType.soa:
      guard let m = name(), let rn = name(), let serial = u32(), let refresh = u32(), let retry = u32(),
        let expire = u32(), let minimum = u32()
      else { return nil }
      return .soa(mname: m, rname: rn, serial: serial, refresh: refresh, retry: retry, expire: expire,
                  minimum: minimum)
    case DNSType.srv:
      guard let p = u16(), let w = u16(), let port = u16(), let t = name() else { return nil }
      return .srv(priority: p, weight: w, port: port, target: t)
    case DNSType.txt, DNSType.hinfo:
      var strings: [[UInt8]] = []
      while at < end {
        guard let n = u8(), at + Int(n) <= end else { return nil }
        strings.append(Array(bytes[at..<at + Int(n)]))
        at += Int(n)
      }
      return .strings(strings)
    default:
      defer { at = end }
      return .raw(Array(bytes[at..<end]))
    }
  }
}

func put16(_ b: inout [UInt8], _ v: UInt16) {
  b.append(UInt8(v >> 8))
  b.append(UInt8(truncatingIfNeeded: v))
}

func put32(_ b: inout [UInt8], _ v: UInt32) {
  put16(&b, UInt16(v >> 16))
  put16(&b, UInt16(truncatingIfNeeded: v))
}

/// `name`'s labels, uncompressed; false if it can't be encoded.
func putName(_ b: inout [UInt8], _ name: String) -> Bool {
  var length = 0
  if !name.isEmpty {
    for label in name.utf8.split(separator: 0x2E, omittingEmptySubsequences: false) {
      guard !label.isEmpty, label.count <= 63 else { return false }
      length += label.count + 1
      b.append(UInt8(label.count))
      b += label
    }
  }
  guard length + 1 <= 255 else { return false }
  b.append(0)
  return true
}

func hex(_ b: UInt8) -> String {
  let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
  return String(digits[Int(b >> 4)]) + String(digits[Int(b & 0xF)])
}

/// The name a reverse lookup asks for: IPv4's in in-addr.arpa, IPv6's
/// nibbles in ip6.arpa (RFC 1035 §3.5, RFC 3596 §2.5).
public func reverseName(_ address: IPv6Address) -> String {
  if let v4 = address.mappedIPv4 {
    let v = v4.value
    return "\(v & 0xFF).\(v >> 8 & 0xFF).\(v >> 16 & 0xFF).\(v >> 24).in-addr.arpa"
  }
  var bytes = [UInt8](repeating: 0, count: 16)
  address.write(&bytes, at: 0)
  let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
  var s = ""
  for b in bytes.reversed() {
    s.append(digits[Int(b & 0xF)])
    s.append(".")
    s.append(digits[Int(b >> 4)])
    s.append(".")
  }
  return s + "ip6.arpa"
}
