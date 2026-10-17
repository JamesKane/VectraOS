// SPDX-License-Identifier: BSD-3-Clause

// IPv6 in the stack's core (N1b part b2): addresses' text forms (RFC
// 5952), the modified EUI-64, the duplicate check and its conflicts,
// neighbour solicitations answered, router adverts and SLAAC (with the
// two-hour rule), echoes, and what is refused. Then Linux against it:
// ping -6 to the link-local and SLAAC addresses with dnsmasq advertising
// a prefix, and a duplicate found when Linux already holds our address.

import FoundationEssentials
import Glibc
@testable import Net
import Testing

let routerMAC = MACAddress(0x0200_0000_00AA)
let routerLL = IPv6Address("fe80::aa")!
let theirLL = IPv6Address("fe80::1")!
let ourLL = IPv6Address("fe80::5054:ff:fe12:3456")!
let ourGlobal = IPv6Address("fd00::5054:ff:fe12:3456")!
let second: Int64 = 1_000_000_000

/// An IPv6 frame carrying ICMPv6 `body`, its checksum filled in.
func icmp6Frame(from source: IPv6Address, to destination: IPv6Address, mac: MACAddress = theirs,
                toMAC: MACAddress? = nil, hopLimit: UInt8 = 255, _ body: [UInt8]) -> [UInt8] {
  var f = [UInt8](repeating: 0, count: 14 + 40 + body.count)
  let dmac = toMAC ?? (destination.isMulticast ? destination.multicastMAC : ours)
  Ethernet.writeHeader(&f, at: 0, destination: dmac, source: mac, type: Ethernet.typeIPv6)
  f[14] = 0x60
  f.put16(UInt16(body.count), 18)
  f[20] = 58
  f[21] = hopLimit
  source.write(&f, at: 22)
  destination.write(&f, at: 38)
  for (i, b) in body.enumerated() { f[54 + i] = b }
  var c = InternetChecksum.ipv6(source, destination, length: body.count, next: 58)
  c.add(f, 54, body.count)
  f.put16(c.value, 56)
  return f
}

func bytes(_ a: IPv6Address) -> [UInt8] {
  var b = [UInt8](repeating: 0, count: 16)
  a.write(&b, at: 0)
  return b
}

func macBytes(_ m: MACAddress) -> [UInt8] {
  var b = [UInt8](repeating: 0, count: 6)
  m.write(&b, at: 0)
  return b
}

/// The ICMPv6 messages queued: (type, source, destination, body).
func sentICMPv6(_ s: NetStack) -> [(type: UInt8, source: IPv6Address, destination: IPv6Address, frame: [UInt8])] {
  (0..<s.transmit.count).compactMap { i in
    let f = s.transmit.frame(i)
    guard f.be16(12) == Ethernet.typeIPv6 else { return nil }
    var at = 54
    if f[20] == 0 { at += (Int(f[55]) + 1) * 8 }  // hop-by-hop
    return (f[at], IPv6Address(f, at: 22), IPv6Address(f, at: 38), f)
  }
}

/// A stack whose link-local address has passed its check, at time 1 s.
func started() -> NetStack {
  var s = stack()
  s.startIPv6(now: 0)
  s.poll(now: second)
  s.transmit.removeAll()
  return s
}

@Test func addressesReadAndPrintAsTheRFCsSay() {
  for (text, canonical) in [("2001:db8::1", "2001:db8::1"), ("::", "::"), ("::1", "::1"),
                            ("2001:DB8:0:0:1:0:0:1", "2001:db8::1:0:0:1"), ("2001:0:0:1:0:0:0:1", "2001:0:0:1::1"),
                            ("2001:db8:0:1:1:1:1:1", "2001:db8:0:1:1:1:1:1"), ("fe80::5054:ff:fe12:3456", "fe80::5054:ff:fe12:3456"),
                            ("1:0:0:0:0:0:0:0", "1::"), ("0:0:0:0:0:0:0:1", "::1")] {
    #expect(IPv6Address(text)?.text == canonical, "\(text)")
  }
  for bad in ["", ":", ":1", "1:", "1::2::3", "12345::", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7", "g::", ":::"] {
    #expect(IPv6Address(bad) == nil, "\(bad)")
  }
  // RFC 4291 appendix A: the MAC's halves around ff:fe, U/L flipped.
  #expect(IPv6Address.linkLocal(IPv6Address.interfaceID(ours)) == ourLL)
  #expect(ourLL.solicitedNode == IPv6Address("ff02::1:ff12:3456")! && ourLL.solicitedNode.multicastMAC.text == "33:33:ff:12:34:56")
  #expect(ourGlobal.hasPrefix(IPv6Address("fd00::")!, length: 64) && !ourGlobal.hasPrefix(IPv6Address("fd01::")!, length: 16))
  #expect(IPv6Address(mapping: ourIP).mappedIPv4 == ourIP && ourLL.mappedIPv4 == nil)
}

@Test func theLinkLocalAddressIsCheckedThenRoutersAskedFor() {
  var s = stack()
  s.startIPv6(now: 0)
  let first = sentICMPv6(s)
  // The MLDv2 report (from ::, hop-by-hop router alert), then the check:
  // a solicitation from :: to the solicited-node group, no link address.
  #expect(first.map { $0.type } == [143, 135])
  #expect(first[0].destination == .mldv2Routers && first[0].frame[20] == 0 && first[0].frame[21] == 1)
  #expect(first[1].source == .any && first[1].destination == ourLL.solicitedNode && first[1].frame.count == 14 + 40 + 24)
  #expect(MACAddress(first[1].frame, at: 0).text == "33:33:ff:12:34:56")
  #expect(IPv6Address(first[1].frame, at: 62) == ourLL)
  #expect(s.ipv6Addresses.isEmpty && s.nextDeadline == second)
  s.transmit.removeAll()
  // A second without objection: ours, and routers solicited from it, three
  // times four seconds apart.
  s.poll(now: second)
  #expect(s.ipv6Addresses == [ourLL])
  var solicitations = sentICMPv6(s).filter { $0.type == 133 }.count
  #expect(sentICMPv6(s).first?.source == ourLL && sentICMPv6(s).first?.destination == .allRouters)
  var now = second
  while let d = s.nextDeadline {
    s.transmit.removeAll()
    now = d
    s.poll(now: now)
    solicitations += sentICMPv6(s).filter { $0.type == 133 }.count
  }
  #expect(solicitations == 3 && now == second + 8 * second)
}

@Test func aDuplicateIsGivenUp() {
  // Someone answers our check: the address is theirs.
  var s = stack()
  s.startIPv6(now: 0)
  let na = icmp6Frame(from: ourLL, to: .allNodes, [136, 0, 0, 0, 0x20, 0, 0, 0] + bytes(ourLL) + [2, 1] + macBytes(theirs))
  s.receive(na, length: na.count, now: 1000)
  s.poll(now: second)
  #expect(s.ipv6Addresses.isEmpty && s.counters.duplicateAddresses == 1)
  // Someone checks the same address at the same time: neither has it.
  var t = stack()
  t.startIPv6(now: 0)
  let check = icmp6Frame(from: .any, to: ourLL.solicitedNode, [135, 0, 0, 0, 0, 0, 0, 0] + bytes(ourLL))
  t.receive(check, length: check.count, now: 1000)
  t.poll(now: second)
  #expect(t.ipv6Addresses.isEmpty && t.counters.duplicateAddresses == 1)
  // Once ours, another's check is answered for all nodes, unsolicited.
  var u = started()
  u.receive(check, length: check.count, now: 2 * second)
  let answer = sentICMPv6(u)
  #expect(answer.count == 1 && answer[0].type == 136 && answer[0].destination == .allNodes)
  #expect(answer[0].frame[58] == 0x20 && u.ipv6Addresses == [ourLL])
}

@Test func solicitationsAreAnswered() {
  var s = started()
  let ns = icmp6Frame(from: theirLL, to: ourLL.solicitedNode,
                      [135, 0, 0, 0, 0, 0, 0, 0] + bytes(ourLL) + [1, 1] + macBytes(theirs))
  s.receive(ns, length: ns.count, now: 2 * second)
  let na = sentICMPv6(s)
  #expect(na.count == 1 && na[0].type == 136 && na[0].source == ourLL && na[0].destination == theirLL)
  let f = na[0].frame
  #expect(MACAddress(f, at: 0) == theirs && f[58] == 0x60 && IPv6Address(f, at: 62) == ourLL)
  #expect(f[78] == 2 && MACAddress(f, at: 80) == ours && f[21] == 255)
  #expect(s.neighbors.mac(theirLL) == theirs)
  // Not from this link (hop limit below 255), or for someone else: no.
  s.transmit.removeAll()
  let far = icmp6Frame(from: theirLL, to: ourLL.solicitedNode, hopLimit: 254,
                       [135, 0, 0, 0, 0, 0, 0, 0] + bytes(ourLL) + [1, 1] + macBytes(theirs))
  s.receive(far, length: far.count, now: 2 * second)
  let other = icmp6Frame(from: theirLL, to: IPv6Address("fe80::9")!.solicitedNode,
                         [135, 0, 0, 0, 0, 0, 0, 0] + bytes(IPv6Address("fe80::9")!) + [1, 1] + macBytes(theirs))
  s.receive(other, length: other.count, now: 2 * second)
  let badOption = icmp6Frame(from: theirLL, to: ourLL.solicitedNode,
                             [135, 0, 0, 0, 0, 0, 0, 0] + bytes(ourLL) + [1, 0] + macBytes(theirs))
  s.receive(badOption, length: badOption.count, now: 2 * second)
  #expect(s.transmit.isEmpty && s.counters.malformed == 2)
}

func routerAdvert(lifetime: UInt16 = 1800, valid: UInt32 = 86400, preferred: UInt32 = 14400,
                  flags: UInt8 = 0xC0) -> [UInt8] {
  var body: [UInt8] = [134, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  body.put16(lifetime, 6)
  body += [1, 1] + macBytes(routerMAC)
  var prefix: [UInt8] = [3, 4, 64, flags, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + bytes(IPv6Address("fd00::")!)
  prefix.put32(valid, 4)
  prefix.put32(preferred, 8)
  body += prefix
  return icmp6Frame(from: routerLL, to: .allNodes, mac: routerMAC, body)
}

@Test func routerAdvertsGiveAnAddressAndARoute() {
  var s = started()
  let ra = routerAdvert()
  s.receive(ra, length: ra.count, now: 2 * second)
  // The SLAAC address is tentative: checked first.
  #expect(s.ipv6Addresses == [ourLL] && sentICMPv6(s).last?.type == 135)
  #expect(IPv6Address(sentICMPv6(s).last!.frame, at: 62) == ourGlobal)
  s.poll(now: 3 * second)
  #expect(s.ipv6Addresses == [ourLL, ourGlobal])
  // Off-link goes through the router, from the global address; on the
  // prefix goes direct (asked for by solicitation).
  s.transmit.removeAll()
  let far = IPv6Address("2001:db8::7")!
  #expect(s.sendICMPv6(from: s.ipv6Source(for: far, now: 3 * second)!, to: far, now: 3 * second) { b, at, _ in
    b[at] = 128
    b[at + 1] = 0
    return 8
  })
  let out = sentICMPv6(s)
  #expect(out.count == 1 && MACAddress(out[0].frame, at: 0) == routerMAC && out[0].source == ourGlobal)
  s.transmit.removeAll()
  let near = IPv6Address("fd00::9")!
  #expect(s.sendICMPv6(from: ourGlobal, to: near, now: 3 * second) { b, at, _ in
    b[at] = 128
    return 8
  })
  #expect(sentICMPv6(s).map { $0.type } == [135] && sentICMPv6(s)[0].destination == near.solicitedNode)
  // The two-hour rule: a short lifetime is cut to two hours, not below;
  // a router lifetime of 0 removes the router.
  let short = routerAdvert(lifetime: 0, valid: 60, preferred: 30)
  s.receive(short, length: short.count, now: 4 * second)
  let i = s.ipv6.find(ourGlobal)!
  #expect(s.ipv6.validUntil[i] == 4 * second + NetStack.twoHours && s.ipv6.preferredUntil[i] == 34 * second)
  #expect(s.routers.first == nil)
  // An advert from beyond the link, or not link-local, is refused.
  var forged = routerAdvert()
  forged[21] = 64
  s.receive(forged, length: forged.count, now: 5 * second)
  #expect(s.counters.badChecksums + s.counters.malformed >= 1 && s.routers.first == nil)
}

@Test func echoesAreAnsweredOverIPv6() {
  var s = started()
  let request = icmp6Frame(from: theirLL, to: ourLL, [128, 0, 0, 0, 0, 7, 0, 1] + Array(0..<56))
  s.receive(request, length: request.count, now: 2 * second)
  // Their link address isn't known: asked for, then the reply goes.
  #expect(sentICMPv6(s).map { $0.type } == [135])
  s.transmit.removeAll()
  let na = icmp6Frame(from: theirLL, to: ourLL, [136, 0, 0, 0, 0x60, 0, 0, 0] + bytes(theirLL) + [2, 1] + macBytes(theirs))
  s.receive(na, length: na.count, now: 2 * second)
  let reply = sentICMPv6(s)
  #expect(reply.count == 1 && reply[0].type == 129 && reply[0].source == ourLL && reply[0].destination == theirLL)
  var c = InternetChecksum.ipv6(ourLL, theirLL, length: 64, next: 58)
  c.add(reply[0].frame, 54, 64)
  #expect(c.value == 0 && Array(reply[0].frame[58..<118]) == Array(request[58..<118]))
  // To all nodes, or with a bad checksum: no answer.
  s.transmit.removeAll()
  let group = icmp6Frame(from: theirLL, to: .allNodes, [128, 0, 0, 0, 0, 7, 0, 2])
  s.receive(group, length: group.count, now: 2 * second)
  var bad = request
  bad[60] ^= 1
  s.receive(bad, length: bad.count, now: 2 * second)
  #expect(s.transmit.isEmpty && s.counters.badChecksums == 1 && s.counters.echoesAnswered == 1)
}

// MARK: Linux against it

/// dnsmasq as the namespace's router (and in b3 its DHCP server). Killed
/// with SIGKILL: the test runner's threads block signals, and the
/// processes it starts inherit that, SIGTERM included.
/// Waits (up to 10 s) for Linux's own link-local address on tap0 to pass
/// its duplicate check: an advert sent before then has no source address
/// and is lost, and ours would wait for our next router solicitation.
let linuxReady = """
  i=0
  until ip -6 addr show dev tap0 scope link | grep -q inet6 && ! ip -6 addr show dev tap0 tentative | grep -q inet6; do
    i=$((i + 1)); [ $i -lt 200 ] || exit 5; sleep 0.05
  done
  """

let dnsmasq = "dnsmasq --keep-in-foreground --conf-file=/dev/null --port=0 --user= --group= --pid-file=$PWD/dm.pid"
  + " --leasefile-ro --interface=tap0 --bind-interfaces --log-facility=$PWD/dm.log"

@Test(.enabled(if: namespacesWork)) func linuxPingsTheStackOverIPv6() throws {
  let nettap = repository + "/.build/debug/nettap"
  try #require(FileManager.default.fileExists(atPath: nettap), "build nettap first (swift build)")
  let (status, out) = inNamespace("""
    set -e
    \(startNettap(nettap))
    ip addr add fd00::1/64 dev tap0 nodad
    \(linuxReady)
    \(dnsmasq) --enable-ra --dhcp-range=::,constructor:tap0,ra-only,64,10m &
    DM=$!
    trap 'status=$?; kill -KILL $DM 2> /dev/null; [ $status = 0 ] || cat nettap.log dm.log' EXIT
    i=0
    until grep -q "ipv6 fd00" nettap.log; do i=$((i + 1)); [ $i -lt 200 ] || exit 4; sleep 0.05; done
    ping -6 -c 3 -i 0.2 -W 2 fe80::5054:ff:fe12:3456%tap0
    ping -6 -c 3 -i 0.2 -W 2 fd00::5054:ff:fe12:3456
    ping -6 -c 2 -i 0.2 -W 2 -s 1452 -M do fd00::5054:ff:fe12:3456
    ip -6 neigh show dev tap0
    \(stopNettap)
    """)
  #expect(status == 0, "\(out)")
  #expect(out.contains("nettap: ipv6 fe80::5054:ff:fe12:3456") && out.contains("nettap: ipv6 fd00::5054:ff:fe12:3456"),
          "\(out)")
  #expect(out.components(separatedBy: "3 packets transmitted, 3 received").count == 3, "\(out)")
  #expect(out.contains("2 packets transmitted, 2 received"), "\(out)")
  #expect(out.contains("fd00::5054:ff:fe12:3456 lladdr 52:54:00:12:34:56"), "\(out)")
  #expect(out.contains("duplicates 0,") && out.contains("echoes 8,"), "\(out)")
}

@Test(.enabled(if: namespacesWork)) func aDuplicateOnLinuxIsFound() throws {
  let nettap = repository + "/.build/debug/nettap"
  try #require(FileManager.default.fileExists(atPath: nettap), "build nettap first (swift build)")
  // Linux holds our SLAAC address already (nodad: it doesn't check), so
  // it answers our check of it; our link-local address is unharmed.
  let (status, out) = inNamespace("""
    set -e
    \(startNettap(nettap))
    ip addr add fd00::1/64 dev tap0
    ip addr add fd00::5054:ff:fe12:3456/64 dev tap0 nodad
    \(linuxReady)
    \(dnsmasq) --enable-ra --dhcp-range=::,constructor:tap0,ra-only,64,10m &
    DM=$!
    trap 'status=$?; kill -KILL $DM 2> /dev/null; [ $status = 0 ] || cat nettap.log dm.log' EXIT
    i=0
    until grep -q "duplicates 1" nettap.log; do i=$((i + 1)); [ $i -lt 200 ] || exit 4; sleep 0.05; done
    ping -6 -c 2 -i 0.2 -W 2 fe80::5054:ff:fe12:3456%tap0
    \(stopNettap)
    """)
  #expect(status == 0, "\(out)")
  #expect(out.contains("nettap: ipv6 fe80::5054:ff:fe12:3456") && !out.contains("nettap: ipv6 fd00"), "\(out)")
  #expect(out.contains("duplicates 1,") && out.contains("2 packets transmitted, 2 received"), "\(out)")
}
