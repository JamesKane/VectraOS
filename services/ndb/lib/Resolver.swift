// SPDX-License-Identifier: BSD-3-Clause

// dns(8)'s resolver: a name's records of a type, asked of the name
// servers the database gives (`dns=`), recursively (RD set), and kept for
// their TTL. Each server is asked in turn, three rounds, waiting 1, 2 and
// 4 seconds; a reply that is truncated is asked again over TCP. A CNAME
// in the answer is followed, in the answer or by asking again, eight
// deep at most. A name that doesn't exist, or has no records of the type,
// is kept as such for its zone's SOA minimum (RFC 2308), or a minute.
//
// The servers are reached through `exchange`, which `network` makes from
// a namespace's /net: a UDP conversation dialled for each query (closed
// after it, so a late reply goes nowhere), a TCP one for a truncated
// reply, its messages each after a two-byte length (RFC 7766).

import IPC
import Net
import Node
import Sys

/// Why a lookup has no records.
public enum DNSFailure: Error, Equatable, Sendable {
  /// The name doesn't exist (NXDOMAIN).
  case noName
  /// The name has no records of the type (the rcode the reply had).
  case noRecords(UInt16)
  /// No server answered, or every one failed.
  case failed

  /// As dns(8) says it.
  public var text: String {
    switch self {
    case .noName: "name does not exist"
    case .noRecords(let rcode): "resource does not exist; negrcode \(rcode)"
    case .failed: "dns failure"
    }
  }
}

public final class Resolver: @unchecked Sendable {
  /// A query to a server and its reply: UDP, or TCP if `tcp`, waiting
  /// `timeout` nanoseconds at most; nil if none came.
  public typealias Exchange = @Sendable (_ server: String, _ query: [UInt8], _ tcp: Bool, _ timeout: Int64)
    -> [UInt8]?

  struct Cached {
    var name: String
    var type: UInt16
    var records: [DNSRecord]
    /// No records: why.
    var failure: DNSFailure?
    var expires: Int64
  }

  let servers: @Sendable () -> [String]
  let exchange: Exchange
  let random: @Sendable () -> UInt16
  let lock = Lock()
  var cache: [Cached] = []
  /// Queries sent, for tests and status.
  public private(set) var sent = 0

  public static let cacheSize = 512
  static let rounds = 3
  static let negativeTTL: UInt32 = 60
  static let maxTTL: UInt32 = 86400

  public init(servers: @escaping @Sendable () -> [String], exchange: @escaping Exchange,
              random: @escaping @Sendable () -> UInt16) {
    self.servers = servers
    self.exchange = exchange
    self.random = random
  }

  /// Drops what is kept.
  public func flush() { lock.withLock { cache = [] } }

  /// `name`'s records of `type` (`all` for any), following CNAMEs.
  public func lookup(_ name: String, _ type: UInt16) -> Result<[DNSRecord], DNSFailure> {
    var name = name
    for _ in 0..<8 {
      let now = Clock.monotonic()
      if let c = cached(name, type, now) {
        if let f = c.failure { return .failure(f) }
        return .success(c.records)
      }
      if type != DNSType.cname, type != DNSType.all, let c = cached(name, DNSType.cname, now), c.failure == nil,
        case .name(let target) = c.records.first?.data
      {
        name = target
        continue
      }
      guard let reply = ask(name, type) else { return .failure(.failed) }
      let now2 = Clock.monotonic()
      keep(reply, now2)
      // The chain of CNAMEs the answer gives, to the name it ends at.
      var owner = name
      if type != DNSType.cname, type != DNSType.all {
        var hops = 0
        while hops < 8, let c = reply.answers.first(where: { $0.type == DNSType.cname && equal($0.owner, owner) }),
          case .name(let target) = c.data
        {
          owner = target
          hops += 1
        }
      }
      let records = reply.answers.filter { equal($0.owner, owner) && (type == DNSType.all || $0.type == type) }
      if !records.isEmpty { return .success(records) }
      if !equal(owner, name) {
        name = owner
        continue
      }
      let failure: DNSFailure = reply.rcode == DNSMessage.nameError ? .noName : .noRecords(reply.rcode)
      let ttl = reply.authority.compactMap { r -> UInt32? in
        guard case .soa(_, _, _, _, _, _, let minimum) = r.data else { return nil }
        return min(r.ttl, minimum)
      }.first ?? Resolver.negativeTTL
      put(Cached(name: lower(name), type: type, records: [], failure: failure, expires: now2 + Int64(ttl) * 1_000_000_000))
      return .failure(failure)
    }
    return .failure(.failed)
  }

  /// What is kept for `name` and `type` and still good; a name that
  /// doesn't exist has no records of any type.
  func cached(_ name: String, _ type: UInt16, _ now: Int64) -> Cached? {
    let key = lower(name)
    return lock.withLock {
      cache.removeAll { $0.expires <= now }
      return cache.first { same($0.name, key) && ($0.type == type || $0.failure == .noName) }
    }
  }

  /// Keeps a reply's answers, each owner and type's records together, for
  /// the least TTL among them.
  func keep(_ reply: DNSMessage, _ now: Int64) {
    var groups: [Cached] = []
    for r in reply.answers {
      let key = lower(r.owner)
      if let i = groups.firstIndex(where: { same($0.name, key) && $0.type == r.type }) {
        groups[i].records.append(r)
        groups[i].expires = min(groups[i].expires, now + Int64(min(r.ttl, Resolver.maxTTL)) * 1_000_000_000)
      } else {
        groups.append(Cached(name: key, type: r.type, records: [r], failure: nil,
                             expires: now + Int64(min(r.ttl, Resolver.maxTTL)) * 1_000_000_000))
      }
    }
    for g in groups where g.expires > now { put(g) }
  }

  func put(_ c: Cached) {
    lock.withLock {
      cache.removeAll { same($0.name, c.name) && $0.type == c.type }
      if cache.count >= Resolver.cacheSize { cache.removeFirst() }
      cache.append(c)
    }
  }

  /// The first good reply to a query for `name`'s `type`: one that
  /// answers it, or says the name doesn't exist. Nil if none came.
  func ask(_ name: String, _ type: UInt16) -> DNSMessage? {
    let servers = self.servers()
    for round in 0..<Resolver.rounds {
      for server in servers {
        let id = random()
        guard let query = DNSMessage.query(id: id, name, type).encode() else { return nil }
        lock.withLock { sent += 1 }
        let timeout = Int64(1_000_000_000) << Int64(round)
        guard var reply = answer(exchange(server, query, false, timeout), id, name, type) else { continue }
        if reply.isTruncated {
          guard let whole = answer(exchange(server, query, true, 5_000_000_000), id, name, type) else { continue }
          reply = whole
        }
        if reply.rcode == DNSMessage.ok || reply.rcode == DNSMessage.nameError { return reply }
      }
    }
    return nil
  }

  /// `bytes` as the reply to query `id` for `name`'s `type`, or nil.
  func answer(_ bytes: [UInt8]?, _ id: UInt16, _ name: String, _ type: UInt16) -> DNSMessage? {
    guard let bytes, let m = DNSMessage(decoding: bytes), m.id == id, m.isResponse, let q = m.questions.first,
      m.questions.count == 1, equal(q.name, name), q.type == type
    else { return nil }
    return m
  }

  /// Exchanges through `namespace`'s /net (dial(2)).
  public static func network(_ namespace: Namespace) -> Exchange {
    return { server, query, tcp, timeout in
      if tcp {
        guard var c = try? namespace.dial("tcp!\(server)!53") else { return nil }
        c.data.connection.timeout = timeout
        let deadline = Clock.monotonic() + timeout
        guard (try? c.data.write(offset: 0, [UInt8(query.count >> 8), UInt8(truncatingIfNeeded: query.count)] + query))
          != nil
        else { return nil }
        var got: [UInt8] = []
        while got.count < 2 || got.count < 2 + (Int(got[0]) << 8 | Int(got[1])) {
          guard Clock.monotonic() < deadline, let bytes = try? c.data.read(offset: 0, max: 65536), !bytes.isEmpty
          else { return nil }
          got += bytes
        }
        return Array(got[2..<2 + (Int(got[0]) << 8 | Int(got[1]))])
      }
      guard var c = try? namespace.dial("udp!\(server)!53") else { return nil }
      c.data.connection.timeout = timeout
      guard (try? c.data.write(offset: 0, query)) != nil else { return nil }
      return try? c.data.read(offset: 0, max: 65536)
    }
  }
}

/// Whether two names are the same, as DNS compares them: ASCII's case
/// ignored.
public func equal(_ a: String, _ b: String) -> Bool {
  a.utf8.elementsEqual(b.utf8) { lowerByte($0) == lowerByte($1) }
}

func lower(_ s: String) -> String { String(decoding: s.utf8.map(lowerByte), as: UTF8.self) }

func lowerByte(_ c: UInt8) -> UInt8 { c >= 0x41 && c <= 0x5A ? c | 0x20 : c }
