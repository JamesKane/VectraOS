// SPDX-License-Identifier: BSD-3-Clause

// TCP (RFC 9293), N1b: connections, their buffers, the API, and segments
// built and sent. TCPInput.swift takes segments in; TCPOutput.swift
// decides what to send and runs the timers.
//
// A connection is a slot in `tcp`, its send and receive rings slices of
// two pooled byte arrays (`TCPStorage`, a class so a segment's payload
// can be copied from a ring while the frame is built in `transmit`).
// Data is copied twice at most: into the send ring by `writeTCP`, from it
// into the frame; from the frame into the receive ring, from it by
// `readTCP`. Out-of-order data goes straight to its place in the ring,
// the ranges held noted, so a loss costs one retransmission, not every
// segment after it.
//
// Options: MSS, window scaling (RFC 7323 §2) when the peer offers it
// too, and SACK (RFC 2018). Our ACKs name the ranges held beyond a hole,
// so the peer resends only what's missing. Of the peer's blocks we keep
// only the highest byte they reach: losses are repaired by NewReno (RFC
// 6582), which that tells when to start (three segments beyond the hole,
// as RFC 6675's DupThresh) and when a resend was lost too (data sent
// after it has arrived). A tail loss probe (RFC 8985 §7) answers the loss
// of a flight's last segments, or of the one ACK a peer sent for all of
// them, in two round trips rather than a timeout. Not timestamps, or
// keepalives (SSH has its own).
// Initial sequence
// numbers are RFC 6528's: a keyed hash of the connection's addresses and
// ports, plus a 4 µs clock.

import TDCrypto

public enum TCPState: UInt8, Sendable {
  case closed, listen, synSent, synReceived, established, finWait1, finWait2, closeWait, closing, lastAck, timeWait
}

/// Why a connection ended, if it didn't end well.
public enum TCPError: UInt8, Sendable {
  case none
  /// Our SYN was answered by a reset.
  case refused
  /// The peer reset the connection.
  case reset
  /// Retransmissions went unanswered too long.
  case timedOut
}

/// The connections' rings: a send and a receive ring of `size` bytes
/// each. They start in memory of the stack's own; a connection shared
/// with a client (the net service's, NetRing) has its rings moved into
/// the memory both map, so TCP sends from and receives into them there.
@safe final class TCPStorage {
  let size: Int
  let own: UnsafeMutableRawPointer
  var send: [UnsafeMutableRawPointer]
  var receive: [UnsafeMutableRawPointer]

  init(connections: Int, size: Int) {
    self.size = size
    unsafe own = UnsafeMutableRawPointer.allocate(byteCount: connections * 2 * size, alignment: 64)
    unsafe own.initializeMemory(as: UInt8.self, repeating: 0, count: connections * 2 * size)
    let base = unsafe own
    unsafe send = (0..<connections).map { unsafe base + 2 * $0 * size }
    unsafe receive = (0..<connections).map { unsafe base + (2 * $0 + 1) * size }
  }

  deinit { unsafe own.deallocate() }

  /// Connection `c`'s rings back in our own memory.
  func reset(_ c: Int) {
    unsafe send[c] = own + 2 * c * size
    unsafe receive[c] = own + (2 * c + 1) * size
  }
}

struct TCPConnection {
  var state = TCPState.closed
  /// Held by the app (from `listenTCP`, `connectTCP` or `acceptTCP`).
  var held = false
  var isListener = false
  /// For a passive open, the listener it came through, and whether it
  /// has been accepted.
  var listener = -1
  var accepted = false
  /// A listener's limit on connections opening or waiting to be accepted.
  var backlog = 0
  var local = IPv6Address.any, remote = IPv6Address.any
  var localPort: UInt16 = 0, remotePort: UInt16 = 0
  var error = TCPError.none

  // Sending: sndUna oldest unacknowledged, sndNxt next to send, sndMax
  // highest sent. The ring holds data from `sendSeq` on: `sendCount`
  // bytes from ring index `sendHead`.
  var iss: UInt32 = 0, sndUna: UInt32 = 0, sndNxt: UInt32 = 0, sndMax: UInt32 = 0
  var sndWnd = 0, sndWl1: UInt32 = 0, sndWl2: UInt32 = 0
  var sendSeq: UInt32 = 0, sendHead = 0, sendCount = 0
  /// The app is done writing: a FIN follows the data.
  var finQueued = false
  var mss = 536
  /// Window scale shifts: the peer's window, and ours (0 unless both offered).
  var sndShift = 0, rcvShift = 0
  /// Both offered SACK: our ACKs carry blocks.
  var sack = false
  /// Window scaling is offered (by us, actively) or was (by the peer).
  var scaling = true

  // Congestion (RFC 5681, 6582).
  var cwnd = 0, ssthresh = Int.max, dupAcks = 0, recover: UInt32 = 0, inRecovery = false
  /// How far the last new acknowledgment moved (RFC 6582 §4.2).
  var lastAdvance = 0
  /// `recover` was set by a timeout, whose going back may resend what
  /// the peer holds: RFC 6582's careful check applies until it's passed.
  var afterTimeout = false
  /// Limited transmit's allowance beyond cwnd (RFC 3042).
  var limitedTransmit = 0
  /// At the last resend of the oldest segment in recovery: the duplicate
  /// ACKs counted, the segments then in flight, and sndMax.
  var dupAcksAtResend = 0, flightAtResend = 0
  var sndMaxAtResend: UInt32 = 0
  /// The highest byte the peer's SACK blocks reach (past sndUna, if any).
  var sackHigh: UInt32 = 0

  // Round trips and retransmission (RFC 6298).
  var srtt: Int64 = 0, rttvar: Int64 = 0, rto: Int64 = 1_000_000_000
  var timing = false, rttSeq: UInt32 = 0, rttStart: Int64 = 0
  var retransmitAt: Int64?
  var retries = 0
  /// The tail loss probe (RFC 8985 §7): when it's due, and whether it
  /// has gone since the last new acknowledgment.
  var probeAt: Int64?
  var probed = false
  var persistAt: Int64?

  // Receiving: rcvNxt next expected; `recvCount` in-order bytes unread
  // from ring index `recvHead`; out-of-order ranges held beyond them,
  // sorted, by sequence number (`heldStarts[i]..<heldEnds[i]`).
  var irs: UInt32 = 0, rcvNxt: UInt32 = 0, rcvAdvertised: UInt32 = 0
  var recvHead = 0, recvCount = 0
  var heldStarts: [UInt32] = [], heldEnds: [UInt32] = []
  /// The start of the held range the newest out-of-order data joined:
  /// SACK's first block (RFC 2018 §4).
  var newestHeld: UInt32 = 0
  var finReceived = false
  var finSeq: UInt32?
  var ackNow = false, unacked = 0
  var ackAt: Int64?
  var timeWaitUntil: Int64?
}

/// Sequence-space comparisons (mod 2^32).
@inline(__always) func seqLT(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }
@inline(__always) func seqLE(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) <= 0 }
@inline(__always) func seqGT(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) > 0 }
@inline(__always) func seqGE(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) >= 0 }

/// Copies `count` bytes out of a ring of `size` bytes from its index
/// `at`, wrapping, to `to` from `into`.
@inline(__always) func copyFromRing(_ ring: UnsafeMutableRawPointer, size: Int, at: Int, count: Int, to: inout [UInt8],
                                    into: Int) {
  let first = min(count, size - at)
  precondition(into + count <= to.count)
  to.withUnsafeMutableBytes { t in
    unsafe (t.baseAddress! + into).copyMemory(from: ring + at, byteCount: first)
    if count > first { unsafe (t.baseAddress! + into + first).copyMemory(from: ring, byteCount: count - first) }
  }
}

/// Copies `count` bytes of `data` from `from` into a ring of `size` bytes
/// at its index `at`, wrapping.
@inline(__always) func copyIntoRing(_ data: [UInt8], from: Int, count: Int, ring: UnsafeMutableRawPointer, size: Int,
                                    at: Int) {
  let first = min(count, size - at)
  precondition(from + count <= data.count)
  data.withUnsafeBytes { d in
    unsafe (ring + at).copyMemory(from: d.baseAddress! + from, byteCount: first)
    if count > first { unsafe ring.copyMemory(from: d.baseAddress! + from + first, byteCount: count - first) }
  }
}

extension NetStack {
  static let protocolTCP: UInt8 = 6
  static let tcpHeaderSize = 20
  static let fin: UInt8 = 0x01, syn: UInt8 = 0x02, rst: UInt8 = 0x04, psh: UInt8 = 0x08, ack: UInt8 = 0x10
  static let msl: Int64 = 30_000_000_000
  static let minRTO: Int64 = 200_000_000
  static let maxRTO: Int64 = 60_000_000_000
  static let delayedAck: Int64 = 40_000_000
  static let maxRetries = 12, maxSynRetries = 6
  static let maxHeldRanges = 32
  static let minProbe: Int64 = 10_000_000

  // MARK: The API

  /// Listens on `port`; the listener's handle, or nil if the port is
  /// taken or no slot is free. `backlog` connections may wait to be
  /// accepted (or still be opening).
  public mutating func listenTCP(port: UInt16, backlog: Int = 8) -> Int? {
    guard port != 0 else { return nil }
    for i in 0..<tcp.count where tcp[i].isListener && tcp[i].localPort == port && tcp[i].state == .listen { return nil }
    guard let i = freeTCP() else { return nil }
    tcp[i] = TCPConnection()
    tcp[i].state = .listen
    tcp[i].isListener = true
    tcp[i].held = true
    tcp[i].localPort = port
    tcp[i].backlog = backlog
    return i
  }

  /// The oldest established connection waiting on `listener`, now the
  /// app's; nil if none.
  public mutating func acceptTCP(_ listener: Int) -> Int? {
    for i in 0..<tcp.count where tcp[i].listener == listener && !tcp[i].accepted && !tcp[i].isListener {
      guard tcp[i].state != .synReceived && tcp[i].state != .closed else { continue }
      tcp[i].accepted = true
      tcp[i].held = true
      return i
    }
    return nil
  }

  /// Opens a connection to `port` at `destination` (IPv4-mapped for
  /// IPv4); its handle, or nil if there's no source address or slot.
  public mutating func connectTCP(to destination: IPv6Address, port: UInt16, now: Int64) -> Int? {
    let source: IPv6Address
    if destination.mappedIPv4 != nil {
      guard ipv4 != .any else { return nil }
      source = IPv6Address(mapping: ipv4)
    } else {
      guard let s = ipv6Source(for: destination, now: now) else { return nil }
      source = s
    }
    guard let i = freeTCP() else { return nil }
    var localPort: UInt16 = 0
    for _ in 0..<16384 {
      let p = nextTCPPort
      nextTCPPort = nextTCPPort == UInt16.max ? 49152 : nextTCPPort + 1
      if findTCP(local: source, localPort: p, remote: destination, remotePort: port) == nil {
        localPort = p
        break
      }
    }
    guard localPort != 0 else { return nil }
    tcp[i] = TCPConnection()
    tcp[i].held = true
    tcp[i].local = source
    tcp[i].localPort = localPort
    tcp[i].remote = destination
    tcp[i].remotePort = port
    startConnection(i, now: now)
    tcp[i].state = .synSent
    tcpOutput(i, now: now)
    return i
  }

  public func tcpState(_ c: Int) -> TCPState { tcp[c].state }
  public func tcpError(_ c: Int) -> TCPError { tcp[c].error }
  public func tcpPeer(_ c: Int) -> (address: IPv6Address, port: UInt16) { (tcp[c].remote, tcp[c].remotePort) }
  public func tcpLocal(_ c: Int) -> (address: IPv6Address, port: UInt16) { (tcp[c].local, tcp[c].localPort) }
  /// Bytes waiting to be read.
  public func tcpReadable(_ c: Int) -> Int { tcp[c].recvCount }
  /// Bytes `writeTCP` would take now.
  public func tcpWritable(_ c: Int) -> Int {
    switch tcp[c].state {
    case .synSent, .synReceived, .established, .closeWait: tcp[c].finQueued ? 0 : tcpStorage.size - tcp[c].sendCount
    default: 0
    }
  }
  /// Whether the peer has finished sending and everything it sent is read.
  public func tcpAtEnd(_ c: Int) -> Bool {
    (tcp[c].finReceived || tcp[c].state == .closed) && tcp[c].recvCount == 0
  }

  /// Takes up to `count` bytes of `data` from `offset` to send; how many
  /// it took (the send ring may be full).
  public mutating func writeTCP(_ c: Int, _ data: [UInt8], offset: Int = 0, count: Int? = nil, now: Int64) -> Int {
    let n = min(count ?? data.count - offset, tcpWritable(c))
    guard n > 0 else { return 0 }
    let size = tcpStorage.size
    unsafe copyIntoRing(data, from: offset, count: n, ring: tcpStorage.send[c], size: size,
                        at: (tcp[c].sendHead + tcp[c].sendCount) % size)
    _ = tcpAppended(c, n, now: now)
    return n
  }

  /// Reads up to `max` bytes into `buffer` from its start; how many.
  public mutating func readTCP(_ c: Int, into buffer: inout [UInt8], max: Int, now: Int64) -> Int {
    let n = min(max, tcp[c].recvCount, buffer.count)
    guard n > 0 else { return 0 }
    let size = tcpStorage.size
    unsafe copyFromRing(tcpStorage.receive[c], size: size, at: tcp[c].recvHead, count: n, to: &buffer, into: 0)
    tcpConsumed(c, n, now: now)
    return n
  }

  // MARK: Shared rings (the net service's, NetRing)

  /// The size of each connection's send and receive ring.
  public var tcpRingSize: Int { tcpStorage.size }

  /// Moves connection `c`'s rings to `send` and `receive` (`tcpRingSize`
  /// bytes each, which must outlive the connection or the next
  /// `tcpShareRings`), what they hold copied so it stays where it is.
  public mutating func tcpShareRings(_ c: Int, send: UnsafeMutableRawPointer, receive: UnsafeMutableRawPointer) {
    let size = tcpStorage.size
    unsafe send.copyMemory(from: tcpStorage.send[c], byteCount: size)
    unsafe receive.copyMemory(from: tcpStorage.receive[c], byteCount: size)
    unsafe tcpStorage.send[c] = send
    unsafe tcpStorage.receive[c] = receive
  }

  /// Where connection `c`'s rings stand: the send ring's first byte not
  /// yet acknowledged (an index) and how many it holds; the receive ring's
  /// first unread byte and how many are readable.
  public func tcpRings(_ c: Int) -> (sendHead: Int, sendCount: Int, receiveHead: Int, receiveCount: Int) {
    (tcp[c].sendHead, tcp[c].sendCount, tcp[c].recvHead, tcp[c].recvCount)
  }

  /// The app put `n` bytes in the send ring after what it held: they're
  /// sent. False if that's more than `tcpWritable` allowed.
  public mutating func tcpAppended(_ c: Int, _ n: Int, now: Int64) -> Bool {
    guard n <= tcpWritable(c) else { return false }
    guard n > 0 else { return true }
    tcp[c].sendCount += n
    tcpOutput(c, now: now)
    return true
  }

  /// The app took `n` bytes from the receive ring's head (at most
  /// `tcpReadable`): the window opens.
  public mutating func tcpConsumed(_ c: Int, _ n: Int, now: Int64) {
    precondition(n <= tcp[c].recvCount)
    guard n > 0 else { return }
    let size = tcpStorage.size
    tcp[c].recvHead = (tcp[c].recvHead + n) % size
    tcp[c].recvCount -= n
    // Announce the opened window once it has grown enough (RFC 9293
    // §3.8.6.2.2: by half the buffer or a segment).
    let edge = tcp[c].rcvNxt &+ UInt32(receiveSpace(c))
    if Int(edge &- tcp[c].rcvAdvertised) >= min(size / 2, tcp[c].mss) {
      tcp[c].ackNow = true
      tcpOutput(c, now: now)
    }
  }

  /// Done sending: a FIN follows what was written.
  public mutating func shutdownTCP(_ c: Int, now: Int64) {
    switch tcp[c].state {
    case .synSent:
      releaseSlot(c)
    case .synReceived, .established:
      tcp[c].finQueued = true
      tcp[c].state = .finWait1
    case .closeWait:
      tcp[c].finQueued = true
      tcp[c].state = .lastAck
    default: return
    }
    tcpOutput(c, now: now)
  }

  /// Done with the connection: shut down gracefully, the handle the
  /// stack's again. Unread data makes it a reset (RFC 1122 §4.2.2.13).
  /// A listener closes, resetting connections not yet accepted.
  public mutating func closeTCP(_ c: Int, now: Int64) {
    if tcp[c].isListener {
      for i in 0..<tcp.count where tcp[i].listener == c && !tcp[i].accepted && !tcp[i].isListener {
        sendReset(i, now: now)
        releaseSlot(i)
      }
      releaseSlot(c)
      return
    }
    if tcp[c].recvCount > 0 {
      abortTCP(c, now: now)
      return
    }
    tcp[c].held = false
    if tcp[c].state == .closed { releaseSlot(c) } else { shutdownTCP(c, now: now) }
  }

  /// Ends the connection with a reset; the handle the stack's again.
  public mutating func abortTCP(_ c: Int, now: Int64) {
    switch tcp[c].state {
    case .synReceived, .established, .finWait1, .finWait2, .closeWait: sendReset(c, now: now)
    default: break
    }
    releaseSlot(c)
  }

  // MARK: Slots

  func freeTCP() -> Int? {
    for i in 0..<tcp.count where tcp[i].state == .closed && !tcp[i].held { return i }
    // Else the TIME-WAIT nearest its end, held by no one.
    var victim: Int?
    for i in 0..<tcp.count where tcp[i].state == .timeWait && !tcp[i].held {
      if victim == nil || tcp[i].timeWaitUntil! < tcp[victim!].timeWaitUntil! { victim = i }
    }
    return victim
  }

  func findTCP(local: IPv6Address, localPort: UInt16, remote: IPv6Address, remotePort: UInt16) -> Int? {
    for i in 0..<tcp.count where !tcp[i].isListener && tcp[i].state != .closed {
      let t = tcp[i]
      if t.localPort == localPort && t.remotePort == remotePort && t.remote == remote && t.local == local { return i }
    }
    return nil
  }

  mutating func releaseSlot(_ c: Int) {
    tcp[c] = TCPConnection()
    tcpStorage.reset(c)
    tcpGenerations[c] &+= 1
  }

  /// Counts the times slot `c` has been freed: a connection whose
  /// generation has changed is gone (its rings back in our memory), and
  /// the slot may hold another.
  public func tcpGeneration(_ c: Int) -> UInt32 { tcpGenerations[c] }

  /// Established connections waiting on `listener` to be accepted.
  public func tcpPending(_ listener: Int) -> Int {
    var n = 0
    for i in 0..<tcp.count where tcp[i].listener == listener && !tcp[i].accepted && !tcp[i].isListener {
      if tcp[i].state != .synReceived && tcp[i].state != .closed { n += 1 }
    }
    return n
  }

  /// Ends the connection for the protocol; the slot is freed once the
  /// app lets go of it too.
  mutating func closeConnection(_ c: Int, _ error: TCPError = .none) {
    tcp[c].state = .closed
    tcp[c].error = error
    tcp[c].retransmitAt = nil
    tcp[c].persistAt = nil
    tcp[c].ackAt = nil
    tcp[c].timeWaitUntil = nil
    if !tcp[c].held { releaseSlot(c) }
  }

  /// RFC 6528's initial sequence number for a connection.
  func initialSequence(_ c: Int, now: Int64) -> UInt32 {
    var b = tcpSecret
    var tuple = [UInt8](repeating: 0, count: 36)
    tcp[c].local.write(&tuple, at: 0)
    tcp[c].remote.write(&tuple, at: 16)
    tuple.put16(tcp[c].localPort, 32)
    tuple.put16(tcp[c].remotePort, 34)
    b += tuple
    let h = SHA256.hash(b)
    let keyed = UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3])
    return keyed &+ UInt32(truncatingIfNeeded: now / 4000)
  }

  /// Sets a new connection's sending side and offers.
  mutating func startConnection(_ c: Int, now: Int64) {
    let iss = initialSequence(c, now: now)
    tcp[c].iss = iss
    tcp[c].sndUna = iss
    tcp[c].sndNxt = iss
    tcp[c].sndMax = iss
    tcp[c].sendSeq = iss &+ 1
    tcp[c].recover = iss  // RFC 6582 §3.2
    tcp[c].sackHigh = iss  // (no block yet: a stale 0 could compare as ahead)
    tcp[c].mss = defaultMSS(c)
    tcp[c].cwnd = 10 * tcp[c].mss  // RFC 6928's initial window
    tcp[c].rto = 1_000_000_000
    // Our window scale: the least that lets the ring be offered whole.
    var shift = 0
    while (tcpStorage.size >> shift) > 65535 && shift < 14 { shift += 1 }
    tcp[c].rcvShift = shift
  }

  /// What a segment can carry with no MSS option: RFC 9293's defaults.
  func defaultMSS(_ c: Int) -> Int { tcp[c].remote.mappedIPv4 != nil ? 536 : 1220 }

  /// The most a segment to this peer may carry on our link.
  func linkMSS(_ c: Int) -> Int {
    mtu - (tcp[c].remote.mappedIPv4 != nil ? NetStack.ipv4HeaderSize : NetStack.ipv6HeaderSize) - NetStack.tcpHeaderSize
  }

  /// The data a segment may carry now: the MSS less the SACK blocks
  /// our ACKs would add (RFC 9293 §3.7.1: the MSS doesn't count options).
  func sendMSS(_ c: Int) -> Int {
    let t = tcp[c]
    guard t.sack && !t.heldStarts.isEmpty else { return t.mss }
    return t.mss - 4 - 8 * min(t.heldStarts.count, 4)
  }

  /// Free room in the receive ring beyond what's unread.
  func receiveSpace(_ c: Int) -> Int { tcpStorage.size - tcp[c].recvCount }

  // MARK: Segments

  /// Sends one segment of connection `c`: `count` bytes of the send ring
  /// from sequence `seq` (data must start at or after `sendSeq`), with
  /// `flags`. False if it couldn't be queued (no route, no room).
  mutating func sendSegment(_ c: Int, seq: UInt32, flags: UInt8, count: Int, now: Int64) -> Bool {
    let t = tcp[c]
    let isSyn = flags & NetStack.syn != 0
    // A SYN offers our MSS, window scale and SACK: MSS, NOP, window scale,
    // NOP, NOP, SACK permitted. A SYN-ACK offers the last two only if the
    // SYN did (RFC 7323 §2.2, RFC 2018 §2).
    let offerScale = isSyn && (t.state == .synSent || t.scaling)
    let offerSack = isSyn && (t.state == .synSent || t.sack)
    // An ACK with ranges held names up to four: NOP, NOP, SACK; as many as
    // fit beside the data.
    var blocks: [UInt32] = []
    let room = (linkMSS(c) - count - 4) / 8
    if !isSyn && t.sack && flags & NetStack.ack != 0 && !t.heldStarts.isEmpty && room > 0 {
      if let i = t.heldStarts.firstIndex(of: t.newestHeld) {
        blocks += [t.heldStarts[i], t.heldEnds[i]]
      }
      for i in 0..<t.heldStarts.count where t.heldStarts[i] != t.newestHeld && blocks.count < 8 {
        blocks += [t.heldStarts[i], t.heldEnds[i]]
      }
      if blocks.count > 2 * room { blocks.removeLast(blocks.count - 2 * room) }
    }
    let optionLength = isSyn ? 4 + (offerScale ? 4 : 0) + (offerSack ? 4 : 0) : (blocks.isEmpty ? 0 : 4 + 4 * blocks.count)
    let headerLength = NetStack.tcpHeaderSize + optionLength
    let space = receiveSpace(c)
    let window = isSyn ? min(space, 65535) : min(space >> t.rcvShift, 65535)
    let advertisedEdge = t.rcvNxt &+ UInt32(window << (isSyn ? 0 : t.rcvShift))
    let ack = flags & NetStack.ack != 0 ? t.rcvNxt : 0
    let size = tcpStorage.size
    let ring = unsafe tcpStorage.send[c]
    let ringAt = count > 0 ? (t.sendHead + Int(seq &- t.sendSeq)) % size : 0
    let mss = linkMSS(c), shift = t.rcvShift
    let total = headerLength + count
    let sourcePort = t.localPort, port = t.remotePort
    let build: (inout [UInt8], Int, Int) -> Int = { b, at, _ in
      b.put16(sourcePort, at)
      b.put16(port, at + 2)
      b.put32(seq, at + 4)
      b.put32(ack, at + 8)
      b[at + 12] = UInt8(headerLength / 4) << 4
      b[at + 13] = flags
      b.put16(UInt16(window), at + 14)
      b.put32(0, at + 16)  // checksum, urgent pointer
      if isSyn {
        b[at + 20] = 2
        b[at + 21] = 4
        b.put16(UInt16(mss), at + 22)
        var p = at + 24
        if offerScale {
          b[p] = 1
          b[p + 1] = 3
          b[p + 2] = 3
          b[p + 3] = UInt8(shift)
          p += 4
        }
        if offerSack { b.put32(0x0101_0402, p) }  // NOP, NOP, SACK permitted
      } else if !blocks.isEmpty {
        b[at + 20] = 1
        b[at + 21] = 1
        b[at + 22] = 5
        b[at + 23] = UInt8(2 + 4 * blocks.count)
        for (k, edge) in blocks.enumerated() { b.put32(edge, at + 24 + 4 * k) }
      }
      if count > 0 {
        unsafe copyFromRing(ring, size: size, at: ringAt, count: count, to: &b, into: at + headerLength)
      }
      return total
    }
    let sent: Bool
    if let v4 = t.remote.mappedIPv4 {
      let source = ipv4
      sent = sendIPv4(protocol: NetStack.protocolTCP, to: v4, now: now) { b, at, limit in
        let n = build(&b, at, limit)
        var sum = InternetChecksum()
        sum.add32(source.value)
        sum.add32(v4.value)
        sum.add16(UInt16(NetStack.protocolTCP))
        sum.add16(UInt16(n))
        sum.add(b, at, n)
        b.put16(sum.value, at + 16)
        return n
      }
    } else {
      sent = sendIPv6(from: t.local, to: t.remote, next: NetStack.protocolTCP, hopLimit: hopLimit, checksumAt: 16,
                      now: now, payload: build)
    }
    if sent {
      counters.tcpSegmentsOut += 1
      if flags & NetStack.ack != 0 {
        tcp[c].ackNow = false
        tcp[c].unacked = 0
        tcp[c].ackAt = nil
      }
      if seqGT(advertisedEdge, tcp[c].rcvAdvertised) || flags & NetStack.syn != 0 { tcp[c].rcvAdvertised = advertisedEdge }
    }
    return sent
  }

  /// A reset on connection `c` (RFC 9293 §3.10.7.4 for a synchronized one).
  mutating func sendReset(_ c: Int, now: Int64) {
    let t = tcp[c]
    sendBareReset(local: t.local, localPort: t.localPort, remote: t.remote, remotePort: t.remotePort, seq: t.sndNxt,
                  ack: t.rcvNxt, withAck: true, now: now)
  }

  /// A reset outside any connection (to a segment for none, §3.10.7.1).
  mutating func sendBareReset(local: IPv6Address, localPort: UInt16, remote: IPv6Address, remotePort: UInt16,
                              seq: UInt32, ack: UInt32, withAck: Bool, now: Int64) {
    let flags = NetStack.rst | (withAck ? NetStack.ack : 0)
    let build: (inout [UInt8], Int, Int) -> Int = { b, at, _ in
      b.put16(localPort, at)
      b.put16(remotePort, at + 2)
      b.put32(seq, at + 4)
      b.put32(withAck ? ack : 0, at + 8)
      b[at + 12] = 5 << 4
      b[at + 13] = flags
      b.put16(0, at + 14)
      b.put32(0, at + 16)
      return NetStack.tcpHeaderSize
    }
    if let v4 = remote.mappedIPv4 {
      let source = local.mappedIPv4 ?? ipv4
      sendIPv4(protocol: NetStack.protocolTCP, to: v4, now: now) { b, at, limit in
        let n = build(&b, at, limit)
        var sum = InternetChecksum()
        sum.add32(source.value)
        sum.add32(v4.value)
        sum.add16(UInt16(NetStack.protocolTCP))
        sum.add16(UInt16(n))
        sum.add(b, at, n)
        b.put16(sum.value, at + 16)
        return n
      }
    } else {
      sendIPv6(from: local, to: remote, next: NetStack.protocolTCP, hopLimit: hopLimit, checksumAt: 16, now: now,
               payload: build)
    }
    counters.tcpResetsOut += 1
  }
}
