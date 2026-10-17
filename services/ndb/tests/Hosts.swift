// SPDX-License-Identifier: BSD-3-Clause

// Two hosts on a wire, as IPTests has them: each a stack under ip(4)'s
// tree, mounted at /net in a namespace of its own. Host A also runs cs
// and dns, mounted after the stack's files at /net, with its database at
// /lib/ndb/local; host B a name server (`NameServer`) and an echo.

import Glibc
import IPC
import IP
import Ndb
import Net
import Node
import Synchronization
import Sys
import Testing

/// A host: a stack under a tree, served on a dispatcher of its own.
final class Host: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let tree: NodeTree
  var ip: IP!
  var thread = pthread_t()
  let ns = Namespace()

  init(mac: UInt64, address: IPv4Address, wire: Wire, side: Int) throws {
    dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
    var stack = NetStack(mac: MACAddress(mac), tcpConnections: 8, tcpBuffer: 64 * 1024)
    stack.tcpSecret = [UInt8](repeating: UInt8(side + 1), count: 32)
    stack.configureIPv4(address, prefixLength: 24)
    ip = IP(tree: tree, at: "", stack: stack,
            link: IPLink(device: "/net/ether0", transmit: { wire.carry($0, from: side) }, wake: { _ in }))
    pthread_create(&thread, nil, { arg in
      let h = Unmanaged<Host>.fromOpaque(arg!).takeUnretainedValue()
      try? h.dispatcher.run()
      return nil
    }, Unmanaged.passUnretained(self).toOpaque())
    let ends = try Channel.create()
    try tree.serve(ends.b)
    try ns.mount(ends.a, at: "/net")
  }

  func stop() {
    dispatcher.stop()
    pthread_join(thread, nil)
  }
}

/// The link between two hosts: frames queued, carried on a thread of its
/// own, and each host's timers run.
final class Wire: @unchecked Sendable {
  let lock = Lock()
  var queue: [(to: Int, frame: [UInt8])] = []
  var hosts: [Host] = []
  let done = Atomic<Bool>(false)
  var thread = pthread_t()

  func carry(_ frame: [UInt8], from side: Int) { lock.withLock { queue.append((1 - side, frame)) } }

  func start() {
    pthread_create(&thread, nil, { arg in
      let w = Unmanaged<Wire>.fromOpaque(arg!).takeUnretainedValue()
      while !w.done.load(ordering: .relaxed) {
        let batch = w.lock.withLock {
          defer { w.queue = [] }
          return w.queue
        }
        let now = Clock.monotonic()
        for (to, frame) in batch { w.hosts[to].ip.receive(frame, now: now) }
        for h in w.hosts { h.ip.poll(now: Clock.monotonic()) }
        if batch.isEmpty { Sys.sleep(until: Clock.monotonic() + 200_000) }
      }
      return nil
    }, Unmanaged.passUnretained(self).toOpaque())
  }

  func stop() {
    done.store(true, ordering: .relaxed)
    pthread_join(thread, nil)
  }
}

/// cs and dns for a host, on a dispatcher of their own, with `local` as
/// the database's file.
final class Names: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let tree: NodeTree
  let lib: NodeTree
  var thread = pthread_t()
  var cs: ConnectionServer!
  var dns: DNSService!

  init(_ host: Host, local: String) throws {
    dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
    lib = NodeTree(dispatcher: dispatcher)
    lib.file("local", Array(local.utf8))
    pthread_create(&thread, nil, { arg in
      let n = Unmanaged<Names>.fromOpaque(arg!).takeUnretainedValue()
      try? n.dispatcher.run()
      return nil
    }, Unmanaged.passUnretained(self).toOpaque())
    let libEnds = try Channel.create()
    try lib.serve(libEnds.b)
    try host.ns.mount(libEnds.a, at: "/lib/ndb")
    let database = NetDatabase(namespace: host.ns)
    let counter = Atomic<UInt16>(0x1234)
    let resolver = Resolver(servers: { database.nameServers() }, exchange: Resolver.network(host.ns),
                            random: { counter.add(1, ordering: .relaxed).newValue })
    cs = ConnectionServer(tree: tree, at: "", namespace: host.ns, database: database)
    dns = DNSService(tree: tree, at: "", resolver: resolver)
    let ends = try Channel.create()
    try tree.serve(ends.b)
    try host.ns.mount(ends.a, at: "/net", .after)
  }

  func stop() {
    dispatcher.stop()
    pthread_join(thread, nil)
  }
}

let addressA = IPv4Address(10, 0, 0, 1), addressB = IPv4Address(10, 0, 0, 2)

/// A's database: B by name, the network's name server B.
let localA = """
  database=
  \tfile=/lib/ndb/local
  \tfile=/lib/ndb/common

  # the test network
  ipnet=test ip=10.0.0.0 ipmask=255.255.255.0
  \tdns=10.0.0.2 auth=bee
  sys=bee ip=10.0.0.2
  sys=six ip=fe80::1
  tcp=echo port=7
  udp=domain port=53

  """

/// Two hosts, A (with cs and dns) and B (with a name server), for `body`.
func pair(_ body: (Host, Host, Names, NameServer) throws -> Void) throws {
  let wire = Wire()
  let a = try Host(mac: 0x0200_0000_000A, address: addressA, wire: wire, side: 0)
  let b = try Host(mac: 0x0200_0000_000B, address: addressB, wire: wire, side: 1)
  wire.hosts = [a, b]
  wire.start()
  let names = try Names(a, local: localA)
  let server = try NameServer(b)
  defer {
    wire.stop()
    names.stop()
    a.stop()
    b.stop()
  }
  try body(a, b, names, server)
}

/// Waits until `done`, or five seconds; whether it was done.
func soon(_ done: () -> Bool) -> Bool {
  let deadline = Clock.monotonic() + 5_000_000_000
  while !done() {
    if Clock.monotonic() > deadline { return false }
    Sys.sleep(until: Clock.monotonic() + 1_000_000)
  }
  return true
}

/// A query's answers, one a read, or the code its write failed with.
func ask(_ ns: Namespace, _ file: String, _ query: String) -> Result<[String], NodeIPC.NodeError> {
  guard var f = try? ns.open(file) else { return .failure(.notFound) }
  do throws(NodeIPC.NodeClient.Failure) {
    _ = try f.write(offset: 0, Array(query.utf8))
  } catch {
    if case .remote(let code) = error { return .failure(code) }
    return .failure(.io)
  }
  var out: [String] = []
  while let bytes = try? f.read(offset: 0, max: 1024), !bytes.isEmpty { out.append(String(decoding: bytes, as: UTF8.self)) }
  return .success(out)
}
