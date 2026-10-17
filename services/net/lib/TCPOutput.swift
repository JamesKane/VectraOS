// SPDX-License-Identifier: BSD-3-Clause

// TCP's output and timers (RFC 9293 §3.8, RFC 5681, RFC 6298), N1b: what
// a connection may send now (the peer's window and the congestion
// window), the retransmission timer and its backoff, delayed ACKs, the
// zero-window probe, and TIME-WAIT.
//
// The retransmission timeout is RFC 6298's but for its floor: 200 ms,
// not 1 s, as Linux's; on a LAN, a second's stall after each lost tail
// would cost more than a spurious retransmission. A timeout goes back to
// the oldest unacknowledged byte with a window of one segment.

extension NetStack {
  /// Sends what connection `c` may: its SYN, new or resent data, its FIN,
  /// or an ACK it owes.
  mutating func tcpOutput(_ c: Int, now: Int64) {
    switch tcp[c].state {
    case .closed, .listen: return
    case .synSent, .synReceived:
      if tcp[c].sndNxt == tcp[c].iss {
        let flags = NetStack.syn | (tcp[c].state == .synReceived ? NetStack.ack : 0)
        guard sendSegment(c, seq: tcp[c].iss, flags: flags, count: 0, now: now) else { return }
        tcp[c].sndNxt = tcp[c].iss &+ 1
        if seqGT(tcp[c].sndNxt, tcp[c].sndMax) { tcp[c].sndMax = tcp[c].sndNxt }
        if tcp[c].retries == 0 && !tcp[c].timing {
          tcp[c].timing = true
          tcp[c].rttSeq = tcp[c].iss
          tcp[c].rttStart = now
        }
        if tcp[c].retransmitAt == nil { tcp[c].retransmitAt = now + tcp[c].rto }
      }
      return
    case .timeWait:
      if tcp[c].ackNow { _ = sendSegment(c, seq: tcp[c].sndNxt, flags: NetStack.ack, count: 0, now: now) }
      return
    default: break
    }
    let mss = sendMSS(c)
    while true {
      let t = tcp[c]
      let flight = Int(t.sndNxt &- t.sndUna)
      let window = min(t.sndWnd, t.cwnd + t.limitedTransmit) - flight
      let offset = Int(t.sndNxt &- t.sendSeq)
      let unsent = t.sendCount - offset
      let n = max(0, min(mss, unsent, window))
      // No small segment while others are in flight unless it's the last
      // of the data (the sender's silly window avoidance, RFC 9293
      // §3.8.6.2.1): their ACKs will open the window for a full one.
      if n < min(mss, unsent) && flight > 0 { break }
      // The FIN goes with the last data, or alone after it, once.
      let finAt = t.sendSeq &+ UInt32(t.sendCount)
      let fin = t.finQueued && offset + n == t.sendCount && seqLE(t.sndNxt, finAt)
        && (t.state == .finWait1 || t.state == .closing || t.state == .lastAck)
        && (n > 0 || window >= 0)
      guard n > 0 || fin else { break }
      var flags = NetStack.ack
      if n > 0 && n == unsent { flags |= NetStack.psh }
      if fin { flags |= NetStack.fin }
      guard sendSegment(c, seq: t.sndNxt, flags: flags, count: n, now: now) else { break }
      if n > 0 { counters.tcpBytesOut += n }
      // Time one new segment at a time, never a resent one (Karn).
      if !tcp[c].timing && t.sndNxt == t.sndMax && n > 0 {
        tcp[c].timing = true
        tcp[c].rttSeq = t.sndNxt
        tcp[c].rttStart = now
      }
      tcp[c].sndNxt = t.sndNxt &+ UInt32(n) &+ (fin ? 1 : 0)
      if seqGT(tcp[c].sndNxt, tcp[c].sndMax) { tcp[c].sndMax = tcp[c].sndNxt }
      if tcp[c].retransmitAt == nil { tcp[c].retransmitAt = now + tcp[c].rto }
      if tcp[c].probeAt == nil { armProbe(c, now: now) }
      if fin { break }
    }
    if tcp[c].ackNow { _ = sendSegment(c, seq: tcp[c].sndNxt, flags: NetStack.ack, count: 0, now: now) }
    // Data waiting on a closed window, nothing in flight: probe it.
    let t = tcp[c]
    if t.sndWnd == 0 && t.sendCount > Int(t.sndNxt &- t.sendSeq) && t.sndUna == t.sndMax && t.persistAt == nil {
      tcp[c].persistAt = now + t.rto
    }
  }

  /// Resends the oldest unacknowledged segment (SYN, data or FIN).
  mutating func retransmitFirst(_ c: Int, now: Int64) {
    let t = tcp[c]
    tcp[c].timing = false
    tcp[c].dupAcksAtResend = t.dupAcks
    tcp[c].flightAtResend = Int(t.sndMax &- t.sndUna) / max(t.mss, 1)
    tcp[c].sndMaxAtResend = t.sndMax
    counters.tcpRetransmits += 1
    if t.state == .synSent || t.state == .synReceived {
      tcp[c].sndNxt = t.iss
      tcpOutput(c, now: now)
      return
    }
    let n = min(sendMSS(c), t.sendCount - Int(t.sndUna &- t.sendSeq))
    let finAt = t.sendSeq &+ UInt32(t.sendCount)
    let fin = t.finQueued && t.sndUna &+ UInt32(max(n, 0)) == finAt && seqLT(finAt, t.sndMax)
    guard n > 0 || fin else { return }
    _ = sendSegment(c, seq: t.sndUna, flags: NetStack.ack | (fin ? NetStack.fin : 0), count: max(n, 0), now: now)
  }

  mutating func pollTCP(now: Int64) {
    for c in 0..<tcp.count where tcp[c].state != .closed && !tcp[c].isListener {
      if let d = tcp[c].timeWaitUntil, d <= now {
        closeConnection(c)
        continue
      }
      if let d = tcp[c].retransmitAt, d <= now {
        retransmissionTimeout(c, now: now)
        if tcp[c].state == .closed { continue }
      }
      if let d = tcp[c].probeAt, d <= now { probe(c, now: now) }
      if let d = tcp[c].persistAt, d <= now {
        // A probe: an ACK one below sndUna, which the peer must answer
        // with its window.
        tcp[c].persistAt = tcp[c].sndWnd == 0 ? now + min(tcp[c].rto * 2, NetStack.maxRTO) : nil
        tcp[c].rto = min(tcp[c].rto * 2, NetStack.maxRTO)
        _ = sendSegment(c, seq: tcp[c].sndUna &- 1, flags: NetStack.ack, count: 0, now: now)
      }
      if let d = tcp[c].ackAt, d <= now {
        tcp[c].ackAt = nil
        tcp[c].ackNow = true
      }
      tcpOutput(c, now: now)
    }
  }

  /// Arms the tail loss probe: two smoothed round trips on (at least
  /// 10 ms), if that's before the retransmission timer, once per flight.
  mutating func armProbe(_ c: Int, now: Int64) {
    let t = tcp[c]
    guard !t.probed, t.srtt > 0, t.sndUna != t.sndMax, let rto = t.retransmitAt,
          t.state == .established || t.state == .closeWait || t.state == .finWait1 || t.state == .lastAck
    else {
      tcp[c].probeAt = nil
      return
    }
    let at = now + max(2 * t.srtt, NetStack.minProbe)
    tcp[c].probeAt = at < rto ? at : nil
  }

  /// The probe (RFC 8985 §7.3): in recovery, the hole again; else a new
  /// segment if the peer's window has room, or the last one sent. Its
  /// ACK shows what's missing, or that nothing is.
  mutating func probe(_ c: Int, now: Int64) {
    tcp[c].probeAt = nil
    tcp[c].probed = true
    counters.tcpProbes += 1
    let t = tcp[c]
    if t.inRecovery {
      retransmitFirst(c, now: now)
      return
    }
    let offset = Int(t.sndNxt &- t.sendSeq)
    let unsent = t.sendCount - offset
    let flight = Int(t.sndNxt &- t.sndUna)
    let mss = sendMSS(c)
    if unsent > 0 && t.sndWnd - flight >= min(mss, unsent) {
      let n = min(mss, unsent)
      if sendSegment(c, seq: t.sndNxt, flags: NetStack.ack | (n == unsent ? NetStack.psh : 0), count: n, now: now) {
        tcp[c].sndNxt = t.sndNxt &+ UInt32(n)
        if seqGT(tcp[c].sndNxt, tcp[c].sndMax) { tcp[c].sndMax = tcp[c].sndNxt }
      }
      return
    }
    // The last segment: its data (from sendSeq on), or the FIN alone.
    let data = Int(t.sndMax &- t.sendSeq) - (t.finQueued && seqGT(t.sndMax, t.sendSeq &+ UInt32(t.sendCount)) ? 1 : 0)
    let count = min(mss, max(data, 0))
    if count == 0 {
      retransmitFirst(c, now: now)
      return
    }
    let seq = t.sendSeq &+ UInt32(data - count)
    let fin = data == t.sendCount && t.finQueued && seqGT(t.sndMax, t.sendSeq &+ UInt32(t.sendCount))
    counters.tcpRetransmits += 1
    _ = sendSegment(c, seq: seq, flags: NetStack.ack | (fin ? NetStack.fin : 0), count: count, now: now)
  }

  /// RFC 6298 §5: back off, go back to the oldest unacknowledged byte
  /// with one segment's window (RFC 5681 §3.1), or give up.
  mutating func retransmissionTimeout(_ c: Int, now: Int64) {
    let t = tcp[c]
    tcp[c].retransmitAt = nil
    tcp[c].probeAt = nil
    tcp[c].retries += 1
    let limit = t.state == .synSent || t.state == .synReceived ? NetStack.maxSynRetries : NetStack.maxRetries
    guard tcp[c].retries <= limit else {
      if t.state != .synSent { sendReset(c, now: now) }
      if t.state == .synReceived && !t.accepted && t.listener >= 0 {
        releaseSlot(c)
      } else {
        closeConnection(c, .timedOut)
      }
      return
    }
    counters.tcpTimeouts += 1
    let flight = Int(t.sndMax &- t.sndUna)
    tcp[c].ssthresh = max(flight / 2, 2 * t.mss)
    tcp[c].cwnd = t.mss
    tcp[c].inRecovery = false
    tcp[c].dupAcks = 0
    tcp[c].limitedTransmit = 0
    tcp[c].recover = t.sndMax
    tcp[c].afterTimeout = true
    tcp[c].timing = false
    tcp[c].rto = min(t.rto * 2, NetStack.maxRTO)
    tcp[c].sndNxt = t.state == .synSent || t.state == .synReceived ? t.iss : t.sndUna
    counters.tcpRetransmits += 1
    tcpOutput(c, now: now)
    if tcp[c].retransmitAt == nil && tcp[c].sndUna != tcp[c].sndMax { tcp[c].retransmitAt = now + tcp[c].rto }
  }

  /// When `pollTCP` next has work.
  var tcpDeadline: Int64? {
    var next: Int64?
    for c in 0..<tcp.count where tcp[c].state != .closed {
      next = earlier(next, earlier(earlier(tcp[c].retransmitAt, tcp[c].persistAt), earlier(tcp[c].ackAt, tcp[c].timeWaitUntil)))
      next = earlier(next, tcp[c].probeAt)
    }
    return next
  }
}
