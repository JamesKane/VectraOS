// SPDX-License-Identifier: BSD-3-Clause

// bin/9gate (D77, D78): 9P2000 between nodes, over Noise IK. It serves
// its files (9gate(4)) at the root of its tree: this node's key, made
// from the CPRNG when it starts, the keys it trusts, its listeners and
// its imports. It dials and announces through its namespace's /net, and
// exports from its namespace; nothing listens until its ctl says so.

import Gate
import IPC
import Node
import Noise
import Sys

func fail(_ what: String) -> Never {
  print("9gate: \(what)")
  Process.exit(code: 1)
}

func random() -> [UInt8] {
  do throws(Status) { return try CPRNG.draw(count: 32) } catch { fail("no random bytes") }
}

@main struct GateProgram {
  static func main() {
    let start = Startup.current
    guard start.args.count == 1 else { fail("usage: 9gate") }
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { fail("no namespace") }
    let dispatcher: IPCDispatcher, imports: IPCDispatcher
    do throws(Status) {
      dispatcher = try IPCDispatcher()
      imports = try IPCDispatcher()
    } catch { fail("can't make a dispatcher") }
    // Imported trees are served apart from this tree, which forwards walks
    // into them and waits (gate(2)).
    do throws(Status) {
      _ = try Thread.spawn { try? imports.run() }.release()
    } catch { fail("can't start the imports' thread") }
    let tree = NodeTree(dispatcher: dispatcher)
    // The key lasts one boot, until factotum holds it (D75).
    let gate = GateService(tree: tree, at: "", namespace: ns, key: StaticKey(privateKey: random()), imports: imports,
                           random: { random() })
    do throws(Status) {
      guard let export = start.export() else { fail("no export (its manifest's `export`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      fail("can't serve: \(error)")
    }
    _ = gate
  }
}
