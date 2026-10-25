// SPDX-License-Identifier: BSD-3-Clause

// The network stack's core (N1b; architecture §9): one interface's
// protocols, written from the RFCs, with no I/O of its own. Frames come in
// through `receive` with the time; frames to send collect in `transmit`
// for the device's owner to drain; `poll` runs the timers, and
// `nextDeadline` says when it next needs to. The same core runs hosted
// over a TAP device and natively over the net class's rings.
//
// Times are monotonic nanoseconds. Nothing here allocates per frame: the
// queues and tables are packed arrays sized at the start and reused.

public struct NetStack {
  public struct Counters: Sendable {
    public var framesIn = 0
    /// Frames for another station, or of a type we don't speak.
    public var ignored = 0
    /// Frames too short for their headers, or with lengths that disagree.
    public var malformed = 0
    public var badChecksums = 0
    /// IPv4 fragments: not reassembled (a LAN at 1500 bytes doesn't send them).
    public var fragments = 0
    public var arpIn = 0
    public var ipv4In = 0
    public var echoesAnswered = 0
    public var ipv6In = 0
    /// Neighbour discovery's messages taken (solicitations, adverts, router adverts).
    public var ndpIn = 0
    /// Our addresses found in use by another station (RFC 4862 §5.4.5).
    public var duplicateAddresses = 0
    public var udpIn = 0
    /// Datagrams dropped because their endpoint's ring was full.
    public var udpDropped = 0
    public var portsUnreachable = 0
    /// DHCP offers declined: the address answered an ARP probe.
    public var dhcpDeclined = 0
    public var tcpSegmentsIn = 0, tcpSegmentsOut = 0, tcpBytesIn = 0, tcpBytesOut = 0
    public var tcpRetransmits = 0, tcpFastRetransmits = 0, tcpTimeouts = 0
    /// Resends found lost themselves in recovery, and sent again; tail
    /// loss probes sent.
    public var tcpLostRetransmits = 0, tcpProbes = 0
    /// Resets sent, connections refused (no listener, or its backlog full),
    /// and challenge ACKs sent (RFC 5961).
    public var tcpResetsOut = 0, tcpRefused = 0, tcpChallenges = 0
    /// Packets dropped waiting for an address that never resolved.
    public var unresolved = 0
  }

  public let mac: MACAddress
  public let mtu: Int
  public internal(set) var ipv4 = IPv4Address.any
  public internal(set) var prefixLength = 0
  public internal(set) var gateway: IPv4Address?

  /// Frames to send, in order.
  public var transmit: FrameQueue
  public internal(set) var counters = Counters()

  var neighbors = NeighborCache(capacity: 64)
  var pending = PendingFrames(capacity: 32)
  var nextIPv4ID: UInt16 = 1

  var udp: UDPEndpoints
  var lastICMPError = Int64.min / 2
  /// The DHCPv4 client (DHCP.swift).
  public internal(set) var dhcp = DHCPClient()

  /// TCP's connections (TCP.swift) and their rings.
  var tcp: [TCPConnection]
  let tcpStorage: TCPStorage
  var nextTCPPort: UInt16 = 49152
  /// The key for initial sequence numbers (RFC 6528): the owner sets it
  /// from its randomness before connections open.
  public var tcpSecret: [UInt8] = []

  /// IPv6, once `startIPv6` has run (IPv6.swift).
  public internal(set) var ipv6Started = false
  var ipv6 = IPv6Addresses(capacity: 8)
  var onLink = IPv6Prefixes(capacity: 8)
  var routers = IPv6Routers(capacity: 4)
  /// The hop limit a router advertised, else 64.
  var hopLimit: UInt8 = 64
  /// Router solicitations sent, and when the next is due (RFC 4861 §6.3.7).
  var routerSolicitations = 0
  var nextRouterSolicitation: Int64?

  /// `udpEndpoints` endpoints can be open at once, `udpSlots` datagrams
  /// waiting on each; `tcpConnections` TCP connections and listeners,
  /// with send and receive rings of `tcpBuffer` bytes each.
  public init(mac: MACAddress, mtu: Int = 1500, transmitCapacity: Int = 256, udpEndpoints: Int = 16, udpSlots: Int = 16,
              tcpConnections: Int = 16, tcpBuffer: Int = 256 * 1024) {
    self.mac = mac
    self.mtu = mtu
    transmit = FrameQueue(capacity: transmitCapacity)
    udp = UDPEndpoints(capacity: udpEndpoints, slots: udpSlots)
    tcp = [TCPConnection](repeating: TCPConnection(), count: tcpConnections)
    tcpStorage = TCPStorage(connections: tcpConnections, size: tcpBuffer)
  }

  /// Gives the interface an IPv4 address on a subnet, and a default
  /// route through `gateway` if there is one.
  public mutating func configureIPv4(_ address: IPv4Address, prefixLength: Int, gateway: IPv4Address? = nil) {
    precondition(prefixLength >= 0 && prefixLength <= 32)
    ipv4 = address
    self.prefixLength = prefixLength
    self.gateway = gateway
  }

  /// Takes one received frame: the first `length` bytes of `frame`,
  /// Ethernet without the FCS.
  public mutating func receive(_ frame: [UInt8], length: Int, now: Int64) {
    counters.framesIn += 1
    guard length >= Ethernet.headerSize && length <= frame.count else {
      counters.malformed += 1
      return
    }
    let destination = MACAddress(frame, at: 0)
    guard destination == mac || destination == .broadcast || isOurGroup(destination) else {
      counters.ignored += 1
      return
    }
    switch frame.be16(12) {
    case Ethernet.typeARP: receiveARP(frame, length: length, now: now)
    case Ethernet.typeIPv4: receiveIPv4(frame, length: length, now: now)
    case Ethernet.typeIPv6: receiveIPv6(frame, length: length, now: now)
    default: counters.ignored += 1
    }
  }

  /// Runs the timers due by `now`: address resolution's retries and
  /// expiries, and IPv6's address and router timers.
  public mutating func poll(now: Int64) {
    pollNeighbors(now: now)
    pollIPv6(now: now)
    pollDHCP(now: now)
    pollTCP(now: now)
  }

  /// When `poll` next has work, or nil if nothing is waiting on time.
  public var nextDeadline: Int64? {
    var next = earlier(neighbors.nextDeadline, ipv6.nextDeadline)
    next = earlier(next, earlier(onLink.nextDeadline, routers.nextDeadline))
    next = earlier(next, earlier(nextRouterSolicitation, dhcp.deadline))
    return earlier(next, tcpDeadline)
  }
}

/// The earlier of two deadlines, either perhaps absent.
@inline(__always) func earlier(_ a: Int64?, _ b: Int64?) -> Int64? {
  guard let a else { return b }
  guard let b else { return a }
  return min(a, b)
}

enum Ethernet {
  static let headerSize = 14
  static let typeIPv4: UInt16 = 0x0800
  static let typeARP: UInt16 = 0x0806
  static let typeIPv6: UInt16 = 0x86DD

  /// Writes a header at `offset`: destination, source, type.
  static func writeHeader(_ b: inout [UInt8], at offset: Int, destination: MACAddress, source: MACAddress,
                          type: UInt16) {
    destination.write(&b, at: offset)
    source.write(&b, at: offset + 6)
    b.put16(type, offset + 12)
  }
}
