// SPDX-License-Identifier: BSD-3-Clause

// bin/net (D79): the network stack over an Ethernet device, serving /net's
// protocols (ip(3)) at `net` in its tree, which manifests mount after the
// devices at /net. Its argument is the device's directory (`/net/ether0`,
// its manifest mounting devmgr's /net); `-a ADDRESS/PREFIX` and `-g
// GATEWAY` before it configure IPv4, which DHCP does otherwise. IPv6
// starts on its link-local address.
//
// One conversation of the device takes every type (`connect -1`), read
// through the one ring by a thread of its own, 64 reads in flight, the
// frames come by each wakeup given to the stack together;
// frames out go through a second ring, one an entry, offered without
// waiting for each, 32 in flight. A frame from our own
// address is one we sent, given back as ether(3) gives back broadcasts,
// and is dropped. A second thread runs the stack's timers, asleep on a
// futex until the next deadline or one earlier. The device gone, it exits
// 1 for the launcher to restart it.

import IP
import IPC
import Net
import Node
import Synchronization
import Sys

func fail(_ what: String) -> Never {
  print("net: \(what)")
  Process.exit(code: 1)
}

/// The frames out, through a ring on the conversation's data.
final class Transmitter: @unchecked Sendable {
  let lock = Lock()
  var ring: NodeBulkChannel
  var sent = 0, failed = 0

  init(_ ring: consuming NodeBulkChannel) { self.ring = ring }

  func send(_ frame: [UInt8]) {
    // Padded to Ethernet's 60 bytes, which ether(3) takes at least.
    let padded = frame.count >= 60 ? frame : frame + [UInt8](repeating: 0, count: 60 - frame.count)
    lock.withLock {
      // Offered, not waited for: a burst of ACKs goes without a round
      // trip through the driver for each, which held the receiving thread.
      if (try? ring.offer(padded)) != nil { sent += 1 } else { failed += 1 }
    }
  }
}

/// A ring a thread takes for its own.
final class RingBox: @unchecked Sendable {
  var ring: NodeBulkChannel
  init(_ ring: consuming NodeBulkChannel) { self.ring = ring }
}

/// The stack's timers: a thread asleep until the next deadline, woken
/// early when one comes sooner.
final class Timers: @unchecked Sendable {
  let word = Atomic<UInt32>(0)
  /// The deadline the thread sleeps until.
  let target = Atomic<Int64>(Int64.max)

  var address: UnsafeMutablePointer<UInt32> {
    unsafe withUnsafePointer(to: word) { unsafe UnsafeMutablePointer(mutating: UnsafeRawPointer($0).assumingMemoryBound(to: UInt32.self)) }
  }

  /// A deadline, perhaps earlier than the one slept until.
  func wake(_ deadline: Int64?) {
    guard let deadline, deadline < target.load(ordering: .acquiring) else { return }
    word.add(1, ordering: .releasing)
    unsafe Futex.wake(address, count: 1)
  }

  func run(_ ip: IP) -> Never {
    var address = IPv4Address.any
    while true {
      let seen = word.load(ordering: .acquiring)
      let now = Clock.monotonic()
      ip.poll(now: now)
      // The address DHCP gave, or took back.
      let bound = ip.read { s in (s.ipv4, s.prefixLength, s.dhcp.state) }
      if bound.0 != address {
        address = bound.0
        let how = bound.2 == .off ? "" : " by DHCP"
        print("net: \(address == .any ? "no address" : "\(address.text)/\(bound.1)")\(how)")
      }
      let deadline = ip.nextDeadline ?? Int64.max
      target.store(deadline, ordering: .releasing)
      if deadline <= Clock.monotonic() { continue }
      try? unsafe Futex.wait(self.address, current: seen, deadline: deadline)
    }
  }
}

@main struct NetProgram {
  static func main() {
    let start = Startup.current
    var args = Array(start.args.dropFirst())
    var configured: (IPv4Address, Int)?
    var gateway: IPv4Address?
    while args.count >= 2, args[0].utf8.first == 0x2D {  // "-"
      let flag = args.removeFirst(), value = args.removeFirst()
      if flag.utf8.elementsEqual("-a".utf8) {
        let parts = value.utf8.split(separator: 0x2F).map { String(decoding: $0, as: UTF8.self) }
        guard parts.count == 2, let a = IPv4Address(parts[0]), let n = Int(parts[1]), n >= 0, n <= 32 else {
          fail("bad address \(value)")
        }
        configured = (a, n)
      } else if flag.utf8.elementsEqual("-g".utf8), let g = IPv4Address(value) {
        gateway = g
      } else {
        fail("usage: net [-a ADDRESS/PREFIX] [-g GATEWAY] DEVICE")
      }
    }
    guard args.count == 1 else { fail("usage: net [-a ADDRESS/PREFIX] [-g GATEWAY] DEVICE") }
    let device = args[0]
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(start) } catch { fail("no namespace") }

    // The device comes once its driver has: ten seconds at most, or
    // there is none, and nothing to serve.
    func clone() -> NodeIPC.NodeClient {
      for _ in 0..<1000 {
        if let c = try? ns.open(device + "/clone") { return c }
        Sys.sleep(until: Clock.monotonic() + 10_000_000)
      }
      fail("no \(device)")
    }
    var ctl = clone()
    func must<R: ~Copyable, E: Error>(_ body: () throws(E) -> R) -> R {
      do throws(E) { return try body() } catch { fail("can't open \(device): \(error)") }
    }
    let number = String(decoding: must { () throws(NodeIPC.NodeClient.Failure) in try ctl.readAll() }.filter { $0 != 0x20 },
                        as: UTF8.self)
    must { () throws(NodeIPC.NodeClient.Failure) in try ctl.writeText("connect -1") }
    var addr = must { () throws(NamespaceError) in try ns.open(device + "/addr") }
    let hex = must { () throws(NodeIPC.NodeClient.Failure) in try addr.readAll() }
    guard hex.count >= 12, let value = UInt64(String(decoding: hex[..<12], as: UTF8.self), radix: 16) else {
      fail("\(device)/addr isn't an address")
    }
    let mac = MACAddress(value)
    let data = device + "/\(number)/data"
    let out = must { () throws(NamespaceError) in try ns.open(data) }
    let inbound = must { () throws(NamespaceError) in try ns.open(data) }
    let transmitter: Transmitter
    var receive: NodeBulkChannel
    do throws(NodeBulkChannel.Failure) {
      transmitter = Transmitter(try NodeBulkChannel(out, slots: 32, dataSize: 32 * 2048))
      receive = try NodeBulkChannel(inbound, slots: 64, dataSize: 64 * 2048)
    } catch {
      fail("can't attach a ring to \(data): \(error)")
    }

    var stack = NetStack(mac: mac, tcpConnections: 16, tcpBuffer: 64 * 1024)
    guard let secret = try? CPRNG.draw(count: 36) else { fail("no randomness") }
    stack.tcpSecret = Array(secret[0..<32])
    let xid = secret[32..<36].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    let dispatcher: IPCDispatcher
    do throws(Status) { dispatcher = try IPCDispatcher() } catch { fail("can't make a dispatcher") }
    let tree = NodeTree(dispatcher: dispatcher)
    let timers = Timers()
    let ip = IP(tree: tree, at: "net", stack: stack,
                link: IPLink(device: device, transmit: { transmitter.send($0) }, wake: { timers.wake($0) }))
    ip.withStack { s, now in
      if let c = configured {
        s.configureIPv4(c.0, prefixLength: c.1, gateway: gateway)
      } else {
        s.startDHCP(xid: xid, now: now)
      }
      s.startIPv6(now: now)
    }
    print("net: \(device) \(mac.text), \(configured == nil ? "asking for an address by DHCP" : "configured")")
    tree.text("status", read: {
      ip.read { s in "device \(device)\nmac \(s.mac.text)\n" }
    })

    do throws(Status) {
      // The receiving ring is this thread's alone from here.
      receive.timeout = Int64.max
      let box = RingBox(receive)
      _ = try Thread.spawn {
        while true {
          // Every frame come by now, to the stack at once: a burst is one
          // settle, its reader woken once.
          guard let frames = try? box.ring.takeMany(max: 2048), !frames.isEmpty else { fail("\(device) is gone") }
          // Ours, given back (a broadcast we sent): not news.
          ip.receive(frames.filter { $0.count < 12 || MACAddress($0, at: 6) != mac }, now: Clock.monotonic())
        }
      }.release()
      _ = try Thread.spawn { timers.run(ip) }.release()
      // The link: each time it comes up, an address still being asked
      // for is asked for again at once (ether(3)'s `link` waits for a
      // change).
      if var link = try? ns.open(device + "/link") {
        let raw = link.takeChannel().release()
        _ = try Thread.spawn {
          var c = NodeIPC.NodeClient(channel: Handle(raw: raw))
          var up = false
          while let b = try? c.read(offset: 0, max: 16), !b.isEmpty {
            let now = b.first == 0x75  // "up"
            if now && !up {
              print("net: \(device) link up")
              ip.withStack { s, t in s.linkCameUp(now: t) }
            }
            up = now
          }
        }.release()
      }
      guard let export = start.export() else { fail("no export (its manifest's `export`)") }
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      fail("can't serve: \(error)")
    }
    _ = consume ctl
  }
}
