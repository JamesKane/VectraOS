// SPDX-License-Identifier: BSD-3-Clause

// TCP's input (RFC 9293 §3.10.7), N1b: a segment to its connection, a
// SYN to a listener, anything else answered by a reset. The checks run in
// the RFC's order: acceptability, RST, SYN, ACK, data, FIN. RFC 5961's
// defences hold: a reset or SYN that isn't exactly where expected gets a
// challenge ACK, not obedience.

extension NetStack {
  mutating func receiveTCP4(_ f: [UInt8], at o: Int, length: Int, from source: IPv4Address,
                            to destination: IPv4Address, unicast: Bool, now: Int64) {
    guard unicast else {
      counters.ignored += 1
      return
    }
    var c = InternetChecksum()
    c.add32(source.value)
    c.add32(destination.value)
    c.add16(UInt16(NetStack.protocolTCP))
    c.add16(UInt16(length))
    c.add(f, o, length)
    guard c.value == 0 else {
      counters.badChecksums += 1
      return
    }
    receiveTCP(f, at: o, length: length, from: IPv6Address(mapping: source), to: IPv6Address(mapping: destination),
               now: now)
  }

  mutating func receiveTCP6(_ f: [UInt8], at o: Int, length: Int, from source: IPv6Address, to destination: IPv6Address,
                            now: Int64) {
    guard !destination.isMulticast else {
      counters.ignored += 1
      return
    }
    var c = InternetChecksum.ipv6(source, destination, length: length, next: NetStack.protocolTCP)
    c.add(f, o, length)
    guard c.value == 0 else {
      counters.badChecksums += 1
      return
    }
    receiveTCP(f, at: o, length: length, from: source, to: destination, now: now)
  }

  /// The options of a SYN: the peer's MSS and window scale, if given,
  /// and whether it permits SACK.
  static func tcpOptions(_ f: [UInt8], from o: Int, to end: Int) -> (mss: Int?, scale: Int?, sack: Bool) {
    var mss: Int?, scale: Int?, sack = false
    var p = o
    while p < end {
      let kind = f[p]
      if kind == 0 { break }
      if kind == 1 {
        p += 1
        continue
      }
      guard p + 1 < end else { break }
      let size = Int(f[p + 1])
      guard size >= 2 && p + size <= end else { break }
      if kind == 2 && size == 4 { mss = Int(f.be16(p + 2)) }
      if kind == 3 && size == 3 { scale = min(Int(f[p + 2]), 14) }
      if kind == 4 && size == 2 { sack = true }
      p += size
    }
    return (mss, scale, sack)
  }

  /// The highest right edge of the SACK blocks (kind 5) in the options,
  /// if there are any.
  static func sackHighEdge(_ f: [UInt8], from o: Int, to end: Int) -> UInt32? {
    var p = o
    while p < end {
      let kind = f[p]
      if kind == 0 { return nil }
      if kind == 1 {
        p += 1
        continue
      }
      guard p + 1 < end, f[p + 1] >= 2, p + Int(f[p + 1]) <= end else { return nil }
      if kind == 5 && f[p + 1] >= 10 {
        var high: UInt32?
        var b = p + 2
        while b + 8 <= p + Int(f[p + 1]) {
          let right = f.be32(b + 4)
          if high == nil || seqGT(right, high!) { high = right }
          b += 8
        }
        return high
      }
      p += Int(f[p + 1])
    }
    return nil
  }

  mutating func receiveTCP(_ f: [UInt8], at o: Int, length n: Int, from remote: IPv6Address, to local: IPv6Address,
                           now: Int64) {
    guard n >= NetStack.tcpHeaderSize else {
      counters.malformed += 1
      return
    }
    let headerLength = Int(f[o + 12] >> 4) * 4
    guard headerLength >= NetStack.tcpHeaderSize && headerLength <= n else {
      counters.malformed += 1
      return
    }
    counters.tcpSegmentsIn += 1
    let remotePort = f.be16(o), localPort = f.be16(o + 2)
    let seq = f.be32(o + 4), ack = f.be32(o + 8), flags = f[o + 13]
    let len = n - headerLength
    if let c = findTCP(local: local, localPort: localPort, remote: remote, remotePort: remotePort) {
      segmentArrives(c, f, at: o, headerLength: headerLength, length: len, now: now)
      return
    }
    guard flags & NetStack.rst == 0 else { return }
    // A SYN to a listener opens a connection (§3.10.7.2).
    if flags & (NetStack.syn | NetStack.ack) == NetStack.syn {
      for l in 0..<tcp.count where tcp[l].isListener && tcp[l].state == .listen && tcp[l].localPort == localPort {
        var waiting = 0
        for i in 0..<tcp.count where tcp[i].listener == l && !tcp[i].accepted && !tcp[i].isListener { waiting += 1 }
        guard waiting < tcp[l].backlog, let c = freeTCP() else {
          counters.tcpRefused += 1
          return
        }
        tcp[c] = TCPConnection()
        tcp[c].listener = l
        tcp[c].local = local
        tcp[c].localPort = localPort
        tcp[c].remote = remote
        tcp[c].remotePort = remotePort
        startConnection(c, now: now)
        takeSyn(c, f, at: o, headerLength: headerLength, seq: seq)
        tcp[c].sndWnd = Int(f.be16(o + 14))
        tcp[c].sndWl1 = seq
        tcp[c].state = .synReceived
        tcpOutput(c, now: now)
        return
      }
    }
    // No connection, no listener: a reset (§3.10.7.1).
    counters.tcpRefused += 1
    if flags & NetStack.ack != 0 {
      sendBareReset(local: local, localPort: localPort, remote: remote, remotePort: remotePort, seq: ack, ack: 0,
                    withAck: false, now: now)
    } else {
      let consumed = UInt32(len) &+ (flags & NetStack.syn != 0 ? 1 : 0) &+ (flags & NetStack.fin != 0 ? 1 : 0)
      sendBareReset(local: local, localPort: localPort, remote: remote, remotePort: remotePort, seq: 0,
                    ack: seq &+ consumed, withAck: true, now: now)
    }
  }

  /// The peer's SYN: its sequence numbers start, and its options.
  mutating func takeSyn(_ c: Int, _ f: [UInt8], at o: Int, headerLength: Int, seq: UInt32) {
    tcp[c].irs = seq
    tcp[c].rcvNxt = seq &+ 1
    tcp[c].rcvAdvertised = seq &+ 1
    let (mss, scale, sack) = NetStack.tcpOptions(f, from: o + NetStack.tcpHeaderSize, to: o + headerLength)
    tcp[c].sack = sack
    tcp[c].mss = min(mss ?? defaultMSS(c), linkMSS(c))
    tcp[c].cwnd = 10 * tcp[c].mss
    tcp[c].scaling = scale != nil
    if let s = scale {
      tcp[c].sndShift = s
    } else {
      tcp[c].sndShift = 0
      tcp[c].rcvShift = 0
    }
  }

  mutating func segmentArrives(_ c: Int, _ f: [UInt8], at o: Int, headerLength: Int, length len: Int, now: Int64) {
    let seq = f.be32(o + 4), ack = f.be32(o + 8), flags = f[o + 13]
    let window = Int(f.be16(o + 14))
    let hasAck = flags & NetStack.ack != 0, hasSyn = flags & NetStack.syn != 0
    let hasRst = flags & NetStack.rst != 0, hasFin = flags & NetStack.fin != 0

    if tcp[c].state == .synSent {
      if hasAck && (seqLE(ack, tcp[c].iss) || seqGT(ack, tcp[c].sndMax)) {
        if !hasRst {
          sendBareReset(local: tcp[c].local, localPort: tcp[c].localPort, remote: tcp[c].remote,
                        remotePort: tcp[c].remotePort, seq: ack, ack: 0, withAck: false, now: now)
        }
        return
      }
      if hasRst {
        if hasAck { closeConnection(c, .refused) }
        return
      }
      guard hasSyn else { return }
      takeSyn(c, f, at: o, headerLength: headerLength, seq: seq)
      tcp[c].sndWnd = window  // unscaled in a SYN
      tcp[c].sndWl1 = seq
      tcp[c].sndWl2 = ack
      if hasAck {
        acknowledge(c, ack: ack, now: now)
        tcp[c].state = .established
        tcp[c].ackNow = true
      } else {
        // Both opened at once: answer with SYN-ACK.
        tcp[c].state = .synReceived
        tcp[c].sndNxt = tcp[c].iss
      }
      tcpOutput(c, now: now)
      return
    }

    // 1. Is it in the window (§3.10.7.4, the four cases)?
    let segLength = UInt32(len) &+ (hasSyn ? 1 : 0) &+ (hasFin ? 1 : 0)
    let wnd = max(Int(tcp[c].rcvAdvertised &- tcp[c].rcvNxt), 0)
    let rcvNxt = tcp[c].rcvNxt
    let inWindow = { (s: UInt32) in seqLE(rcvNxt, s) && seqLT(s, rcvNxt &+ UInt32(wnd)) }
    let acceptable: Bool
    if segLength == 0 {
      acceptable = wnd == 0 ? seq == rcvNxt : inWindow(seq)
    } else {
      acceptable = wnd > 0 && (inWindow(seq) || inWindow(seq &+ segLength &- 1))
    }
    if !acceptable {
      if !hasRst {
        tcp[c].ackNow = true
        tcpOutput(c, now: now)
      }
      return
    }
    // 2. A reset: obeyed only exactly at rcvNxt; else a challenge ACK.
    // In TIME-WAIT, ignored (RFC 1337): both FINs are done, and a peer
    // that has closed answers our re-ACK of its resent FIN with one.
    if hasRst {
      if tcp[c].state == .timeWait { return }
      if seq == rcvNxt {
        if tcp[c].state == .synReceived && tcp[c].listener >= 0 && !tcp[c].accepted {
          releaseSlot(c)
        } else {
          closeConnection(c, .reset)
        }
      } else {
        challenge(c, now: now)
      }
      return
    }
    // 3. A SYN in a synchronized state: a challenge ACK (RFC 5961 §4).
    if hasSyn {
      challenge(c, now: now)
      return
    }
    // 4. The acknowledgment.
    guard hasAck else { return }
    if tcp[c].state == .synReceived {
      guard seqGT(ack, tcp[c].sndUna) && seqLE(ack, tcp[c].sndMax) else {
        sendBareReset(local: tcp[c].local, localPort: tcp[c].localPort, remote: tcp[c].remote,
                      remotePort: tcp[c].remotePort, seq: ack, ack: 0, withAck: false, now: now)
        return
      }
      tcp[c].state = .established
      tcp[c].sndWnd = window << tcp[c].sndShift
      tcp[c].sndWl1 = seq
      tcp[c].sndWl2 = ack
    }
    if seqGT(ack, tcp[c].sndMax) {
      tcp[c].ackNow = true
      tcpOutput(c, now: now)
      return
    }
    // A duplicate ACK (RFC 5681 §2): nothing new acknowledged, no data,
    // the window unchanged; or, whatever its window, one carrying a SACK
    // block, sure sign the peer holds data beyond a hole (a peer using
    // SACK moves its window with every ACK).
    let sackEdge = headerLength > NetStack.tcpHeaderSize
      ? NetStack.sackHighEdge(f, from: o + NetStack.tcpHeaderSize, to: o + headerLength) : nil
    if let e = sackEdge, seqGT(e, tcp[c].sndUna), seqLE(e, tcp[c].sndMax),
       !seqGT(tcp[c].sackHigh, tcp[c].sndUna) || seqGT(e, tcp[c].sackHigh) {
      tcp[c].sackHigh = e
    }
    let duplicate = ack == tcp[c].sndUna && len == 0 && !hasFin && tcp[c].sndMax != tcp[c].sndUna
      && (window << tcp[c].sndShift == tcp[c].sndWnd || sackEdge != nil)
    if seqGT(ack, tcp[c].sndUna) {
      acknowledge(c, ack: ack, now: now)
    } else if duplicate {
      duplicateAck(c, now: now)
    }
    // The send window, from the newest segment (SND.WL1, SND.WL2).
    if seqLT(tcp[c].sndWl1, seq) || (tcp[c].sndWl1 == seq && seqLE(tcp[c].sndWl2, ack)) {
      tcp[c].sndWnd = window << tcp[c].sndShift
      tcp[c].sndWl1 = seq
      tcp[c].sndWl2 = ack
      if tcp[c].sndWnd > 0 { tcp[c].persistAt = nil }
    }
    // Our FIN acknowledged?
    let finAcked = tcp[c].finQueued && tcp[c].sendCount == 0 && seqGT(tcp[c].sndUna, tcp[c].sendSeq)
    switch tcp[c].state {
    case .finWait1 where finAcked: tcp[c].state = .finWait2
    case .closing where finAcked: enterTimeWait(c, now: now)
    case .lastAck where finAcked:
      closeConnection(c)
      return
    case .timeWait:
      // Their FIN again: acknowledged, and the wait starts over.
      if hasFin {
        tcp[c].ackNow = true
        enterTimeWait(c, now: now)
      }
    default: break
    }
    // 5. Data, in the states that take it.
    switch tcp[c].state {
    case .established, .finWait1, .finWait2:
      if len > 0 { takeData(c, f, at: o + headerLength, length: len, seq: seq, now: now) }
    default: break
    }
    // 6. A FIN, taken when everything before it has come.
    if hasFin && tcp[c].state != .timeWait && tcp[c].state != .closed {
      let at = seq &+ UInt32(len)
      if tcp[c].finSeq == nil && seqGE(at, tcp[c].rcvNxt) { tcp[c].finSeq = at }
      takeFinIfDue(c, now: now)
    }
    tcpOutput(c, now: now)
  }

  mutating func challenge(_ c: Int, now: Int64) {
    counters.tcpChallenges += 1
    tcp[c].ackNow = true
    tcpOutput(c, now: now)
  }

  mutating func enterTimeWait(_ c: Int, now: Int64) {
    tcp[c].state = .timeWait
    tcp[c].timeWaitUntil = now + 2 * NetStack.msl
    tcp[c].retransmitAt = nil
    tcp[c].persistAt = nil
  }

  /// The peer's FIN, once rcvNxt has reached it.
  mutating func takeFinIfDue(_ c: Int, now: Int64) {
    guard let at = tcp[c].finSeq, at == tcp[c].rcvNxt, !tcp[c].finReceived else { return }
    tcp[c].rcvNxt &+= 1
    tcp[c].finReceived = true
    tcp[c].ackNow = true
    let finAcked = tcp[c].finQueued && tcp[c].sendCount == 0 && seqGT(tcp[c].sndUna, tcp[c].sendSeq)
    switch tcp[c].state {
    case .synReceived, .established: tcp[c].state = .closeWait
    case .finWait1: if finAcked { enterTimeWait(c, now: now) } else { tcp[c].state = .closing }
    case .finWait2: enterTimeWait(c, now: now)
    default: break
    }
  }

  /// `len` bytes at `o` with sequence number `seq`: into the receive ring
  /// where they belong, trimmed to what's new and what fits.
  mutating func takeData(_ c: Int, _ f: [UInt8], at o: Int, length: Int, seq: UInt32, now: Int64) {
    var seq = seq, from = o, len = length
    if seqLT(seq, tcp[c].rcvNxt) {
      let skip = Int(tcp[c].rcvNxt &- seq)
      guard skip < len else {
        tcp[c].ackNow = true  // all old: they missed our ACK
        return
      }
      seq = tcp[c].rcvNxt
      from += skip
      len -= skip
    }
    let gap = Int(seq &- tcp[c].rcvNxt)
    let room = receiveSpace(c) - gap
    guard room > 0 else {
      tcp[c].ackNow = true
      return
    }
    len = min(len, room)
    let size = tcpStorage.size
    unsafe copyIntoRing(f, from: from, count: len, ring: tcpStorage.receive[c], size: size,
                 at: (tcp[c].recvHead + tcp[c].recvCount + gap) % size)
    let end = seq &+ UInt32(len)
    if gap == 0 {
      tcp[c].rcvNxt = end
      tcp[c].recvCount += len
      // Ranges held beyond it that now join on.
      var filled = false
      while let first = tcp[c].heldStarts.first, seqLE(first, tcp[c].rcvNxt) {
        let e = tcp[c].heldEnds[0]
        if seqGT(e, tcp[c].rcvNxt) {
          tcp[c].recvCount += Int(e &- tcp[c].rcvNxt)
          tcp[c].rcvNxt = e
        }
        tcp[c].heldStarts.removeFirst()
        tcp[c].heldEnds.removeFirst()
        filled = true
      }
      counters.tcpBytesIn += len
      // A hole filled is acknowledged at once (RFC 5681 §4.2); else every
      // second segment, or after 40 ms.
      tcp[c].unacked += 1
      if filled || tcp[c].unacked >= 2 || !tcp[c].heldStarts.isEmpty {
        tcp[c].ackNow = true
      } else if tcp[c].ackAt == nil {
        tcp[c].ackAt = now + NetStack.delayedAck
      }
    } else {
      holdRange(c, seq, end)
      // Out of order: a duplicate ACK at once (RFC 5681 §4.2).
      tcp[c].ackNow = true
    }
  }

  /// Notes `start..<end` as held beyond a hole, merged with its neighbours.
  mutating func holdRange(_ c: Int, _ start: UInt32, _ end: UInt32) {
    var s = start, e = end
    var starts: [UInt32] = [], ends: [UInt32] = []
    var placed = false
    for i in 0..<tcp[c].heldStarts.count {
      let a = tcp[c].heldStarts[i], b = tcp[c].heldEnds[i]
      if seqLT(b, s) {
        starts.append(a)
        ends.append(b)
      } else if seqLT(e, a) {
        if !placed {
          starts.append(s)
          ends.append(e)
          placed = true
        }
        starts.append(a)
        ends.append(b)
      } else {
        // Overlapping or touching: merged.
        if seqLT(a, s) { s = a }
        if seqGT(b, e) { e = b }
      }
    }
    if !placed {
      starts.append(s)
      ends.append(e)
    }
    tcp[c].newestHeld = s
    // At most 32 ranges: the furthest are forgotten (their data is
    // resent, and lands in the same place).
    if starts.count > NetStack.maxHeldRanges {
      starts.removeLast(starts.count - NetStack.maxHeldRanges)
      ends.removeLast(ends.count - NetStack.maxHeldRanges)
    }
    tcp[c].heldStarts = starts
    tcp[c].heldEnds = ends
  }

  /// An acknowledgment of new data (`ack` past sndUna, not past sndMax):
  /// the round trip timed, the ring freed, the window grown (RFC 5681,
  /// NewReno's recovery, RFC 6582).
  mutating func acknowledge(_ c: Int, ack: UInt32, now: Int64) {
    let acked = Int(ack &- tcp[c].sndUna)
    tcp[c].lastAdvance = acked
    if tcp[c].timing && seqGT(ack, tcp[c].rttSeq) {
      sampleRTT(c, now - tcp[c].rttStart)
      tcp[c].timing = false
    }
    // Data acknowledged leaves the ring.
    if seqGT(ack, tcp[c].sendSeq) {
      let data = min(Int(ack &- tcp[c].sendSeq), tcp[c].sendCount)
      tcp[c].sendHead = (tcp[c].sendHead + data) % tcpStorage.size
      tcp[c].sendCount -= data
      tcp[c].sendSeq &+= UInt32(data)
    }
    tcp[c].sndUna = ack
    if seqLT(tcp[c].sndNxt, ack) { tcp[c].sndNxt = ack }
    let mss = tcp[c].mss
    if tcp[c].inRecovery {
      if seqGE(ack, tcp[c].recover) {
        // A full acknowledgment: recovery ends.
        let flight = Int(tcp[c].sndMax &- ack)
        tcp[c].cwnd = min(tcp[c].ssthresh, max(flight, mss) + mss)
        tcp[c].inRecovery = false
      } else {
        // A partial one: the next hole is resent at once.
        retransmitFirst(c, now: now)
        tcp[c].cwnd = max(tcp[c].cwnd - acked + mss, mss)
      }
    } else if tcp[c].cwnd < tcp[c].ssthresh {
      tcp[c].cwnd += min(acked, mss)
    } else {
      tcp[c].cwnd += max(1, mss * mss / tcp[c].cwnd)
    }
    tcp[c].dupAcks = 0
    tcp[c].limitedTransmit = 0
    tcp[c].retries = 0
    tcp[c].rto = currentRTO(c)
    tcp[c].retransmitAt = tcp[c].sndUna == tcp[c].sndMax ? nil : now + tcp[c].rto
    tcp[c].probed = false
    armProbe(c, now: now)
  }

  /// A loss shown (a third duplicate ACK, or SACKed data more than three
  /// segments past the hole) starts fast retransmit and recovery (RFC 5681
  /// §3.2, RFC 6582 §3.2); later duplicates grow the window. After a
  /// timeout, within the data it went back over (below `recover`), RFC
  /// 6582's careful check holds, with §4.2's ACK heuristic: the last ACK
  /// moved four segments or less, so the duplicates mean a loss, not our
  /// own needless resending. (After a fast recovery it needn't: that
  /// resends only holes.)
  ///
  /// The first two duplicates each let one new segment out (limited
  /// transmit, RFC 3042), so a small window still makes three. And in
  /// recovery a resend found lost is sent again rather than waiting out
  /// the timer: data sent after it has been SACKed, or, without SACK, more
  /// duplicates have come than the segments in flight at the resend, plus
  /// three. Either means segments sent after it arrived without it (the
  /// link keeps order).
  mutating func duplicateAck(_ c: Int, now: Int64) {
    tcp[c].dupAcks += 1
    let mss = tcp[c].mss
    let sacked = seqGT(tcp[c].sackHigh, tcp[c].sndUna) && seqLE(tcp[c].sackHigh, tcp[c].sndMax)
      ? Int(tcp[c].sackHigh &- tcp[c].sndUna) : 0
    let lossShown = tcp[c].dupAcks >= 3 || sacked > 3 * mss
    let allowed = !tcp[c].afterTimeout || seqGT(tcp[c].sndUna &- 1, tcp[c].recover)
      || (tcp[c].cwnd > mss && tcp[c].lastAdvance <= 4 * mss)
    if lossShown && !tcp[c].inRecovery && allowed {
      tcp[c].afterTimeout = false
      let flight = Int(tcp[c].sndMax &- tcp[c].sndUna)
      tcp[c].ssthresh = max(flight / 2, 2 * mss)
      tcp[c].recover = tcp[c].sndMax
      tcp[c].inRecovery = true
      tcp[c].limitedTransmit = 0
      counters.tcpFastRetransmits += 1
      retransmitFirst(c, now: now)
      tcp[c].cwnd = tcp[c].ssthresh + 3 * mss
    } else if tcp[c].inRecovery {
      tcp[c].cwnd += mss
      let resendLost = sacked > 0 ? seqGT(tcp[c].sackHigh, tcp[c].sndMaxAtResend)
        : tcp[c].dupAcks - tcp[c].dupAcksAtResend > tcp[c].flightAtResend + 3
      if resendLost {
        counters.tcpLostRetransmits += 1
        retransmitFirst(c, now: now)
      }
      tcpOutput(c, now: now)
    } else if tcp[c].dupAcks < 3 && !tcp[c].inRecovery {
      tcp[c].limitedTransmit = tcp[c].dupAcks * mss
      tcpOutput(c, now: now)
    }
  }

  /// RFC 6298 §2: the smoothed round trip and its variation.
  mutating func sampleRTT(_ c: Int, _ r: Int64) {
    if tcp[c].srtt == 0 {
      tcp[c].srtt = max(r, 1)
      tcp[c].rttvar = r / 2
    } else {
      let delta = tcp[c].srtt > r ? tcp[c].srtt - r : r - tcp[c].srtt
      tcp[c].rttvar = (3 * tcp[c].rttvar + delta) / 4
      tcp[c].srtt = (7 * tcp[c].srtt + r) / 8
    }
  }

  func currentRTO(_ c: Int) -> Int64 {
    guard tcp[c].srtt > 0 else { return 1_000_000_000 }
    return min(max(tcp[c].srtt + max(1_000_000, 4 * tcp[c].rttvar), NetStack.minRTO), NetStack.maxRTO)
  }
}
