// SPDX-License-Identifier: BSD-3-Clause

// bin/9gate (D77, D78): 9P2000 between nodes, over Noise IK. It serves
// its files (9gate(4)) at the root of its tree: this node's key, which
// factotum holds and runs each handshake with (D75), the keys it trusts,
// its listeners and its imports. It dials and announces through its
// namespace's /net, and exports from its namespace; nothing listens
// until its ctl says so.

import Gate
import IPC
import Node
import Sys

@main struct GateProgram {
  static func main() {
    let start = Startup.current
    guard start.args.count == 1 else { Process.fail("usage: 9gate") }
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { Process.fail("no namespace") }
    let dispatcher: IPCDispatcher, imports: IPCDispatcher
    do throws(Status) {
      dispatcher = try IPCDispatcher()
      imports = try IPCDispatcher()
    } catch { Process.fail("can't make a dispatcher") }
    // Imported trees are served apart from this tree, which forwards walks
    // into them and waits (gate(2)).
    do throws(Status) {
      _ = try Thread.spawn { try? imports.run() }.release()
    } catch { Process.fail("can't start the imports' thread") }
    let identity: Identity
    do throws(GateError) { identity = try Identity.factotum(ns, at: "/svc/factotum/auth") } catch {
      Process.fail("no key from factotum")
    }
    let tree = NodeTree(dispatcher: dispatcher)
    let gate = GateService(tree: tree, at: "", namespace: ns, identity: identity, imports: imports)
    do throws(Status) {
      guard let export = start.export() else { Process.fail("no export (its manifest's `export`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      Process.fail("can't serve: \(error)")
    }
    _ = gate
  }
}
