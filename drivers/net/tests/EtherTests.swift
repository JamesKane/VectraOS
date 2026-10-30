// SPDX-License-Identifier: BSD-3-Clause

// The net class (D82) over a fake NIC: ether(3)'s files and formats as
// 9front's netif.c gives them; clone, connect and a conversation's end;
// frames to the conversations of their type, to the promiscuous, and as
// headersonly records; writes checked, their source put in, sent, and a
// broadcast also seen here.

import Glibc
import IPC
import NetClass
import Node
import Sys
import Testing

let mac: [UInt8] = [0x52, 0x54, 0x00, 0x12, 0x34, 0x56]
let other: [UInt8] = [0x52, 0x54, 0x00, 0xAB, 0xCD, 0xEF]

/// A frame to `to` of `type`, padded to Ethernet's minimum.
func frame(to: [UInt8], from: [UInt8] = other, type: UInt16, _ payload: [UInt8] = [1, 2, 3]) -> [UInt8] {
  var f = to + from + [UInt8(type >> 8), UInt8(type & 0xFF)] + payload
  if f.count < Ether.minFrame { f += [UInt8](repeating: 0, count: Ether.minFrame - f.count) }
  return f
}

/// What the device was asked to send.
final class FakeNIC: @unchecked Sendable {
  let lock = Lock()
  var sent: [[UInt8]] = []
  var nic: EtherNIC {
    EtherNIC(mac: mac, mbps: 1000, transmit: { f in self.lock.withLock { self.sent.append(f) }; return true },
             ifstats: { "virtio\n" })
  }
}

/// An ether directory served on a thread of its own.
final class EtherService: @unchecked Sendable {
  let dispatcher: IPCDispatcher
  let tree: NodeTree
  let ether: Ether
  let device = FakeNIC()
  var thread = pthread_t()

  init() throws {
    dispatcher = try IPCDispatcher()
    tree = NodeTree(dispatcher: dispatcher)
    ether = Ether(tree: tree, at: "ether", nic: device.nic)
    pthread_create(&thread, nil, { arg in
      let s = Unmanaged<EtherService>.fromOpaque(arg!).takeUnretainedValue()
      try? s.dispatcher.run()
      return nil
    }, Unmanaged.passUnretained(self).toOpaque())
  }

  func connect() throws -> NodeIPC.NodeClient {
    let ends = try Channel.create()
    try tree.serve(ends.b)
    return NodeIPC.NodeClient(channel: ends.a)
  }

  func stop() {
    dispatcher.stop()
    pthread_join(thread, nil)
  }
}

@Test func numbersAddressesAndTypesAreRead9frontsWay() {
  #expect(Ether.number(3) == "          3 ")
  #expect(Ether.number(-1) == " 4294967295 ")
  #expect(Ether.hex(mac) == "525400123456")
  #expect(Ether.parseType("0x806") == 0x806)
  #expect(Ether.parseType("2048") == 2048)
  #expect(Ether.parseType("010") == 8)
  #expect(Ether.parseType("-1") == -1)
  #expect(Ether.parseType("-2") == -2)
  #expect(Ether.parseType("0x") == nil)
  #expect(Ether.parseType("12z") == nil)
  #expect(Ether.parseAddress("01:00:5e:00:00:fb") == [0x01, 0x00, 0x5E, 0x00, 0x00, 0xFB])
  #expect(Ether.parseAddress("01005e0000fb") == [0x01, 0x00, 0x5E, 0x00, 0x00, 0xFB])
  #expect(Ether.parseAddress("01005e") == nil)
}

@Test func theDirectoryIsEther3s() throws {
  let service = try EtherService()
  defer { service.stop() }
  var root = try service.connect()
  #expect(try root.list("ether").map { $0.name }.sorted() == ["addr", "clone", "ifstats", "link", "stats"])
  #expect(try root.readText("ether/addr") == "525400123456")
  #expect(try root.readText("ether/ifstats") == "virtio\n")
  service.ether.setLink(true)
  #expect(try root.readText("ether/stats") == "in: 0\nlink: 1\nout: 0\ncrc errs: 0\noverflows: 0\nsoft overflows: 0\n"
    + "framing errs: 0\nbuffer errs: 0\noutput errs: 0\nprom: 0\nmbps: 1000\naddr: 525400123456\n")

  // clone opens a conversation's ctl, which reads as its number.
  var ctl = try root.open("ether/clone")
  #expect(try ctl.readAll() == Array(Ether.number(0).utf8))
  #expect(try root.list("ether/0").map { $0.name }.sorted() == ["ctl", "data", "ifstats", "stats", "type"])
  try ctl.writeText("connect 0x806")
  #expect(try root.readText("ether/0/type") == Ether.number(0x806))
  var second = try root.open("ether/clone")
  #expect(try second.readAll() == Array(Ether.number(1).utf8))
  // A type in use is refused elsewhere; -1, every type, isn't one.
  #expect(throws: (any Error).self) { try second.writeText("connect 2054") }
  #expect(throws: (any Error).self) { try second.writeText("bridge") }
  try second.writeText("connect -1\n")
  #expect(try root.readText("ether/1/type") == Ether.number(-1))
  _ = consume second
  _ = consume ctl
}

@Test func framesGoToTheConversationsThatWantThem() throws {
  let service = try EtherService()
  defer { service.stop() }
  var root = try service.connect()
  var arp = try root.open("ether/clone")
  try arp.writeText("connect 0x806")
  var ip = try root.open("ether/clone")
  try ip.writeText("connect 0x800")
  var arpData = try root.open("ether/0/data")
  var ipData = try root.open("ether/1/data")

  // Broadcast ARP to the ARP conversation; IP to us to IP's; to another
  // host, to nobody (nothing is promiscuous): received together, as an
  // interrupt's.
  let request = frame(to: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], type: 0x806, [9, 9])
  let packet = frame(to: mac, type: 0x800, [4, 5])
  service.ether.receive([request, packet, frame(to: other, type: 0x800)])
  #expect(try arpData.read(offset: 0, max: 2048) == request)
  #expect(try ipData.read(offset: 0, max: 2048) == packet)

  // Promiscuous: frames to another host too; one read a frame, cut short
  // to a short read.
  try ip.writeText("promiscuous")
  #expect(try root.readText("ether/stats").contains("prom: 1\n"))
  let elsewhere = frame(to: other, type: 0x800, [7])
  service.ether.receive(elsewhere)
  #expect(try ipData.read(offset: 0, max: 20) == Array(elsewhere.prefix(20)))
  #expect(service.ether.current.inPackets == 4)
  _ = consume arpData
  _ = consume ipData
  _ = consume arp
  _ = consume ip
}

@Test func writesAreCheckedSourcedSentAndBroadcastsSeenHere() throws {
  let service = try EtherService()
  defer { service.stop() }
  var root = try service.connect()
  var arp = try root.open("ether/clone")
  try arp.writeText("connect 0x806")
  var data = try root.open("ether/0/data")
  #expect(throws: (any Error).self) { _ = try data.write(offset: 0, [UInt8](repeating: 0, count: 59)) }
  #expect(throws: (any Error).self) { _ = try data.write(offset: 0, [UInt8](repeating: 0, count: 1515)) }
  // The source is ours whatever was written; a broadcast comes back to
  // the conversations of its type, as Plan 9's does.
  let request = frame(to: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], from: [0, 0, 0, 0, 0, 0], type: 0x806)
  #expect(try data.write(offset: 0, request) == UInt32(request.count))
  let sent = service.device.lock.withLock { service.device.sent }
  #expect(sent.count == 1 && Array(sent[0][6..<12]) == mac && Array(sent[0][12...]) == Array(request[12...]))
  #expect(try data.read(offset: 0, max: 2048) == sent[0])
  #expect(service.ether.current.outPackets == 1)
  _ = consume data
  _ = consume arp
}

@Test func headersOnlyGivesSixtyFourByteRecords() throws {
  let service = try EtherService()
  defer { service.stop() }
  var root = try service.connect()
  var ctl = try root.open("ether/clone")
  try ctl.writeText("connect -1")
  try ctl.writeText("headersonly")
  var data = try root.open("ether/0/data")
  let big = frame(to: mac, type: 0x800, [UInt8](repeating: 0xAA, count: 300))
  service.ether.receive(big)
  let record = try data.read(offset: 0, max: 2048)
  #expect(record.count == 64)
  #expect(Array(record.prefix(58)) == Array(big.prefix(58)))
  #expect(Int(record[58]) << 8 | Int(record[59]) == big.count)
  _ = consume data
  _ = consume ctl
}

@Test func aConversationEndsWithItsLastChannel() throws {
  let service = try EtherService()
  defer { service.stop() }
  var root = try service.connect()
  do {
    var ctl = try root.open("ether/clone")
    try ctl.writeText("connect 0x800")
    _ = consume ctl
  }
  // Once the dispatcher has seen the close, clone gives 0 again, its type
  // back to 0.
  var reused = false
  for _ in 0..<100 {
    var ctl = try root.open("ether/clone")
    reused = try ctl.readAll() == Array(Ether.number(0).utf8)
    if reused {
      #expect(try root.readText("ether/0/type") == Ether.number(0))
      _ = consume ctl
      break
    }
    _ = consume ctl
    usleep(10_000)
  }
  #expect(reused)
}

/// A link whose interrupt can't say it changed is read at the first
/// interrupt, then at most once an interval: an interrupt too soon puts the
/// read off to the interval's end, which a wake then makes, and only one.
@Test func linkWatchReadsAtMostOnceAnInterval() {
  var w = LinkWatch()
  let i = LinkWatch.interval
  var reads: [Bool] = []
  #expect(w.deadline == nil)
  reads.append(w.interrupt(now: 1000))  // the first: at once
  reads.append(w.due(now: 1000 + i))  // nothing put off
  reads.append(w.interrupt(now: 2000))  // too soon: put off
  reads.append(w.interrupt(now: 3000))
  #expect(w.deadline == 1000 + i)
  reads.append(w.due(now: 1000 + i - 1))
  reads.append(w.due(now: 1000 + i))  // the interval's end: read
  #expect(w.deadline == nil)
  reads.append(w.due(now: 1000 + 3 * i))  // only one
  reads.append(w.interrupt(now: 1000 + 3 * i))  // an interval since: at once
  #expect(reads == [true, false, false, false, false, true, false, true])
}

/// `link`: the state at once on a channel's first read, then each read
/// waits until it changes (ip(4) restarts DHCP when it comes up).
@Test func linkReadsWaitForTheLinkToChange() throws {
  let service = try EtherService()
  defer { service.stop() }
  var root = try service.connect()
  var link = try root.open("ether/link")
  #expect(try link.read(offset: 0, max: 16) == Array("down\n".utf8))
  // The next read waits: a thread reads, the link comes up, it returns.
  let got = Locked<[UInt8]?>(nil)
  let raw = link.takeChannel().release()
  let reader = try Thread.spawn {
    var c = NodeIPC.NodeClient(channel: Handle(raw: raw))
    let bytes = try? c.read(offset: 0, max: 16)
    got.withLock { $0 = bytes }
  }
  usleep(50_000)
  #expect(got.withLock { $0 } == nil)  // still waiting
  service.ether.setLink(true)
  _ = try reader.wait(for: Signals.terminated, deadline: Clock.monotonic() + 5_000_000_000)
  #expect(got.withLock { $0 } == Array("up\n".utf8))
  // Setting it as it is wakes no one; a new channel reads the state at once.
  service.ether.setLink(true)
  var again = try root.open("ether/link")
  #expect(try again.read(offset: 0, max: 16) == Array("up\n".utf8))
}
