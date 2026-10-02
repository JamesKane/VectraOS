// tcp_test.c: lib/vx-net's TCP between two whole stacks, a client (10.0.2.15)
// and a server (10.0.2.2), joined by a simulated wire that can lose frames.
// Time is the test's: when nothing is moving, it jumps to the next deadline
// either stack asked for. Hand-built segments check what a hostile peer
// cannot do: reset a connection with a guessed sequence number.

#include <string.h>

#include "check.h"
#include "../../lib/vx-net/net.c"

static const uint8_t C_MAC[6] = {0x52, 0x54, 0, 0x12, 0x34, 0x56}, S_MAC[6] = {0x52, 0x55, 10, 0, 2, 2};
static constexpr uint32_t C_IP = 0x0a00'020f, S_IP = 0x0a00'0202;

static vx_net client, server;
static vx_instant now;

// --- The wire: a queue of frames each way ---

typedef struct wire {
  uint8_t frames[1024][VX_ETHER_MAX_FRAME];
  size_t len[1024];
  uint32_t head, count;
} wire;

static wire to_server, to_client;
static uint64_t sent_frames;
static bool (*lose)(const uint8_t *frame, size_t len); // nullptr: nothing is lost

static void put_frame(void *ctx, const uint8_t *frame, size_t len) {
  wire *w = ctx;
  sent_frames++;
  if (w->count == 1024) return; // a full queue drops, as a switch would
  uint32_t at = (w->head + w->count++) % 1024;
  memcpy(w->frames[at], frame, len);
  w->len[at] = len;
}

// Delivers frames until both queues are empty.
static void settle(void) {
  static uint8_t f[VX_ETHER_MAX_FRAME];
  for (int rounds = 0; (to_server.count || to_client.count) && rounds < 100000; rounds++) {
    wire *w = to_server.count ? &to_server : &to_client;
    vx_net *to = w == &to_server ? &server : &client;
    size_t len = w->len[w->head];
    memcpy(f, w->frames[w->head], len);
    w->head = (w->head + 1) % 1024;
    w->count--;
    if (!lose || !lose(f, len)) vx_net_input(to, f, len, now);
  }
}

// Time jumps to the next deadline, and the timers run.
static void advance(void) {
  vx_instant a = vx_net_poll(&client, now), b = vx_net_poll(&server, now);
  vx_instant next = a < b ? a : b;
  if (next != NET_NEVER && next > now) now = next;
  vx_net_poll(&client, now);
  vx_net_poll(&server, now);
  settle();
}

static void setup(void) {
  now = 1000 * NET_SECOND;
  lose = nullptr;
  to_server = to_client = (wire){};
  vx_net_init(&client, C_MAC, 1500, 11, put_frame, &to_server);
  vx_net_init(&server, S_MAC, 1500, 22, put_frame, &to_client);
  vx_net_set_addr(&client, C_IP, 0xffff'ff00, S_IP);
  vx_net_set_addr(&server, S_IP, 0xffff'ff00, 0);
}

static vx_net_conv *conv(vx_net *n, uint32_t *id) {
  uint32_t i = 0;
  CHECK(vx_net_conv_new(n, VX_NET_TCP, &i) == VX_OK);
  if (id) *id = i;
  return &n->conv[i];
}

// A listener on the server, a connection to it from the client, and the
// server's side of it, accepted.
static vx_net_conv *connected(vx_net_conv **cc, uint32_t *listener) {
  vx_net_conv *l = conv(&server, listener);
  CHECK(vx_net_tcp_listen(&server, l, 7777) == VX_OK && l->tcb.state == VX_TCP_LISTEN);
  vx_net_conv *c = conv(&client, nullptr);
  CHECK(vx_net_tcp_connect(&client, c, S_IP, 7777, now) == VX_OK && c->tcb.state == VX_TCP_SYN_SENT);
  settle(); // ARP first; the SYN waited for it
  CHECK(c->tcb.state == VX_TCP_ESTABLISHED);
  uint32_t sid = 0;
  CHECK(vx_net_tcp_accept(&server, l, &sid) == VX_OK);
  vx_net_conv *s = &server.conv[sid];
  CHECK(s->tcb.state == VX_TCP_ESTABLISHED && s->raddr == C_IP && s->rport == c->lport && s->lport == 7777);
  CHECK(vx_net_tcp_accept(&server, l, &sid) == VX_ERR_SHOULD_WAIT); // one call, taken once
  *cc = c;
  return s;
}

// Sends `total` bytes of a pattern from a to b, reading as it goes; true if
// all of it arrived, in order, within the time allowed.
static bool transfer(vx_net *na, vx_net_conv *a, vx_net *nb, vx_net_conv *b, size_t total, bool *recovered) {
  static uint8_t buf[8192];
  size_t sent = 0, got = 0;
  vx_instant give_up = now + 600 * NET_SECOND;
  for (int rounds = 0; got < total && now < give_up && rounds < 100000;
       rounds++) { // bounded: time may stand still
    while (sent < total) {
      for (size_t i = 0; i < sizeof buf; i++) buf[i] = (uint8_t)((sent + i) * 7 + 3);
      size_t chunk = total - sent < sizeof buf ? total - sent : sizeof buf, taken = 0;
      if (vx_net_tcp_write(na, a, buf, chunk, &taken, now) != VX_OK || !taken) break;
      sent += taken;
    }
    uint64_t before = sent_frames;
    settle();
    if (recovered && a->tcb.in_recovery) *recovered = true;
    for (size_t n = 0; vx_net_tcp_read(nb, b, buf, sizeof buf, &n, now) == VX_OK && n;) {
      for (size_t i = 0; i < n; i++)
        if (buf[i] != (uint8_t)((got + i) * 7 + 3)) return false;
      got += n;
    }
    settle();
    if (sent_frames == before) advance(); // nothing moved: a timer must
  }
  return got == total;
}

static void test_handshake_and_data(void) {
  setup();
  vx_net_conv *c;
  uint32_t lid;
  vx_net_conv *s = connected(&c, &lid);
  CHECK(c->tcb.snd_shift == 0 && s->tcb.snd_shift == 0); // both offered window scaling
  CHECK(c->tcb.mss == 1460 && s->tcb.mss == 1460);
  size_t n = 0;
  uint8_t buf[64];
  CHECK(vx_net_tcp_read(&server, s, buf, sizeof buf, &n, now) == VX_ERR_SHOULD_WAIT);
  CHECK(vx_net_tcp_write(&client, c, (const uint8_t *)"hello", 5, &n, now) == VX_OK && n == 5);
  settle();
  CHECK(vx_net_tcp_read(&server, s, buf, sizeof buf, &n, now) == VX_OK && n == 5 &&
        memcmp(buf, "hello", 5) == 0);
  CHECK(vx_net_tcp_write(&server, s, (const uint8_t *)"world", 5, &n, now) == VX_OK);
  settle();
  CHECK(vx_net_tcp_read(&client, c, buf, sizeof buf, &n, now) == VX_OK && n == 5 &&
        memcmp(buf, "world", 5) == 0);
  CHECK(c->tcb.slen == 0 && s->tcb.slen == 0); // all acknowledged
  CHECK(c->tcb.measured && s->tcb.measured);   // RTTs were measured (0 ns, in this test's time)

  // A megabyte each way, nothing lost: no retransmission at all.
  uint64_t before = sent_frames;
  CHECK(transfer(&client, c, &server, s, 1 << 20, nullptr));
  CHECK(transfer(&server, s, &client, c, 1 << 20, nullptr));
  CHECK(c->tcb.retries == 0 && s->tcb.retries == 0 && !c->tcb.in_recovery);
  CHECK(sent_frames - before < 2 * (2 << 20) / 1460 + 200); // data segments and their ACKs, about

  // Close: the client's FIN, end of file at the server; the server's FIN,
  // and the client waits in TIME_WAIT, then is closed.
  vx_net_tcp_close(&client, c, now);
  settle();
  CHECK(c->tcb.state == VX_TCP_FIN_WAIT_2 && s->tcb.state == VX_TCP_CLOSE_WAIT);
  CHECK(vx_net_tcp_read(&server, s, buf, sizeof buf, &n, now) == VX_OK && n == 0);   // end of file
  CHECK(vx_net_tcp_write(&client, c, (const uint8_t *)"x", 1, &n, now) != VX_OK);    // our side is closed
  CHECK(vx_net_tcp_write(&server, s, (const uint8_t *)"late", 4, &n, now) == VX_OK); // theirs is not
  vx_net_tcp_close(&server, s, now);
  settle();
  CHECK(vx_net_tcp_read(&client, c, buf, sizeof buf, &n, now) == VX_OK && n == 4);
  CHECK(c->tcb.state == VX_TCP_TIME_WAIT && s->tcb.state == VX_TCP_CLOSED && s->tcb.error == VX_OK);
  advance();
  CHECK(c->tcb.state == VX_TCP_CLOSED && c->tcb.error == VX_OK);
}

static uint32_t loss_count, loss_every;
static bool lose_some_data(const uint8_t *f, size_t len) {
  // Lose every Nth frame from the client that carries TCP data.
  bool data = net_get16(f + 12) == 0x0800 && f[23] == 6 && len > 54 && net_get32(f + 26) == C_IP &&
              net_get16(f + 16) > 40 + (uint32_t)((f[46] >> 4) * 4 - 20);
  return data && ++loss_count % loss_every == 0;
}

static void test_loss(void) {
  setup();
  vx_net_conv *c;
  uint32_t lid;
  vx_net_conv *s = connected(&c, &lid);
  // One in 50 data segments lost: NewReno's fast retransmit and recovery
  // repair each, and the stream arrives whole.
  lose = lose_some_data;
  loss_count = 0, loss_every = 50;
  bool recovered = false;
  CHECK(transfer(&client, c, &server, s, 2 << 20, &recovered));
  CHECK(recovered && loss_count > 20);
  CHECK(c->tcb.cwnd >= c->tcb.mss && c->tcb.ssthresh < UINT32_MAX); // it reacted to the loss

  // Heavy loss: one in 3. Timeouts and go-back repair what fast retransmit cannot.
  loss_count = 0, loss_every = 3;
  CHECK(transfer(&client, c, &server, s, 200'000, nullptr));
  lose = nullptr;
}

static bool lose_everything(const uint8_t *f, size_t len) {
  (void)f, (void)len;
  return true;
}

static void test_refused_and_timeout(void) {
  setup();
  // Nothing listens on 9999: the server resets the SYN, and the connect fails.
  vx_net_conv *c = conv(&client, nullptr);
  CHECK(vx_net_tcp_connect(&client, c, S_IP, 9999, now) == VX_OK);
  settle();
  CHECK(c->tcb.state == VX_TCP_CLOSED && c->tcb.error == VX_ERR_REFUSED);
  size_t n;
  uint8_t buf[8];
  CHECK(vx_net_tcp_read(&client, c, buf, sizeof buf, &n, now) == VX_ERR_REFUSED);

  // Nobody answers at all: SYNs again, backing off, then TIMED_OUT.
  vx_net_conv *d = conv(&client, nullptr);
  lose = lose_everything;
  CHECK(vx_net_tcp_connect(&client, d, S_IP, 7777, now) == VX_OK);
  vx_instant start = now;
  for (int i = 0; i < 50 && d->tcb.state != VX_TCP_CLOSED; i++) advance();
  CHECK(d->tcb.state == VX_TCP_CLOSED && d->tcb.error == VX_ERR_TIMED_OUT);
  CHECK(now - start > 60 * NET_SECOND); // 1 + 2 + 4 + ... seconds of trying
  lose = nullptr;
}

static void test_zero_window(void) {
  setup();
  vx_net_conv *c;
  uint32_t lid;
  vx_net_conv *s = connected(&c, &lid);
  // The server reads nothing: its window closes, the client's ring fills,
  // and the client probes the closed window, backing off.
  static uint8_t buf[VX_TCP_BUF];
  size_t n, total = 0;
  for (int i = 0; i < 4; i++) {
    if (vx_net_tcp_write(&client, c, buf, sizeof buf, &n, now) == VX_OK) total += n;
    settle();
  }
  CHECK(s->tcb.rlen == VX_TCP_BUF && c->tcb.snd_wnd == 0 && total == (size_t)2 * VX_TCP_BUF);
  CHECK(vx_net_tcp_write(&client, c, buf, 1, &n, now) == VX_ERR_SHOULD_WAIT); // the ring is full
  for (int i = 0; i < 5; i++) advance();
  CHECK(c->tcb.persist_shift >= 3 && c->tcb.state == VX_TCP_ESTABLISHED); // probing, not giving up
  // The server reads: the window opens, its update gets through, and the rest flows.
  size_t got = 0;
  for (int i = 0; i < 100 && got < total; i++) {
    while (vx_net_tcp_read(&server, s, buf, sizeof buf, &n, now) == VX_OK && n) got += n;
    settle();
    advance();
  }
  CHECK(got == total && c->tcb.slen == 0);
}

// A segment from the server's address and port to the client's connection.
static void inject(const vx_net_conv *c, uint32_t seq, uint32_t ack, uint8_t flags) {
  static uint8_t f[54];
  memcpy(f, C_MAC, 6);
  memcpy(f + 6, S_MAC, 6);
  net_put16(f + 12, 0x0800);
  uint8_t *ip = f + 14, *t = f + 34;
  memset(ip, 0, 40);
  ip[0] = 0x45, ip[8] = 64, ip[9] = 6;
  net_put16(ip + 2, 40);
  net_put32(ip + 12, S_IP);
  net_put32(ip + 16, C_IP);
  net_put16(ip + 10, net_fold(net_sum(0, ip, 20)));
  net_put16(t, c->rport);
  net_put16(t + 2, c->lport);
  net_put32(t + 4, seq);
  net_put32(t + 8, ack);
  t[12] = 5 << 4, t[13] = flags;
  net_put16(t + 14, 1000);
  net_put16(t + 16, net_fold(net_sum(net_pseudo(S_IP, C_IP, 6, 20), t, 20)));
  vx_net_input(&client, f, sizeof f, now);
}

static void test_hostile_segments(void) {
  setup();
  vx_net_conv *c;
  uint32_t lid;
  vx_net_conv *s = connected(&c, &lid);
  // A reset whose sequence number is in the window but not the next one gets
  // a challenge ACK, not a reset (RFC 5961); one outside the window, nothing.
  to_server = (wire){};
  inject(c, c->tcb.rcv_nxt + 100, 0, TCP_RST);
  CHECK(c->tcb.state == VX_TCP_ESTABLISHED && to_server.count == 1);
  inject(c, c->tcb.rcv_nxt + 200'000, 0, TCP_RST);
  CHECK(c->tcb.state == VX_TCP_ESTABLISHED);
  // A SYN on an open connection: a challenge ACK too.
  inject(c, c->tcb.rcv_nxt, 0, TCP_SYN);
  CHECK(c->tcb.state == VX_TCP_ESTABLISHED);
  // An ACK for data never sent changes nothing.
  inject(c, c->tcb.rcv_nxt, c->tcb.snd_max + 5000, TCP_ACK);
  CHECK(c->tcb.state == VX_TCP_ESTABLISHED && c->tcb.snd_una == c->tcb.snd_max);
  settle();
  // The exact next sequence number resets it.
  inject(c, c->tcb.rcv_nxt, 0, TCP_RST);
  CHECK(c->tcb.state == VX_TCP_CLOSED && c->tcb.error == VX_ERR_PEER_CLOSED);
  (void)s, (void)lid;
}

static void test_backlog_and_orphans(void) {
  setup();
  uint32_t lid;
  vx_net_conv *l = conv(&server, &lid);
  CHECK(vx_net_tcp_listen(&server, l, 80) == VX_OK);
  vx_net_conv *cs[6];
  for (int i = 0; i < 6; i++) {
    cs[i] = conv(&client, nullptr);
    CHECK(vx_net_tcp_connect(&client, cs[i], S_IP, 80, now) == VX_OK);
    if (i == 0) settle(); // ARP first: a lookup holds one packet, so the SYNs would replace each other
  }
  settle();
  int up = 0;
  for (int i = 0; i < 6; i++) up += cs[i]->tcb.state == VX_TCP_ESTABLISHED;
  CHECK(up == 4); // the backlog; the others' SYNs were dropped, to be sent again
  uint32_t ids[6];
  int taken = 0;
  while (vx_net_tcp_accept(&server, l, &ids[taken]) == VX_OK) taken++;
  CHECK(taken == 4);
  for (int i = 0; i < 10; i++) advance(); // the others try again, and get in
  up = 0;
  for (int i = 0; i < 6; i++) up += cs[i]->tcb.state == VX_TCP_ESTABLISHED;
  CHECK(up == 6);

  // The listener goes: the connections it made that nobody took are reset.
  vx_net_conv_free(&server, lid, now);
  settle();
  int reset = 0;
  for (int i = 0; i < 6; i++)
    reset += cs[i]->tcb.state == VX_TCP_CLOSED && cs[i]->tcb.error == VX_ERR_PEER_CLOSED;
  CHECK(reset == 2 && server.conv[lid].proto == 0);

  // An orphan with unread data is reset; one without closes with a FIN and is freed once closed.
  size_t n;
  vx_net_conv *s0 = &server.conv[ids[0]], *s1 = &server.conv[ids[1]];
  vx_net_conv *c0 = nullptr, *c1 = nullptr;
  for (int i = 0; i < 6; i++) {
    if (cs[i]->lport == s0->rport) c0 = cs[i];
    if (cs[i]->lport == s1->rport) c1 = cs[i];
  }
  CHECK(c0 && c1);
  if (!c0 || !c1) return;
  CHECK(vx_net_tcp_write(&client, c0, (const uint8_t *)"unread", 6, &n, now) == VX_OK);
  settle();
  vx_net_conv_free(&server, ids[0], now);
  settle();
  CHECK(c0->tcb.state == VX_TCP_CLOSED && c0->tcb.error == VX_ERR_PEER_CLOSED && s0->proto == 0);
  vx_net_conv_free(&server, ids[1], now);
  settle();
  CHECK(c1->tcb.state == VX_TCP_CLOSE_WAIT && s1->proto == VX_NET_TCP); // still closing
  vx_net_tcp_close(&client, c1, now);
  settle();
  // The orphan closed first, so it waits out TIME_WAIT, and then it goes.
  CHECK(c1->tcb.state == VX_TCP_CLOSED && s1->tcb.state == VX_TCP_TIME_WAIT);
  advance();
  CHECK(s1->proto == 0);
}

// Loopback: one stack talks to itself, on 127.0.0.1 and on its own address,
// with nothing on the wire; a forged 127/8 packet from the wire is dropped.
static void loop_settle(vx_net *n) {
  for (int i = 0; i < 1000 && n->loop_used; i++) vx_net_poll(n, now);
}

static void test_loopback(void) {
  setup();
  uint64_t wire_before = sent_frames;
  static const uint32_t addrs[2] = {0x7f00'0001, C_IP};
  for (int a = 0; a < 2; a++) {
    uint32_t lid, sid = 0;
    vx_net_conv *l = conv(&client, &lid), *c = conv(&client, nullptr);
    CHECK(vx_net_tcp_listen(&client, l, (uint16_t)(7000 + a)) == VX_OK);
    CHECK(vx_net_tcp_connect(&client, c, addrs[a], (uint16_t)(7000 + a), now) == VX_OK);
    loop_settle(&client);
    CHECK(c->tcb.state == VX_TCP_ESTABLISHED && vx_net_tcp_accept(&client, l, &sid) == VX_OK);
    vx_net_conv *s = &client.conv[sid];
    CHECK(s->raddr == addrs[a] && s->rport == c->lport);
    size_t n = 0;
    static uint8_t big[20000], got[20000];
    for (size_t i = 0; i < sizeof big; i++) big[i] = (uint8_t)(i * 7);
    size_t sent = 0, recvd = 0;
    for (int round = 0; round < 1000 && recvd < sizeof big; round++) {
      if (sent < sizeof big && vx_net_tcp_write(&client, c, big + sent, sizeof big - sent, &n, now) == VX_OK)
        sent += n;
      loop_settle(&client);
      if (vx_net_tcp_read(&client, s, got + recvd, sizeof got - recvd, &n, now) == VX_OK) recvd += n;
    }
    CHECK(recvd == sizeof big && memcmp(big, got, sizeof big) == 0);
    vx_net_conv_free(&client, lid, now);
    vx_net_tcp_close(&client, c, now);
    vx_net_tcp_close(&client, s, now);
    loop_settle(&client);
    CHECK(c->tcb.state == VX_TCP_CLOSED || c->tcb.state == VX_TCP_TIME_WAIT);
  }
  // UDP over loopback.
  uint32_t uid;
  CHECK(vx_net_conv_new(&client, VX_NET_UDP, &uid) == VX_OK);
  vx_net_conv *u = &client.conv[uid];
  CHECK(vx_net_conv_announce(&client, u, 9000) == VX_OK);
  CHECK(vx_net_conv_write(&client, u, 0x7f00'0001, 9000, (const uint8_t *)"ping", 4, now) == VX_OK);
  loop_settle(&client);
  vx_net_datagram d;
  uint8_t buf[16];
  size_t n = 0;
  CHECK(vx_net_conv_read(u, &d, buf, sizeof buf, &n) && n == 4 && d.addr == 0x7f00'0001 && d.port == 9000);
  CHECK(sent_frames == wire_before); // nothing went out

  // The same datagram, from the wire: dropped, as a forgery.
  uint8_t f[60] = {};
  memcpy(f, C_MAC, 6), memcpy(f + 6, S_MAC, 6), f[12] = 8;
  uint8_t *ip = f + 14;
  ip[0] = 0x45, ip[2] = 0, ip[3] = 32, ip[8] = 64, ip[9] = 17;
  net_put32(ip + 12, 0x7f00'0001), net_put32(ip + 16, 0x7f00'0001);
  net_put16(ip + 10, net_fold(net_sum(0, ip, 20)));
  net_put16(ip + 20, 9000), net_put16(ip + 22, 9000), net_put16(ip + 24, 12);
  memcpy(ip + 28, "evil", 4);
  uint64_t bad = client.stats.bad;
  vx_net_input(&client, f, sizeof f, now);
  CHECK(client.stats.bad == bad + 1 && !vx_net_conv_read(u, &d, buf, sizeof buf, &n));
}

int main(void) {
  test_handshake_and_data();
  test_loopback();
  test_loss();
  test_refused_and_timeout();
  test_zero_window();
  test_hostile_segments();
  test_backlog_and_orphans();
  return check_result();
}
