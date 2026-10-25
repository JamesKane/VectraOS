// SPDX-License-Identifier: BSD-3-Clause

// bin/dns (D79): Plan 9's dns as a resolver, serving `dns` at `net` in
// its tree, which manifests mount after the stack's files at /net. It
// asks the name servers /net/ndb and the database (/lib/ndb/local, or
// `-f FILE`) give, through its namespace's /net.

import IPC
import Ndb
import Node
import Sys

@main struct DNSProgram {
  static func main() {
    let start = Startup.current
    var args = Array(start.args.dropFirst())
    var file = "/lib/ndb/local"
    if args.count == 2, args[0].utf8.elementsEqual("-f".utf8) {
      file = args[1]
      args = []
    }
    guard args.isEmpty else { Process.fail("usage: dns [-f FILE]") }
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { Process.fail("no namespace") }
    let dispatcher: IPCDispatcher
    do throws(Status) { dispatcher = try IPCDispatcher() } catch { Process.fail("can't make a dispatcher") }
    let tree = NodeTree(dispatcher: dispatcher)
    let database = NetDatabase(namespace: ns, file: file)
    let resolver = Resolver(servers: { database.nameServers() }, exchange: Resolver.network(ns), random: {
      guard let b = try? CPRNG.draw(count: 2) else { return UInt16(truncatingIfNeeded: Clock.monotonic()) }
      return UInt16(b[0]) << 8 | UInt16(b[1])
    })
    let dns = DNSService(tree: tree, at: "net", resolver: resolver)
    tree.text("status", read: {
      let servers = database.nameServers()
      return "servers \(servers.isEmpty ? "none" : servers.joined(separator: " "))\n"
    })
    do throws(Status) {
      guard let export = start.export() else { Process.fail("no export (its manifest's `export`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.fail("can't serve: \(error)")
    }
    _ = dns
  }
}
