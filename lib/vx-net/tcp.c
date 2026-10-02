// vx-net TCP: part of net.c, which includes it (after the IP output helpers,
// before input and timers).
//
// RFC 793's state machine with RFC 9293's corrections; RFC 5961's challenge
// ACKs for resets and SYNs inside the window; RFC 6298's retransmission timer
// with Karn's rule; NewReno congestion control (RFC 5681, RFC 6582): slow
// start, congestion avoidance, fast retransmit and fast recovery with partial
// ACKs; window scaling (RFC 7323), so a peer may offer more than 64 KiB; the
// MSS option; zero-window probes. No SACK and no timestamps yet.
//
// Each connection has a 64 KiB ring each way. Our window is what the receive
// ring has free, which fits 16 bits, so we scale by nothing; data that
// arrives out of order is dropped and ACKed again, and the peer's fast
// retransmit fills the hole. A segment for no connection gets a reset.

static constexpr vx_instant TCP_RTO_MIN = 200'000'000, TCP_RTO_MAX = 60 * NET_SECOND;
static constexpr vx_instant TCP_RTO_INITIAL = NET_SECOND;    // RFC 6298 §2.1
static constexpr vx_instant TCP_TIME_WAIT = 10 * NET_SECOND; // 2 MSL, with a short MSL: slots are few
static constexpr vx_instant TCP_ORPHAN_FIN_WAIT_2 = 60 * NET_SECOND;
static constexpr uint32_t TCP_BACKLOG = 4;
static constexpr uint8_t TCP_SYN_RETRIES = 6, TCP_RETRIES = 12;

enum : uint8_t { TCP_FIN = 1, TCP_SYN = 2, TCP_RST = 4, TCP_PSH = 8, TCP_ACK = 16 };

static bool seq_lt(uint32_t a, uint32_t b) { return (int32_t)(a - b) < 0; }
static bool seq_leq(uint32_t a, uint32_t b) { return (int32_t)(a - b) <= 0; }
static uint32_t tcp_min(uint32_t a, uint32_t b) { return a < b ? a : b; }

static const char *const TCP_STATE_NAMES[] = {
    "Closed",   "Listen",  "Syn_sent",  "Syn_received", "Established", "Finwait1",
    "Finwait2", "Closing", "Time_wait", "Close_wait",   "Last_ack",
};

// The state's name, as Plan 9's /net/tcp/N/status says it.
[[maybe_unused]] static const char *vx_net_tcp_state_name(vx_tcp_state s) {
  return s < sizeof TCP_STATE_NAMES / sizeof TCP_STATE_NAMES[0] ? TCP_STATE_NAMES[s] : "Closed";
}

// One segment to raddr: the header, any options, then len bytes of data
// from the ring at `from` (VX_TCP_BUF bytes, starting at index start).
static void tcp_emit(vx_net *n, uint32_t raddr, uint16_t lport, uint16_t rport, uint32_t seq, uint32_t ack,
                     uint8_t flags, uint16_t window, const uint8_t *opt, uint32_t optlen, const uint8_t *ring,
                     uint32_t start, uint32_t len, vx_instant now) {
  uint8_t *s = n->frame + 34;
  uint32_t hlen = 20 + optlen;
  net_put16(s, lport);
  net_put16(s + 2, rport);
  net_put32(s + 4, seq);
  net_put32(s + 8, ack);
  s[12] = (uint8_t)(hlen / 4 << 4);
  s[13] = flags;
  net_put16(s + 14, window);
  net_put32(s + 16, 0); // checksum and urgent pointer
  if (optlen) memcpy(s + 20, opt, optlen);
  if (len) { // from the ring, which may wrap
    uint32_t first = tcp_min(len, VX_TCP_BUF - start);
    memcpy(s + hlen, ring + start, first);
    memcpy(s + hlen + first, ring, len - first);
  }
  uint32_t src = net_src(n, raddr);
  net_put16(s + 16, net_fold(net_sum(net_pseudo(src, raddr, 6, hlen + len), s, hlen + len)));
  net_ip_header(n, 6, src, raddr, hlen + len);
  net_ip_route(n, raddr, 20 + hlen + len, now);
}

// What our window is: the receive ring's free space.
static uint16_t tcp_window(const vx_net_tcb *t) { return (uint16_t)(VX_TCP_BUF - t->rlen); }

// A segment on a connection. `off` is where its data starts, counted from
// sbuf_seq. A SYN carries our MSS, and our window scale (by nothing) when
// we are the first to offer it, or the peer offered it.
static void tcp_send(vx_net *n, vx_net_conv *c, uint32_t seq, uint8_t flags, uint32_t off, uint32_t len,
                     vx_instant now) {
  vx_net_tcb *t = &c->tcb;
  uint8_t opt[8];
  uint32_t optlen = 0;
  if (flags & TCP_SYN) {
    uint32_t mss = n->mtu - 40;
    opt[0] = 2, opt[1] = 4, opt[2] = (uint8_t)(mss >> 8), opt[3] = (uint8_t)mss; // MSS
    optlen = 4;
    bool offer = t->state == VX_TCP_SYN_SENT || t->snd_shift != 0xff;
    if (offer) opt[4] = 1, opt[5] = 3, opt[6] = 3, opt[7] = 0, optlen = 8; // NOP, window scale 0
  }
  if (t->state != VX_TCP_SYN_SENT) flags |= TCP_ACK;
  if (flags & TCP_ACK) t->ack_now = false;
  tcp_emit(n, c->raddr, c->lport, c->rport, seq, t->rcv_nxt, flags, tcp_window(t), opt, optlen, t->sbuf,
           (t->shead + off) % VX_TCP_BUF, len, now);
}

static void tcp_arm(vx_net_tcb *t, vx_instant now) {
  if (t->rto_at == NET_NEVER) t->rto_at = now + t->rto;
}

// The end of the data written so far: where a FIN goes.
static uint32_t tcp_end(const vx_net_tcb *t) { return t->sbuf_seq + t->slen; }

// Retransmits the first unacknowledged segment (fast retransmit, partial ACKs).
static void tcp_resend_first(vx_net *n, vx_net_conv *c, vx_instant now) {
  vx_net_tcb *t = &c->tcb;
  uint32_t end = tcp_end(t);
  if (seq_lt(t->snd_una, end)) {
    uint32_t len = tcp_min(end - t->snd_una, t->mss);
    tcp_send(n, c, t->snd_una, len == end - t->snd_una ? TCP_PSH : 0, t->snd_una - t->sbuf_seq, len, now);
  } else if (t->fin_queued) {
    tcp_send(n, c, end, TCP_FIN, 0, 0, now);
  }
  t->timing = false; // Karn: no sample from what was sent twice
}

// Sends what the windows allow: data, then a FIN once all of it has gone;
// and an ACK if one is owed and nothing else carried it.
static void tcp_output(vx_net *n, vx_net_conv *c, vx_instant now) {
  vx_net_tcb *t = &c->tcb;
  bool sending = t->state == VX_TCP_ESTABLISHED || t->state == VX_TCP_CLOSE_WAIT ||
                 t->state == VX_TCP_FIN_WAIT_1 || t->state == VX_TCP_CLOSING || t->state == VX_TCP_LAST_ACK;
  if (sending) {
    uint32_t end = tcp_end(t), window = tcp_min(t->snd_wnd, t->cwnd);
    for (;;) {
      uint32_t flight = t->snd_nxt - t->snd_una;
      uint32_t unsent = seq_lt(t->snd_nxt, end) ? end - t->snd_nxt : 0;
      uint32_t len = tcp_min(tcp_min(unsent, window > flight ? window - flight : 0), t->mss);
      if (!len) break;
      tcp_send(n, c, t->snd_nxt, len == unsent ? TCP_PSH : 0, t->snd_nxt - t->sbuf_seq, len, now);
      if (!t->timing && !seq_lt(t->snd_nxt, t->snd_max)) { // time new data only
        t->timing = true;
        t->rtt_seq = t->snd_nxt;
        t->rtt_start = now;
      }
      t->snd_nxt += len;
      if (seq_lt(t->snd_max, t->snd_nxt)) t->snd_max = t->snd_nxt;
      tcp_arm(t, now);
    }
    if (t->fin_queued && t->snd_nxt == end) {
      tcp_send(n, c, end, TCP_FIN, 0, 0, now);
      t->snd_nxt = end + 1;
      if (seq_lt(t->snd_max, t->snd_nxt)) t->snd_max = t->snd_nxt;
      if (t->state == VX_TCP_ESTABLISHED) t->state = VX_TCP_FIN_WAIT_1;
      if (t->state == VX_TCP_CLOSE_WAIT) t->state = VX_TCP_LAST_ACK;
      tcp_arm(t, now);
    }
    // Data waits, nothing is in flight, and the peer offers no window: probe it.
    if (!t->snd_wnd && seq_lt(t->snd_nxt, end) && t->snd_nxt == t->snd_una && t->persist_at == NET_NEVER)
      t->persist_at = now + (t->rto << t->persist_shift);
  }
  if (t->ack_now && t->state != VX_TCP_SYN_SENT && t->state != VX_TCP_CLOSED && t->state != VX_TCP_LISTEN)
    tcp_send(n, c, t->snd_nxt, 0, 0, 0, now);
}

// The connection is closed. An orphan, or a listener's connection nobody took,
// goes; otherwise it stays, Closed, for its application to see why.
static void tcp_closed(vx_net_conv *c, vx_status why) {
  vx_net_tcb *t = &c->tcb;
  t->state = VX_TCP_CLOSED;
  if (why != VX_OK && t->error == VX_OK) t->error = why;
  t->rto_at = t->persist_at = t->linger_at = NET_NEVER;
  if (t->orphan || (t->parent && !t->accepted)) c->proto = 0;
}

// RTO from the estimates (RFC 6298 §2.3), clamped; the initial one before any sample.
static void tcp_rto_set(vx_net_tcb *t) {
  if (!t->measured) {
    t->rto = TCP_RTO_INITIAL;
    return;
  }
  t->rto = t->srtt + (4 * t->rttvar > 1'000'000 ? 4 * t->rttvar : 1'000'000);
  if (t->rto < TCP_RTO_MIN) t->rto = TCP_RTO_MIN;
  if (t->rto > TCP_RTO_MAX) t->rto = TCP_RTO_MAX;
}

static void tcp_rtt_sample(vx_net_tcb *t, vx_instant r) {
  if (!t->measured) {
    t->measured = true;
    t->srtt = r;
    t->rttvar = r / 2;
  } else {
    vx_instant diff = t->srtt > r ? t->srtt - r : r - t->srtt;
    t->rttvar = (3 * t->rttvar + diff) / 4;
    t->srtt = (7 * t->srtt + r) / 8;
  }
  tcp_rto_set(t);
}

// A fresh connection's sending side: ISS, window and timers.
static void tcp_start(vx_net *n, vx_net_tcb *t) {
  t->iss = net_random(n);
  t->snd_una = t->snd_max = t->recover = t->iss;
  t->snd_nxt = t->iss + 1;
  t->sbuf_seq = t->iss + 1;
  t->mss = 536; // until the peer says (RFC 9293 §3.7.1)
  t->ssthresh = UINT32_MAX;
  t->rto = TCP_RTO_INITIAL;
  t->rto_at = t->persist_at = t->linger_at = NET_NEVER;
  t->snd_shift = 0xff; // the peer has not offered window scaling
}

// The MSS and window scale options of a SYN.
static void tcp_syn_options(vx_net *n, vx_net_tcb *t, const uint8_t *opt, uint32_t len) {
  for (uint32_t i = 0; i < len;) {
    uint8_t kind = opt[i];
    if (kind == 0) break;
    if (kind == 1) {
      i++;
      continue;
    }
    if (i + 1 >= len || opt[i + 1] < 2 || i + opt[i + 1] > len) break; // runs past the header
    if (kind == 2 && opt[i + 1] == 4) t->mss = net_get16(opt + i + 2);
    if (kind == 3 && opt[i + 1] == 3) t->snd_shift = opt[i + 2] > 14 ? 14 : opt[i + 2];
    i += opt[i + 1];
  }
  uint32_t ours = n->mtu - 40;
  if (t->mss < 64 || t->mss > ours) t->mss = (uint16_t)(t->mss < 64 ? 536 : ours);
  t->cwnd = 10u * t->mss; // RFC 6928's initial window
}

// The peer's window from a segment, scaled unless it is a SYN's.
static void tcp_window_update(vx_net_tcb *t, uint32_t seq, uint32_t ack, uint16_t window, bool syn) {
  if (!(seq_lt(t->snd_wl1, seq) || (t->snd_wl1 == seq && seq_leq(t->snd_wl2, ack)))) return;
  uint8_t shift = syn || t->snd_shift == 0xff ? 0 : t->snd_shift;
  t->snd_wnd = (uint32_t)window << shift;
  t->snd_wl1 = seq;
  t->snd_wl2 = ack;
  if (t->snd_wnd) {
    t->persist_at = NET_NEVER;
    t->persist_shift = 0;
  }
}

static void tcp_reset_reply(vx_net *n, uint32_t src, uint16_t sport, uint16_t dport, uint32_t seq,
                            uint32_t ack, uint8_t flags, uint32_t seglen, vx_instant now) {
  if (flags & TCP_RST) return;
  if (flags & TCP_ACK)
    tcp_emit(n, src, dport, sport, ack, 0, TCP_RST, 0, nullptr, 0, nullptr, 0, 0, now);
  else
    tcp_emit(n, src, dport, sport, 0, seq + seglen, TCP_RST | TCP_ACK, 0, nullptr, 0, nullptr, 0, 0, now);
}

// Takes acknowledged bytes out of the send ring.
static void tcp_acked(vx_net_tcb *t, uint32_t ack) {
  uint32_t end = tcp_end(t);
  uint32_t upto = seq_lt(end, ack) ? end : ack;
  if (seq_lt(t->sbuf_seq, upto)) {
    uint32_t n = upto - t->sbuf_seq;
    t->shead = (t->shead + n) % VX_TCP_BUF;
    t->slen -= n;
    t->sbuf_seq = upto;
  }
}

// The ACK field of a segment on a synchronized connection. False if the
// segment is to be dropped here.
static bool tcp_ack(vx_net *n, vx_net_conv *c, uint32_t seq, uint32_t ack, uint16_t window, uint32_t dlen,
                    uint8_t flags, vx_instant now) {
  vx_net_tcb *t = &c->tcb;
  if (t->state == VX_TCP_SYN_RCVD) {
    if (!seq_lt(t->snd_una, ack) || seq_lt(t->snd_max, ack)) {
      tcp_emit(n, c->raddr, c->lport, c->rport, ack, 0, TCP_RST, 0, nullptr, 0, nullptr, 0, 0, now);
      return false;
    }
    t->state = VX_TCP_ESTABLISHED;
    t->snd_wl1 = seq - 1; // so this segment's window is taken
  }
  if (seq_lt(t->snd_max, ack)) { // acknowledges what was never sent
    t->ack_now = true;
    return false;
  }
  if (seq_lt(ack, t->snd_una)) return true; // an old one: nothing to learn, but its data may be new

  bool window_same = ((uint32_t)window << (t->snd_shift == 0xff ? 0 : t->snd_shift)) == t->snd_wnd;
  if (ack == t->snd_una) {
    bool dup = !dlen && !(flags & (TCP_SYN | TCP_FIN)) && window_same && t->snd_max != t->snd_una;
    if (dup) {
      t->dupacks++;
      // The third: fast retransmit, unless this loss is inside a window
      // already recovered (RFC 6582 §3.2 step 2).
      if (t->dupacks == 3 && !t->in_recovery && seq_leq(t->recover, ack - 1)) {
        uint32_t flight = t->snd_max - t->snd_una;
        t->ssthresh = flight / 2 > 2u * t->mss ? flight / 2 : 2u * t->mss;
        t->recover = t->snd_max;
        t->in_recovery = true;
        tcp_resend_first(n, c, now);
        t->cwnd = t->ssthresh + 3u * t->mss;
      } else if (t->in_recovery && t->dupacks > 3) {
        t->cwnd += t->mss; // each dupack: a segment has left the network
      }
    }
    tcp_window_update(t, seq, ack, window, false);
    return true;
  }

  // New data acknowledged.
  uint32_t acked = ack - t->snd_una;
  if (t->timing && seq_lt(t->rtt_seq, ack)) {
    tcp_rtt_sample(t, now - t->rtt_start);
    t->timing = false;
  }
  tcp_acked(t, ack);
  t->snd_una = ack;
  if (seq_lt(t->snd_nxt, ack)) t->snd_nxt = ack;
  t->dupacks = 0;
  t->retries = 0;
  // New data acknowledged: the timer's backoff goes (RFC 6298 §5.7 allows it,
  // as BSD does), or after a timeout under loss Karn's rule would keep it
  // backed off for as long as retransmitted data is being acknowledged.
  tcp_rto_set(t);
  if (t->in_recovery) {
    if (!seq_lt(ack, t->recover)) { // a full ACK: recovery is over
      uint32_t flight = t->snd_max - t->snd_una;
      t->cwnd = tcp_min(t->ssthresh, flight + t->mss);
      t->in_recovery = false;
    } else { // a partial ACK: the next hole, at once, and the window deflated
      tcp_resend_first(n, c, now);
      t->cwnd = t->cwnd > acked ? t->cwnd - acked : 0;
      t->cwnd += t->mss;
    }
  } else if (t->cwnd < t->ssthresh) {
    t->cwnd += tcp_min(acked, t->mss); // slow start
  } else {
    uint32_t more = (uint32_t)((uint64_t)t->mss * t->mss / t->cwnd); // congestion avoidance
    t->cwnd += more ? more : 1;
  }
  t->rto_at = t->snd_una == t->snd_max ? NET_NEVER : now + t->rto;
  tcp_window_update(t, seq, ack, window, false);

  if (t->fin_queued && ack == tcp_end(t) + 1) { // our FIN is acknowledged
    if (t->state == VX_TCP_FIN_WAIT_1) {
      t->state = VX_TCP_FIN_WAIT_2;
      if (t->orphan) t->linger_at = now + TCP_ORPHAN_FIN_WAIT_2;
    } else if (t->state == VX_TCP_CLOSING) {
      t->state = VX_TCP_TIME_WAIT;
      t->linger_at = now + TCP_TIME_WAIT;
    } else if (t->state == VX_TCP_LAST_ACK) {
      tcp_closed(c, VX_OK);
      return false;
    }
  }
  return true;
}

// A segment arrived for this connection (not a listener's).
static void tcp_segment(vx_net *n, vx_net_conv *c, uint32_t seq, uint32_t ack, uint8_t flags, uint16_t window,
                        const uint8_t *opt, uint32_t optlen, const uint8_t *data, uint32_t dlen,
                        vx_instant now) {
  vx_net_tcb *t = &c->tcb;
  if (t->state == VX_TCP_SYN_SENT) {
    bool ack_ok = (flags & TCP_ACK) && seq_lt(t->iss, ack) && seq_leq(ack, t->snd_max);
    if ((flags & TCP_ACK) && !ack_ok) {
      if (!(flags & TCP_RST))
        tcp_emit(n, c->raddr, c->lport, c->rport, ack, 0, TCP_RST, 0, nullptr, 0, nullptr, 0, 0, now);
      return;
    }
    if (flags & TCP_RST) {
      if (ack_ok) tcp_closed(c, VX_ERR_REFUSED);
      return;
    }
    if (!(flags & TCP_SYN)) return;
    t->irs = seq;
    t->rcv_nxt = seq + 1;
    tcp_syn_options(n, t, opt, optlen);
    if (ack_ok) {
      t->snd_una = ack;
      t->snd_wnd = window; // a SYN's window is never scaled
      t->snd_wl1 = seq;
      t->snd_wl2 = ack;
      t->state = VX_TCP_ESTABLISHED;
      if (t->timing) tcp_rtt_sample(t, now - t->rtt_start), t->timing = false;
      t->retries = 0;
      t->rto_at = NET_NEVER;
      t->ack_now = true;
      tcp_output(n, c, now);
    } else { // a simultaneous open
      t->state = VX_TCP_SYN_RCVD;
      tcp_send(n, c, t->iss, TCP_SYN, 0, 0, now);
    }
    return;
  }

  // Synchronized states: is the segment inside our window (RFC 9293 §3.10.7.4)?
  uint32_t seglen = dlen + !!(flags & TCP_SYN) + !!(flags & TCP_FIN);
  uint32_t wnd = tcp_window(t);
  bool in_first = seq_leq(t->rcv_nxt, seq) && seq_lt(seq, t->rcv_nxt + wnd);
  bool in_last =
      seglen && seq_leq(t->rcv_nxt, seq + seglen - 1) && seq_lt(seq + seglen - 1, t->rcv_nxt + wnd);
  bool acceptable;
  if (seglen)
    acceptable = wnd && (in_first || in_last);
  else
    acceptable = wnd ? in_first : seq == t->rcv_nxt; // a zero window takes only the next sequence
  if (!acceptable) {
    if (!(flags & TCP_RST)) {
      t->ack_now = true;
      if (t->state == VX_TCP_TIME_WAIT) t->linger_at = now + TCP_TIME_WAIT; // a FIN again: our ACK was lost
      tcp_output(n, c, now);
    }
    return;
  }
  if (flags & TCP_RST) { // RFC 5961 §3.2: only the exact next sequence resets
    if (seq == t->rcv_nxt)
      tcp_closed(c, VX_ERR_PEER_CLOSED);
    else
      t->ack_now = true, tcp_output(n, c, now);
    return;
  }
  if (flags & TCP_SYN) { // RFC 5961 §4.2: a challenge ACK
    t->ack_now = true;
    tcp_output(n, c, now);
    return;
  }
  if (!(flags & TCP_ACK) || !tcp_ack(n, c, seq, ack, window, dlen, flags, now)) {
    if (c->proto && t->state != VX_TCP_CLOSED) tcp_output(n, c, now);
    return;
  }

  // Data, in order only: the part before rcv_nxt was had already; the part
  // past the window is trimmed off, and its FIN with it.
  bool fin = flags & TCP_FIN;
  if (seq_lt(seq, t->rcv_nxt)) {
    uint32_t skip = tcp_min(t->rcv_nxt - seq, dlen);
    data += skip, dlen -= skip, seq += skip;
    if (seq != t->rcv_nxt) fin = false; // the FIN was had already too
  }
  if (seq != t->rcv_nxt) { // a hole before it: ask again for what is missing
    dlen = 0;
    fin = false;
    t->ack_now = true;
  }
  bool taking =
      t->state == VX_TCP_ESTABLISHED || t->state == VX_TCP_FIN_WAIT_1 || t->state == VX_TCP_FIN_WAIT_2;
  if (dlen && taking) {
    uint32_t take = tcp_min(dlen, VX_TCP_BUF - t->rlen);
    if (take < dlen) fin = false;
    if (!t->orphan) { // an orphan's data has no reader: taken, and dropped
      uint32_t at = (t->rhead + t->rlen) % VX_TCP_BUF, first = tcp_min(take, VX_TCP_BUF - at);
      memcpy(t->rbuf + at, data, first);
      memcpy(t->rbuf, data + first, take - first);
      t->rlen += take;
    }
    t->rcv_nxt += take;
    t->ack_now = true;
  }
  if (fin && taking) {
    t->rcv_nxt++;
    t->fin_received = true;
    t->ack_now = true;
    if (t->state == VX_TCP_ESTABLISHED) {
      t->state = VX_TCP_CLOSE_WAIT;
    } else if (t->state == VX_TCP_FIN_WAIT_1) {
      t->state = VX_TCP_CLOSING; // both FINs crossed; ours is not yet acknowledged
    } else {
      t->state = VX_TCP_TIME_WAIT;
      t->linger_at = now + TCP_TIME_WAIT;
    }
  }
  tcp_output(n, c, now);
}

static void net_tcp_input(vx_net *n, uint32_t src, uint32_t dst, const uint8_t *s, size_t len,
                          vx_instant now) {
  if (len < 20 || net_fold(net_sum(net_pseudo(src, dst, 6, (uint32_t)len), s, len)) != 0) {
    n->stats.bad++;
    return;
  }
  uint32_t hlen = (uint32_t)(s[12] >> 4) * 4;
  if (hlen < 20 || hlen > len) {
    n->stats.bad++;
    return;
  }
  if (!net_loopback(dst) && (!n->addr || dst != n->addr)) return; // no broadcast TCP
  uint16_t sport = net_get16(s), dport = net_get16(s + 2), window = net_get16(s + 14);
  uint32_t seq = net_get32(s + 4), ack = net_get32(s + 8);
  uint8_t flags = s[13] & 0x3f;
  const uint8_t *data = s + hlen;
  uint32_t dlen = (uint32_t)len - hlen;
  uint32_t seglen = dlen + !!(flags & TCP_SYN) + !!(flags & TCP_FIN);

  vx_net_conv *listener = nullptr;
  uint32_t listener_id = 0;
  for (uint32_t i = 0; i < VX_NET_CONVS; i++) {
    vx_net_conv *c = &n->conv[i];
    if (c->proto != VX_NET_TCP || c->lport != dport) continue;
    if (c->tcb.state == VX_TCP_LISTEN) {
      listener = c, listener_id = i;
    } else if (c->tcb.state != VX_TCP_CLOSED && c->raddr == src && c->rport == sport) {
      tcp_segment(n, c, seq, ack, flags, window, s + 20, hlen - 20, data, dlen, now);
      return;
    }
  }
  if (!listener) {
    tcp_reset_reply(n, src, sport, dport, seq, ack, flags, seglen, now);
    return;
  }
  // A listener's: only a SYN makes anything (RFC 9293 §3.10.7.2).
  if (flags & TCP_RST) return;
  if (flags & TCP_ACK) {
    tcp_reset_reply(n, src, sport, dport, seq, ack, flags, seglen, now);
    return;
  }
  if (!(flags & TCP_SYN)) return;
  uint32_t waiting = 0;
  for (uint32_t i = 0; i < VX_NET_CONVS; i++)
    if (n->conv[i].proto == VX_NET_TCP && n->conv[i].tcb.parent == listener_id + 1 &&
        !n->conv[i].tcb.accepted)
      waiting++;
  uint32_t id;
  if (waiting >= TCP_BACKLOG || vx_net_conv_new(n, VX_NET_TCP, &id) != VX_OK) {
    n->stats.dropped++; // the backlog is full: the peer will try again
    return;
  }
  vx_net_conv *c = &n->conv[id];
  vx_net_tcb *t = &c->tcb;
  c->lport = dport, c->raddr = src, c->rport = sport;
  tcp_start(n, t);
  t->parent = listener_id + 1;
  t->state = VX_TCP_SYN_RCVD;
  t->irs = seq;
  t->rcv_nxt = seq + 1;
  t->snd_wnd = window;
  t->snd_wl1 = seq;
  tcp_syn_options(n, t, s + 20, hlen - 20);
  tcp_send(n, c, t->iss, TCP_SYN, 0, 0, now);
  t->snd_nxt = t->snd_max = t->iss + 1;
  tcp_arm(t, now);
}

// The connection's timers: retransmission, zero-window probes, TIME_WAIT.
// Returns the next deadline.
static vx_instant net_tcp_poll(vx_net *n, vx_net_conv *c, vx_instant now) {
  vx_net_tcb *t = &c->tcb;
  if (t->state == VX_TCP_CLOSED || t->state == VX_TCP_LISTEN) return NET_NEVER; // no timers run
  if (t->linger_at <= now) {
    tcp_closed(c, t->state == VX_TCP_TIME_WAIT ? VX_OK : VX_ERR_TIMED_OUT);
    return NET_NEVER;
  }
  if (t->rto_at <= now) {
    bool syn = t->state == VX_TCP_SYN_SENT || t->state == VX_TCP_SYN_RCVD;
    if (++t->retries > (syn ? TCP_SYN_RETRIES : TCP_RETRIES)) {
      if (!syn)
        tcp_emit(n, c->raddr, c->lport, c->rport, t->snd_nxt, 0, TCP_RST, 0, nullptr, 0, nullptr, 0, 0, now);
      tcp_closed(c, VX_ERR_TIMED_OUT);
      return NET_NEVER;
    }
    t->timing = false;
    t->rto = t->rto * 2 > TCP_RTO_MAX ? TCP_RTO_MAX : t->rto * 2;
    uint32_t flight = t->snd_max - t->snd_una;
    t->ssthresh = flight / 2 > 2u * t->mss ? flight / 2 : 2u * t->mss;
    t->cwnd = t->mss; // one segment, and slow start again
    t->in_recovery = false;
    t->dupacks = 0;
    t->recover = t->snd_max;
    t->rto_at = now + t->rto;
    if (syn) {
      tcp_send(n, c, t->iss, TCP_SYN, 0, 0, now);
    } else {
      t->snd_nxt = t->snd_una; // go back: send it all again, as the window allows
      tcp_output(n, c, now);
    }
  }
  if (t->persist_at <= now) { // one byte past the window, without counting it sent
    uint32_t end = tcp_end(t);
    if (!t->snd_wnd && seq_lt(t->snd_nxt, end)) {
      tcp_send(n, c, t->snd_nxt, 0, t->snd_nxt - t->sbuf_seq, 1, now);
      if (seq_lt(t->snd_max, t->snd_nxt + 1)) t->snd_max = t->snd_nxt + 1;
      if (t->persist_shift < 8) t->persist_shift++;
      t->persist_at =
          now + ((t->rto << t->persist_shift) > TCP_RTO_MAX ? TCP_RTO_MAX : t->rto << t->persist_shift);
    } else {
      t->persist_at = NET_NEVER;
    }
  }
  vx_instant next = t->rto_at < t->persist_at ? t->rto_at : t->persist_at;
  return t->linger_at < next ? t->linger_at : next;
}

// --- What an application does with a connection ---

// Connects: a SYN to addr!port, from a free local port. The connection is
// made when its state is Established; or, Closed, it failed (tcb.error).
[[maybe_unused]] static vx_status vx_net_tcp_connect(vx_net *n, vx_net_conv *c, uint32_t addr, uint16_t port,
                                                     vx_instant now) {
  if (c->proto != VX_NET_TCP || c->raddr || c->tcb.state != VX_TCP_CLOSED || !addr || !port)
    return VX_ERR_INVALID;
  if (!net_can_send(n, addr)) return VX_ERR_BAD_STATE;
  if (!c->lport) {
    vx_status st = vx_net_conv_announce(n, c, 0);
    if (st != VX_OK) return st;
  }
  c->raddr = addr, c->rport = port;
  vx_net_tcb *t = &c->tcb;
  tcp_start(n, t);
  t->state = VX_TCP_SYN_SENT;
  t->timing = true;
  t->rtt_start = now;
  tcp_send(n, c, t->iss, TCP_SYN, 0, 0, now);
  t->snd_max = t->iss + 1; // the SYN is sent: its ACK is acceptable
  tcp_arm(t, now);
  return VX_OK;
}

// Listens on a port (0: a free one): SYNs that come to it make connections,
// for vx_net_tcp_accept to take.
[[maybe_unused]] static vx_status vx_net_tcp_listen(vx_net *n, vx_net_conv *c, uint16_t port) {
  if (c->proto != VX_NET_TCP || c->raddr || c->tcb.state != VX_TCP_CLOSED) return VX_ERR_INVALID;
  vx_status st = vx_net_conv_announce(n, c, port);
  if (st == VX_OK) c->tcb.state = VX_TCP_LISTEN;
  return st;
}

// Takes a connection the listener has made, its number in *id: SHOULD_WAIT
// if none has been made yet.
[[maybe_unused]] static vx_status vx_net_tcp_accept(vx_net *n, vx_net_conv *l, uint32_t *id) {
  if (l->proto != VX_NET_TCP || l->tcb.state != VX_TCP_LISTEN) return VX_ERR_BAD_STATE;
  uint32_t lid = (uint32_t)(l - n->conv);
  for (uint32_t i = 0; i < VX_NET_CONVS; i++) {
    vx_net_tcb *t = &n->conv[i].tcb;
    if (n->conv[i].proto != VX_NET_TCP || t->parent != lid + 1 || t->accepted) continue;
    if (t->state == VX_TCP_SYN_RCVD) continue; // not made yet
    t->accepted = true;
    *id = i;
    return VX_OK;
  }
  return VX_ERR_SHOULD_WAIT;
}

// Reads what has arrived, in order: *got bytes, 0 at the end of the stream.
// SHOULD_WAIT: nothing yet. An error: the connection failed.
[[maybe_unused]] static vx_status vx_net_tcp_read(vx_net *n, vx_net_conv *c, uint8_t *buf, size_t cap,
                                                  size_t *got, vx_instant now) {
  vx_net_tcb *t = &c->tcb;
  *got = 0;
  if (!t->rlen) {
    if (t->fin_received) return VX_OK;
    if (t->state == VX_TCP_CLOSED) return t->error != VX_OK ? t->error : VX_OK;
    return VX_ERR_SHOULD_WAIT;
  }
  uint32_t before = tcp_window(t);
  uint32_t take = tcp_min(t->rlen, (uint32_t)(cap < VX_TCP_BUF ? cap : VX_TCP_BUF));
  uint32_t first = tcp_min(take, VX_TCP_BUF - t->rhead);
  memcpy(buf, t->rbuf + t->rhead, first);
  memcpy(buf + first, t->rbuf, take - first);
  t->rhead = (t->rhead + take) % VX_TCP_BUF;
  t->rlen -= take;
  *got = take;
  // Tell the peer the window opened, once it is worth a segment: from under
  // an MSS, or by half the ring (RFC 9293 §3.8.6.2.2's receiver side).
  uint32_t after = tcp_window(t);
  if ((before < t->mss && after >= t->mss) || after - before >= VX_TCP_BUF / 2) {
    t->ack_now = true;
    tcp_output(n, c, now);
  }
  return VX_OK;
}

// Writes into the send ring, as much as fits: *taken bytes. SHOULD_WAIT if
// none fits. Data written before the connection is made goes once it is.
[[maybe_unused]] static vx_status vx_net_tcp_write(vx_net *n, vx_net_conv *c, const uint8_t *data, size_t len,
                                                   size_t *taken, vx_instant now) {
  vx_net_tcb *t = &c->tcb;
  *taken = 0;
  bool open = t->state == VX_TCP_SYN_SENT || t->state == VX_TCP_SYN_RCVD || t->state == VX_TCP_ESTABLISHED ||
              t->state == VX_TCP_CLOSE_WAIT;
  if (!open || t->fin_queued) return t->error != VX_OK ? t->error : VX_ERR_PEER_CLOSED;
  uint32_t room = VX_TCP_BUF - t->slen, take = tcp_min(room, (uint32_t)(len < VX_TCP_BUF ? len : VX_TCP_BUF));
  if (!take) return len ? VX_ERR_SHOULD_WAIT : VX_OK;
  uint32_t at = (t->shead + t->slen) % VX_TCP_BUF, first = tcp_min(take, VX_TCP_BUF - at);
  memcpy(t->sbuf + at, data, first);
  memcpy(t->sbuf, data + first, take - first);
  t->slen += take;
  *taken = take;
  tcp_output(n, c, now);
  return VX_OK;
}

// Closes our side: a FIN once the data written has gone. Reading goes on.
[[maybe_unused]] static void vx_net_tcp_close(vx_net *n, vx_net_conv *c, vx_instant now) {
  vx_net_tcb *t = &c->tcb;
  if (t->state == VX_TCP_LISTEN || t->state == VX_TCP_SYN_SENT) {
    tcp_closed(c, VX_OK);
    return;
  }
  if (t->fin_queued || t->state == VX_TCP_CLOSED) return;
  t->fin_queued = true;
  tcp_output(n, c, now);
}

// The application let go of a connection. A listener's waiting connections
// are reset; a connection with data never read is reset (RFC 2525 §2.17);
// any other is closed as usual, and goes once it is.
static void net_tcp_free(vx_net *n, vx_net_conv *c, vx_instant now) {
  vx_net_tcb *t = &c->tcb;
  uint32_t id = (uint32_t)(c - n->conv);
  if (t->state == VX_TCP_LISTEN) {
    for (uint32_t i = 0; i < VX_NET_CONVS; i++) {
      vx_net_conv *w = &n->conv[i];
      if (w->proto != VX_NET_TCP || w->tcb.parent != id + 1 || w->tcb.accepted) continue;
      if (w->tcb.state != VX_TCP_CLOSED)
        tcp_emit(n, w->raddr, w->lport, w->rport, w->tcb.snd_nxt, 0, TCP_RST, 0, nullptr, 0, nullptr, 0, 0,
                 now);
      w->proto = 0;
    }
  }
  t->orphan = true;
  bool synced = t->state != VX_TCP_CLOSED && t->state != VX_TCP_LISTEN && t->state != VX_TCP_SYN_SENT;
  if (synced && (t->rlen || t->state == VX_TCP_SYN_RCVD)) {
    tcp_emit(n, c->raddr, c->lport, c->rport, t->snd_nxt, 0, TCP_RST, 0, nullptr, 0, nullptr, 0, 0, now);
    tcp_closed(c, VX_OK);
  } else if (synced) {
    vx_net_tcp_close(n, c, now);
    if (t->state == VX_TCP_FIN_WAIT_2) t->linger_at = now + TCP_ORPHAN_FIN_WAIT_2;
  } else {
    c->proto = 0;
  }
}
