// SPDX-License-Identifier: BSD-3-Clause

// IPv6 (RFC 8200) and ICMPv6's echo (RFC 4443), N1b. The interface's
// addresses are a link-local one from the MAC's modified EUI-64 and those
// SLAAC forms from routers' prefixes (NDP.swift), each checked for
// duplicates first. Packets are taken for our valid addresses, all-nodes
// and our solicited-node groups; hop-by-hop and destination options are
// skipped; fragments are counted and dropped. Sent packets go to the
// destination when it's link-local or on an advertised on-link prefix,
// else to a default router; the source is the link-local address for
// link-local and multicast destinations, else a preferred global one.

/// The interface's IPv6 addresses, parallel arrays; `any` is a free slot.
struct IPv6Addresses {
  let capacity: Int
  var addresses: [IPv6Address]
  /// Still being checked for duplicates (RFC 4862 §5.4): not ours yet.
  var tentative: [Bool]
  /// When the duplicate check ends, for a tentative address.
  var dadDeadlines: [Int64]
  /// Lifetimes (Int64.max for none): past `preferredUntil` deprecated,
  /// past `validUntil` gone.
  var validUntil: [Int64]
  var preferredUntil: [Int64]

  init(capacity: Int) {
    self.capacity = capacity
    addresses = [IPv6Address](repeating: .any, count: capacity)
    tentative = [Bool](repeating: false, count: capacity)
    dadDeadlines = [Int64](repeating: 0, count: capacity)
    validUntil = [Int64](repeating: 0, count: capacity)
    preferredUntil = [Int64](repeating: 0, count: capacity)
  }

  func find(_ a: IPv6Address) -> Int? {
    for i in 0..<capacity where addresses[i] == a { return i }
    return nil
  }

  /// A valid (not tentative) address of ours.
  func isOurs(_ a: IPv6Address) -> Bool {
    for i in 0..<capacity where addresses[i] == a && !tentative[i] { return true }
    return false
  }

  mutating func add(_ a: IPv6Address, dadEnds: Int64, validUntil v: Int64, preferredUntil p: Int64) -> Int? {
    for i in 0..<capacity where addresses[i] == .any {
      addresses[i] = a
      tentative[i] = true
      dadDeadlines[i] = dadEnds
      validUntil[i] = v
      preferredUntil[i] = p
      return i
    }
    return nil
  }

  var nextDeadline: Int64? {
    var next: Int64?
    for i in 0..<capacity where addresses[i] != .any {
      let d = tentative[i] ? dadDeadlines[i] : validUntil[i]
      if d != Int64.max && (next == nil || d < next!) { next = d }
    }
    return next
  }
}

/// On-link prefixes from router adverts (RFC 4861 §6.3.4).
struct IPv6Prefixes {
  let capacity: Int
  var prefixes: [IPv6Address]
  /// 0 for a free slot.
  var lengths: [Int]
  var validUntil: [Int64]

  init(capacity: Int) {
    self.capacity = capacity
    prefixes = [IPv6Address](repeating: .any, count: capacity)
    lengths = [Int](repeating: 0, count: capacity)
    validUntil = [Int64](repeating: 0, count: capacity)
  }

  func contains(_ a: IPv6Address) -> Bool {
    for i in 0..<capacity where lengths[i] != 0 && a.hasPrefix(prefixes[i], length: lengths[i]) { return true }
    return false
  }

  var nextDeadline: Int64? {
    var next: Int64?
    for i in 0..<capacity where lengths[i] != 0 && validUntil[i] != Int64.max {
      if next == nil || validUntil[i] < next! { next = validUntil[i] }
    }
    return next
  }
}

/// Default routers (RFC 4861 §6.3.4), by their link-local addresses.
struct IPv6Routers {
  let capacity: Int
  /// `any` for a free slot.
  var addresses: [IPv6Address]
  var until: [Int64]

  init(capacity: Int) {
    self.capacity = capacity
    addresses = [IPv6Address](repeating: .any, count: capacity)
    until = [Int64](repeating: 0, count: capacity)
  }

  var first: IPv6Address? {
    for i in 0..<capacity where addresses[i] != .any { return addresses[i] }
    return nil
  }

  var nextDeadline: Int64? {
    var next: Int64?
    for i in 0..<capacity where addresses[i] != .any {
      if next == nil || until[i] < next! { next = until[i] }
    }
    return next
  }
}

extension InternetChecksum {
  mutating func add(_ a: IPv6Address) {
    add32(UInt32(truncatingIfNeeded: a.hi >> 32))
    add32(UInt32(truncatingIfNeeded: a.hi))
    add32(UInt32(truncatingIfNeeded: a.lo >> 32))
    add32(UInt32(truncatingIfNeeded: a.lo))
  }

  /// The pseudo-header an upper layer's checksum covers over IPv6 (RFC
  /// 8200 §8.1).
  static func ipv6(_ source: IPv6Address, _ destination: IPv6Address, length: Int, next: UInt8) -> InternetChecksum {
    var c = InternetChecksum()
    c.add(source)
    c.add(destination)
    c.add32(UInt32(length))
    c.add16(UInt16(next))
    return c
  }
}

extension NetStack {
  static let ipv6HeaderSize = 40
  static let protocolICMPv6: UInt8 = 58

  /// The interface's valid IPv6 addresses.
  public var ipv6Addresses: [IPv6Address] {
    var out: [IPv6Address] = []
    for i in 0..<ipv6.capacity where ipv6.addresses[i] != .any && !ipv6.tentative[i] { out.append(ipv6.addresses[i]) }
    return out
  }

  /// The link-local address the MAC gives.
  public var linkLocalAddress: IPv6Address { .linkLocal(IPv6Address.interfaceID(mac)) }

  /// Starts IPv6: the link-local address, checked for duplicates, then
  /// routers asked for (RFC 4862 §5.3, §5.4; RFC 4861 §6.3.7). DAD sends
  /// one solicitation and waits a second, with no random delay first.
  public mutating func startIPv6(now: Int64) {
    guard !ipv6Started else { return }
    ipv6Started = true
    beginAddress(linkLocalAddress, validUntil: Int64.max, preferredUntil: Int64.max, now: now)
  }

  /// Adds a tentative address: joins its solicited-node group, reports
  /// the groups (MLDv2), and sends the duplicate check.
  mutating func beginAddress(_ a: IPv6Address, validUntil: Int64, preferredUntil: Int64, now: Int64) {
    guard ipv6.add(a, dadEnds: now + NeighborCache.retry, validUntil: validUntil, preferredUntil: preferredUntil) != nil
    else { return }
    sendMulticastReport(now: now)
    sendDuplicateCheck(a, now: now)
  }

  /// A group's Ethernet address we take: all-nodes, or an address's
  /// solicited-node group.
  func isOurGroup(_ m: MACAddress) -> Bool {
    guard ipv6Started && m.value >> 32 == 0x3333 else { return false }
    if m == IPv6Address.allNodes.multicastMAC { return true }
    for i in 0..<ipv6.capacity where ipv6.addresses[i] != .any {
      if m == ipv6.addresses[i].solicitedNode.multicastMAC { return true }
    }
    return false
  }

  /// Whether a packet to `a` is ours to take: a valid address, all-nodes,
  /// or a solicited-node group of any address (tentative ones' too, for
  /// others' duplicate checks).
  func takesIPv6(_ a: IPv6Address) -> Bool {
    if ipv6.isOurs(a) || a == .allNodes { return true }
    for i in 0..<ipv6.capacity where ipv6.addresses[i] != .any && a == ipv6.addresses[i].solicitedNode { return true }
    return false
  }

  mutating func receiveIPv6(_ f: [UInt8], length: Int, now: Int64) {
    let o = Ethernet.headerSize
    guard ipv6Started else {
      counters.ignored += 1
      return
    }
    guard length >= o + NetStack.ipv6HeaderSize, f[o] >> 4 == 6 else {
      counters.malformed += 1
      return
    }
    let end = o + NetStack.ipv6HeaderSize + Int(f.be16(o + 4))
    guard end <= length else {
      counters.malformed += 1
      return
    }
    let source = IPv6Address(f, at: o + 8), destination = IPv6Address(f, at: o + 24)
    guard !source.isMulticast else {
      counters.malformed += 1
      return
    }
    guard takesIPv6(destination) else {
      counters.ignored += 1
      return
    }
    counters.ipv6In += 1
    var next = f[o + 6]
    var at = o + NetStack.ipv6HeaderSize
    while true {
      switch next {
      case 0, 60:  // hop-by-hop and destination options: skipped
        guard at + 8 <= end else {
          counters.malformed += 1
          return
        }
        next = f[at]
        at += (Int(f[at + 1]) + 1) * 8
        guard at <= end else {
          counters.malformed += 1
          return
        }
      case 44:
        counters.fragments += 1
        return
      case NetStack.protocolICMPv6:
        receiveICMPv6(f, at: at, length: end - at, from: source, to: destination, hopLimit: f[o + 7], now: now)
        return
      case NetStack.protocolTCP:
        receiveTCP6(f, at: at, length: end - at, from: source, to: destination, now: now)
        return
      case NetStack.protocolUDP:
        receiveUDP6(f, at: at, length: end - at, from: source, to: destination, ip: o, ipLength: end - o, now: now)
        return
      default:
        counters.ignored += 1
        return
      }
    }
  }

  /// The source for a packet to `destination`: the link-local address for
  /// link-local and multicast destinations, else a preferred global one,
  /// else any valid one. Nil if none is valid.
  func ipv6Source(for destination: IPv6Address, now: Int64) -> IPv6Address? {
    var fallback: IPv6Address?
    for i in 0..<ipv6.capacity where ipv6.addresses[i] != .any && !ipv6.tentative[i] {
      let a = ipv6.addresses[i]
      if destination.isLinkLocal || destination.isMulticast {
        if a.isLinkLocal { return a }
      } else if !a.isLinkLocal && ipv6.preferredUntil[i] > now {
        return a
      }
      if fallback == nil { fallback = a }
    }
    return fallback
  }

  /// Sends an IPv6 packet: headers here, the payload by `payload` (as
  /// sendIPv4's). With `checksumAt`, the payload's checksum at that
  /// offset is filled in over the pseudo-header. `routerAlert` adds a
  /// hop-by-hop header with the router alert (MLD's, RFC 3810 §5).
  @discardableResult
  mutating func sendIPv6(from source: IPv6Address, to destination: IPv6Address, next: UInt8, hopLimit: UInt8,
                         checksumAt: Int?, routerAlert: Bool = false, now: Int64,
                         payload: (inout [UInt8], Int, Int) -> Int) -> Bool {
    let hop: IPv6Address
    var known: MACAddress?
    if destination.isMulticast {
      hop = destination
      known = destination.multicastMAC
    } else if destination.isLinkLocal || onLink.contains(destination) {
      hop = destination
    } else if let r = routers.first {
      hop = r
    } else {
      return false
    }
    let from = mac, limit = mtu - NetStack.ipv6HeaderSize - (routerAlert ? 8 : 0)
    return send(via: hop, mac: known, now: now) { b, o, to in
      NetStack.buildIPv6(&b, at: o, from: from, to: to, source: source, destination: destination, next: next,
                         hopLimit: hopLimit, checksumAt: checksumAt, routerAlert: routerAlert, limit: limit,
                         payload: payload)
    }
  }

  /// Writes an Ethernet frame holding an IPv6 packet at `o`; its length.
  static func buildIPv6(_ b: inout [UInt8], at o: Int, from: MACAddress, to: MACAddress, source: IPv6Address,
                        destination: IPv6Address, next: UInt8, hopLimit: UInt8, checksumAt: Int?, routerAlert: Bool,
                        limit: Int, payload: (inout [UInt8], Int, Int) -> Int) -> Int {
    Ethernet.writeHeader(&b, at: o, destination: to, source: from, type: Ethernet.typeIPv6)
    let h = o + Ethernet.headerSize
    var body = h + ipv6HeaderSize
    if routerAlert {
      // Next header, length 0 (8 bytes), router alert (type 5, 2 bytes,
      // MLD's value 0), PadN of 0.
      let options: [UInt8] = [next, 0, 5, 2, 0, 0, 1, 0]
      for k in 0..<8 { b[body + k] = options[k] }
      body += 8
    }
    let n = payload(&b, body, limit)
    precondition(n <= limit)
    b[h] = 0x60
    b[h + 1] = 0
    b.put16(0, h + 2)
    b.put16(UInt16(body - h - ipv6HeaderSize + n), h + 4)
    b[h + 6] = routerAlert ? 0 : next
    b[h + 7] = hopLimit
    source.write(&b, at: h + 8)
    destination.write(&b, at: h + 24)
    if let c = checksumAt {
      b.put16(0, body + c)
      var sum = InternetChecksum.ipv6(source, destination, length: n, next: next)
      sum.add(b, body, n)
      // UDP's 0 means "none", which IPv6 forbids: all ones instead.
      let v = sum.value
      b.put16(v == 0 && next == protocolUDP ? 0xFFFF : v, body + c)
    }
    var end = body + n
    while end < o + 60 {
      b[end] = 0
      end += 1
    }
    return end - o
  }

  /// Sends an ICMPv6 message built by `body` (its checksum filled in).
  @discardableResult
  mutating func sendICMPv6(from source: IPv6Address, to destination: IPv6Address, hopLimit: UInt8 = 255,
                           routerAlert: Bool = false, now: Int64, body: (inout [UInt8], Int, Int) -> Int) -> Bool {
    sendIPv6(from: source, to: destination, next: NetStack.protocolICMPv6, hopLimit: hopLimit, checksumAt: 2,
             routerAlert: routerAlert, now: now, payload: body)
  }

  mutating func receiveICMPv6(_ f: [UInt8], at o: Int, length: Int, from source: IPv6Address,
                              to destination: IPv6Address, hopLimit: UInt8, now: Int64) {
    guard length >= 4 else {
      counters.malformed += 1
      return
    }
    var sum = InternetChecksum.ipv6(source, destination, length: length, next: NetStack.protocolICMPv6)
    sum.add(f, o, length)
    guard sum.value == 0 else {
      counters.badChecksums += 1
      return
    }
    switch f[o] {
    case 128: receiveEcho6(f, at: o, length: length, from: source, to: destination, now: now)
    case 130: receiveMulticastQuery(f, at: o, length: length, hopLimit: hopLimit, now: now)
    case 134: receiveRouterAdvert(f, at: o, length: length, from: source, hopLimit: hopLimit, now: now)
    case 135: receiveNeighborSolicitation(f, at: o, length: length, from: source, to: destination, hopLimit: hopLimit,
                                          now: now)
    case 136: receiveNeighborAdvert(f, at: o, length: length, hopLimit: hopLimit, now: now)
    default: counters.ignored += 1
    }
  }

  /// An echo request to one of our addresses (not to a group), answered
  /// from it with the same identifier, sequence and data.
  mutating func receiveEcho6(_ f: [UInt8], at o: Int, length: Int, from source: IPv6Address,
                             to destination: IPv6Address, now: Int64) {
    guard f[o + 1] == 0 && length >= 8 && ipv6.isOurs(destination)
            && length <= mtu - NetStack.ipv6HeaderSize
    else {
      counters.ignored += 1
      return
    }
    let sent = sendICMPv6(from: destination, to: source, hopLimit: hopLimit, now: now) { b, at, _ in
      for k in 0..<length { b[at + k] = f[o + k] }
      b[at] = 129
      return length
    }
    if sent { counters.echoesAnswered += 1 }
  }

  mutating func pollIPv6(now: Int64) {
    guard ipv6Started else { return }
    for i in 0..<ipv6.capacity where ipv6.addresses[i] != .any {
      if ipv6.tentative[i] {
        guard ipv6.dadDeadlines[i] <= now else { continue }
        // No one claimed it: ours. A link-local address now lets us ask
        // for routers.
        ipv6.tentative[i] = false
        if ipv6.addresses[i].isLinkLocal { sendRouterSolicitation(now: now) }
      } else if ipv6.validUntil[i] <= now {
        ipv6.addresses[i] = .any
      }
    }
    for i in 0..<onLink.capacity where onLink.lengths[i] != 0 && onLink.validUntil[i] <= now { onLink.lengths[i] = 0 }
    for i in 0..<routers.capacity where routers.addresses[i] != .any && routers.until[i] <= now {
      routers.addresses[i] = .any
    }
    if let d = nextRouterSolicitation, d <= now { sendRouterSolicitation(now: now) }
  }
}
