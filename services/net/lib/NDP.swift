// SPDX-License-Identifier: BSD-3-Clause

// IPv6 neighbour discovery (RFC 4861), stateless address
// autoconfiguration (RFC 4862) and the MLDv2 reports a snooping switch
// needs to send us our groups (RFC 3810), N1b. A host's part only: we
// solicit routers and take their adverts, but never advertise as one.
//
// Every message is checked as §7.1.1 and §6.1.2 say: hop limit 255 (it
// came from this link), code 0, long enough, its options' lengths
// nonzero and inside it. Router adverts come from link-local sources.

extension NetStack {
  static let routerSolicitationInterval: Int64 = 4_000_000_000
  static let maxRouterSolicitations = 3
  static let twoHours: Int64 = 7_200_000_000_000

  /// Whether the options from `o` to `end` are well formed.
  static func ndpOptionsValid(_ f: [UInt8], from o: Int, to end: Int) -> Bool {
    var p = o
    while p < end {
      guard p + 2 <= end, f[p + 1] != 0 else { return false }
      p += Int(f[p + 1]) * 8
    }
    return p == end
  }

  /// The link address in the first option of `type` (1 source, 2 target).
  static func ndpLinkAddress(_ f: [UInt8], from o: Int, to end: Int, type: UInt8) -> MACAddress? {
    var p = o
    while p + 8 <= end {
      if f[p] == type && f[p + 1] == 1 { return MACAddress(f, at: p + 2) }
      p += Int(f[p + 1]) * 8
    }
    return nil
  }

  /// A lifetime in seconds as a deadline; all ones is forever.
  static func deadline(_ seconds: UInt32, now: Int64) -> Int64 {
    seconds == UInt32.max ? Int64.max : now + Int64(seconds) * 1_000_000_000
  }

  // MARK: Sending

  /// The duplicate check for a tentative address: a solicitation from the
  /// unspecified address to its solicited-node group (RFC 4862 §5.4.2).
  mutating func sendDuplicateCheck(_ a: IPv6Address, now: Int64) {
    sendICMPv6(from: .any, to: a.solicitedNode, now: now) { b, at, _ in
      b[at] = 135
      b[at + 1] = 0
      for k in 4..<8 { b[at + k] = 0 }
      a.write(&b, at: at + 8)
      return 24
    }
  }

  /// Asks for `target`'s link address (RFC 4861 §7.2.2).
  mutating func sendNeighborSolicitation(_ target: IPv6Address, now: Int64) {
    guard let source = ipv6Source(for: target, now: now) else { return }
    let ours = mac
    sendICMPv6(from: source, to: target.solicitedNode, now: now) { b, at, _ in
      b[at] = 135
      b[at + 1] = 0
      for k in 4..<8 { b[at + k] = 0 }
      target.write(&b, at: at + 8)
      b[at + 24] = 1  // source link address
      b[at + 25] = 1
      ours.write(&b, at: at + 26)
      return 32
    }
  }

  /// Advertises our `target` to `destination` (RFC 4861 §7.2.4).
  mutating func sendNeighborAdvert(_ target: IPv6Address, to destination: IPv6Address, solicited: Bool, now: Int64) {
    let ours = mac
    sendICMPv6(from: target, to: destination, now: now) { b, at, _ in
      b[at] = 136
      b[at + 1] = 0
      b[at + 4] = (solicited ? 0x40 : 0) | 0x20  // S, and O: override
      for k in 5..<8 { b[at + k] = 0 }
      target.write(&b, at: at + 8)
      b[at + 24] = 2  // target link address
      b[at + 25] = 1
      ours.write(&b, at: at + 26)
      return 32
    }
  }

  /// Asks for routers, from our link-local address, three times four
  /// seconds apart until one answers (RFC 4861 §6.3.7).
  mutating func sendRouterSolicitation(now: Int64) {
    guard routerSolicitations < NetStack.maxRouterSolicitations, ipv6.isOurs(linkLocalAddress) else {
      nextRouterSolicitation = nil
      return
    }
    routerSolicitations += 1
    nextRouterSolicitation = routerSolicitations < NetStack.maxRouterSolicitations
      ? now + NetStack.routerSolicitationInterval : nil
    let ours = mac
    sendICMPv6(from: linkLocalAddress, to: .allRouters, now: now) { b, at, _ in
      b[at] = 133
      b[at + 1] = 0
      for k in 4..<8 { b[at + k] = 0 }
      b[at + 8] = 1
      b[at + 9] = 1
      ours.write(&b, at: at + 10)
      return 16
    }
  }

  /// An MLDv2 report of our solicited-node groups (RFC 3810 §5.2):
  /// record type 4 (changed to exclude: joined) unasked, 2 (is exclude)
  /// answering a query. From the link-local address once it's ours,
  /// else the unspecified one.
  mutating func sendMulticastReport(now: Int64, answering: Bool = false) {
    var groups: [IPv6Address] = []
    for i in 0..<ipv6.capacity where ipv6.addresses[i] != .any {
      let g = ipv6.addresses[i].solicitedNode
      if !groups.contains(g) { groups.append(g) }
    }
    guard !groups.isEmpty else { return }
    let source = ipv6.isOurs(linkLocalAddress) ? linkLocalAddress : .any
    let recordType: UInt8 = answering ? 2 : 4
    sendICMPv6(from: source, to: .mldv2Routers, hopLimit: 1, routerAlert: true, now: now) { b, at, _ in
      b[at] = 143
      b[at + 1] = 0
      b.put16(0, at + 4)
      b.put16(UInt16(groups.count), at + 6)
      var r = at + 8
      for g in groups {
        b[r] = recordType
        b[r + 1] = 0
        b.put16(0, r + 2)
        g.write(&b, at: r + 4)
        r += 20
      }
      return r - at
    }
  }

  // MARK: Receiving

  mutating func receiveMulticastQuery(_ f: [UInt8], at o: Int, length: Int, hopLimit: UInt8, now: Int64) {
    guard hopLimit == 1 && length >= 24 else {
      counters.malformed += 1
      return
    }
    sendMulticastReport(now: now, answering: true)
  }

  mutating func receiveNeighborSolicitation(_ f: [UInt8], at o: Int, length: Int, from source: IPv6Address,
                                            to destination: IPv6Address, hopLimit: UInt8, now: Int64) {
    let end = o + length
    guard hopLimit == 255, f[o + 1] == 0, length >= 24, NetStack.ndpOptionsValid(f, from: o + 24, to: end) else {
      counters.malformed += 1
      return
    }
    let target = IPv6Address(f, at: o + 8)
    let sourceLink = NetStack.ndpLinkAddress(f, from: o + 24, to: end, type: 1)
    // From the unspecified address: a duplicate check, which must go to a
    // solicited-node group and carry no link address.
    guard !target.isMulticast, source != .any || (destination == target.solicitedNode && sourceLink == nil) else {
      counters.malformed += 1
      return
    }
    counters.ndpIn += 1
    guard let i = ipv6.find(target) else { return }
    if ipv6.tentative[i] {
      // Another station checking the same address: it's theirs too, so
      // neither may use it (RFC 4862 §5.4.3).
      if source == .any { duplicate(i) }
      return
    }
    if source != .any, let m = sourceLink { learn(source, m, create: true, now: now) }
    if source == .any {
      sendNeighborAdvert(target, to: .allNodes, solicited: false, now: now)
    } else {
      sendNeighborAdvert(target, to: source, solicited: true, now: now)
    }
  }

  mutating func receiveNeighborAdvert(_ f: [UInt8], at o: Int, length: Int, hopLimit: UInt8, now: Int64) {
    let end = o + length
    guard hopLimit == 255, f[o + 1] == 0, length >= 24, NetStack.ndpOptionsValid(f, from: o + 24, to: end) else {
      counters.malformed += 1
      return
    }
    let target = IPv6Address(f, at: o + 8)
    guard !target.isMulticast else {
      counters.malformed += 1
      return
    }
    counters.ndpIn += 1
    if let i = ipv6.find(target) {
      // Someone else has our address: a tentative one is given up; a
      // valid one is kept, and the conflict counted (§5.4.4).
      if ipv6.tentative[i] { duplicate(i) } else { counters.duplicateAddresses += 1 }
      return
    }
    if let m = NetStack.ndpLinkAddress(f, from: o + 24, to: end, type: 2) { learn(target, m, create: false, now: now) }
  }

  /// Gives up a tentative address another station has.
  mutating func duplicate(_ i: Int) {
    ipv6.addresses[i] = .any
    ipv6.tentative[i] = false
    counters.duplicateAddresses += 1
  }

  mutating func receiveRouterAdvert(_ f: [UInt8], at o: Int, length: Int, from source: IPv6Address,
                                    hopLimit: UInt8, now: Int64) {
    let end = o + length
    guard hopLimit == 255, f[o + 1] == 0, length >= 16, source.isLinkLocal,
          NetStack.ndpOptionsValid(f, from: o + 16, to: end)
    else {
      counters.malformed += 1
      return
    }
    counters.ndpIn += 1
    nextRouterSolicitation = nil
    if f[o + 4] != 0 { self.hopLimit = f[o + 4] }
    if let m = NetStack.ndpLinkAddress(f, from: o + 16, to: end, type: 1) { learn(source, m, create: true, now: now) }
    let lifetime = f.be16(o + 6)
    updateRouter(source, until: lifetime == 0 ? nil : now + Int64(lifetime) * 1_000_000_000)
    var p = o + 16
    while p < end {
      let size = Int(f[p + 1]) * 8
      if f[p] == 3 && size == 32 { takePrefix(f, at: p, now: now) }
      p += size
    }
  }

  mutating func updateRouter(_ r: IPv6Address, until: Int64?) {
    var free: Int?
    for i in 0..<routers.capacity {
      if routers.addresses[i] == r {
        if let until { routers.until[i] = until } else { routers.addresses[i] = .any }
        return
      }
      if routers.addresses[i] == .any && free == nil { free = i }
    }
    if let until, let i = free {
      routers.addresses[i] = r
      routers.until[i] = until
    }
  }

  /// A prefix information option (RFC 4861 §4.6.2): on-link (L) and
  /// autonomous (A, RFC 4862 §5.5.3) prefixes.
  mutating func takePrefix(_ f: [UInt8], at p: Int, now: Int64) {
    let length = Int(f[p + 2]), flags = f[p + 3]
    let valid = f.be32(p + 4), preferred = f.be32(p + 8)
    let prefix = IPv6Address(f, at: p + 16)
    guard !prefix.isLinkLocal && !prefix.isMulticast && length <= 128 else { return }
    if flags & 0x80 != 0 && length > 0 {
      var slot: Int?
      for i in 0..<onLink.capacity where onLink.lengths[i] == length && onLink.prefixes[i] == prefix { slot = i }
      if valid == 0 {
        if let i = slot { onLink.lengths[i] = 0 }
      } else {
        if slot == nil {
          for i in 0..<onLink.capacity where onLink.lengths[i] == 0 && slot == nil { slot = i }
        }
        if let i = slot {
          onLink.prefixes[i] = prefix
          onLink.lengths[i] = length
          onLink.validUntil[i] = NetStack.deadline(valid, now: now)
        }
      }
    }
    // An address of the prefix and our interface ID, which needs a /64.
    guard flags & 0x40 != 0 && length == 64 && preferred <= valid else { return }
    let address = IPv6Address(hi: prefix.hi, lo: IPv6Address.interfaceID(mac))
    if let i = ipv6.find(address) {
      // The two-hour rule (§5.5.3 e): an advert can't cut a lifetime
      // below two hours, so a forged one can't take the address away.
      let remaining = ipv6.validUntil[i] == Int64.max ? Int64.max : ipv6.validUntil[i] - now
      let offered = valid == UInt32.max ? Int64.max : Int64(valid) * 1_000_000_000
      if offered > NetStack.twoHours || offered > remaining {
        ipv6.validUntil[i] = NetStack.deadline(valid, now: now)
      } else if remaining > NetStack.twoHours {
        ipv6.validUntil[i] = now + NetStack.twoHours
      }
      ipv6.preferredUntil[i] = NetStack.deadline(preferred, now: now)
    } else if valid > 0 {
      beginAddress(address, validUntil: NetStack.deadline(valid, now: now),
                   preferredUntil: NetStack.deadline(preferred, now: now), now: now)
    }
  }
}
