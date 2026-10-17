// SPDX-License-Identifier: BSD-3-Clause

// /net's interface files, as Plan 9's ip(3) prints them: `ipifc` (the one
// interface, 0, and its ctl), `iproute`, `arp`, `ipselftab`, and `ndb`
// (what DHCP said, as ipconfig leaves it for cs and dns).

import Net
import Node
import Sys

extension IP {
  func files() {
    tree.directory(file("ipifc"))
    tree.directory(file("ipifc/0"))
    tree.text(file("ipifc/stats"), read: { [self] in lock.withLock { interfaceStats() } })
    tree.text(file("ipifc/0/status"), read: { [self] in lock.withLock { interfaceStatus() } })
    tree.text(file("ipifc/0/local"), read: { [self] in lock.withLock { interfaceLocal() } })
    tree.text(file("ipifc/0/ctl"), read: { "0" }, write: { [self] (line: String) throws(NodeError) in
      try interfaceControl(Array(line.utf8))
    })
    tree.text(file("iproute"), read: { [self] in lock.withLock { routes() } },
              write: { [self] (line: String) throws(NodeError) in try routeControl(Array(line.utf8)) })
    tree.text(file("arp"), read: { [self] in lock.withLock { neighbors() } })
    tree.text(file("ipselftab"), read: { [self] in lock.withLock { selfTable() } })
    tree.text(file("ndb"), read: { [self] in lock.withLock { ndb() } })
  }

  // MARK: ipifc

  func interfaceStats() -> String {
    let n = stack.counters
    return "ipin: \(n.ipv4In + n.ipv6In)\nipv4in: \(n.ipv4In)\nipv6in: \(n.ipv6In)\narpin: \(n.arpIn)\n"
      + "malformed: \(n.malformed)\nbadchecksums: \(n.badChecksums)\nfragments: \(n.fragments)\n"
      + "echoes: \(n.echoesAnswered)\nunresolved: \(n.unresolved)\nduplicates: \(n.duplicateAddresses)\n"
  }

  /// Plan 9's first line (the router advertisement fields as a host's),
  /// then an address a line: the address, its mask, its network, and its
  /// valid and preferred lifetimes in milliseconds.
  func interfaceStatus() -> String {
    let n = stack.counters
    var out = "device \(link.device) maxtu \(stack.mtu + 14) sendra 0 recvra 1 mflag 0 oflag 0 maxraint 600000"
      + " minraint 200000 linkmtu 0 reachtime 0 rxmitra 0 ttl 255 routerlt 0 pktin \(n.framesIn) pktout \(framesOut)"
      + " errin \(n.malformed + n.badChecksums) errout 0 speed 0 delay 40\n"
    var any = false
    if stack.ipv4 != .any {
      let lifetime = stack.dhcp.state == .off ? "4294967295" : "\(UInt64(stack.dhcp.leaseSeconds) * 1000)"
      let network = IPv4Address(stack.ipv4.value & IPv4Address.mask(stack.prefixLength))
      out += "\t" + IP.pad(stack.ipv4.text, 40) + " " + IP.pad("/\(96 + stack.prefixLength)", 10) + " "
        + IP.pad(network.text, 40) + " " + IP.pad(lifetime, 12) + " " + IP.pad(lifetime, 12) + "\n"
      any = true
    }
    for a in stack.ipv6Addresses {
      let length = a.isLinkLocal ? 64 : (stack.ipv6Prefixes.first { a.hasPrefix($0.prefix, length: $0.length) }?.length ?? 64)
      out += "\t" + IP.pad(a.text, 40) + " " + IP.pad("/\(length)", 10) + " " + IP.pad(IP.network(a, length).text, 40)
        + " " + IP.pad("4294967295", 12) + " " + IP.pad("4294967295", 12) + "\n"
      any = true
    }
    return any ? out : out + "\n"
  }

  func interfaceLocal() -> String {
    var out = ""
    if stack.ipv4 != .any { out += IP.pad(stack.ipv4.text, 40) + " ->\n" }
    for a in stack.ipv6Addresses { out += IP.pad(a.text, 40) + " ->\n" }
    return out
  }

  /// ipifc's ctl: `add LOCAL MASK` gives the interface its IPv4 address
  /// (`try` too), `remove LOCAL MASK` takes it away. The device is bound
  /// already; there is one interface.
  func interfaceControl(_ bytes: [UInt8]) throws(NodeError) {
    let words = IP.words(bytes)
    guard let verb = words.first else { throw .invalid }
    func named(_ name: String) -> Bool { verb.elementsEqual(name.utf8) }
    try settled(Clock.monotonic()) { () throws(NodeError) in
      if named("add") || named("try") {
        guard words.count >= 2, let address = IPv4Address(String(decoding: words[1], as: UTF8.self)) else {
          throw .invalid
        }
        let length = words.count >= 3 ? try IP.prefixLength(words[2]) : 24
        stack.configureIPv4(address, prefixLength: length, gateway: stack.gateway)
      } else if named("remove") {
        guard words.count >= 2, IPv4Address(String(decoding: words[1], as: UTF8.self)) == stack.ipv4 else {
          throw .invalid
        }
        stack.configureIPv4(.any, prefixLength: 0, gateway: nil)
      } else {
        throw .invalid
      }
    }
  }

  // MARK: iproute

  /// A route a line, as Plan 9's: target, mask, next hop, type, tag,
  /// interface, source and its mask. They follow from the interface's
  /// addresses, its gateway and IPv6's routers.
  func routes() -> String {
    var out = ""
    func route(_ target: String, _ mask: Int, _ hop: String, _ type: String, v4: Bool) {
      let any = v4 ? "0.0.0.0" : "::"
      out += IP.pad(target, 15) + " " + IP.pad("/\(mask)", 4) + " " + IP.pad(hop, 15) + " " + IP.pad(type, 4)
        + " none   0 " + IP.pad(any, 15) + " " + (v4 ? "/96" : "/0") + "\n"
    }
    if stack.ipv4 != .any {
      if let g = stack.gateway { route("0.0.0.0", 96, g.text, "4", v4: true) }
      let network = IPv4Address(stack.ipv4.value & IPv4Address.mask(stack.prefixLength))
      route(network.text, 96 + stack.prefixLength, network.text, "4i", v4: true)
      route(stack.ipv4.text, 128, stack.ipv4.text, "4u", v4: true)
    }
    if let r = stack.ipv6Routers.first { route("::", 0, r.text, "6", v4: false) }
    route("fe80::", 64, "fe80::", "6i", v4: false)
    for p in stack.ipv6Prefixes { route(p.prefix.text, p.length, p.prefix.text, "6i", v4: false) }
    for a in stack.ipv6Addresses { route(a.text, 128, a.text, "6u", v4: false) }
    return out
  }

  /// iproute's ctl: `add 0 0 GATEWAY` (or `0.0.0.0 0.0.0.0`) sets IPv4's
  /// default route, `del 0 0` removes it; the others follow from the
  /// interface.
  func routeControl(_ bytes: [UInt8]) throws(NodeError) {
    let words = IP.words(bytes)
    guard words.count >= 3, let verb = words.first else { throw .invalid }
    func zero(_ w: [UInt8]) -> Bool { w.elementsEqual("0".utf8) || w.elementsEqual("0.0.0.0".utf8) }
    guard zero(words[1]), zero(words[2]) else { throw .invalid }
    try settled(Clock.monotonic()) { () throws(NodeError) in
      if verb.elementsEqual("add".utf8), words.count >= 4,
        let g = IPv4Address(String(decoding: words[3], as: UTF8.self))
      {
        stack.configureIPv4(stack.ipv4, prefixLength: stack.prefixLength, gateway: g)
      } else if verb.elementsEqual("del".utf8) {
        stack.configureIPv4(stack.ipv4, prefixLength: stack.prefixLength, gateway: nil)
      } else {
        throw .invalid
      }
    }
  }

  // MARK: arp, ipselftab, ndb

  func neighbors() -> String {
    var out = ""
    for n in stack.neighborEntries {
      let mac = n.resolved ? IP.hex(n.mac) : ""
      out += "ether  " + IP.pad(n.resolved ? "OK" : "WAIT", 4) + " " + IP.pad(IP.text(n.address), 40) + " "
        + IP.pad(mac, 16) + " " + IP.text(interfaceAddress(for: n.address)) + "\n"
    }
    return out
  }

  /// The addresses taken as ours: each with its count of interfaces (one)
  /// and its type.
  func selfTable() -> String {
    var out = ""
    func entry(_ address: String, _ type: String) { out += IP.pad(address, 44) + " 01 " + IP.pad(type, 4) + "\n" }
    if stack.ipv4 != .any {
      entry(stack.ipv4.text, "4u")
      let broadcast = IPv4Address(stack.ipv4.value | ~IPv4Address.mask(stack.prefixLength))
      entry(broadcast.text, "4b")
    }
    entry("255.255.255.255", "4b")
    for a in stack.ipv6Addresses { entry(a.text, "6u") }
    return out
  }

  /// What DHCP gave, as ipconfig writes it.
  func ndb() -> String {
    let d = stack.dhcp
    guard stack.ipv4 != .any else { return "" }
    let mask = IPv4Address(IPv4Address.mask(stack.prefixLength))
    var out = "ip=\(stack.ipv4.text) ipmask=\(mask.text)"
    if let g = stack.gateway { out += " ipgw=\(g.text)" }
    out += "\n"
    for s in d.nameServers { out += "\tdns=\(s.text)\n" }
    return out
  }

  // MARK: Text

  static func pad(_ s: String, _ width: Int) -> String {
    let n = s.utf8.count
    return n >= width ? s : s + String(repeating: " ", count: width - n)
  }

  static func hex(_ mac: MACAddress) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    for i in stride(from: 40, through: 0, by: -8) {
      let b = Int((mac.value >> UInt64(i)) & 0xFF)
      out += [digits[b >> 4], digits[b & 15]]
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// `a`'s first `length` bits.
  static func network(_ a: IPv6Address, _ length: Int) -> IPv6Address {
    let hiMask: UInt64 = length >= 64 ? .max : (length == 0 ? 0 : ~(UInt64.max >> UInt64(length)))
    let loMask: UInt64 = length >= 128 ? .max : (length <= 64 ? 0 : ~(UInt64.max >> UInt64(length - 64)))
    return IPv6Address(hi: a.hi & hiMask, lo: a.lo & loMask)
  }

  static func words(_ bytes: [UInt8]) -> [[UInt8]] {
    var line = bytes
    while let last = line.last, last == 0x0A || last == 0x20 { line.removeLast() }
    return line.split(separator: 0x20).map { Array($0) }
  }

  /// A mask as a ctl line gives it: dotted IPv4 (`255.255.255.0`), or
  /// `/24` (or IPv6's `/120`).
  static func prefixLength(_ word: [UInt8]) throws(NodeError) -> Int {
    if word.first == 0x2F {
      guard let n = Int(String(decoding: word.dropFirst(), as: UTF8.self)), n >= 0, n <= 128 else { throw .invalid }
      let length = n > 32 ? n - 96 : n
      guard length >= 0 else { throw .invalid }
      return length
    }
    guard let m = IPv4Address(String(decoding: word, as: UTF8.self)) else { throw .invalid }
    let length = m.value.leadingZeroBitCount == 0 ? (~m.value).leadingZeroBitCount : 0
    guard IPv4Address.mask(length) == m.value else { throw .invalid }
    return length
  }
}
