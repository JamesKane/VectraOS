// SPDX-License-Identifier: BSD-3-Clause

// Link and network addresses (N1b), as integers: compared, hashed into
// arrays and copied without allocation.

/// A 48-bit Ethernet address, in the low bits, the first byte highest.
public struct MACAddress: Equatable, Sendable {
  public var value: UInt64

  public init(_ value: UInt64) { self.value = value & 0xFFFF_FFFF_FFFF }

  public init(_ b: [UInt8], at offset: Int = 0) {
    var v: UInt64 = 0
    for i in 0..<6 { v = v << 8 | UInt64(b[offset + i]) }
    value = v
  }

  public static let broadcast = MACAddress(0xFFFF_FFFF_FFFF)
  public static let zero = MACAddress(0)

  /// Writes the six bytes at `offset`.
  public func write(_ b: inout [UInt8], at offset: Int) {
    for i in 0..<6 { b[offset + i] = UInt8(truncatingIfNeeded: value >> UInt64(8 * (5 - i))) }
  }

  /// Whether the group bit is set (broadcast and multicast).
  public var isGroup: Bool { value >> 40 & 1 == 1 }

  /// "52:54:00:12:34:56".
  public var text: String {
    let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    var s = ""
    for i in 0..<6 {
      let byte = Int(value >> UInt64(8 * (5 - i)) & 0xFF)
      if i > 0 { s.append(":") }
      s.append(digits[byte >> 4])
      s.append(digits[byte & 15])
    }
    return s
  }
}

/// An IPv4 address, the first byte highest.
public struct IPv4Address: Equatable, Sendable {
  public var value: UInt32

  public init(_ value: UInt32) { self.value = value }

  public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
    value = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
  }

  /// Parses "10.0.0.2"; nil if it isn't four decimal bytes.
  public init?(_ text: String) {
    var v: UInt32 = 0, part: UInt32 = 0, digits = 0, parts = 0
    for c in text.utf8 {
      if c == UInt8(ascii: ".") {
        guard digits > 0 else { return nil }
        v = v << 8 | part
        part = 0
        digits = 0
        parts += 1
      } else if c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") {
        part = part * 10 + UInt32(c - UInt8(ascii: "0"))
        digits += 1
        guard part <= 255 && digits <= 3 else { return nil }
      } else {
        return nil
      }
    }
    guard digits > 0 && parts == 3 else { return nil }
    value = v << 8 | part
  }

  public static let any = IPv4Address(0)
  public static let broadcast = IPv4Address(0xFFFF_FFFF)

  /// The mask of a prefix length (0 to 32).
  public static func mask(_ prefixLength: Int) -> UInt32 {
    prefixLength == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefixLength)
  }

  public var text: String {
    "\(value >> 24).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
  }
}

/// An IPv6 address as two 64-bit halves, the first byte highest. IPv4
/// next hops share the neighbour table as IPv4-mapped addresses
/// (::ffff:a.b.c.d, RFC 4291 §2.5.5.2).
public struct IPv6Address: Equatable, Sendable {
  public var hi: UInt64
  public var lo: UInt64

  public init(hi: UInt64, lo: UInt64) {
    self.hi = hi
    self.lo = lo
  }

  public init(_ b: [UInt8], at offset: Int = 0) {
    var h: UInt64 = 0, l: UInt64 = 0
    for i in 0..<8 { h = h << 8 | UInt64(b[offset + i]) }
    for i in 8..<16 { l = l << 8 | UInt64(b[offset + i]) }
    hi = h
    lo = l
  }

  public init(mapping v4: IPv4Address) { self.init(hi: 0, lo: 0xFFFF_0000_0000 | UInt64(v4.value)) }

  public static let any = IPv6Address(hi: 0, lo: 0)
  public static let allNodes = IPv6Address(hi: 0xFF02 << 48, lo: 1)
  public static let allRouters = IPv6Address(hi: 0xFF02 << 48, lo: 2)
  public static let mldv2Routers = IPv6Address(hi: 0xFF02 << 48, lo: 0x16)

  /// fe80::/64 with `interfaceID`.
  public static func linkLocal(_ interfaceID: UInt64) -> IPv6Address {
    IPv6Address(hi: 0xFE80 << 48, lo: interfaceID)
  }

  /// The modified EUI-64 interface ID of a MAC address (RFC 4291
  /// appendix A): ff:fe in the middle, the universal/local bit flipped.
  public static func interfaceID(_ mac: MACAddress) -> UInt64 {
    let m = mac.value
    return ((m >> 24) << 40 | 0xFF_FE00_0000 | (m & 0xFF_FFFF)) ^ (0x02 << 56)
  }

  public func write(_ b: inout [UInt8], at offset: Int) {
    for i in 0..<8 { b[offset + i] = UInt8(truncatingIfNeeded: hi >> UInt64(8 * (7 - i))) }
    for i in 0..<8 { b[offset + 8 + i] = UInt8(truncatingIfNeeded: lo >> UInt64(8 * (7 - i))) }
  }

  /// The IPv4 address this maps, if it is IPv4-mapped.
  public var mappedIPv4: IPv4Address? {
    hi == 0 && lo >> 32 == 0xFFFF ? IPv4Address(UInt32(truncatingIfNeeded: lo)) : nil
  }

  /// fe80::/10.
  public var isLinkLocal: Bool { hi >> 54 == 0x3FA }
  /// ff00::/8.
  public var isMulticast: Bool { hi >> 56 == 0xFF }

  /// Its solicited-node group, ff02::1:ffXX:XXXX (RFC 4291 §2.7.1).
  public var solicitedNode: IPv6Address {
    IPv6Address(hi: 0xFF02 << 48, lo: 0x1_FF00_0000 | (lo & 0xFF_FFFF))
  }

  /// A multicast address's Ethernet group, 33:33 and its last 32 bits
  /// (RFC 2464 §7).
  public var multicastMAC: MACAddress { MACAddress(0x3333_0000_0000 | (lo & 0xFFFF_FFFF)) }

  /// Whether the first `length` bits match `prefix`'s.
  public func hasPrefix(_ prefix: IPv6Address, length: Int) -> Bool {
    if length <= 0 { return true }
    if length <= 64 {
      let m = length == 64 ? ~UInt64(0) : ~(~UInt64(0) >> UInt64(length))
      return hi & m == prefix.hi & m
    }
    let m = length >= 128 ? ~UInt64(0) : ~(~UInt64(0) >> UInt64(length - 64))
    return hi == prefix.hi && lo & m == prefix.lo & m
  }

  func group(_ i: Int) -> UInt16 { UInt16(truncatingIfNeeded: (i < 4 ? hi : lo) >> UInt64(16 * (3 - i % 4))) }

  /// Parses RFC 4291 §2.2's text form (with one "::"; no embedded IPv4).
  public init?(_ text: String) {
    // A leading colon only as "::".
    if text.utf8.first == UInt8(ascii: ":") && !text.utf8.starts(with: "::".utf8) { return nil }
    var groups: [UInt16] = []
    var tail: [UInt16]?
    var value: UInt32 = 0, digits = 0, last: UInt8 = 0
    func push(_ g: UInt16) {
      if tail != nil { tail!.append(g) } else { groups.append(g) }
    }
    for c in text.utf8 {
      if c == UInt8(ascii: ":") {
        if last == UInt8(ascii: ":") {
          guard tail == nil else { return nil }
          tail = []
        } else if digits > 0 {
          push(UInt16(value))
          value = 0
          digits = 0
        } else if last != 0 {
          return nil
        }
      } else {
        let d: UInt8
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): d = c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): d = c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): d = c - UInt8(ascii: "A") + 10
        default: return nil
        }
        value = value << 4 | UInt32(d)
        digits += 1
        guard digits <= 4 else { return nil }
      }
      last = c
    }
    if digits > 0 { push(UInt16(value)) } else if last == UInt8(ascii: ":") && tail == nil { return nil }
    let all: [UInt16]
    if let t = tail {
      guard groups.count + t.count < 8 else { return nil }
      all = groups + [UInt16](repeating: 0, count: 8 - groups.count - t.count) + t
    } else {
      guard groups.count == 8 else { return nil }
      all = groups
    }
    var h: UInt64 = 0, l: UInt64 = 0
    for i in 0..<4 { h = h << 16 | UInt64(all[i]) }
    for i in 4..<8 { l = l << 16 | UInt64(all[i]) }
    hi = h
    lo = l
  }

  /// RFC 5952's form: lowercase, no leading zeros, the longest run of two
  /// or more zero groups (the first, on a tie) as "::".
  public var text: String {
    var best = -1, bestLength = 1, run = -1
    for i in 0...8 {
      if i < 8 && group(i) == 0 {
        if run < 0 { run = i }
      } else if run >= 0 {
        if i - run > bestLength {
          best = run
          bestLength = i - run
        }
        run = -1
      }
    }
    let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    var s = ""
    var i = 0
    while i < 8 {
      if i == best {
        s += "::"
        i += bestLength
        continue
      }
      if i > 0 && i != best + bestLength { s += ":" }
      let g = group(i)
      var started = false
      for shift in stride(from: 12, through: 0, by: -4) {
        let d = Int(g >> UInt16(shift) & 15)
        if d != 0 || started || shift == 0 {
          s.append(digits[d])
          started = true
        }
      }
      i += 1
    }
    return s
  }
}
