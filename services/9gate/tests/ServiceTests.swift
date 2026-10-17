// SPDX-License-Identifier: BSD-3-Clause

// 9gate's service between two hosts on a wire, as NdbTests' are: A
// trusts B's key and listens, exporting a tree; B imports it at n/a over
// TCP and reads it through its own files. A caller A doesn't trust, and
// a server whose key isn't the one named, are refused.

import Factotum
import Gate
import Glibc
import IP
import IPC
import Net
import Node
import Noise
import Synchronization
import Sys
import Testing

/// A host: a stack under a tree, served on a dispatcher of its own, at
/// /net in its namespace.
final class Host: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let tree: NodeTree
  var ip: IP!
  let ns = Namespace()

  init(mac: UInt64, address: IPv4Address, wire: Wire, side: Int) throws {
    dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
    var stack = NetStack(mac: MACAddress(mac), tcpConnections: 8, tcpBuffer: 64 * 1024)
    stack.tcpSecret = [UInt8](repeating: UInt8(side + 1), count: 32)
    stack.configureIPv4(address, prefixLength: 24)
    ip = IP(tree: tree, at: "", stack: stack,
            link: IPLink(device: "/net/ether0", transmit: { wire.carry($0, from: side) }, wake: { _ in }))
    let d = dispatcher
    _ = try Thread.spawn { try? d.run() }.release()
    let ends = try Channel.create()
    try tree.serve(ends.b)
    try ns.mount(ends.a, at: "/net")
  }

  deinit { dispatcher.stop() }
}

/// The link between two hosts: frames carried on a thread of its own,
/// which runs each host's timers too.
final class Wire: @unchecked Sendable {
  let lock = Lock()
  var queue: [(to: Int, frame: [UInt8])] = []
  var hosts: [Host] = []
  let done = Atomic<Bool>(false)

  func carry(_ frame: [UInt8], from side: Int) { lock.withLock { queue.append((1 - side, frame)) } }

  func start() throws {
    _ = try Thread.spawn { [self] in
      while !done.load(ordering: .relaxed) {
        let batch = lock.withLock {
          defer { queue = [] }
          return queue
        }
        let now = Clock.monotonic()
        for (to, frame) in batch { hosts[to].ip.receive(frame, now: now) }
        for h in hosts { h.ip.poll(now: Clock.monotonic()) }
        if batch.isEmpty { Sys.sleep(until: Clock.monotonic() + 200_000) }
      }
    }.release()
  }

  deinit { done.store(true, ordering: .relaxed) }
}

/// 9gate on a host, its files mounted at /mnt/9gate there.
final class Gate9: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let imports: IPCDispatcher
  let tree: NodeTree
  let key: StaticKey
  var service: GateService!

  /// With `factotum`, its key is factotum's, at /svc/factotum.
  init(_ host: Host, seed: UInt8, factotum: Bool = false) throws {
    dispatcher = try IPCDispatcher()
    imports = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
    key = StaticKey(privateKey: Array(repeating: seed, count: 32))
    let counter = Atomic<UInt8>(seed)
    let identity = factotum ? try Identity.factotum(host.ns, at: "/svc/factotum/auth")
      : Identity.local(key) { Array(repeating: counter.add(1, ordering: .relaxed).newValue, count: 32) }
    service = GateService(tree: tree, at: "", namespace: host.ns, identity: identity, imports: imports)
    let d = dispatcher, i = imports
    _ = try Thread.spawn { try? d.run() }.release()
    _ = try Thread.spawn { try? i.run() }.release()
    let ends = try Channel.create()
    try tree.serve(ends.b)
    try host.ns.mount(ends.a, at: "/mnt/9gate")
  }

  deinit {
    dispatcher.stop()
    imports.stop()
  }
}

func ctl(_ ns: Namespace, _ line: String) throws {
  var c = try ns.open("/mnt/9gate/ctl")
  try c.writeText(line)
}

func status(_ ns: Namespace) -> String {
  guard var s = try? ns.open("/mnt/9gate/status") else { return "" }
  return (try? s.readText()) ?? ""
}

/// Waits until `done`, or ten seconds; whether it was done.
func soon(_ done: () -> Bool) -> Bool {
  let deadline = Clock.monotonic() + 10_000_000_000
  while !done() {
    if Clock.monotonic() > deadline { return false }
    Sys.sleep(until: Clock.monotonic() + 1_000_000)
  }
  return true
}

func holds(_ text: String, _ line: String) -> Bool {
  text.split(separator: "\n").contains { $0.utf8.elementsEqual(line.utf8) }
}

@Test func gateImportsAnotherHostsExport() throws {
  let wire = Wire()
  let a = try Host(mac: 0x0200_0000_000A, address: IPv4Address(10, 0, 0, 1), wire: wire, side: 0)
  let b = try Host(mac: 0x0200_0000_000B, address: IPv4Address(10, 0, 0, 2), wire: wire, side: 1)
  wire.hosts = [a, b]
  try wire.start()
  let ga = try Gate9(a, seed: 0x11), gb = try Gate9(b, seed: 0x22)
  // A's tree to export, at /export.
  let exportDispatcher = try IPCDispatcher()
  let exported = NodeTree(dispatcher: exportDispatcher)
  exported.file("motd", Array("hello from a\n".utf8))
  exported.file("d/f", Array("deep".utf8))
  _ = try Thread.spawn { try? exportDispatcher.run() }.release()
  defer { exportDispatcher.stop() }
  let ends = try Channel.create()
  try exported.serve(ends.b)
  try a.ns.mount(ends.a, at: "/export")

  // The key file, and nothing listening until told.
  var keyFile = try a.ns.open("/mnt/9gate/key")
  #expect(try keyFile.readText() == hex(ga.key.publicKey) + "\n")
  #expect(status(a.ns).isEmpty)
  #expect(throws: (any Error).self) { try ctl(a.ns, "listen") }
  #expect(throws: (any Error).self) { try ctl(a.ns, "trust 1234") }

  try ctl(a.ns, "trust " + hex(gb.key.publicKey))
  try ctl(a.ns, "listen tcp!*!564 /export")
  #expect(soon { holds(status(a.ns), "listen tcp!*!564 /export listening") })

  // B imports it, and reads it through its own files.
  try ctl(b.ns, "import tcp!10.0.0.1!564 " + hex(ga.key.publicKey) + " a")
  #expect(soon { holds(status(b.ns), "import a tcp!10.0.0.1!564 ready") }, "\(status(b.ns))")
  var motd = try b.ns.open("/mnt/9gate/n/a/motd")
  #expect(try motd.readText() == "hello from a\n")
  var deep = try b.ns.open("/mnt/9gate/n/a/d/f")
  #expect(try deep.readText() == "deep")
  #expect(try b.ns.list("/mnt/9gate/n/a").map { $0.name }.sorted() == ["d", "motd"])
  #expect(throws: (any Error).self) { try ctl(b.ns, "import tcp!10.0.0.1!564 " + hex(ga.key.publicKey) + " a") }

  // A server whose key isn't the one named fails the handshake.
  try ctl(b.ns, "import tcp!10.0.0.1!564 " + hex(StaticKey(privateKey: Array(repeating: 0x44, count: 32)).publicKey)
    + " wrong")
  #expect(soon { status(b.ns).contains("import wrong tcp!10.0.0.1!564 failed") }, "\(status(b.ns))")
}

@Test func gateRefusesAnUntrustedCaller() throws {
  let wire = Wire()
  let a = try Host(mac: 0x0200_0000_000A, address: IPv4Address(10, 0, 0, 1), wire: wire, side: 0)
  let b = try Host(mac: 0x0200_0000_000B, address: IPv4Address(10, 0, 0, 2), wire: wire, side: 1)
  wire.hosts = [a, b]
  try wire.start()
  let ga = try Gate9(a, seed: 0x11), gb = try Gate9(b, seed: 0x22)
  _ = gb
  try ctl(a.ns, "listen tcp!*!564 /net")
  #expect(soon { holds(status(a.ns), "listen tcp!*!564 /net listening") })
  try ctl(b.ns, "import tcp!10.0.0.1!564 " + hex(ga.key.publicKey) + " a")
  #expect(soon { status(b.ns).contains("import a tcp!10.0.0.1!564 failed") }, "\(status(b.ns))")
  #expect(throws: (any Error).self) { _ = try b.ns.open("/mnt/9gate/n/a") }
}

/// factotum for a host, its tree for 9gate (granted proto=noise-ik) at
/// /svc/factotum.
final class Keys: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let state: FactotumState

  init(_ host: Host) throws {
    dispatcher = try IPCDispatcher()
    let counter = Atomic<UInt8>(0x60)
    state = FactotumState(dispatcher: dispatcher, nonce: { "n" }) { n in
      Array(repeating: counter.add(1, ordering: .relaxed).newValue, count: n)
    }
    let d = dispatcher
    _ = try Thread.spawn { try? d.run() }.release()
    let clients = try Channel.create()
    try state.serveClients(clients.b)
    var c = LaunchIPC.ClientsClient(channel: clients.a)
    let tree = try Channel.create()
    try c.open(client: "9gate", grants: ["proto=noise-ik"], node: tree.b)
    try host.ns.mount(tree.a, at: "/svc/factotum")
  }

  deinit { dispatcher.stop() }
}

@Test func gateRunsItsHandshakesThroughFactotum() throws {
  let wire = Wire()
  let a = try Host(mac: 0x0200_0000_000A, address: IPv4Address(10, 0, 0, 1), wire: wire, side: 0)
  let b = try Host(mac: 0x0200_0000_000B, address: IPv4Address(10, 0, 0, 2), wire: wire, side: 1)
  wire.hosts = [a, b]
  try wire.start()
  let keys = try Keys(a)
  let ga = try Gate9(a, seed: 0x11, factotum: true), gb = try Gate9(b, seed: 0x22)
  // A's key is factotum's, which 9gate never holds.
  var keyFile = try a.ns.open("/mnt/9gate/key")
  let shown = try keyFile.readText()
  #expect(shown != hex(ga.key.publicKey) + "\n")
  #expect(keys.state.listing == "key proto=noise-ik !private?\n")
  try ctl(a.ns, "trust " + hex(gb.key.publicKey))
  try ctl(a.ns, "listen tcp!*!564 /net")
  #expect(soon { holds(status(a.ns), "listen tcp!*!564 /net listening") })
  try ctl(b.ns, "import tcp!10.0.0.1!564 " + String(shown.utf8.prefix(64))! + " a")
  #expect(soon { holds(status(b.ns), "import a tcp!10.0.0.1!564 ready") }, "\(status(b.ns))")
  #expect(try b.ns.list("/mnt/9gate/n/a").map { $0.name }.contains("tcp"))
}
