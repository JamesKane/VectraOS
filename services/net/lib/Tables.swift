// SPDX-License-Identifier: BSD-3-Clause

// The stack's tables as its owner shows them (ip(3)'s iproute, ipifc and
// arp): IPv6's on-link prefixes, its default routers, and the neighbour
// cache, read only.

/// A neighbour cache entry: an address, IPv4's mapped, and its MAC once
/// resolved.
public struct Neighbor: Equatable, Sendable {
  public var address: IPv6Address
  public var mac: MACAddress
  public var resolved: Bool
}

extension NetStack {
  /// IPv6's on-link prefixes and their lengths.
  public var ipv6Prefixes: [(prefix: IPv6Address, length: Int)] {
    var out: [(prefix: IPv6Address, length: Int)] = []
    for i in 0..<onLink.capacity where onLink.lengths[i] != 0 { out.append((onLink.prefixes[i], onLink.lengths[i])) }
    return out
  }

  /// IPv6's default routers, by their link-local addresses.
  public var ipv6Routers: [IPv6Address] {
    var out: [IPv6Address] = []
    for i in 0..<routers.capacity where routers.addresses[i] != .any { out.append(routers.addresses[i]) }
    return out
  }

  /// The neighbour cache's entries.
  public var neighborEntries: [Neighbor] {
    var out: [Neighbor] = []
    for i in 0..<neighbors.capacity where neighbors.addresses[i] != .any {
      out.append(Neighbor(address: neighbors.addresses[i], mac: MACAddress(neighbors.macs[i]),
                          resolved: neighbors.resolved[i]))
    }
    return out
  }
}
