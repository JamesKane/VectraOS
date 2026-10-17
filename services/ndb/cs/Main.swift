// SPDX-License-Identifier: BSD-3-Clause

// bin/cs (D79): Plan 9's connection server, serving `cs` at `net` in its
// tree, which manifests mount after the stack's files at /net. It
// translates dial strings through its namespace's /net (the stack, and
// dns for domain names) and the database, /lib/ndb/local or `-f FILE`.

import IPC
import Ndb
import Node
import Sys

func fail(_ what: String) -> Never {
  print("cs: \(what)")
  Process.exit(code: 1)
}

@main struct CSProgram {
  static func main() {
    let start = Startup.current
    var args = Array(start.args.dropFirst())
    var file = "/lib/ndb/local"
    if args.count == 2, args[0].utf8.elementsEqual("-f".utf8) {
      file = args[1]
      args = []
    }
    guard args.isEmpty else { fail("usage: cs [-f FILE]") }
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { fail("no namespace") }
    let dispatcher: IPCDispatcher
    do throws(Status) { dispatcher = try IPCDispatcher() } catch { fail("can't make a dispatcher") }
    let tree = NodeTree(dispatcher: dispatcher)
    let database = NetDatabase(namespace: ns, file: file)
    let cs = ConnectionServer(tree: tree, at: "net", namespace: ns, database: database)
    tree.text("status", read: { "database \(file)\n" })
    do throws(Status) {
      guard let export = start.export() else { fail("no export (its manifest's `export`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      fail("can't serve: \(error)")
    }
    _ = cs
  }
}
