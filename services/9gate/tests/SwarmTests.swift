// SPDX-License-Identifier: BSD-3-Clause

// The swarm service between two hosts on a wire (D152): each finds its
// own entry in the swarm file by its key, a file node has 9gate export
// its tree, and a push from one member replaces the other's file, which
// cs then rereads. A file that isn't a swarm's, and a push from a key
// the file doesn't list, are refused.

@testable import Swarm
import Gate
import IP
import IPC
import Net
import Node
import Noise
import Synchronization
import Sys
import Testing

/// The swarm service on a host, its files at /mnt/swarm there, its swarm
/// file the host's /lib/ndb/swarm (the CS fixture's), listening unless
/// `listening` is false.
final class SwarmNode: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  var service: SwarmService!

  init(_ host: Host, key: StaticKey, at path: String = "/mnt/swarm", listening: Bool = true) throws {
    dispatcher = try IPCDispatcher()
    let tree = NodeTree(dispatcher: dispatcher), remote = NodeTree(dispatcher: dispatcher)
    let d = dispatcher
    _ = try Thread.spawn { try? d.run() }.release()
    let counter = Atomic<UInt8>(key.publicKey[0])
    let identity = Identity.local(key) { Array(repeating: counter.add(1, ordering: .relaxed).newValue, count: 32) }
    let remoteEnds = try Channel.create()
    try remote.serve(remoteEnds.b)
    try host.ns.mount(remoteEnds.a, at: "/remote")
    service = SwarmService(tree: tree, remote: remote, namespace: host.ns, identity: identity,
                           path: "/lib/ndb/swarm", gate: "/mnt/9gate", log: { _ in })
    let ends = try Channel.create()
    try tree.serve(ends.b)
    try host.ns.mount(ends.a, at: path)
    if listening {
      let s = service!
      _ = try Thread.spawn { _ = s.listen() }.release()
    }
  }

  deinit { dispatcher.stop() }
}

func swarmText(_ ns: Namespace, _ path: String) -> String { ns.readText(path) ?? "" }

@Test func swarmStartsItsRolesAndTakesAMembersPush() throws {
  let wire = Wire()
  let a = try Host(mac: 0x0200_0000_000A, address: IPv4Address(10, 0, 0, 1), wire: wire, side: 0)
  let b = try Host(mac: 0x0200_0000_000B, address: IPv4Address(10, 0, 0, 2), wire: wire, side: 1)
  wire.hosts = [a, b]
  try wire.start()
  let ga = try Gate9(a, seed: 0x11), gb = try Gate9(b, seed: 0x22)
  let d = try exportMotd(a)
  defer { d.stop() }
  let ka = hex(ga.key.publicKey), kb = hex(gb.key.publicKey)
  let database = "database=\n\tfile=/lib/ndb/local\n\tfile=/lib/ndb/swarm\n"
  let first = """
    sys=nodea ip=10.0.0.1 key=\(ka) roles=file,terminal export=/export
    sys=nodeb ip=10.0.0.2 key=\(kb) roles=cpu

    """
  let csa = try CS(a, files: [("local", database), ("swarm", first)])
  let csb = try CS(b, files: [("local", database), ("swarm", first)])
  let sa = try SwarmNode(a, key: ga.key), sb = try SwarmNode(b, key: gb.key)

  // A's entry has `file`: its 9gate exports the entry's tree; B's has not.
  #expect(soon { holds(status(a.ns), "listen tcp!*!564 /export listening") }, "\(status(a.ns))")
  #expect(holds(swarmText(a.ns, "/mnt/swarm/status"), "node nodea roles file,terminal"))
  #expect(holds(swarmText(a.ns, "/mnt/swarm/status"), "file: asked 9gate to listen tcp!*!564 /export"))
  #expect(swarmText(b.ns, "/mnt/swarm/status") == "node nodeb roles cpu\n")
  #expect(!status(b.ns).contains("listen"))
  #expect(swarmText(a.ns, "/mnt/swarm/nodes/nodeb") == "sys=nodeb ip=10.0.0.2 key=\(kb) roles=cpu\n")

  // What isn't a swarm file is refused, and nothing changes.
  #expect(!b.ns.writeText("/mnt/swarm/file", "sys=nodex key=0123\n"))
  #expect(!b.ns.writeText("/mnt/swarm/file", first + "sys=nodea key=\(String(repeating: "0", count: 64))\n"))
  #expect(swarmText(b.ns, "/mnt/swarm/file") == first)

  // B adds a member and pushes: A takes it, and its cs knows the new one.
  let kc = hex(StaticKey(privateKey: Array(repeating: 0x44, count: 32)).publicKey)
  let second = first + "sys=nodec key=\(kc) roles=terminal\n"
  #expect(b.ns.writeText("/mnt/swarm/file", second))
  #expect(swarmText(b.ns, "/lib/ndb/swarm") == second)
  #expect(b.ns.writeText("/mnt/swarm/ctl", "push"))
  #expect(soon { holds(swarmText(b.ns, "/mnt/swarm/status"), "push nodec skipped: no ip") },
          "\(swarmText(b.ns, "/mnt/swarm/status"))")
  #expect(holds(swarmText(b.ns, "/mnt/swarm/status"), "push nodea ok"))
  #expect(swarmText(a.ns, "/lib/ndb/swarm") == second)
  #expect(soon { a.ns.ndbValue(sys: "nodec", attr: "key") == kc })
  #expect(swarmText(a.ns, "/mnt/swarm/nodes/nodec") == "sys=nodec key=\(kc) roles=terminal\n")

  // A key the file doesn't list can't push.
  let stranger = try SwarmNode(b, key: StaticKey(privateKey: Array(repeating: 0x33, count: 32)),
                               at: "/mnt/stranger", listening: false)
  let outcome = stranger.service.send(Array(first.utf8), to: "tcp!10.0.0.1!17020", key: ga.key.publicKey)
  #expect(outcome.utf8.starts(with: "failed".utf8), "\(outcome)")
  #expect(swarmText(a.ns, "/lib/ndb/swarm") == second)
  withExtendedLifetime((csa, csb, sa, sb, stranger)) {}
}
