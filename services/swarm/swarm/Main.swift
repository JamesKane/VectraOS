// SPDX-License-Identifier: BSD-3-Clause

// bin/swarm (D152): the swarm's files (swarm(4)) at its export, the
// swarm file read from the node's volume and this node's roles started
// from its entry. It listens on tcp!*!17020 for the swarm's members,
// through factotum's noise-ik key, and exports its file alone there, at
// /remote in its namespace, for another member's push. On tcp!*!17021 it
// answers other nodes' swarm slots with factotum's mcr key (D153).

import Gate
import IPC
import Node
import Swarm
import Sys

/// A counter one thread adds to and another waits on.
final class Ready: @unchecked Sendable {
  let bell: Handle
  init() throws(Status) { bell = try Counter.create() }
}

@main struct SwarmProgram {
  static func main() {
    let start = Startup.current
    guard start.args.count == 1 else { Process.fail("usage: swarm") }
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { Process.fail("no namespace") }
    let dispatcher: IPCDispatcher
    do throws(Status) { dispatcher = try IPCDispatcher() } catch { Process.fail("can't make a dispatcher") }
    let identity: Identity
    do throws(GateError) { identity = try Identity.factotum(ns, at: "/svc/factotum/auth") } catch {
      Process.fail("no key from factotum")
    }
    let tree = NodeTree(dispatcher: dispatcher), remote = NodeTree(dispatcher: dispatcher)
    do throws(Status) {
      let ends = try Channel.create()
      try remote.serve(ends.b)
      do throws(NamespaceError) { try ns.mount(ends.a, at: "/remote") } catch { Process.fail("can't mount /remote") }
      _ = try Thread.spawn { try? dispatcher.run() }.release()
    } catch { Process.fail("can't serve /remote") }
    let unlocks = UnlockAnswerer(namespace: ns)
    if let unlocks {
      // Its line said before the service's own.
      do throws(Status) {
        let ready = try Ready()
        _ = try Thread.spawn {
          let failed = unlocks.listen(ready: { try? Counter.add(ready.bell, 1) })
          print("swarm: can't answer unlocks: \(failed.reason)")
        }.release()
        try? Counter.wait(ready.bell, until: 1)
      } catch { print("swarm: can't answer unlocks") }
    } else {
      print("swarm: no mcr key from factotum: answering no unlocks")
    }
    let swarm = SwarmService(tree: tree, remote: remote, namespace: ns, identity: identity, unlocks: unlocks)
    do throws(Status) {
      guard let export = start.export() else { Process.fail("no export (its manifest's `export`)") }
      try tree.serve(export)
    } catch { Process.fail("can't serve: \(error)") }
    Process.fail("can't listen: \(swarm.listen().reason)")
  }
}
