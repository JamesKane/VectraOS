// SPDX-License-Identifier: BSD-3-Clause

// TCP in the stack's core (N1b part b4). Two of our stacks back to back,
// frames carried between them with seeded loss and time jumping to the
// next deadline when the link is idle: the handshake's options, streams
// both ways through loss, the close in both orders and TIME-WAIT,
// retransmission's backoff and giving up, a closed window probed. Then
// segments made by hand: a reset for a closed port, RFC 5961's challenge
// ACKs, out-of-order data held and SACKed.

import FoundationEssentials
import Glibc
@testable import Net
import Testing

/// Two stacks on one link: `a` (10.0.0.2, ours) and `b` (10.0.0.1).
struct Pair {
  var a: NetStack
  var b: NetStack
  var now: Int64 = 0
  var loss: Double
  var random: UInt64 = 0x2545_F491_4F6C_DD1D
  var dropped = 0
  /// Every frame carried, in order, `a`'s marked true.
  var log: [(fromA: Bool, frame: [UInt8])] = []
  var keepLog = false

  init(loss: Double = 0, buffer: Int = 256 * 1024) {
    a = NetStack(mac: ours, tcpConnections: 4, tcpBuffer: buffer)
    b = NetStack(mac: theirs, tcpConnections: 4, tcpBuffer: buffer)
    a.configureIPv4(ourIP, prefixLength: 24)
    b.configureIPv4(theirIP, prefixLength: 24)
    a.tcpSecret = [1, 2, 3]
    b.tcpSecret = [4, 5, 6]
    self.loss = loss
  }

  mutating func drops() -> Bool {
    guard loss > 0 else { return false }
    random ^= random >> 12
    random ^= random << 25
    random ^= random >> 27
    return Double((random &* 0x2545_F491_4F6C_DD1D) >> 11) / Double(1 << 53) < loss
  }

  /// Carries what each side queued to the other; how many frames moved.
  mutating func exchange() -> Int {
    let fromA = (0..<a.transmit.count).map { a.transmit.frame($0) }
    let fromB = (0..<b.transmit.count).map { b.transmit.frame($0) }
    a.transmit.removeAll()
    b.transmit.removeAll()
    for f in fromA {
      if keepLog { log.append((true, f)) }
      if drops() { dropped += 1 } else { b.receive(f, length: f.count, now: now) }
    }
    for f in fromB {
      if keepLog { log.append((false, f)) }
      if drops() { dropped += 1 } else { a.receive(f, length: f.count, now: now) }
    }
    return fromA.count + fromB.count
  }

  /// Runs until `done`, carrying frames, running timers, and jumping
  /// time to the next deadline (or 1 ms on) when the link is idle. False
  /// if `limit` passes first.
  mutating func run(limit: Int64 = 600 * second, until done: (inout Pair) -> Bool) -> Bool {
    while now <= limit {
      if done(&self) { return true }
      a.poll(now: now)
      b.poll(now: now)
      if exchange() == 0 {
        let next = earlier(a.nextDeadline, b.nextDeadline) ?? now + 1_000_000
        now = max(now + 1, min(next, now + 1_000_000))
      } else {
        now += 1000  // a microsecond a round
      }
    }
    return false
  }

  /// `b` connects to `a`'s port 80: (a's handle, b's handle) once both are
  /// established.
  mutating func connect() -> (Int, Int)? {
    guard let l = a.listenTCP(port: 80), let cb = b.connectTCP(to: IPv6Address(mapping: ourIP), port: 80, now: now)
    else { return nil }
    var ca: Int?
    let ok = run(limit: now + 10 * second) { p in
      if ca == nil { ca = p.a.acceptTCP(l) }
      return ca != nil && p.b.tcpState(cb) == .established
    }
    return ok ? (ca!, cb) : nil
  }
}

/// The TCP segment in an IPv4 frame: (flags, seq, ack, window, options, payload length).
func segment(_ f: [UInt8]) -> (flags: UInt8, seq: UInt32, ack: UInt32, window: UInt16, options: [UInt8], length: Int)? {
  guard f.be16(12) == Ethernet.typeIPv4, f[23] == 6 else { return nil }
  let o = 34, h = Int(f[o + 12] >> 4) * 4
  let total = Int(f.be16(16)) - 20
  return (f[o + 13], f.be32(o + 4), f.be32(o + 8), f.be16(o + 14), Array(f[o + 20..<o + h]), total - h)
}

@Test func theHandshakeOffersMSSWindowScaleAndSack() throws {
  var p = Pair()
  p.keepLog = true
  let made1 = p.connect()
  let (ca, cb) = try #require(made1)
  let segments = p.log.compactMap { e in segment(e.frame).map { (e.fromA, $0) } }
  let syn = try #require(segments.first { !$0.0 && $0.1.flags == NetStack.syn })
  let synAck = try #require(segments.first { $0.0 && $0.1.flags == NetStack.syn | NetStack.ack })
  // MSS 1460, NOP, window scale 3 (256 KiB rings), NOP, NOP, SACK permitted.
  #expect(syn.1.options == [2, 4, 0x05, 0xB4, 1, 3, 3, 3, 1, 1, 4, 2])
  #expect(synAck.1.options == [2, 4, 0x05, 0xB4, 1, 3, 3, 3, 1, 1, 4, 2] && synAck.1.ack == syn.1.seq &+ 1)
  #expect(p.a.tcp[ca].sndShift == 3 && p.a.tcp[ca].sack && p.b.tcp[cb].mss == 1460)
  #expect(p.a.tcpState(ca) == .established && p.b.tcpPeer(cb).port == 80)
  // Initial sequence numbers differ by connection (RFC 6528's hash).
  #expect(syn.1.seq != synAck.1.seq)
}

/// Sends `count` bytes of the pattern each way and checks what arrives.
func stream(_ p: inout Pair, _ ca: Int, _ cb: Int, count: Int, limit: Int64) -> Bool {
  var sent = [0, 0], got = [0, 0], bad = [false, false]
  var buffer = [UInt8](repeating: 0, count: 65536)
  let block: [UInt8] = (0..<251 * 64).map { UInt8($0 % 251) }
  return p.run(limit: limit) { p in
    for side in 0..<2 {
      let c = side == 0 ? ca : cb
      if sent[side] < count {
        let n = min(count - sent[side], block.count - 251)
        let k = side == 0 ? p.a.writeTCP(c, block, offset: sent[side] % 251, count: n, now: p.now)
          : p.b.writeTCP(c, block, offset: sent[side] % 251, count: n, now: p.now)
        sent[side] += k
      }
      while true {
        let k = side == 0 ? p.a.readTCP(c, into: &buffer, max: buffer.count, now: p.now)
          : p.b.readTCP(c, into: &buffer, max: buffer.count, now: p.now)
        guard k > 0 else { break }
        for i in 0..<k where buffer[i] != UInt8((got[side] + i) % 251) { bad[side] = true }
        got[side] += k
      }
    }
    return got[0] == count && got[1] == count && !bad[0] && !bad[1]
  }
}

@Test func streamsSurviveLossBothWays() throws {
  for loss in [0.0, 0.01, 0.05] {
    var p = Pair(loss: loss)
    let made2 = p.connect()
    let (ca, cb) = try #require(made2)
    #expect(stream(&p, ca, cb, count: 4 << 20, limit: 300 * second), "loss \(loss)")
    if loss > 0 {
      #expect(p.dropped > 0 && p.a.counters.tcpRetransmits > 0 && p.b.counters.tcpRetransmits > 0, "loss \(loss)")
    } else {
      #expect(p.a.counters.tcpRetransmits == 0 && p.b.counters.tcpRetransmits == 0)
    }
  }
}

@Test func smallRingsScaleAndFill() throws {
  // 16 KiB rings: no window scaling, the window fills and opens.
  var p = Pair(buffer: 16 * 1024)
  let made3 = p.connect()
  let (ca, cb) = try #require(made3)
  #expect(p.a.tcp[ca].rcvShift == 0 && p.b.tcp[cb].sndShift == 0)
  #expect(stream(&p, ca, cb, count: 1 << 20, limit: 60 * second))
}

@Test func closingInBothOrders() throws {
  var p = Pair()
  let made4 = p.connect()
  let (ca, cb) = try #require(made4)
  // b closes first: b FIN-WAIT, a CLOSE-WAIT; a closes: b TIME-WAIT, a gone.
  p.b.shutdownTCP(cb, now: p.now)
  #expect(p.run { p in p.a.tcpState(ca) == .closeWait && p.b.tcpState(cb) == .finWait2 })
  #expect(p.a.tcpAtEnd(ca))
  p.a.closeTCP(ca, now: p.now)
  #expect(p.run { p in p.b.tcpState(cb) == .timeWait && p.a.tcp[ca].state == .closed })
  let waitStarted = p.now
  // TIME-WAIT lasts 2 MSL (60 s), then the connection is closed.
  #expect(p.run { p in p.b.tcpState(cb) == .closed })
  #expect(p.now - waitStarted >= 2 * NetStack.msl && p.now - waitStarted < 2 * NetStack.msl + second)
  #expect(p.b.tcpError(cb) == .none)
  // Both at once: both pass through CLOSING to TIME-WAIT.
  var q = Pair()
  let made5 = q.connect()
  let (da, db) = try #require(made5)
  q.a.shutdownTCP(da, now: q.now)
  q.b.shutdownTCP(db, now: q.now)
  var states: [TCPState] = []
  #expect(q.run { q in
    if states.last != q.a.tcpState(da) { states.append(q.a.tcpState(da)) }
    return q.a.tcpState(da) == .timeWait && q.b.tcpState(db) == .timeWait
  })
  #expect(states.contains(.closing) || states.contains(.finWait2))
}

@Test func timeWaitIgnoresAReset() throws {
  // a closes first and ends in TIME-WAIT; a reset there, even exactly at
  // rcvNxt, is ignored (RFC 1337): a peer gone CLOSED sends one when we
  // re-ACK its resent FIN, and the stream was complete.
  var p = Pair()
  let made = p.connect()
  let (ca, cb) = try #require(made)
  p.a.shutdownTCP(ca, now: p.now)
  #expect(p.run { p in p.b.tcpState(cb) == .closeWait })
  p.b.closeTCP(cb, now: p.now)
  #expect(p.run { p in p.a.tcpState(ca) == .timeWait })
  let rst = tcpFrame(from: p.a.tcp[ca].remotePort, to: p.a.tcp[ca].localPort, seq: p.a.tcp[ca].rcvNxt,
                     flags: NetStack.rst)
  p.a.receive(rst, length: rst.count, now: p.now)
  #expect(p.a.tcpState(ca) == .timeWait && p.a.tcpError(ca) == .none)
}

@Test func unreadDataMakesCloseAReset() throws {
  var p = Pair()
  let made6 = p.connect()
  let (ca, cb) = try #require(made6)
  _ = p.b.writeTCP(cb, [1, 2, 3], now: p.now)
  #expect(p.run { p in p.a.tcpReadable(ca) == 3 })
  p.a.closeTCP(ca, now: p.now)
  #expect(p.run { p in p.b.tcpState(cb) == .closed })
  #expect(p.b.tcpError(cb) == .reset && p.a.counters.tcpResetsOut == 1)
}

@Test func retransmissionBacksOffThenGivesUp() throws {
  var p = Pair()
  let made7 = p.connect()
  let (_, cb) = try #require(made7)
  // a vanishes: b's data is resent at doubling intervals, then dropped.
  p.loss = 1
  _ = p.b.writeTCP(cb, [UInt8](repeating: 7, count: 100), now: p.now)
  var resends: [Int64] = []
  var last = p.b.counters.tcpTimeouts
  #expect(p.run(limit: p.now + 3600 * second) { p in
    if p.b.counters.tcpTimeouts != last {
      last = p.b.counters.tcpTimeouts
      resends.append(p.now)
    }
    return p.b.tcpState(cb) == .closed
  })
  #expect(p.b.tcpError(cb) == .timedOut && resends.count == NetStack.maxRetries)
  let gaps = zip(resends.dropFirst(), resends).map { $0 - $1 }
  for (g, h) in zip(gaps.dropFirst(), gaps) where h < NetStack.maxRTO / 2 {
    #expect(g >= 2 * h - 2_000_000, "the timer doubles: \(h) then \(g)")
  }
  // A SYN to no one: six retries, then given up.
  var q = Pair(loss: 1)
  let made8 = q.b.connectTCP(to: IPv6Address(mapping: ourIP), port: 80, now: 0)
  let c = try #require(made8)
  #expect(q.run(limit: 3600 * second) { q in q.b.tcpState(c) == .closed })
  #expect(q.b.tcpError(c) == .timedOut && q.b.counters.tcpTimeouts == NetStack.maxSynRetries)
}

@Test func aClosedWindowIsProbed() throws {
  var p = Pair(buffer: 16 * 1024)
  let made9 = p.connect()
  let (ca, cb) = try #require(made9)
  // a doesn't read: b fills a's ring and stops, probing.
  let data = [UInt8](repeating: 5, count: 40 * 1024)
  var written = 0
  #expect(p.run(limit: p.now + 30 * second) { p in
    written += p.b.writeTCP(cb, data, offset: written, count: data.count - written, now: p.now)
    return p.a.tcpReadable(ca) == 16 * 1024 && p.b.tcp[cb].sndWnd == 0
  })
  let quiet = p.now
  #expect(p.run(limit: p.now + 30 * second) { p in p.b.counters.tcpSegmentsOut > 0 && p.now > quiet + 5 * second })
  #expect(p.b.tcp[cb].persistAt != nil)
  // Reading opens it again, and the rest arrives.
  var buffer = [UInt8](repeating: 0, count: 64 * 1024)
  var got = 0
  #expect(p.run(limit: p.now + 60 * second) { p in
    written += p.b.writeTCP(cb, data, offset: written, count: data.count - written, now: p.now)
    got += p.a.readTCP(ca, into: &buffer, max: buffer.count, now: p.now)
    return got == data.count
  })
}

// MARK: Segments by hand

/// A TCP segment to `a` (10.0.0.2) from them, its checksum computed.
func tcpFrame(from port: UInt16 = 40000, to dport: UInt16, seq: UInt32, ack: UInt32 = 0, flags: UInt8,
              window: UInt16 = 65535, options: [UInt8] = [], _ data: [UInt8] = []) -> [UInt8] {
  let h = 20 + options.count
  var tcp = [UInt8](repeating: 0, count: h + data.count)
  tcp.put16(port, 0)
  tcp.put16(dport, 2)
  tcp.put32(seq, 4)
  tcp.put32(ack, 8)
  tcp[12] = UInt8(h / 4) << 4
  tcp[13] = flags
  tcp.put16(window, 14)
  for (i, b) in options.enumerated() { tcp[20 + i] = b }
  for (i, b) in data.enumerated() { tcp[h + i] = b }
  var c = InternetChecksum()
  c.add32(theirIP.value)
  c.add32(ourIP.value)
  c.add16(6)
  c.add16(UInt16(tcp.count))
  c.add(tcp, 0, tcp.count)
  tcp.put16(c.value, 16)
  var f = [UInt8](repeating: 0, count: 14 + 20) + tcp
  Ethernet.writeHeader(&f, at: 0, destination: ours, source: theirs, type: Ethernet.typeIPv4)
  f[14] = 0x45
  f.put16(UInt16(20 + tcp.count), 16)
  f[22] = 64
  f[23] = 6
  f.put32(theirIP.value, 26)
  f.put32(ourIP.value, 30)
  f.put16(InternetChecksum.of(f, 14, 20), 24)
  return f
}

func sentSegments(_ s: NetStack) -> [(flags: UInt8, seq: UInt32, ack: UInt32, window: UInt16, options: [UInt8], length: Int)] {
  (0..<s.transmit.count).compactMap { segment(s.transmit.frame($0)) }
}

/// `a` with a connection from them on port 80 established by hand; its
/// handle and a's next sequence number. Their ISN is 1000.
func handOpened(sack: Bool = true) throws -> (NetStack, Int, UInt32) {
  var s = stack()
  s.tcpSecret = [9]
  s.learn(IPv6Address(mapping: theirIP), theirs, create: true, now: 0)
  let made10 = s.listenTCP(port: 80)
  let l = try #require(made10)
  let syn = tcpFrame(to: 80, seq: 1000, flags: NetStack.syn,
                     options: [2, 4, 0x05, 0xB4] + (sack ? [1, 1, 4, 2] : []))
  s.receive(syn, length: syn.count, now: 0)
  let synAck = try #require(sentSegments(s).first)
  #expect(synAck.flags == NetStack.syn | NetStack.ack && synAck.ack == 1001)
  // No window scale offered, so none in the answer (RFC 7323 §2.2).
  #expect(synAck.options == [2, 4, 0x05, 0xB4] + (sack ? [1, 1, 4, 2] : []))
  s.transmit.removeAll()
  let ack = tcpFrame(to: 80, seq: 1001, ack: synAck.seq &+ 1, flags: NetStack.ack)
  s.receive(ack, length: ack.count, now: 1000)
  let made11 = s.acceptTCP(l)
  let c = try #require(made11)
  return (s, c, synAck.seq &+ 1)
}

@Test func aClosedPortAnswersWithAReset() {
  var s = stack()
  s.learn(IPv6Address(mapping: theirIP), theirs, create: true, now: 0)
  let syn = tcpFrame(to: 81, seq: 5000, flags: NetStack.syn)
  s.receive(syn, length: syn.count, now: 0)
  let rst = sentSegments(s)
  #expect(rst.count == 1 && rst[0].flags == NetStack.rst | NetStack.ack && rst[0].seq == 0 && rst[0].ack == 5001)
  // To a segment with an ACK: a reset at its ack, without one.
  s.transmit.removeAll()
  let stray = tcpFrame(to: 81, seq: 5000, ack: 777, flags: NetStack.ack, [1, 2])
  s.receive(stray, length: stray.count, now: 0)
  #expect(sentSegments(s).first?.flags == NetStack.rst && sentSegments(s).first?.seq == 777)
  // A reset never answers a reset.
  s.transmit.removeAll()
  let reset = tcpFrame(to: 81, seq: 5000, flags: NetStack.rst)
  s.receive(reset, length: reset.count, now: 0)
  #expect(s.transmit.isEmpty && s.counters.tcpRefused == 2)
}

@Test func blindResetsAndSynsGetChallengeAcks() throws {
  var (s, c, ourNext) = try handOpened()
  // In the window but not at rcvNxt: a challenge ACK, and the connection stands.
  let nearly = tcpFrame(to: 80, seq: 1001 + 500, flags: NetStack.rst)
  s.receive(nearly, length: nearly.count, now: 2000)
  #expect(sentSegments(s).first?.flags == NetStack.ack && sentSegments(s).first?.ack == 1001)
  #expect(s.tcpState(c) == .established)
  s.transmit.removeAll()
  // A SYN on an open connection: the same.
  let syn = tcpFrame(to: 80, seq: 1001, flags: NetStack.syn)
  s.receive(syn, length: syn.count, now: 2000)
  #expect(sentSegments(s).first?.flags == NetStack.ack && s.tcpState(c) == .established)
  #expect(s.counters.tcpChallenges == 2)
  s.transmit.removeAll()
  // Outside the window: just an ACK. Exactly at rcvNxt: obeyed.
  let far = tcpFrame(to: 80, seq: 1001 &+ 10_000_000, ack: ourNext, flags: NetStack.ack, [1])
  s.receive(far, length: far.count, now: 2000)
  #expect(sentSegments(s).first?.ack == 1001)
  let exact = tcpFrame(to: 80, seq: 1001, flags: NetStack.rst)
  s.receive(exact, length: exact.count, now: 2000)
  #expect(s.tcpState(c) == .closed && s.tcpError(c) == .reset)
}

@Test func outOfOrderDataIsHeldAndSacked() throws {
  var (s, c, ourNext) = try handOpened()
  let data = (0..<4000).map { UInt8($0 % 251) }
  func piece(_ from: Int, _ to: Int) -> [UInt8] {
    tcpFrame(to: 80, seq: 1001 &+ UInt32(from), ack: ourNext, flags: NetStack.ack, Array(data[from..<to]))
  }
  // 1000..<2000 and 3000..<4000 first: held, each answered at once with
  // the hole's ACK and SACK blocks, the newest first.
  let second = piece(1000, 2000), fourth = piece(3000, 4000)
  s.receive(second, length: second.count, now: 2000)
  var acks = sentSegments(s)
  #expect(acks.count == 1 && acks[0].ack == 1001 && acks[0].options == [1, 1, 5, 10] + be(2001) + be(3001))
  s.transmit.removeAll()
  s.receive(fourth, length: fourth.count, now: 2000)
  acks = sentSegments(s)
  #expect(acks[0].options == [1, 1, 5, 18] + be(4001) + be(5001) + be(2001) + be(3001))
  #expect(s.tcpReadable(c) == 0)
  s.transmit.removeAll()
  // The first hole filled: 0..<2000 readable, ACK at once, one block left.
  let first = piece(0, 1000)
  s.receive(first, length: first.count, now: 2000)
  acks = sentSegments(s)
  #expect(s.tcpReadable(c) == 2000 && acks[0].ack == 3001 && acks[0].options == [1, 1, 5, 10] + be(4001) + be(5001))
  s.transmit.removeAll()
  // A segment overlapping what's held, then the last hole.
  let overlap = piece(2500, 3500), third = piece(2000, 3000)
  s.receive(overlap, length: overlap.count, now: 2000)
  s.receive(third, length: third.count, now: 2000)
  var buffer = [UInt8](repeating: 0, count: 8192)
  let n = s.readTCP(c, into: &buffer, max: buffer.count, now: 3000)
  #expect(n == 4000 && Array(buffer[0..<n]) == data && s.tcp[c].heldStarts.isEmpty)
  #expect(sentSegments(s).last?.ack == 5001)
}

func be(_ v: UInt32) -> [UInt8] {
  var b = [UInt8](repeating: 0, count: 4)
  b.put32(v, 0)
  return b
}
