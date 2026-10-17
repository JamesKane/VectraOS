// SPDX-License-Identifier: BSD-3-Clause

// IPv4 (RFC 791) and ICMP's echo (RFC 792), N1b. Packets are taken for
// our address, the limited broadcast and the subnet's; options are
// skipped; fragments are counted and dropped (no reassembly: a LAN at
// 1500 bytes sends none, and TCP sets DF). Sent packets set DF, TTL 64,
// and go straight out when the next hop's address is known, else wait in
// `pending` while ARP asks.

extension NetStack {
  static let ipv4HeaderSize = 20
  static let protocolICMP: UInt8 = 1

  /// The most payload an IPv4 packet can carry on this link.
  var ipv4PayloadLimit: Int { mtu - NetStack.ipv4HeaderSize }

  mutating func receiveIPv4(_ f: [UInt8], length: Int, now: Int64) {
    let o = Ethernet.headerSize
    guard length >= o + NetStack.ipv4HeaderSize, f[o] >> 4 == 4 else {
      counters.malformed += 1
      return
    }
    let headerLength = Int(f[o] & 15) * 4
    let total = Int(f.be16(o + 2))
    guard headerLength >= NetStack.ipv4HeaderSize, total >= headerLength, o + total <= length else {
      counters.malformed += 1
      return
    }
    guard InternetChecksum.of(f, o, headerLength) == 0 else {
      counters.badChecksums += 1
      return
    }
    // More fragments, or an offset: a piece of a larger packet.
    guard f.be16(o + 6) & 0x3FFF == 0 else {
      counters.fragments += 1
      return
    }
    let destination = IPv4Address(f.be32(o + 16))
    let unicast = ipv4 != .any && destination == ipv4
    guard unicast || isBroadcast(destination) else {
      counters.ignored += 1
      return
    }
    // A broadcast or multicast source is discarded (RFC 1122 §3.2.1.3):
    // answering one would answer the whole subnet.
    let source = IPv4Address(f.be32(o + 12))
    guard !isBroadcast(source) && source.value >> 28 != 0xE else {
      counters.malformed += 1
      return
    }
    counters.ipv4In += 1
    switch f[o + 9] {
    case NetStack.protocolICMP:
      receiveICMP(f, at: o + headerLength, length: total - headerLength, from: source, unicast: unicast, now: now)
    case NetStack.protocolTCP:
      receiveTCP4(f, at: o + headerLength, length: total - headerLength, from: source, to: destination, unicast: unicast,
                  now: now)
    case NetStack.protocolUDP:
      receiveUDP4(f, at: o + headerLength, length: total - headerLength, from: source, to: destination, unicast: unicast,
                  ip: o, ipLength: total, now: now)
    default: counters.ignored += 1
    }
  }

  /// The limited broadcast, or our subnet's.
  func isBroadcast(_ a: IPv4Address) -> Bool {
    if a == .broadcast { return true }
    guard ipv4 != .any && prefixLength < 31 else { return false }
    let host = ~IPv4Address.mask(prefixLength)
    return a.value & ~host == ipv4.value & ~host && a.value & host == host
  }

  /// Sends a packet of `protocol` to `destination`: the headers are
  /// written here, the payload by `payload` (the bytes, where it starts,
  /// the most it may write; it returns how much it wrote). False if
  /// there's no route or no room.
  @discardableResult
  mutating func sendIPv4(protocol p: UInt8, to destination: IPv4Address, now: Int64,
                         payload: (inout [UInt8], Int, Int) -> Int) -> Bool {
    let hop: IPv4Address
    var known: MACAddress?
    let mask = IPv4Address.mask(prefixLength)
    if isBroadcast(destination) {
      hop = destination
      known = .broadcast
    } else if ipv4 != .any && destination.value & mask == ipv4.value & mask {
      hop = destination
    } else if let g = gateway {
      hop = g
    } else {
      return false
    }
    let id = nextIPv4ID
    nextIPv4ID &+= 1
    let source = ipv4, from = mac, limit = ipv4PayloadLimit
    return send(via: IPv6Address(mapping: hop), mac: known, now: now) { b, o, to in
      NetStack.buildIPv4(&b, at: o, protocol: p, source: source, destination: destination, id: id, from: from, to: to,
                         limit: limit, payload: payload)
    }
  }

  /// Writes an Ethernet frame holding an IPv4 packet at `o`; its length.
  static func buildIPv4(_ b: inout [UInt8], at o: Int, protocol p: UInt8, source: IPv4Address,
                        destination: IPv4Address, id: UInt16, from: MACAddress, to: MACAddress, limit: Int,
                        payload: (inout [UInt8], Int, Int) -> Int) -> Int {
    Ethernet.writeHeader(&b, at: o, destination: to, source: from, type: Ethernet.typeIPv4)
    let h = o + Ethernet.headerSize
    let body = h + ipv4HeaderSize
    let n = payload(&b, body, limit)
    precondition(n <= limit)
    b[h] = 0x45
    b[h + 1] = 0
    b.put16(UInt16(ipv4HeaderSize + n), h + 2)
    b.put16(id, h + 4)
    b.put16(0x4000, h + 6)  // DF
    b[h + 8] = 64
    b[h + 9] = p
    b.put16(0, h + 10)
    b.put32(source.value, h + 12)
    b.put32(destination.value, h + 16)
    b.put16(InternetChecksum.of(b, h, ipv4HeaderSize), h + 10)
    // Padded to Ethernet's 60-byte minimum.
    var end = body + n
    while end < o + 60 {
      b[end] = 0
      end += 1
    }
    return end - o
  }

  mutating func receiveICMP(_ f: [UInt8], at o: Int, length: Int, from source: IPv4Address, unicast: Bool,
                            now: Int64) {
    guard length >= 8 else {
      counters.malformed += 1
      return
    }
    guard InternetChecksum.of(f, o, length) == 0 else {
      counters.badChecksums += 1
      return
    }
    // An echo request (type 8) to us, answered with the same identifier,
    // sequence and data; one to a broadcast isn't (as Linux does).
    guard f[o] == 8 && f[o + 1] == 0 && unicast && length <= ipv4PayloadLimit else {
      counters.ignored += 1
      return
    }
    let sent = sendIPv4(protocol: NetStack.protocolICMP, to: source, now: now) { b, at, _ in
      for k in 0..<length { b[at + k] = f[o + k] }
      b[at] = 0
      b.put16(0, at + 2)
      b.put16(InternetChecksum.of(b, at, length), at + 2)
      return length
    }
    if sent { counters.echoesAnswered += 1 }
  }
}
