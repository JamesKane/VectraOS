// SPDX-License-Identifier: BSD-3-Clause

// UDP and the DHCPv4 client in the stack's core (N1b part b3): endpoints,
// checksums, port unreachable; the client's whole life against a server
// played here (selecting, requesting, the ARP probe, bound, renewing,
// rebinding, the lease's end), a NAK, a conflict declined, and its
// backoff.

import FoundationEssentials
import Glibc
@testable import Net
import Testing

let serverIP = IPv4Address(10, 0, 0, 1)
let serverMAC = MACAddress(0x0200_0000_0001)
let offeredIP = IPv4Address(10, 0, 0, 41)

/// A UDP datagram over IPv4 to us, its checksum computed (or 0).
func udp4Frame(from source: IPv4Address = theirIP, to destination: IPv4Address = ourIP, sourcePort: UInt16 = 5000,
               port: UInt16, _ data: [UInt8], checksum: Bool = true, toMAC: MACAddress = ours,
               fromMAC: MACAddress = theirs) -> [UInt8] {
  var f = [UInt8](repeating: 0, count: 14 + 20 + 8 + data.count)
  Ethernet.writeHeader(&f, at: 0, destination: toMAC, source: fromMAC, type: Ethernet.typeIPv4)
  f[14] = 0x45
  f.put16(UInt16(28 + data.count), 16)
  f[22] = 64
  f[23] = 17
  f.put32(source.value, 26)
  f.put32(destination.value, 30)
  f.put16(InternetChecksum.of(f, 14, 20), 24)
  f.put16(sourcePort, 34)
  f.put16(port, 36)
  f.put16(UInt16(8 + data.count), 38)
  for (i, b) in data.enumerated() { f[42 + i] = b }
  if checksum {
    var c = InternetChecksum()
    c.add32(source.value)
    c.add32(destination.value)
    c.add16(17)
    c.add16(UInt16(8 + data.count))
    c.add(f, 34, 8 + data.count)
    f.put16(c.value == 0 ? 0xFFFF : c.value, 40)
  }
  return f
}

// (Swift Testing's macros can't take a mutating call: each is made first.)
@Test func endpointsTakeTheirDatagrams() throws {
  var s = stack()
  let opened = s.openUDP(port: 7)
  let e = try #require(opened)
  let again = s.openUDP(port: 7)
  let ephemeral = s.openUDP()
  #expect(again == nil && ephemeral.map { s.udpPort($0) } == 49152)
  let hello = udp4Frame(port: 7, Array("hello".utf8))
  s.receive(hello, length: hello.count, now: 0)
  let unchecked = udp4Frame(port: 7, Array("no sum".utf8), checksum: false)
  s.receive(unchecked, length: unchecked.count, now: 0)
  var bad = udp4Frame(port: 7, Array("bad".utf8))
  bad[42] ^= 1
  s.receive(bad, length: bad.count, now: 0)
  #expect(s.waitingUDP(e) == 2 && s.counters.badChecksums == 1)
  var buffer = [UInt8](repeating: 0, count: FrameQueue.slotSize)
  let first = s.receiveUDP(e, into: &buffer)
  let d = try #require(first)
  #expect(d == UDPDatagram(source: IPv6Address(mapping: theirIP), sourcePort: 5000,
                           destination: IPv6Address(mapping: ourIP), length: 5))
  #expect(Array(buffer[0..<5]) == Array("hello".utf8))
  let second = s.receiveUDP(e, into: &buffer), none = s.receiveUDP(e, into: &buffer)
  #expect(second?.length == 6 && none == nil)
  // A full ring drops the newest.
  for k in 0..<20 {
    let f = udp4Frame(port: 7, [UInt8(k)])
    s.receive(f, length: f.count, now: 0)
  }
  #expect(s.waitingUDP(e) == 16 && s.counters.udpDropped == 4)
  let oldest = s.receiveUDP(e, into: &buffer)
  #expect(oldest != nil && buffer[0] == 0)
  // Closed again: its port can be bound anew.
  s.closeUDP(e)
  let reopened = s.openUDP(port: 7)
  #expect(reopened != nil)
}

@Test func sentDatagramsCarryTheirChecksums() throws {
  var s = started()
  s.configureIPv4(ourIP, prefixLength: 24)
  s.learn(IPv6Address(mapping: theirIP), theirs, create: true, now: 0)
  s.learn(theirLL, theirs, create: true, now: 0)
  let opened = s.openUDP(port: 4000)
  let e = try #require(opened)
  let sent4 = s.sendUDP(e, to: IPv6Address(mapping: theirIP), port: 53, Array("query".utf8), now: 0)
  let sent6 = s.sendUDP(e, to: theirLL, port: 53, Array("query6".utf8), now: 0)
  #expect(sent4 && sent6)
  let v4 = s.transmit.frame(0), v6 = s.transmit.frame(1)
  var c = InternetChecksum()
  c.add32(ourIP.value)
  c.add32(theirIP.value)
  c.add16(17)
  c.add16(13)
  c.add(v4, 34, 13)
  #expect(v4[23] == 17 && v4.be16(34) == 4000 && v4.be16(36) == 53 && v4.be16(38) == 13 && c.value == 0)
  var c6 = InternetChecksum.ipv6(ourLL, theirLL, length: 14, next: 17)
  c6.add(v6, 54, 14)
  #expect(v6[20] == 17 && v6.be16(54) == 4000 && c6.value == 0 && v6.be16(60) != 0)
  // Too big for one packet: refused, not fragmented.
  let tooBig = s.sendUDP(e, to: IPv6Address(mapping: theirIP), port: 53, [UInt8](repeating: 0, count: 1473), now: 0)
  #expect(!tooBig)
}

@Test func closedPortsAnswerUnreachable() {
  var s = stack()
  s.learn(IPv6Address(mapping: theirIP), theirs, create: true, now: 0)
  let f = udp4Frame(port: 9, Array("anyone?".utf8))
  s.receive(f, length: f.count, now: 0)
  #expect(s.transmit.count == 1)
  let icmp = s.transmit.frame(0)
  #expect(icmp[23] == 1 && icmp[34] == 3 && icmp[35] == 3 && InternetChecksum.of(icmp, 34, 8 + 28) == 0)
  #expect(Array(icmp[42..<42 + 28]) == Array(f[14..<42]))  // their header and 8 bytes on
  // Within 100 ms: no second error. To a broadcast: none at all.
  s.transmit.removeAll()
  s.receive(f, length: f.count, now: 50_000_000)
  let b = udp4Frame(to: IPv4Address(10, 0, 0, 255), port: 9, [1], toMAC: .broadcast)
  s.receive(b, length: b.count, now: 500_000_000)
  #expect(s.transmit.isEmpty && s.counters.portsUnreachable == 1)
  // Over IPv6, a checksum of 0 is refused.
  var t = started()
  let zero = icmp6Frame(from: theirLL, to: ourLL, [0x13, 0x88, 0, 9, 0, 9, 0, 0, 1])
  var z = zero
  z[20] = 17
  z.put16(9, 56)  // the destination port, where ICMPv6's checksum went
  z.put16(0, 60)
  t.receive(z, length: z.count, now: 2 * second)
  #expect(t.counters.badChecksums == 1 && t.transmit.isEmpty)
}

// MARK: DHCP

/// The DHCP message in a frame we sent: its type and options by code.
func dhcpSent(_ f: [UInt8]) -> (type: UInt8, xid: UInt32, flags: UInt16, ciaddr: UInt32, options: [UInt8: [UInt8]])? {
  guard f.be16(12) == Ethernet.typeIPv4, f[23] == 17, f.be16(36) == 67 else { return nil }
  var options: [UInt8: [UInt8]] = [:]
  var p = 42 + 240
  while f[p] != 255 {
    options[f[p]] = Array(f[p + 2..<p + 2 + Int(f[p + 1])])
    p += 2 + Int(f[p + 1])
  }
  return (options[53]?.first ?? 0, f.be32(46), f.be16(52), f.be32(54), options)
}

func dhcpMessages(_ s: NetStack) -> [(type: UInt8, xid: UInt32, flags: UInt16, ciaddr: UInt32, options: [UInt8: [UInt8]])] {
  (0..<s.transmit.count).compactMap { dhcpSent(s.transmit.frame($0)) }
}

/// A server's reply, broadcast.
func dhcpReply(_ type: UInt8, xid: UInt32, yiaddr: IPv4Address = offeredIP, lease: UInt32 = 600,
               to destination: IPv4Address = .broadcast) -> [UInt8] {
  var body = [UInt8](repeating: 0, count: 240)
  body[0] = 2
  body[1] = 1
  body[2] = 6
  body.put32(xid, 4)
  body.put32(yiaddr.value, 16)
  ours.write(&body, at: 28)
  body.put32(0x6382_5363, 236)
  body += [53, 1, type, 54, 4, 10, 0, 0, 1, 1, 4, 255, 255, 255, 0, 3, 4, 10, 0, 0, 1, 6, 8, 10, 0, 0, 1, 9, 9, 9, 9]
  var l: [UInt8] = [51, 4, 0, 0, 0, 0]
  l.put32(lease, 2)
  body += l + [255]
  return udp4Frame(from: serverIP, to: destination, sourcePort: 67, port: 68, body,
                   toMAC: destination == .broadcast ? .broadcast : ours, fromMAC: serverMAC)
}

@Test func dhcpLeasesRenewsRebindsAndLetsGo() {
  var s = NetStack(mac: ours)
  s.startDHCP(xid: 100, now: 0)
  var sent = dhcpMessages(s)
  #expect(sent.count == 1 && sent[0].type == 1 && sent[0].flags == 0x8000 && sent[0].ciaddr == 0)
  #expect(sent[0].options[61] == [1] + macBytes(ours) && sent[0].options[55] == [1, 3, 6, 51, 58, 59])
  #expect(s.transmit.frame(0).be32(30) == IPv4Address.broadcast.value && s.transmit.frame(0).count >= 342)
  let xid = sent[0].xid
  s.transmit.removeAll()
  // An offer for another transaction is ignored; ours is requested.
  let stray = dhcpReply(2, xid: xid &+ 9)
  s.receive(stray, length: stray.count, now: 1000)
  #expect(s.transmit.isEmpty && s.dhcp.state == .selecting)
  let offer = dhcpReply(2, xid: xid)
  s.receive(offer, length: offer.count, now: 1000)
  sent = dhcpMessages(s)
  #expect(sent.count == 1 && sent[0].type == 3 && sent[0].options[50] == [10, 0, 0, 41])
  #expect(sent[0].options[54] == [10, 0, 0, 1] && s.dhcp.state == .requesting)
  s.transmit.removeAll()
  // The ACK: probed (an ARP request from 0.0.0.0) and used at once, the
  // probe alone sent; bound, and announced, a second on.
  let ack = dhcpReply(5, xid: xid)
  s.receive(ack, length: ack.count, now: 2000)
  #expect(s.dhcp.state == .checking && s.ipv4 == offeredIP && s.gateway == serverIP)
  #expect(s.transmit.count == 1)
  let probe = s.transmit.frame(0)
  #expect(probe.be16(12) == Ethernet.typeARP && probe.be32(28) == 0 && probe.be32(38) == offeredIP.value)
  s.transmit.removeAll()
  s.poll(now: 2000 + second)
  #expect(s.dhcp.state == .bound && s.ipv4 == offeredIP && s.prefixLength == 24 && s.gateway == serverIP)
  #expect(s.dhcp.nameServers == [serverIP, IPv4Address(9, 9, 9, 9)] && s.dhcp.leaseSeconds == 600)
  let announce = s.transmit.frame(0)
  #expect(announce.be32(28) == offeredIP.value && announce.be32(38) == offeredIP.value)
  s.transmit.removeAll()
  // T1 (300 s): a REQUEST to the server, from our address.
  #expect(s.dhcp.deadline == 2000 + 300 * second)
  // (The server's link address is known throughout: the client's
  // timing is what's tested here, not ARP's.)
  s.learn(IPv6Address(mapping: serverIP), serverMAC, create: true, now: 2000 + 300 * second)
  s.poll(now: 2000 + 300 * second)
  sent = dhcpMessages(s)
  #expect(s.dhcp.state == .renewing && sent.count == 1 && sent[0].type == 3)
  #expect(sent[0].ciaddr == offeredIP.value && sent[0].flags == 0 && sent[0].options[50] == nil)
  #expect(s.transmit.frame(0).be32(30) == serverIP.value && MACAddress(s.transmit.frame(0), at: 0) == serverMAC)
  s.transmit.removeAll()
  let renewed = dhcpReply(5, xid: sent[0].xid, to: offeredIP)
  s.receive(renewed, length: renewed.count, now: 2000 + 301 * second)
  #expect(s.dhcp.state == .bound && s.dhcp.deadline == 2000 + 601 * second)
  // No answers now: renewing (retried at least a minute apart), rebinding
  // at T2 (by broadcast), then the address is let go at the end.
  s.transmit.removeAll()
  var now = 2000 + 601 * second
  var requests: [(Int64, UInt32)] = []
  while s.ipv4 != .any, let d = s.nextDeadline {
    now = d
    s.learn(IPv6Address(mapping: serverIP), serverMAC, create: true, now: now)
    s.poll(now: now)
    for i in 0..<s.transmit.count where dhcpSent(s.transmit.frame(i))?.type == 3 {
      requests.append((now, s.transmit.frame(i).be32(30)))
    }
    s.transmit.removeAll()
  }
  let t2 = 2000 + 301 * second + 525 * second, end = 2000 + 301 * second + 600 * second
  #expect(requests.first.map { $0.1 } == serverIP.value)
  #expect(requests.contains { $0.0 == t2 && $0.1 == IPv4Address.broadcast.value })
  #expect(now == end && s.dhcp.state == .selecting)
}

@Test func dhcpTakesANakAndBacksOff() {
  var s = NetStack(mac: ours)
  s.startDHCP(xid: 7, now: 0)
  // DISCOVERs at 4, 8, 16, 32, 64, then 64 s apart.
  var times: [Int64] = [0]
  var now: Int64 = 0
  while times.count < 8, let d = s.nextDeadline {
    s.transmit.removeAll()
    now = d
    s.poll(now: now)
    if dhcpMessages(s).first?.type == 1 { times.append(now) }
  }
  #expect(times.map { $0 / second } == [0, 4, 12, 28, 60, 124, 188, 252])
  // A NAK to our REQUEST starts again.
  let xid = dhcpMessages(s)[0].xid
  s.transmit.removeAll()
  let offer = dhcpReply(2, xid: xid)
  s.receive(offer, length: offer.count, now: now)
  let nak = dhcpReply(6, xid: xid, yiaddr: .any)
  s.receive(nak, length: nak.count, now: now)
  #expect(s.dhcp.state == .selecting && dhcpMessages(s).last?.type == 1)
}

@Test func dhcpDeclinesATakenAddress() {
  var s = NetStack(mac: ours)
  s.startDHCP(xid: 7, now: 0)
  let xid = dhcpMessages(s)[0].xid
  let offer = dhcpReply(2, xid: xid), ack = dhcpReply(5, xid: xid)
  s.receive(offer, length: offer.count, now: 0)
  s.receive(ack, length: ack.count, now: 0)
  s.transmit.removeAll()
  #expect(s.ipv4 == offeredIP)  // in use while it is checked
  // Someone answers the probe: the address is theirs, given up at once.
  let reply = arpFrame(operation: 2, senderMAC: theirs, sender: offeredIP, target: .any, to: ours)
  s.receive(reply, length: reply.count, now: 1000)
  #expect(s.ipv4 == .any)
  let decline = dhcpMessages(s)
  #expect(decline.count == 1 && decline[0].type == 4 && decline[0].options[50] == [10, 0, 0, 41])
  #expect(decline[0].options[54] == [10, 0, 0, 1] && s.dhcp.state == .declined && s.counters.dhcpDeclined == 1)
  s.poll(now: second + 1000)
  #expect(s.ipv4 == .any && s.dhcp.state == .declined)
  s.transmit.removeAll()
  s.poll(now: 10 * second + 1000)
  #expect(s.dhcp.state == .selecting && dhcpMessages(s).first?.type == 1)
}
