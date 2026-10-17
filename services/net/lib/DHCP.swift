// SPDX-License-Identifier: BSD-3-Clause

// The DHCPv4 client (RFC 2131, options RFC 2132), N1b: an address, its
// subnet, a router and name servers from the LAN's server.
//
//     selecting   DISCOVER broadcast, again after 4, 8, 16, 32, 64, 64... s
//     requesting  REQUEST for the first OFFER, four tries, then selecting
//     checking    an ARP probe of the address (RFC 5227), a second's wait;
//                 an answer means it's taken: DECLINE, ten seconds, again
//     bound       configured (and announced by ARP) until T1 (half the lease)
//     renewing    REQUEST to the server, until T2 (7/8 of it)
//     rebinding   REQUEST broadcast, until the lease ends: unconfigured,
//                 and selecting again
//
// Retransmissions while renewing and rebinding come at half the time
// left, at least a minute (§4.4.5). No random jitter: the core has no
// randomness, so the caller gives the transaction ID. Replies are asked
// for by broadcast (the flag in §4.1) until we have an address, so a
// server needn't reach an unconfigured interface by unicast.

public struct DHCPClient: Sendable {
  public enum State: Sendable { case off, selecting, requesting, checking, declined, bound, renewing, rebinding }

  public internal(set) var state = State.off
  /// The address offered, then leased.
  public internal(set) var address = IPv4Address.any
  public internal(set) var server = IPv4Address.any
  public internal(set) var prefixLength = 0
  public internal(set) var router: IPv4Address?
  public internal(set) var nameServers: [IPv4Address] = []
  /// The lease, in seconds (UInt32.max for one without end).
  public internal(set) var leaseSeconds: UInt32 = 0
  var xid: UInt32 = 0
  var t1 = Int64.max, t2 = Int64.max, expiry = Int64.max
  /// When `poll` next has work for the client.
  public internal(set) var deadline: Int64?
  var interval: Int64 = 0
  var attempts = 0
  var started: Int64 = 0

  public init() {}
}

extension NetStack {
  static let dhcpServerPort: UInt16 = 67
  static let dhcpCookie: UInt32 = 0x6382_5363
  static let dhcpMinimumRetransmit: Int64 = 60_000_000_000

  enum DHCPMessage: UInt8 {
    case discover = 1, offer, request, decline, ack, nak, release
  }

  /// Starts asking for an address. `xid` starts the transaction IDs: the
  /// caller's randomness (a server tells clients apart by them).
  public mutating func startDHCP(xid: UInt32, now: Int64) {
    dhcp.xid = xid
    dhcp.started = now
    selectDHCP(now: now)
  }

  mutating func selectDHCP(now: Int64) {
    dhcp.xid &+= 1
    dhcp.state = .selecting
    dhcp.address = .any
    dhcp.interval = 4_000_000_000
    dhcp.attempts = 1
    dhcp.deadline = now + dhcp.interval
    sendDHCP(.discover, to: .broadcast, now: now)
  }

  /// Sends a DHCP message: from 0.0.0.0 with the broadcast flag until
  /// bound, then from our address.
  mutating func sendDHCP(_ type: DHCPMessage, to destination: IPv4Address, now: Int64) {
    let bound = ipv4 != .any
    // Selecting's REQUEST and a DECLINE name the address and the server.
    let names = (type == .request && !bound) || type == .decline
    let requested = names ? dhcp.address : nil
    let serverID = names ? dhcp.server : nil
    let xid = dhcp.xid, ours = mac
    let secs = UInt16(min((now - dhcp.started) / 1_000_000_000, 65535))
    let ciaddr = bound && type == .request ? ipv4 : IPv4Address.any
    _ = sendUDP(from: NetStack.dhcpClientPort, to: IPv6Address(mapping: destination), port: NetStack.dhcpServerPort,
                length: 300, now: now) { b, at in
      for k in 0..<300 { b[at + k] = 0 }
      b[at] = 1  // BOOTREQUEST
      b[at + 1] = 1  // Ethernet
      b[at + 2] = 6
      b.put32(xid, at + 4)
      b.put16(secs, at + 8)
      b.put16(bound ? 0 : 0x8000, at + 10)  // broadcast replies until bound
      b.put32(ciaddr.value, at + 12)
      ours.write(&b, at: at + 28)
      b.put32(NetStack.dhcpCookie, at + 236)
      var p = at + 240
      func option(_ code: UInt8, _ bytes: [UInt8]) {
        b[p] = code
        b[p + 1] = UInt8(bytes.count)
        for (k, v) in bytes.enumerated() { b[p + 2 + k] = v }
        p += 2 + bytes.count
      }
      func address(_ a: IPv4Address) -> [UInt8] {
        [UInt8(a.value >> 24), UInt8(a.value >> 16 & 0xFF), UInt8(a.value >> 8 & 0xFF), UInt8(a.value & 0xFF)]
      }
      option(53, [type.rawValue])
      var clientID: [UInt8] = [1, 0, 0, 0, 0, 0, 0]
      ours.write(&clientID, at: 1)
      option(61, clientID)
      if let r = requested { option(50, address(r)) }
      if let s = serverID { option(54, address(s)) }
      if type != .decline { option(55, [1, 3, 6, 51, 58, 59]) }  // mask, router, DNS, lease, T1, T2
      b[p] = 255
    }
  }

  /// A reply from a server: the BOOTP body at `o`, `n` bytes.
  mutating func receiveDHCP(_ f: [UInt8], at o: Int, length n: Int, now: Int64) {
    guard n >= 240, f[o] == 2, f[o + 1] == 1, f[o + 2] == 6, f.be32(o + 4) == dhcp.xid,
          MACAddress(f, at: o + 28) == mac, f.be32(o + 236) == NetStack.dhcpCookie
    else {
      counters.ignored += 1
      return
    }
    var type: UInt8 = 0
    var serverID: IPv4Address?, lease: UInt32?, t1: UInt32?, t2: UInt32?, mask: UInt32?, router: IPv4Address?
    var nameServers: [IPv4Address] = []
    var p = o + 240
    let end = o + n
    while p < end && f[p] != 255 {
      if f[p] == 0 {
        p += 1
        continue
      }
      guard p + 2 <= end, p + 2 + Int(f[p + 1]) <= end else {
        counters.malformed += 1
        return
      }
      let size = Int(f[p + 1]), v = p + 2
      switch (f[p], size) {
      case (53, 1): type = f[v]
      case (54, 4): serverID = IPv4Address(f.be32(v))
      case (51, 4): lease = f.be32(v)
      case (58, 4): t1 = f.be32(v)
      case (59, 4): t2 = f.be32(v)
      case (1, 4): mask = f.be32(v)
      case (3, _) where size >= 4: router = IPv4Address(f.be32(v))
      case (6, _) where size >= 4:
        for k in 0..<size / 4 { nameServers.append(IPv4Address(f.be32(v + 4 * k))) }
      default: break
      }
      p += 2 + size
    }
    let offered = IPv4Address(f.be32(o + 16))
    switch (dhcp.state, type) {
    case (.selecting, DHCPMessage.offer.rawValue):
      guard let s = serverID, offered != .any else { return }
      dhcp.address = offered
      dhcp.server = s
      dhcp.state = .requesting
      dhcp.attempts = 1
      dhcp.interval = 4_000_000_000
      dhcp.deadline = now + dhcp.interval
      sendDHCP(.request, to: .broadcast, now: now)
    case (.requesting, DHCPMessage.ack.rawValue), (.renewing, DHCPMessage.ack.rawValue),
         (.rebinding, DHCPMessage.ack.rawValue):
      guard offered == dhcp.address || dhcp.state == .requesting && offered != .any else { return }
      dhcp.address = offered
      if let s = serverID { dhcp.server = s }
      let l = lease ?? 3600
      dhcp.leaseSeconds = l
      dhcp.expiry = NetStack.deadline(l, now: now)
      dhcp.t1 = NetStack.deadline(t1 ?? (l == UInt32.max ? l : l / 2), now: now)
      dhcp.t2 = NetStack.deadline(t2 ?? (l == UInt32.max ? l : l / 8 * 7), now: now)
      // A mask that isn't contiguous ones is taken as /24.
      let m = mask ?? 0xFFFF_FF00
      dhcp.prefixLength = (~m).leadingZeroBitCount  // its leading ones
      if m != IPv4Address.mask(dhcp.prefixLength) { dhcp.prefixLength = 24 }
      dhcp.router = router
      dhcp.nameServers = nameServers
      if dhcp.state == .requesting {
        // Probe it first (RFC 2131 §3.1.5, RFC 5227): sender 0.0.0.0.
        dhcp.state = .checking
        dhcp.deadline = now + 1_000_000_000
        sendARP(operation: 1, to: .broadcast, targetMAC: .zero, target: dhcp.address)
      } else {
        bindDHCP(now: now)
      }
    case (.requesting, DHCPMessage.nak.rawValue), (.renewing, DHCPMessage.nak.rawValue),
         (.rebinding, DHCPMessage.nak.rawValue):
      if ipv4 != .any { configureIPv4(.any, prefixLength: 0) }
      selectDHCP(now: now)
    default:
      counters.ignored += 1
    }
  }

  /// The lease is ours: configured, announced, renewed at T1.
  mutating func bindDHCP(now: Int64) {
    configureIPv4(dhcp.address, prefixLength: dhcp.prefixLength, gateway: dhcp.router)
    dhcp.state = .bound
    dhcp.deadline = dhcp.t1 == Int64.max ? nil : dhcp.t1
    sendARP(operation: 1, to: .broadcast, targetMAC: .zero, target: dhcp.address)  // an announcement
  }

  /// While probing, an ARP packet from the address, or another probe of
  /// it, means it's taken (RFC 5227 §2.1.1).
  mutating func checkDHCPConflict(senderMAC: MACAddress, sender: IPv4Address, target: IPv4Address, now: Int64) {
    guard dhcp.state == .checking && senderMAC != mac else { return }
    guard sender == dhcp.address || (sender == .any && target == dhcp.address) else { return }
    counters.dhcpDeclined += 1
    sendDHCP(.decline, to: .broadcast, now: now)
    dhcp.state = .declined
    dhcp.address = .any
    dhcp.deadline = now + 10_000_000_000
  }

  mutating func pollDHCP(now: Int64) {
    guard let d = dhcp.deadline, d <= now else { return }
    switch dhcp.state {
    case .off: dhcp.deadline = nil
    case .selecting:
      dhcp.interval = min(dhcp.interval * 2, 64_000_000_000)
      dhcp.attempts += 1
      dhcp.deadline = now + dhcp.interval
      sendDHCP(.discover, to: .broadcast, now: now)
    case .requesting:
      guard dhcp.attempts < 4 else {
        selectDHCP(now: now)
        return
      }
      dhcp.interval = min(dhcp.interval * 2, 64_000_000_000)
      dhcp.attempts += 1
      dhcp.deadline = now + dhcp.interval
      sendDHCP(.request, to: .broadcast, now: now)
    case .checking:
      bindDHCP(now: now)
    case .declined:
      selectDHCP(now: now)
    case .bound, .renewing, .rebinding:
      if now >= dhcp.expiry {
        configureIPv4(.any, prefixLength: 0)
        selectDHCP(now: now)
      } else if now >= dhcp.t2 {
        dhcp.state = .rebinding
        dhcp.deadline = min(dhcp.expiry, now + max(NetStack.dhcpMinimumRetransmit, (dhcp.expiry - now) / 2))
        sendDHCP(.request, to: .broadcast, now: now)
      } else {
        dhcp.state = .renewing
        dhcp.deadline = min(dhcp.t2, now + max(NetStack.dhcpMinimumRetransmit, (dhcp.t2 - now) / 2))
        sendDHCP(.request, to: dhcp.server, now: now)
      }
    }
  }
}
