// SPDX-License-Identifier: BSD-3-Clause

// /net/cs, Plan 9's connection server (ndb(8)'s cs): a channel writes a
// dial string, `net!host!service`, and reads where to call, one a read:
// a clone file and the address to write to its conversation's ctl,
// `/net/tcp/clone 10.0.2.100!7`. As 9front's cs.c:
//   - The network `net` is each network /net has that a dial may use
//     (tcp); a network cs knows (tcp, udp, icmp, icmpv6) translates its
//     host and service; any other is passed on as it is.
//   - A host is an address, `*` (any: an announcement's, the reply only a
//     port), `$attr` (that attribute's values for our own addresses, from
//     the database's ipinfo), or a name: a domain name (with a dot) asked
//     of dns first, then the database; another name looked up in the
//     database (`sys=`), then its `dom` asked of dns, then itself.
//   - A service is a number, `*`, or a name the database gives a port
//     (`tcp=echo port=7`).
//   - An address of a version we have none of is left out; one on a
//     network of ours comes first.
// `!attr=value ...` asks the database itself: each line of the first
// entry holding every pair (`*` any value); `!ipinfo [attr=value]
// attr ...` an address's attributes (ours if no pair), on one line.
// `refresh` reads the database's files again. A write fails `notFound`
// when the host can't be translated (or nothing matches), `invalid` when
// the service can't be or the request is malformed, `io` when dns failed.

import IPC
import Net
import Node
import Sys

public final class ConnectionServer: @unchecked Sendable {
  let namespace: Namespace
  public let database: NetDatabase
  var file: QueryFile?

  struct Network {
    let name: String
    let v4: Bool, v6: Bool
    /// Not a choice for `net`.
    let excluded: Bool
  }

  static let networks = [
    Network(name: "tcp", v4: true, v6: true, excluded: false),
    Network(name: "udp", v4: true, v6: true, excluded: true),
    Network(name: "icmp", v4: true, v6: false, excluded: true),
    Network(name: "icmpv6", v4: false, v6: true, excluded: true),
  ]
  static let maxReplies = 20

  /// What a lookup knows of us: our addresses, and the versions we have
  /// (and those dns can reach: not by a link-local address).
  struct Us {
    var interfaces: [NetDatabase.Interface]
    var v4: Bool, v6: Bool
    var dnsV4: Bool, dnsV6: Bool
  }

  /// Serves `cs` at `path` in `tree`, translating through `namespace`'s
  /// /net and `database`.
  public init(tree: NodeTree, at path: String, namespace: Namespace, database: NetDatabase) {
    self.namespace = namespace
    self.database = database
    file = QueryFile(tree: tree, at: path.isEmpty ? "cs" : path + "/cs", maxRequest: 128,
                     command: { [database] text in
                       guard same(text, "refresh") else { return false }
                       database.refresh()
                       return true
                     }, answer: { [self] text in
                       translate(text).map { $0.map { Array($0.utf8) } }
                     })
  }

  /// A request's replies.
  public func translate(_ request: String) -> Result<[String], NodeError> {
    let db = database.current
    let interfaces = database.interfaces
    var us = Us(interfaces: interfaces, v4: false, v6: false, dnsV4: false, dnsV6: false)
    for i in interfaces {
      if i.address.mappedIPv4 != nil {
        us.v4 = true
        us.dnsV4 = true
      } else {
        us.v6 = true
        if !i.address.isLinkLocal { us.dnsV6 = true }
      }
    }
    if request.utf8.first == 0x21 { return query(String(decoding: request.utf8.dropFirst(), as: UTF8.self), db, us) }
    let fields = request.utf8.split(separator: 0x21, maxSplits: 3, omittingEmptySubsequences: false).map {
      String(decoding: $0, as: UTF8.self)
    }
    let net: String, host: String
    var service: String?, rem: String?
    if fields.count == 1 {
      net = "net"
      host = fields[0]
    } else {
      net = fields[0]
      host = fields[1]
      if fields.count > 2 { service = fields[2] }
      if fields.count > 3 { rem = fields[3] }
    }
    guard !host.isEmpty else { return .failure(.notFound) }
    var replies: [String] = []
    var failure = NodeError.notFound
    if same(net, "net") {
      for np in ConnectionServer.networks where !np.excluded && present(np.name) {
        switch lookup(np, host, service, db, us) {
        case .success(let ips):
          for ip in ips {
            guard replies.count < ConnectionServer.maxReplies,
              let r = trans(ip, np, service!, rem, db, us), !replies.contains(where: { same($0, r) })
            else { continue }
            replies.append(r)
          }
        case .failure(let e): failure = e
        }
      }
    } else if let np = ConnectionServer.networks.first(where: { same($0.name, net) }) {
      switch lookup(np, host, service, db, us) {
      case .success(let ips):
        for ip in ips where replies.count < ConnectionServer.maxReplies {
          if let r = trans(ip, np, service!, rem, db, us) { replies.append(r) }
        }
      case .failure(let e): failure = e
      }
    } else {
      // A network cs doesn't know: nothing to translate.
      replies.append("/net/\(net)/clone \(host)" + (service.map { "!" + $0 } ?? ""))
    }
    return replies.isEmpty ? .failure(failure) : .success(replies)
  }

  /// Whether /net has `network`.
  func present(_ network: String) -> Bool { (try? namespace.open("/net/\(network)")) != nil }

  /// `host`'s addresses on `np` (`*` for any), ours first.
  func lookup(_ np: Network, _ host: String, _ service: String?, _ db: NdbDatabase, _ us: Us)
    -> Result<[String], NodeError>
  {
    guard let service, port(np, service, db) != nil else { return .failure(.invalid) }
    var ips: [String] = []
    var failure = NodeError.notFound
    if host.utf8.first == 0x24 {  // "$attr"
      let attr = String(decoding: host.utf8.dropFirst(), as: UTF8.self)
      for i in us.interfaces {
        for p in db.ipinfo(addressText(i.address), [attr]) {
          if case .success(let more) = lookupHost(np, p.value, db, us) { ips += more }
        }
      }
    } else {
      switch lookupHost(np, host, db, us) {
      case .success(let found): ips = found
      case .failure(let e): failure = e
      }
    }
    guard !ips.isEmpty else { return .failure(failure) }
    // An address on one of our networks first.
    if let i = ips.firstIndex(where: { ip in
      guard let a = parseIP(ip) else { return false }
      return us.interfaces.contains { a.hasPrefix($0.address, length: $0.prefix) }
    }), i > 0 {
      ips.insert(ips.remove(at: i), at: 0)
    }
    return .success(ips)
  }

  /// A host's addresses: itself if it is one, else the database's or dns's.
  func lookupHost(_ np: Network, _ host: String, _ db: NdbDatabase, _ us: Us) -> Result<[String], NodeError> {
    var host = host
    if host.utf8.first == 0x5B {  // "[address]"
      host = String(decoding: host.utf8.dropFirst().prefix { $0 != 0x5D }, as: UTF8.self)
    }
    if same(host, "*") || same(host, "::") { return .success(["*"]) }
    let attr = ipattr(host)
    if same(attr, "ip") { return .success([host]) }
    var failure = NodeError.notFound
    var ips: [String] = []
    if same(attr, "dom") { ips = dns(host, np, us, &failure) }
    if ips.isEmpty {
      for e in db.search(attr, host) { ips += e.values("ip") }
    }
    if ips.isEmpty {
      if !same(attr, "dom"), let dom = db.value(attr, host, want: "dom") { ips = dns(dom, np, us, &failure) }
      if ips.isEmpty { ips = dns(host, np, us, &failure) }
    }
    return ips.isEmpty ? .failure(failure) : .success(ips)
  }

  /// `name`'s addresses from /net/dns, of the versions both `np` and dns
  /// can reach; `failure` says why there are none (`io`: dns failed).
  func dns(_ name: String, _ np: Network, _ us: Us, _ failure: inout NodeError) -> [String] {
    var ips: [String] = []
    for (type, wanted) in [("ip", np.v4 && us.dnsV4), ("ipv6", np.v6 && us.dnsV6)] where wanted {
      guard var f = try? namespace.open("/net/dns") else { return ips }
      do throws(NodeIPC.NodeClient.Failure) {
        _ = try f.write(offset: 0, Array("!\(name) \(type)".utf8))
      } catch {
        if case .remote(.io) = error { failure = .io }
        continue
      }
      while let line = try? f.read(offset: 0, max: 1024), !line.isEmpty {
        ips += parseLine(line).filter { same($0.attr, "ip") }.map { $0.value }
      }
    }
    return ips
  }

  /// A service's port on `np`: itself if a number or `*`, else the
  /// database's (`tcp=echo port=7`).
  func port(_ np: Network, _ service: String, _ db: NdbDatabase) -> String? {
    if same(service, "*") { return service }
    var alpha = false
    for c in service.utf8 {
      switch c {
      case 0x30...0x39: continue
      case 0x41...0x5A, 0x61...0x7A, 0x2D, 0x24: alpha = true
      default: return nil
      }
    }
    return alpha ? db.value(np.name, service, want: "port") : service
  }

  /// One reply: the clone file, then the address and port to call (only
  /// the port for any address); nil for an address of a version we have
  /// none of.
  func trans(_ ip: String, _ np: Network, _ service: String, _ rem: String?, _ db: NdbDatabase, _ us: Us)
    -> String?
  {
    guard let port = port(np, service, db) else { return nil }
    let tail = rem.map { "!" + $0 } ?? ""
    if same(ip, "*") { return "/net/\(np.name)/clone \(port)\(tail)" }
    guard let a = parseIP(ip) else { return nil }
    let v4 = a.mappedIPv4 != nil
    guard v4 ? np.v4 && us.v4 : np.v6 && us.v6 else { return nil }
    return "/net/\(np.name)/clone \(addressText(a))!\(port)\(tail)"
  }

  /// A `!` query of the database.
  func query(_ text: String, _ db: NdbDatabase, _ us: Us) -> Result<[String], NodeError> {
    let words = text.utf8.split { $0 == 0x20 || $0 == 0x09 }.map { String(decoding: $0, as: UTF8.self) }
    guard let first = words.first else { return .failure(.invalid) }
    func pair(_ w: String) -> (String, String)? {
      guard let eq = w.utf8.firstIndex(of: 0x3D) else { return nil }
      return (String(decoding: w.utf8[..<eq], as: UTF8.self), String(decoding: w.utf8[w.utf8.index(after: eq)...], as: UTF8.self))
    }
    if same(first, "ipinfo") {
      var rest = Array(words.dropFirst())
      var addresses = us.interfaces.map { addressText($0.address) }
      if let f = rest.first, let p = pair(f) {
        rest.removeFirst()
        addresses = db.search(p.0, p.1).flatMap { $0.values("ip") }
        if same(p.0, "ip") && addresses.isEmpty { addresses = [p.1] }
      }
      guard !rest.isEmpty else { return .failure(.invalid) }
      var pairs: [String] = []
      for a in addresses {
        for p in db.ipinfo(a, rest) {
          let t = p.attr + "=" + quoted(p.value)
          if !pairs.contains(where: { same($0, t) }) { pairs.append(t) }
        }
      }
      return pairs.isEmpty ? .failure(.notFound) : .success([pairs.joined(separator: " ")])
    }
    var pairs: [(String, String)] = []
    for w in words {
      guard let p = pair(w) else { return .failure(.invalid) }
      pairs.append(p)
    }
    for e in db.search(pairs[0].0, pairs[0].1) {
      let all = pairs.dropFirst().allSatisfy { p in
        e.pairs.contains { same($0.attr, p.0) && (same(p.1, "*") || same($0.value, p.1)) }
      }
      if all { return .success(Array(e.lines.prefix(ConnectionServer.maxReplies))) }
    }
    return .failure(.notFound)
  }
}
