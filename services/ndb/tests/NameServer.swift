// SPDX-License-Identifier: BSD-3-Clause

// A name server for the tests, on host B: port 53 over UDP and TCP,
// answering from a table, and an echo on TCP port 7.
//   bee.test     A 10.0.0.2
//   alias.test   CNAME bee.test, with bee.test's A in the answer
//   far.test     CNAME other.test alone; other.test A 10.0.0.2
//   v6.test      AAAA fe80::2 only
//   big.test     A 10.0.0.2, truncated over UDP; whole over TCP
//   anything else: no such name, its zone's SOA minimum 30 s
// Each query it answers is counted.

import IP
import IPC
import Ndb
import Net
import Node
import Synchronization
import Sys

final class NameServer: @unchecked Sendable {
  let queries = Atomic<Int>(0)
  let tcpQueries = Atomic<Int>(0)
  /// The names asked, in order.
  let asked = Locked<[String]>([])

  init(_ host: Host) throws {
    let ns = host.ns
    let ready = Atomic<Int>(0)
    _ = try Thread.spawn { [self] in
      guard var udp = try? ns.announce("udp!*!53"), (try? udp.ctl.writeText("headers")) != nil,
        var data = try? ns.open(udp.dir + "/data")
      else { return }
      ready.add(1, ordering: .relaxed)
      while let d = try? data.read(offset: 0, max: 2048), d.count > IP.udpHeaderSize {
        let header = Array(d[..<IP.udpHeaderSize])
        guard let reply = answer(Array(d[IP.udpHeaderSize...]), tcp: false) else { continue }
        _ = try? data.write(offset: 0, header + reply)
      }
      _ = consume udp
    }.release()
    _ = try Thread.spawn { [self] in
      guard let tcp = try? ns.announce("tcp!*!53") else { return }
      ready.add(1, ordering: .relaxed)
      while let call = try? ns.listen(tcp), var c = try? ns.accept(call) {
        var got: [UInt8] = []
        while let bytes = try? c.data.read(offset: 0, max: 4096), !bytes.isEmpty {
          got += bytes
          guard got.count >= 2, got.count >= 2 + (Int(got[0]) << 8 | Int(got[1])) else { continue }
          let n = Int(got[0]) << 8 | Int(got[1])
          if let reply = answer(Array(got[2..<2 + n]), tcp: true) {
            _ = try? c.data.write(offset: 0, [UInt8(reply.count >> 8), UInt8(truncatingIfNeeded: reply.count)] + reply)
          }
          break
        }
      }
    }.release()
    _ = try Thread.spawn {
      guard let echo = try? ns.announce("tcp!*!7") else { return }
      ready.add(1, ordering: .relaxed)
      while let call = try? ns.listen(echo), var c = try? ns.accept(call) {
        while let bytes = try? c.data.read(offset: 0, max: 8192), !bytes.isEmpty {
          _ = try? c.data.write(offset: 0, bytes)
        }
      }
    }.release()
    _ = soon { ready.load(ordering: .relaxed) == 3 }
  }

  static let bee = DNSData.address(IPv6Address(mapping: IPv4Address(10, 0, 0, 2)))

  /// The reply to the query in `bytes`.
  func answer(_ bytes: [UInt8], tcp: Bool) -> [UInt8]? {
    guard let q = DNSMessage(decoding: bytes), let question = q.questions.first else { return nil }
    queries.add(1, ordering: .relaxed)
    if tcp { tcpQueries.add(1, ordering: .relaxed) }
    asked.withLock { $0.append(question.name) }
    var r = DNSMessage(id: q.id, flags: DNSMessage.response | DNSMessage.recursionDesired | DNSMessage.recursionAvailable)
    r.questions = q.questions
    let name = question.name, type = question.type
    func a(_ owner: String) -> DNSRecord { DNSRecord(owner, DNSType.a, ttl: 300, NameServer.bee) }
    switch name {
    case "bee.test", "other.test":
      if type == DNSType.a { r.answers = [a(name)] }
    case "alias.test":
      r.answers = [DNSRecord(name, DNSType.cname, ttl: 300, .name("bee.test"))]
      if type == DNSType.a { r.answers.append(a("bee.test")) }
    case "far.test":
      r.answers = [DNSRecord(name, DNSType.cname, ttl: 300, .name("other.test"))]
    case "v6.test":
      if type == DNSType.aaaa {
        r.answers = [DNSRecord(name, DNSType.aaaa, ttl: 300, .address(IPv6Address("fe80::2")!))]
      }
    case "big.test":
      if tcp {
        r.answers = [a(name)]
      } else {
        r.flags |= DNSMessage.truncated
      }
    default:
      r.flags |= DNSMessage.nameError
      r.authority = [DNSRecord("test", DNSType.soa, ttl: 300,
                               .soa(mname: "ns.test", rname: "root.test", serial: 1, refresh: 3600, retry: 600,
                                    expire: 86400, minimum: 30))]
    }
    return r.encode()
  }
}
