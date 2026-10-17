// SPDX-License-Identifier: BSD-3-Clause

// The database as cs and dns see it through a namespace: its files
// (`/lib/ndb/local`, and those its `database` entry names), read at the
// start and again on `refresh`, then /net/ndb, what DHCP gave, read each
// time it is asked for. And this machine's addresses, from
// /net/ipifc/N/status, read each time too, as a lease comes and goes.

import IPC
import Net
import Node
import Sys

public final class NetDatabase: @unchecked Sendable {
  let namespace: Namespace
  let path: String
  let lock = Lock()
  var files = NdbDatabase()

  /// One of our addresses, and its prefix over IPv6's 128 bits.
  public struct Interface: Equatable, Sendable {
    public var address: IPv6Address
    public var prefix: Int
  }

  public init(namespace: Namespace, file path: String = "/lib/ndb/local") {
    self.namespace = namespace
    self.path = path
    refresh()
  }

  /// Reads the files again.
  public func refresh() {
    let main = NdbDatabase(parsing: read(path) ?? [])
    var db = NdbDatabase()
    let names = main.files
    if names.isEmpty {
      db = main
    } else {
      for name in names { db = db + (same(name, path) ? main : NdbDatabase(parsing: read(name) ?? [])) }
    }
    lock.withLock { files = db }
  }

  /// The files', then /net/ndb's.
  public var current: NdbDatabase {
    lock.withLock { files } + NdbDatabase(parsing: read("/net/ndb") ?? [])
  }

  /// Our addresses, every interface's.
  public var interfaces: [Interface] {
    var out: [Interface] = []
    for n in 0..<16 {
      guard let status = read("/net/ipifc/\(n)/status") else { break }
      // After the device's line, an address a line: address, mask, ...
      for line in status.split(separator: 0x0A).dropFirst() {
        let words = line.split { $0 == 0x20 || $0 == 0x09 }
        guard words.count >= 2, let a = parseIP(String(decoding: words[0], as: UTF8.self)),
          words[1].first == 0x2F, let p = Int(String(decoding: words[1].dropFirst(), as: UTF8.self))
        else { continue }
        out.append(Interface(address: a, prefix: p))
      }
    }
    return out
  }

  /// The name servers to ask: /net/ndb's `dns`, then those the files
  /// give our addresses (ipinfo), each once.
  public func nameServers() -> [String] {
    var out = NdbDatabase(parsing: read("/net/ndb") ?? []).entries.flatMap { $0.values("dns") }
    let db = lock.withLock { files }
    for i in interfaces { out += db.ipinfo(addressText(i.address), ["dns"]).map { $0.value } }
    var unique: [String] = []
    for s in out where !unique.contains(where: { same($0, s) }) { unique.append(s) }
    return unique
  }

  func read(_ path: String) -> [UInt8]? {
    guard var f = try? namespace.open(path) else { return nil }
    return try? f.readAll()
  }
}
