// SPDX-License-Identifier: BSD-3-Clause

// /net's protocols (ip(3)) over two stacks joined by a link this test
// carries, each tree mounted at /net in a namespace of its own, used as a
// client would: dial(2)'s calls, then the files by hand. TCP: a call
// announced, listened for, accepted and echoed; a megabyte through a
// send buffer that fills (its writes wait); a refusal and its `err`.
// UDP: a connected pair and an announced conversation's headers. The
// interface's files.

import Glibc
import IPC
@testable import IP
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
/// own (never in the sender's call), and each host's timers run.
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

let addressA = IPv4Address(10, 0, 0, 1), addressB = IPv4Address(10, 0, 0, 2)

/// Two hosts, A and B, on one wire, for `body`.
func pair(_ body: (Host, Host) throws -> Void) throws {
  let wire = Wire()
  let a = try Host(mac: 0x0200_0000_000A, address: addressA, wire: wire, side: 0)
  let b = try Host(mac: 0x0200_0000_000B, address: addressB, wire: wire, side: 1)
  wire.hosts = [a, b]
  wire.start()
  defer {
    wire.stop()
    a.stop()
    b.stop()
  }
  try body(a, b)
}

/// Runs `body` on a thread of its own; join the handle.
func spawn(_ body: @escaping @Sendable () -> Void) throws -> Handle { try Thread.spawn(body) }

/// Waits until `done`, or five seconds; whether it was done.
func soon(_ done: () -> Bool) -> Bool {
  let deadline = Clock.monotonic() + 5_000_000_000
  while !done() {
    if Clock.monotonic() > deadline { return false }
    Sys.sleep(until: Clock.monotonic() + 1_000_000)
  }
  return true
}

func text(_ ns: Namespace, _ path: String) -> String {
  guard var f = try? ns.open(path), let t = try? f.readText() else { return "" }
  return t
}

@Test func aCallIsAnnouncedListenedForAcceptedAndEchoed() throws {
  try pair { a, b in
    let ns = b.ns
    let announcing = Atomic<Int>(0)
    let server = try spawn {
      guard let announced = try? ns.announce("tcp!*!7") else { return announcing.store(-1, ordering: .relaxed) }
      announcing.store(announced.dir == "/net/tcp/0" ? 1 : -1, ordering: .relaxed)
      guard let call = try? ns.listen(announced), var c = try? ns.accept(call) else { return }
      // An echo, until the caller's end.
      while let bytes = try? c.data.read(offset: 0, max: 8192), !bytes.isEmpty {
        _ = try? c.data.write(offset: 0, bytes)
      }
    }
    #expect(soon { announcing.load(ordering: .relaxed) != 0 } && announcing.load(ordering: .relaxed) == 1)
    #expect(text(b.ns, "/net/tcp/0/local") == "::!7\n")
    #expect(text(b.ns, "/net/tcp/0/status").hasPrefix("Listen "))
    var c = try a.ns.dial("tcp!10.0.0.2!7")
    #expect(c.dir == "/net/tcp/0")
    #expect(text(a.ns, c.dir + "/remote") == "10.0.0.2!7\n")
    #expect(text(a.ns, c.dir + "/local").hasPrefix("10.0.0.1!"))
    #expect(text(a.ns, c.dir + "/status").hasPrefix("Established "))
    #expect(try c.data.write(offset: 0, Array("hello".utf8)) == 5)
    #expect(try c.data.read(offset: 0, max: 64) == Array("hello".utf8))
    // The listener's side: the call is conversation 1, and its peer us.
    #expect(text(b.ns, "/net/tcp/1/remote").hasPrefix("10.0.0.1!"))
    try c.ctl.writeText("close")
    _ = try server.wait(for: Signals.terminated, deadline: Clock.monotonic() + 5_000_000_000)
    // The echo's end comes back as ours.
    #expect(try c.data.read(offset: 0, max: 64) == [])
  }
}

@Test func aMegabyteGoesThroughAFullSendBuffer() throws {
  try pair { a, b in
    let ns = b.ns
    let received = Locked<[UInt8]>([])
    let announcing = Atomic<Int>(0)
    let server = try spawn {
      guard let announced = try? ns.announce("tcp!*!9") else { return announcing.store(-1, ordering: .relaxed) }
      announcing.store(1, ordering: .relaxed)
      guard let call = try? ns.listen(announced), var c = try? ns.accept(call) else { return }
      Sys.sleep(until: Clock.monotonic() + 50_000_000)  // let the caller's buffer fill
      while let bytes = try? c.data.read(offset: 0, max: 65536), !bytes.isEmpty {
        received.withLock { $0 += bytes }
      }
    }
    #expect(soon { announcing.load(ordering: .relaxed) != 0 } && announcing.load(ordering: .relaxed) == 1)
    var c = try a.ns.dial("tcp!10.0.0.2!9")
    let sent = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 % 251) }
    var at = 0
    while at < sent.count {
      let n = Int(try c.data.write(offset: 0, Array(sent[at..<min(at + 32768, sent.count)])))
      #expect(n > 0)
      at += n
    }
    try c.ctl.writeText("close")
    _ = try server.wait(for: Signals.terminated, deadline: Clock.monotonic() + 20_000_000_000)
    #expect(received.withLock { $0 } == sent)
  }
}

@Test func aRefusedDialSaysWhy() throws {
  try pair { a, _ in
    #expect(throws: DialError("connection refused")) { _ = try a.ns.dial("tcp!10.0.0.2!99") }
    #expect(throws: DialError("bad address: 10.0.0.2!99")) { _ = try a.ns.dial("10.0.0.2!99") }
  }
}

@Test func udpConversationsConnectedAndWithHeaders() throws {
  try pair { a, b in
    // B announces port 53 and reads with headers: remote, local, interface, ports.
    var server = try b.ns.announce("udp!*!53")
    try server.ctl.writeText("headers")
    var data = try b.ns.open(server.dir + "/data")
    var c = try a.ns.dial("udp!10.0.0.2!53")
    #expect(try c.data.write(offset: 0, Array("query".utf8)) == 5)
    let got = try data.read(offset: 0, max: 2048)
    #expect(got.count == IP.udpHeaderSize + 5)
    #expect(IPv6Address(got, at: 0) == IPv6Address(mapping: addressA))
    #expect(IPv6Address(got, at: 16) == IPv6Address(mapping: addressB))
    #expect(got[50] == 0 && got[51] == 53)
    #expect(Array(got[IP.udpHeaderSize...]) == Array("query".utf8))
    // The reply: the same header, a new body.
    #expect(try data.write(offset: 0, Array(got[..<IP.udpHeaderSize]) + Array("answer".utf8)) == 58)
    #expect(try c.data.read(offset: 0, max: 2048) == Array("answer".utf8))
    #expect(text(a.ns, c.dir + "/remote") == "10.0.0.2!53\n")
    #expect(text(a.ns, c.dir + "/status").hasPrefix("Open "))
  }
}

@Test func theInterfacesFiles() throws {
  try pair { a, _ in
    let status = text(a.ns, "/net/ipifc/0/status")
    #expect(status.hasPrefix("device /net/ether0 maxtu 1514 "))
    #expect(status.contains("\t10.0.0.1                                 /120       10.0.0.0 "))
    var route = try a.ns.open("/net/iproute")
    try route.writeText("add 0 0 10.0.0.254")
    let routes = text(a.ns, "/net/iproute")
    #expect(routes.contains("0.0.0.0         /96  10.0.0.254      4    "))
    #expect(routes.contains("10.0.0.0        /120 10.0.0.0        4i   "))
    #expect(text(a.ns, "/net/ndb") == "ip=10.0.0.1 ipmask=255.255.255.0 ipgw=10.0.0.254\n")
    var ctl = try a.ns.open("/net/ipifc/0/ctl")
    try ctl.writeText("add 10.0.0.9 255.255.0.0")
    #expect(text(a.ns, "/net/ipselftab").contains("10.0.0.9 "))
    #expect(text(a.ns, "/net/ipifc/0/status").contains("/112"))
    #expect(throws: (any Error).self) { try ctl.writeText("bind ether /net/ether1") }
    // A call ARP resolved: in the cache.
    _ = try? a.ns.dial("tcp!10.0.0.2!1")
    #expect(text(a.ns, "/net/arp").contains("ether  OK   10.0.0.2 "))
  }
}

/// The process's CPU time so far, in nanoseconds.
func cpuTime() -> Int64 {
  var t = timespec()
  clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t)
  return Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_nsec)
}

@Test func aReadWaitingOnAQuietCallCostsNothing() throws {
  try pair { a, b in
    let ns = b.ns
    let reading = Atomic<Bool>(false)
    let server = try spawn {
      guard let announced = try? ns.announce("tcp!*!9"), let call = try? ns.listen(announced),
        var c = try? ns.accept(call)
      else { return }
      reading.store(true, ordering: .relaxed)
      while let bytes = try? c.data.read(offset: 0, max: 8192), !bytes.isEmpty {}
    }
    var c = try a.ns.dial("tcp!10.0.0.2!9")
    #expect(soon { reading.load(ordering: .relaxed) })
    // B's read is held, with nothing to give: answering it again and
    // again was a core spent (the settle each take made woke it). Half a
    // second of waiting takes a little of the wire's polling, not that.
    Sys.sleep(until: Clock.monotonic() + 100_000_000)
    let before = cpuTime()
    Sys.sleep(until: Clock.monotonic() + 500_000_000)
    let spent = cpuTime() - before
    #expect(spent < 150_000_000, "\(spent / 1_000_000) ms of CPU in 500 ms with a read waiting")
    try c.ctl.writeText("close")
    _ = try server.wait(for: Signals.terminated, deadline: Clock.monotonic() + 5_000_000_000)
  }
}
