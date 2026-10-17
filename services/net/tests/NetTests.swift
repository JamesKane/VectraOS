// SPDX-License-Identifier: BSD-3-Clause

// The network stack's core (N1b), on frames built here: the checksum,
// ARP's answers and its retries, ICMP's echo (straight out, and waiting
// for ARP), and what is refused. Then Linux's own ping against it, over a
// TAP inside `unshare -Urn` (nettap; skipped where user namespaces
// aren't allowed).

import FoundationEssentials
import Glibc
import IDL
@testable import Net
import Testing

let ours = MACAddress(0x5254_0012_3456)
let theirs = MACAddress(0x0200_0000_0001)
let ourIP = IPv4Address(10, 0, 0, 2)
let theirIP = IPv4Address(10, 0, 0, 1)

func stack() -> NetStack {
  var s = NetStack(mac: ours)
  s.configureIPv4(ourIP, prefixLength: 24)
  return s
}

func arpFrame(operation: UInt16, senderMAC: MACAddress, sender: IPv4Address, target: IPv4Address,
              to destination: MACAddress = .broadcast) -> [UInt8] {
  var f = [UInt8](repeating: 0, count: 60)
  Ethernet.writeHeader(&f, at: 0, destination: destination, source: senderMAC, type: Ethernet.typeARP)
  f.put16(1, 14)
  f.put16(0x0800, 16)
  f[18] = 6
  f[19] = 4
  f.put16(operation, 20)
  senderMAC.write(&f, at: 22)
  f.put32(sender.value, 28)
  f.put32(target.value, 38)
  return f
}

/// An echo request from them to `to`, with `data`.
func pingFrame(to destination: IPv4Address = ourIP, id: UInt16 = 7, sequence: UInt16 = 1, data: [UInt8],
               fragment: UInt16 = 0x4000) -> [UInt8] {
  var f = [UInt8](repeating: 0, count: 14 + 20 + 8 + data.count)
  Ethernet.writeHeader(&f, at: 0, destination: ours, source: theirs, type: Ethernet.typeIPv4)
  f[14] = 0x45
  f.put16(UInt16(28 + data.count), 16)
  f.put16(fragment, 20)
  f[22] = 64
  f[23] = 1
  f.put32(theirIP.value, 26)
  f.put32(destination.value, 30)
  f.put16(InternetChecksum.of(f, 14, 20), 24)
  f[34] = 8
  f.put16(id, 38)
  f.put16(sequence, 40)
  for (i, b) in data.enumerated() { f[42 + i] = b }
  f.put16(InternetChecksum.of(f, 34, 8 + data.count), 36)
  return f
}

@Test func theChecksumIsRFC1071s() {
  // RFC 1071 §3's example: these bytes sum to 0xddf2.
  let b: [UInt8] = [0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]
  #expect(InternetChecksum.of(b, 0, 8) == ~UInt16(0xddf2))
  // An odd last byte is padded with zero; data with its checksum sums to 0.
  #expect(InternetChecksum.of(b + [0xab], 0, 9) == InternetChecksum.of(b + [0xab, 0], 0, 10))
  var c = b + [0, 0]
  c.put16(InternetChecksum.of(b, 0, 8), 8)
  #expect(InternetChecksum.of(c, 0, 10) == 0)
  #expect(IPv4Address("10.0.0.2") == ourIP && IPv4Address("10.0.0") == nil && IPv4Address("1.2.3.256") == nil)
  #expect(ourIP.text == "10.0.0.2" && ours.text == "52:54:00:12:34:56")
}

@Test func arpAnswersForOurAddressAndLearns() {
  var s = stack()
  let request = arpFrame(operation: 1, senderMAC: theirs, sender: theirIP, target: ourIP)
  s.receive(request, length: request.count, now: 0)
  #expect(s.transmit.count == 1)
  var expected = arpFrame(operation: 2, senderMAC: ours, sender: ourIP, target: theirIP, to: theirs)
  theirs.write(&expected, at: 32)  // the target's hardware address
  #expect(s.transmit.frame(0) == expected)
  #expect(s.neighbors.mac(IPv6Address(mapping: theirIP)) == theirs)
  // A request for someone else is not answered, and teaches nothing new.
  s.transmit.removeAll()
  let other = arpFrame(operation: 1, senderMAC: MACAddress(0x0200_0000_0009), sender: IPv4Address(10, 0, 0, 9),
                       target: IPv4Address(10, 0, 0, 3))
  s.receive(other, length: other.count, now: 0)
  #expect(s.transmit.isEmpty && s.neighbors.find(IPv6Address(mapping: IPv4Address(10, 0, 0, 9))) == nil)
}

@Test func echoesAreAnswered() {
  var s = stack()
  let data: [UInt8] = Array(0..<56)
  // Their address unknown: we ask for it, the reply waits, then goes.
  let ping = pingFrame(data: data)
  s.receive(ping, length: ping.count, now: 0)
  #expect(s.transmit.count == 1 && s.transmit.frame(0).be16(12) == Ethernet.typeARP)
  #expect(s.transmit.frame(0).be16(20) == 1 && s.transmit.frame(0).be32(38) == theirIP.value)
  s.transmit.removeAll()
  let answer = arpFrame(operation: 2, senderMAC: theirs, sender: theirIP, target: ourIP, to: ours)
  s.receive(answer, length: answer.count, now: 1_000)
  #expect(s.transmit.count == 1)
  let reply = s.transmit.frame(0)
  #expect(MACAddress(reply, at: 0) == theirs && MACAddress(reply, at: 6) == ours)
  #expect(InternetChecksum.of(reply, 14, 20) == 0 && reply.be32(26) == ourIP.value && reply.be32(30) == theirIP.value)
  #expect(reply[34] == 0 && InternetChecksum.of(reply, 34, 8 + data.count) == 0)
  #expect(Array(reply[38..<42 + data.count]) == Array(ping[38..<42 + data.count]))
  // Known now: straight out.
  s.transmit.removeAll()
  s.receive(ping, length: ping.count, now: 2_000)
  #expect(s.transmit.count == 1 && s.transmit.frame(0).be16(12) == Ethernet.typeIPv4)
  #expect(s.counters.echoesAnswered == 2)
}

@Test func whatIsRefused() {
  var s = stack()
  var bad = pingFrame(data: [1, 2, 3])
  bad[24] ^= 1  // the IPv4 header's checksum
  s.receive(bad, length: bad.count, now: 0)
  var badICMP = pingFrame(data: [1, 2, 3])
  badICMP[36] ^= 1
  s.receive(badICMP, length: badICMP.count, now: 0)
  let piece = pingFrame(data: [1, 2, 3], fragment: 0x2000)
  s.receive(piece, length: piece.count, now: 0)
  let elsewhere = pingFrame(to: IPv4Address(10, 0, 0, 3), data: [1])
  s.receive(elsewhere, length: elsewhere.count, now: 0)
  let broadcast = pingFrame(to: IPv4Address(10, 0, 0, 255), data: [1])
  s.receive(broadcast, length: broadcast.count, now: 0)
  let short = pingFrame(data: [1, 2, 3])
  s.receive(short, length: 30, now: 0)
  var forged = pingFrame(data: [1])  // from the subnet's broadcast
  forged.put32(IPv4Address(10, 0, 0, 255).value, 26)
  forged.put16(0, 24)
  forged.put16(InternetChecksum.of(forged, 14, 20), 24)
  s.receive(forged, length: forged.count, now: 0)
  #expect(s.transmit.isEmpty)
  #expect(s.counters.badChecksums == 2 && s.counters.fragments == 1 && s.counters.malformed == 2)
  #expect(s.counters.ignored == 2 && s.counters.echoesAnswered == 0)
}

@Test func anAddressThatNeverAnswersIsGivenUp() {
  var s = stack()
  let ping = pingFrame(data: [1])
  s.receive(ping, length: ping.count, now: 0)
  var requests = s.transmit.count
  s.transmit.removeAll()
  var now: Int64 = 0
  while let d = s.nextDeadline {
    now = d
    s.poll(now: now)
    requests += s.transmit.count
    s.transmit.removeAll()
  }
  #expect(requests == NeighborCache.maxRequests)
  #expect(now == Int64(NeighborCache.maxRequests) * NeighborCache.retry)
  #expect(s.counters.unresolved == 1 && s.pending.lengths.allSatisfy { $0 == 0 })
}

// MARK: Linux against it

let repository: String = {
  var path = #filePath
  for _ in 0..<4 { path = String(path[..<path.lastIndex(of: "/")!]) }
  return path
}()

/// Runs `script` with sh inside a new user and network namespace; its
/// exit status and output.
func inNamespace(_ script: String) -> (Int32, String) {
  let dir = "\(FileManager.default.temporaryDirectory.path)/nettests-\(getpid())-\(Int.random(in: 0..<1_000_000))"
  try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: dir) }
  try? Data(script.utf8).write(to: URL(fileURLWithPath: dir + "/script.sh"))
  let status = system("cd \(dir) && unshare -Urn sh script.sh > out.txt 2>&1")
  let out = FileManager.default.contents(atPath: dir + "/out.txt").map { String(decoding: $0, as: UTF8.self) } ?? ""
  return (status, out)
}

let namespacesWork = system("unshare -Urn true > /dev/null 2>&1") == 0

/// Starts nettap on tap0 (until `stopNettap`, at most 30 s) and waits for
/// the TAP, then brings Linux's end up.
func startNettap(_ nettap: String) -> String {
  """
  \(nettap) --tap tap0 --address 10.0.0.2/24 --seconds 30 --stop-file stop > nettap.log 2>&1 &
  NT=$!
  i=0
  until ip link show tap0 > /dev/null 2>&1; do i=$((i + 1)); [ $i -lt 100 ] || exit 3; sleep 0.05; done
  ip link set lo up
  ip link set tap0 up
  """
}

/// Stops nettap, waits for its counters, and prints its log.
let stopNettap = """
  touch stop
  wait $NT
  cat nettap.log
  """

@Test(.enabled(if: namespacesWork)) func linuxPingsTheStack() throws {
  let nettap = repository + "/.build/debug/nettap"
  try #require(FileManager.default.fileExists(atPath: nettap), "build nettap first (swift build)")
  let (status, out) = inNamespace("""
    set -e
    \(startNettap(nettap))
    ip addr add 10.0.0.1/24 dev tap0
    ping -c 5 -i 0.2 -W 2 10.0.0.2
    ping -c 3 -i 0.2 -W 2 -s 1472 -M do 10.0.0.2
    ip neigh show dev tap0
    \(stopNettap)
    """)
  #expect(status == 0, "\(out)")
  #expect(out.contains("5 packets transmitted, 5 received"), "\(out)")
  #expect(out.contains("3 packets transmitted, 3 received"), "\(out)")
  #expect(out.contains("lladdr 52:54:00:12:34:56"), "\(out)")
  #expect(out.contains("echoes 8,"), "\(out)")
}

@Test func checkedInOutputsMatchIdlc() throws {
  func read(_ path: String) -> String? {
    FileManager.default.contents(atPath: repository + "/" + path).map { String(decoding: $0, as: UTF8.self) }
  }
  let source = "services/net/ipc/Protocol.swift"
  let interface = try scan([(source, try #require(read(source)))], references: [])
  let library = try #require(interface.libraries.first)
  let regenerate = "regenerate: .build/debug/idlc --c-out services/net/idl --doc-out services/net/idl --baseline services/net/idl \(source)"
  #expect(cHeader(library, source: source) == read("services/net/idl/net_ipc.h"), "\(regenerate)")
  for p in library.protocols {
    let composed = try interface.composedMethods(p, in: library)
    #expect(markdown(p, library, source: source, composed: composed) == read("services/net/idl/\(p.name).md"), "\(regenerate)")
    #expect(Baseline(p, library, composed: composed).text == read("services/net/idl/\(p.id).api"))
  }
}
