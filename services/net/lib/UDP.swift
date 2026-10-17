// SPDX-License-Identifier: BSD-3-Clause

// UDP (RFC 768) over IPv4 and IPv6 (RFC 8200 §8.1), N1b. Endpoints are
// bound to a port (any address of ours); their datagrams wait in fixed
// slots, a ring each, until read, and a full ring drops the newest. One
// address type serves both families: IPv4 peers are IPv4-mapped IPv6
// addresses, as in the neighbour cache.
//
// Checksums are always sent (0 goes out as all ones); one of 0 is taken
// over IPv4 (none sent) and refused over IPv6, where it's mandatory. A
// datagram for a closed port gets ICMP's port unreachable (RFC 1122
// §4.1.3.1, RFC 4443 §3.1), unless it was sent to a group, at most ten a
// second. Port 68 is the DHCP client's (DHCP.swift) while it runs.

/// A datagram read from an endpoint.
public struct UDPDatagram: Equatable, Sendable {
  public var source: IPv6Address
  public var sourcePort: UInt16
  /// The address of ours it was sent to (a group's or a broadcast's too).
  public var destination: IPv6Address
  public var length: Int
}

struct UDPEndpoints {
  let capacity: Int
  let slots: Int
  /// The bound port; 0 for a free endpoint.
  var ports: [UInt16]
  /// Each endpoint's ring: its first queued slot and how many.
  var heads: [Int]
  var counts: [Int]
  /// Every endpoint's slots, `slots` each, FrameQueue.slotSize bytes a slot.
  var bytes: [UInt8]
  var datagrams: [UDPDatagram]
  var nextEphemeral: UInt16 = 49152

  init(capacity: Int, slots: Int) {
    self.capacity = capacity
    self.slots = slots
    ports = [UInt16](repeating: 0, count: capacity)
    heads = [Int](repeating: 0, count: capacity)
    counts = [Int](repeating: 0, count: capacity)
    bytes = [UInt8](repeating: 0, count: capacity * slots * FrameQueue.slotSize)
    datagrams = [UDPDatagram](repeating: UDPDatagram(source: .any, sourcePort: 0, destination: .any, length: 0),
                              count: capacity * slots)
  }

  func find(_ port: UInt16) -> Int? {
    for i in 0..<capacity where ports[i] == port { return i }
    return nil
  }

  /// Slot `k` of endpoint `e`, as an index into `datagrams`.
  func slot(_ e: Int, _ k: Int) -> Int { e * slots + (heads[e] + k) % slots }
}

extension NetStack {
  static let protocolUDP: UInt8 = 17
  static let udpHeaderSize = 8
  static let dhcpClientPort: UInt16 = 68
  static let icmpErrorInterval: Int64 = 100_000_000

  // MARK: Endpoints

  /// Binds an endpoint to `port` (0: a free one from 49152 up). Its
  /// handle, or nil if the port is taken or no endpoint is free.
  public mutating func openUDP(port: UInt16 = 0) -> Int? {
    var p = port
    if p == 0 {
      for _ in 0..<16384 {
        let candidate = udp.nextEphemeral
        udp.nextEphemeral = udp.nextEphemeral == UInt16.max ? 49152 : udp.nextEphemeral + 1
        if udp.find(candidate) == nil && candidate != NetStack.dhcpClientPort {
          p = candidate
          break
        }
      }
    }
    guard p != 0, udp.find(p) == nil, !(p == NetStack.dhcpClientPort && dhcp.state != .off),
          let e = udp.find(0)
    else { return nil }
    udp.ports[e] = p
    udp.heads[e] = 0
    udp.counts[e] = 0
    return e
  }

  public func udpPort(_ e: Int) -> UInt16 { udp.ports[e] }

  public mutating func closeUDP(_ e: Int) {
    udp.ports[e] = 0
    udp.counts[e] = 0
  }

  /// Datagrams waiting on endpoint `e`.
  public func waitingUDP(_ e: Int) -> Int { udp.counts[e] }

  /// Reads the oldest datagram waiting on `e` into `buffer` (from its
  /// start; it must hold FrameQueue.slotSize bytes), or nil if none.
  public mutating func receiveUDP(_ e: Int, into buffer: inout [UInt8]) -> UDPDatagram? {
    guard udp.ports[e] != 0 && udp.counts[e] > 0 else { return nil }
    let s = udp.slot(e, 0)
    let d = udp.datagrams[s]
    let from = s * FrameQueue.slotSize
    for k in 0..<d.length { buffer[k] = udp.bytes[from + k] }
    udp.heads[e] = (udp.heads[e] + 1) % udp.slots
    udp.counts[e] -= 1
    return d
  }

  /// Sends `count` bytes of `data` from `offset` from endpoint `e` to
  /// `port` at `destination` (IPv4-mapped for IPv4). False if there's no
  /// route, no source address, no room, or it's too big for one packet.
  @discardableResult
  public mutating func sendUDP(_ e: Int, to destination: IPv6Address, port: UInt16, _ data: [UInt8], offset: Int = 0,
                               count: Int? = nil, now: Int64) -> Bool {
    let n = count ?? data.count - offset
    return sendUDP(from: udp.ports[e], to: destination, port: port, length: n, now: now) { b, at in
      for k in 0..<n { b[at + k] = data[offset + k] }
    }
  }

  /// Sends a datagram whose `length` bytes `body` writes (the bytes,
  /// where they start).
  mutating func sendUDP(from sourcePort: UInt16, to destination: IPv6Address, port: UInt16, length n: Int,
                        now: Int64, body: (inout [UInt8], Int) -> Void) -> Bool {
    let total = NetStack.udpHeaderSize + n
    if let v4 = destination.mappedIPv4 {
      guard total <= ipv4PayloadLimit else { return false }
      let source = ipv4
      return sendIPv4(protocol: NetStack.protocolUDP, to: v4, now: now) { b, at, _ in
        NetStack.writeUDPHeader(&b, at: at, from: sourcePort, to: port, length: total)
        body(&b, at + NetStack.udpHeaderSize)
        var c = InternetChecksum()
        c.add32(source.value)
        c.add32(v4.value)
        c.add16(UInt16(NetStack.protocolUDP))
        c.add16(UInt16(total))
        c.add(b, at, total)
        let v = c.value
        b.put16(v == 0 ? 0xFFFF : v, at + 6)
        return total
      }
    }
    guard total <= mtu - NetStack.ipv6HeaderSize, let source = ipv6Source(for: destination, now: now) else {
      return false
    }
    return sendIPv6(from: source, to: destination, next: NetStack.protocolUDP, hopLimit: hopLimit, checksumAt: 6,
                    now: now) { b, at, _ in
      NetStack.writeUDPHeader(&b, at: at, from: sourcePort, to: port, length: total)
      body(&b, at + NetStack.udpHeaderSize)
      return total
    }
  }

  static func writeUDPHeader(_ b: inout [UInt8], at o: Int, from: UInt16, to: UInt16, length: Int) {
    b.put16(from, o)
    b.put16(to, o + 2)
    b.put16(UInt16(length), o + 4)
    b.put16(0, o + 6)
  }

  // MARK: Receiving

  /// A UDP datagram at `o` (`length` bytes of IP payload), from `source`
  /// to `destination`, its checksum already verified by the caller.
  /// `ip` and `ipLength` are the whole packet, for an ICMP error.
  mutating func deliverUDP(_ f: [UInt8], at o: Int, length: Int, from source: IPv6Address, to destination: IPv6Address,
                           unicast: Bool, ip: Int, ipLength: Int, now: Int64) {
    let sourcePort = f.be16(o), port = f.be16(o + 2)
    let n = Int(f.be16(o + 4)) - NetStack.udpHeaderSize
    counters.udpIn += 1
    if port == NetStack.dhcpClientPort && dhcp.state != .off && destination.mappedIPv4 != nil {
      receiveDHCP(f, at: o + NetStack.udpHeaderSize, length: n, now: now)
      return
    }
    guard let e = udp.find(port), port != 0 else {
      if unicast { portUnreachable(f, ip: ip, ipLength: ipLength, from: source, to: destination, now: now) }
      return
    }
    guard udp.counts[e] < udp.slots else {
      counters.udpDropped += 1
      return
    }
    let s = udp.slot(e, udp.counts[e])
    let to = s * FrameQueue.slotSize
    for k in 0..<n { udp.bytes[to + k] = f[o + NetStack.udpHeaderSize + k] }
    udp.datagrams[s] = UDPDatagram(source: source, sourcePort: sourcePort, destination: destination, length: n)
    udp.counts[e] += 1
  }

  /// Checks a UDP header at `o` against the IP payload's `length`, and
  /// its checksum with the pseudo-header's sum `pseudo`. The datagram's
  /// length, or nil (counted) if it's refused.
  mutating func checkUDP(_ f: [UInt8], at o: Int, length: Int, pseudo: InternetChecksum, zeroAllowed: Bool) -> Int? {
    guard length >= NetStack.udpHeaderSize else {
      counters.malformed += 1
      return nil
    }
    let n = Int(f.be16(o + 4))
    guard n >= NetStack.udpHeaderSize && n <= length else {
      counters.malformed += 1
      return nil
    }
    if f.be16(o + 6) == 0 {
      guard zeroAllowed else {
        counters.badChecksums += 1
        return nil
      }
      return n
    }
    var c = pseudo
    c.add(f, o, n)
    guard c.value == 0 else {
      counters.badChecksums += 1
      return nil
    }
    return n
  }

  mutating func receiveUDP4(_ f: [UInt8], at o: Int, length: Int, from source: IPv4Address, to destination: IPv4Address,
                            unicast: Bool, ip: Int, ipLength: Int, now: Int64) {
    guard length >= NetStack.udpHeaderSize else {
      counters.malformed += 1
      return
    }
    // The pseudo-header carries UDP's own length.
    var p = InternetChecksum()
    p.add32(source.value)
    p.add32(destination.value)
    p.add16(UInt16(NetStack.protocolUDP))
    p.add16(f.be16(o + 4))
    guard let n = checkUDP(f, at: o, length: length, pseudo: p, zeroAllowed: true) else { return }
    deliverUDP(f, at: o, length: n, from: IPv6Address(mapping: source), to: IPv6Address(mapping: destination),
               unicast: unicast, ip: ip, ipLength: ipLength, now: now)
  }

  mutating func receiveUDP6(_ f: [UInt8], at o: Int, length: Int, from source: IPv6Address, to destination: IPv6Address,
                            ip: Int, ipLength: Int, now: Int64) {
    guard length >= NetStack.udpHeaderSize else {
      counters.malformed += 1
      return
    }
    let p = InternetChecksum.ipv6(source, destination, length: Int(f.be16(o + 4)), next: NetStack.protocolUDP)
    guard let n = checkUDP(f, at: o, length: length, pseudo: p, zeroAllowed: false) else { return }
    deliverUDP(f, at: o, length: n, from: source, to: destination, unicast: !destination.isMulticast, ip: ip,
               ipLength: ipLength, now: now)
  }

  /// ICMP's port unreachable for the packet at `ip`: IPv4's quotes its
  /// header and 8 bytes on; IPv6's as much as fits in 1280 bytes.
  mutating func portUnreachable(_ f: [UInt8], ip: Int, ipLength: Int, from source: IPv6Address,
                                to destination: IPv6Address, now: Int64) {
    guard now - lastICMPError >= NetStack.icmpErrorInterval else { return }
    lastICMPError = now
    if let v4 = source.mappedIPv4 {
      let quoted = min(ipLength, Int(f[ip] & 15) * 4 + 8)
      sendIPv4(protocol: NetStack.protocolICMP, to: v4, now: now) { b, at, _ in
        b[at] = 3
        b[at + 1] = 3
        b.put16(0, at + 2)
        b.put32(0, at + 4)
        for k in 0..<quoted { b[at + 8 + k] = f[ip + k] }
        b.put16(InternetChecksum.of(b, at, 8 + quoted), at + 2)
        return 8 + quoted
      }
    } else {
      let quoted = min(ipLength, 1280 - NetStack.ipv6HeaderSize - 8)
      sendICMPv6(from: destination, to: source, hopLimit: hopLimit, now: now) { b, at, _ in
        b[at] = 1
        b[at + 1] = 4
        b.put32(0, at + 4)
        for k in 0..<quoted { b[at + 8 + k] = f[ip + k] }
        return 8 + quoted
      }
    }
    counters.portsUnreachable += 1
  }
}
