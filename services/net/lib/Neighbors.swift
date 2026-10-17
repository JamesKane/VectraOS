// SPDX-License-Identifier: BSD-3-Clause

// Neighbours: the link addresses of next hops (N1b), for ARP (RFC 826)
// and IPv6's neighbour discovery (RFC 4861 §7.2) alike, IPv4 next hops
// kept as IPv4-mapped addresses. The cache is parallel arrays, an entry a
// slot. A resolved entry lives two minutes (simpler than RFC 4861's
// reachability states: an entry that lapses is asked for again). An
// unresolved one is asked for once a second, three times (RFC 4861's
// MAX_MULTICAST_SOLICIT and RETRANS_TIMER), while the packets for it wait
// in `pending`; then they are dropped.

struct NeighborCache {
  static let lifetime: Int64 = 120_000_000_000
  static let retry: Int64 = 1_000_000_000
  static let maxRequests = 3

  let capacity: Int
  /// The entry's address; `any` for a free slot.
  var addresses: [IPv6Address]
  var macs: [UInt64]
  var resolved: [Bool]
  /// A resolved entry's expiry, or when an unresolved one asks again.
  var deadlines: [Int64]
  /// Requests sent for an unresolved entry.
  var requests: [Int]

  init(capacity: Int) {
    self.capacity = capacity
    addresses = [IPv6Address](repeating: .any, count: capacity)
    macs = [UInt64](repeating: 0, count: capacity)
    resolved = [Bool](repeating: false, count: capacity)
    deadlines = [Int64](repeating: 0, count: capacity)
    requests = [Int](repeating: 0, count: capacity)
  }

  func find(_ a: IPv6Address) -> Int? {
    for i in 0..<capacity where addresses[i] == a { return i }
    return nil
  }

  /// A slot for `a`: a free one, else the resolved entry nearest expiry.
  /// Nil if every slot is waiting on a resolution.
  mutating func take(_ a: IPv6Address) -> Int? {
    var victim: Int?
    for i in 0..<capacity {
      if addresses[i] == .any {
        victim = i
        break
      }
      if resolved[i] && (victim == nil || deadlines[i] < deadlines[victim!]) { victim = i }
    }
    guard let i = victim else { return nil }
    addresses[i] = a
    resolved[i] = false
    requests[i] = 0
    return i
  }

  mutating func free(_ i: Int) {
    addresses[i] = .any
    resolved[i] = false
  }

  /// The link address of `a`, if resolved.
  func mac(_ a: IPv6Address) -> MACAddress? {
    guard let i = find(a), resolved[i] else { return nil }
    return MACAddress(macs[i])
  }

  var nextDeadline: Int64? {
    var next: Int64?
    for i in 0..<capacity where addresses[i] != .any {
      if next == nil || deadlines[i] < next! { next = deadlines[i] }
    }
    return next
  }
}

/// Frames waiting for their next hop's link address: built whole, the
/// Ethernet destination filled in when it resolves.
struct PendingFrames {
  let capacity: Int
  var bytes: [UInt8]
  /// A slot's frame length; 0 for a free slot.
  var lengths: [Int]
  var nextHops: [IPv6Address]

  init(capacity: Int) {
    self.capacity = capacity
    bytes = [UInt8](repeating: 0, count: capacity * FrameQueue.slotSize)
    lengths = [Int](repeating: 0, count: capacity)
    nextHops = [IPv6Address](repeating: .any, count: capacity)
  }

  func offset(_ i: Int) -> Int { i * FrameQueue.slotSize }

  func freeSlot() -> Int? {
    for i in 0..<capacity where lengths[i] == 0 { return i }
    return nil
  }
}

extension NetStack {
  /// Records `a` at `mac`, creating the entry if `create`, and sends what
  /// waited for it. Whether it is (now) in the cache.
  @discardableResult
  mutating func learn(_ a: IPv6Address, _ mac: MACAddress, create: Bool, now: Int64) -> Bool {
    guard !mac.isGroup && mac != .zero else { return false }
    var slot = neighbors.find(a)
    if slot == nil && create { slot = neighbors.take(a) }
    guard let i = slot else { return false }
    neighbors.macs[i] = mac.value
    neighbors.resolved[i] = true
    neighbors.deadlines[i] = now + NeighborCache.lifetime
    for p in 0..<pending.capacity where pending.lengths[p] != 0 && pending.nextHops[p] == a {
      if let o = transmit.reserve() {
        let from = pending.offset(p)
        for k in 0..<pending.lengths[p] { transmit.bytes[o + k] = pending.bytes[from + k] }
        mac.write(&transmit.bytes, at: o)
        transmit.commit(pending.lengths[p])
      }
      pending.lengths[p] = 0
    }
    return true
  }

  /// Asks for `hop`'s link address: by ARP for IPv4, by a neighbour
  /// solicitation for IPv6.
  mutating func solicit(_ hop: IPv6Address, now: Int64) {
    if let v4 = hop.mappedIPv4 {
      sendARP(operation: 1, to: .broadcast, targetMAC: .zero, target: v4)
    } else {
      sendNeighborSolicitation(hop, now: now)
    }
  }

  /// Sends a frame to `hop`: built now by `build` (the bytes, the frame's
  /// offset, its Ethernet destination; it returns the frame's length),
  /// straight out if the link address is known (or `mac` gives it), else
  /// waiting while it's asked for. False if there's no room.
  mutating func send(via hop: IPv6Address, mac known: MACAddress?, now: Int64,
                     build: (inout [UInt8], Int, MACAddress) -> Int) -> Bool {
    if let m = known ?? neighbors.mac(hop) {
      guard let o = transmit.reserve() else { return false }
      transmit.commit(build(&transmit.bytes, o, m))
      return true
    }
    guard let slot = pending.freeSlot() else {
      counters.unresolved += 1
      return false
    }
    let n = build(&pending.bytes, pending.offset(slot), .zero)
    pending.lengths[slot] = n
    pending.nextHops[slot] = hop
    if neighbors.find(hop) == nil {
      guard let i = neighbors.take(hop) else {
        pending.lengths[slot] = 0
        counters.unresolved += 1
        return false
      }
      neighbors.requests[i] = 1
      neighbors.deadlines[i] = now + NeighborCache.retry
      solicit(hop, now: now)
    }
    return true
  }

  mutating func pollNeighbors(now: Int64) {
    for i in 0..<neighbors.capacity where neighbors.addresses[i] != .any && neighbors.deadlines[i] <= now {
      let a = neighbors.addresses[i]
      if neighbors.resolved[i] {
        neighbors.free(i)
      } else if neighbors.requests[i] >= NeighborCache.maxRequests {
        for p in 0..<pending.capacity where pending.lengths[p] != 0 && pending.nextHops[p] == a {
          pending.lengths[p] = 0
          counters.unresolved += 1
        }
        neighbors.free(i)
      } else {
        neighbors.requests[i] += 1
        neighbors.deadlines[i] = now + NeighborCache.retry
        solicit(a, now: now)
      }
    }
  }
}
