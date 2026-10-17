// SPDX-License-Identifier: BSD-3-Clause

// ARP (RFC 826), for IPv4 over Ethernet (N1b), over the neighbour cache
// (Neighbors.swift). The receiving side follows the RFC's algorithm: a
// sender we know is updated, and a request for our address teaches us
// its sender and is answered.

extension NetStack {
  static let arpSize = 28

  mutating func receiveARP(_ f: [UInt8], length: Int, now: Int64) {
    let a = Ethernet.headerSize
    guard length >= a + NetStack.arpSize, f.be16(a) == 1, f.be16(a + 2) == Ethernet.typeIPv4, f[a + 4] == 6,
          f[a + 5] == 4
    else {
      counters.malformed += 1
      return
    }
    counters.arpIn += 1
    let operation = f.be16(a + 6)
    let senderMAC = MACAddress(f, at: a + 8)
    let sender = IPv4Address(f.be32(a + 14))
    let target = IPv4Address(f.be32(a + 24))
    checkDHCPConflict(senderMAC: senderMAC, sender: sender, target: target, now: now)
    // A probe (RFC 5227) has no sender address to learn.
    let known = sender != .any && learn(IPv6Address(mapping: sender), senderMAC, create: false, now: now)
    guard ipv4 != .any && target == ipv4 else { return }
    if !known && sender != .any { learn(IPv6Address(mapping: sender), senderMAC, create: true, now: now) }
    if operation == 1 && !senderMAC.isGroup {
      sendARP(operation: 2, to: senderMAC, targetMAC: senderMAC, target: sender)
    }
  }

  /// A request (1) or reply (2), from our address.
  mutating func sendARP(operation: UInt16, to destination: MACAddress, targetMAC: MACAddress, target: IPv4Address) {
    guard let o = transmit.reserve() else { return }
    Ethernet.writeHeader(&transmit.bytes, at: o, destination: destination, source: mac, type: Ethernet.typeARP)
    let a = o + Ethernet.headerSize
    transmit.bytes.put16(1, a)
    transmit.bytes.put16(Ethernet.typeIPv4, a + 2)
    transmit.bytes[a + 4] = 6
    transmit.bytes[a + 5] = 4
    transmit.bytes.put16(operation, a + 6)
    mac.write(&transmit.bytes, at: a + 8)
    transmit.bytes.put32(ipv4.value, a + 14)
    targetMAC.write(&transmit.bytes, at: a + 18)
    transmit.bytes.put32(target.value, a + 24)
    // Padded to Ethernet's 60-byte minimum, as hardware would.
    let end = Ethernet.headerSize + NetStack.arpSize
    for k in end..<60 { transmit.bytes[o + k] = 0 }
    transmit.commit(60)
  }
}
