// netd: the network service (docs/00 §3, 02 §5, 04 §5 M3). It runs vx-net
// over the network driver's frames (/srv/ether0, the net class protocol in
// lib/vx-driver/netproto.h) and serves /net, posted as /srv/net, in Plan 9's
// layout:
//
//   /net/ipifc/0/status     dev=ether0 addr=10.0.2.15/24 gw=10.0.2.2 dhcp lease=86400s
//   /net/ipifc/0/ctl        write "add 10.0.2.15/24 [10.0.2.2]" (a static address) or "dhcp"
//   /net/icmp, /net/udp, /net/tcp    conversations:
//     clone                 opening it makes conversation N, and the fid becomes N/ctl
//     N/ctl                 read: N; write "connect ADDR[!PORT]", "announce PORT", "hangup";
//                           a TCP connect returns once the connection is made, or refused
//     N/data                a datagram a read (waiting for one), a datagram a write;
//                           ICMP: whole messages, the identifier and checksum filled in
//     N/local, N/remote     ADDR!PORT
//     N/status              Open, Announced or Closed; TCP's state, as Plan 9 names it
//     N/listen              TCP, announced: opening it waits for a call, and the fid
//                           becomes the new connection's ctl
//   TCP's data is a stream: a read returns what has arrived (0 at the end), a
//   write takes what fits, and waits only if nothing fits.
//
// A conversation lasts while any of its files is open. /net is served from
// the start, with or without a driver, since every namespace that mounts it
// connects when its program starts; netd dials the driver without waiting,
// and again if the driver goes. The address comes from DHCP.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-ring/session.c"
#include "../../lib/vx-driver/netproto.h"
#include "../../lib/vx-net/net.c"

// --- Text, for the files that are read ---

typedef struct text {
  char buf[256];
  size_t len;
} text;

static void put(text *t, vx_str s) {
  for (size_t i = 0; i < s.len && t->len < sizeof t->buf; i++) t->buf[t->len++] = s.ptr[i];
}

static void put_u64(text *t, uint64_t v) {
  char digits[20];
  size_t n = sizeof digits;
  do digits[--n] = (char)('0' + v % 10);
  while (v /= 10);
  put(t, (vx_str){digits + n, sizeof digits - n});
}

static void put_ip(text *t, uint32_t ip) {
  char buf[16];
  put(t, (vx_str){buf, vx_net_format_ip(ip, buf)});
}

static vx_net stack;
static bool stack_up; // vx_net_init done: the driver said its MAC address
static p9_ring_server server;

// --- The driver ---

enum : uint64_t { KEY_ANSWER = P9_KEY_USER, KEY_BELL, KEY_GONE }; // and the link's generation above bit 8
static constexpr uint64_t TAG_TX = 1ull << 32, TAG_RX = 2ull << 32, TAG_INFO = 3ull << 32;

static struct {
  vx_handle connector;
  bool asked, answer_armed;
  vx_instant retry_at; // when to ask again; VX_INFINITE while an ask is out or the link is up
  bool up, bell_armed;
  uint32_t gen;
  vx_ring ring;
  vx_handle end;
  uint64_t tx_free; // a bit for each of the first 64 slots of our arena
} link;

static uint64_t link_key(uint64_t kind) { return kind + ((uint64_t)link.gen << 8); }

static void submit(vx_sqe e) {
  vx_sqe *slot = vx_ring_produce_slot(&link.ring);
  if (!slot) return; // cannot happen: offers and sends together never outnumber the queue
  *slot = e;
  if (vx_ring_produce(&link.ring)) vx_ring_notify(link.end);
}

// vx-net's way out: a frame into a free slot of our arena, and a TX for it.
static void send_frame(void *ctx, const uint8_t *frame, size_t len) {
  (void)ctx;
  if (!link.up || !link.ring.base || !link.tx_free || len > VX_ETHER_MAX_FRAME) {
    stack.stats.dropped++; // no driver, or every slot is in flight: as a full NIC would
    return;
  }
  uint32_t slot = (uint32_t)__builtin_ctzll(link.tx_free);
  link.tx_free &= ~(1ull << slot);
  uint64_t arena_size;
  uint8_t *arena = vx_ring_arena(&link.ring, &arena_size);
  memcpy(arena + (size_t)slot * VX_NET_SLOT, frame, len);
  submit((vx_sqe){.opcode = VX_NET_TX,
                  .flags = VX_SQE_DREF,
                  .user_data = TAG_TX | slot,
                  .arena_off = slot * VX_NET_SLOT,
                  .len = (uint32_t)len});
}

static void ask_driver(void) {
  link.asked = vx_session_ask(link.connector, VX_NET_CONNECT) == VX_OK;
  link.retry_at = link.asked ? VX_INFINITE : vx_clock_read() + 1'000'000'000;
}

static void link_down(void) {
  if (link.up) vx_print(VX_STR("netd: the driver is gone; asking again\n"));
  vx_handle_close(link.end);
  link.up = link.bell_armed = false;
  link.gen++;
  link.retry_at = vx_clock_read() + 1'000'000'000;
}

static void link_answer(void) {
  vx_status st = vx_session_answer(link.connector, &VX_NET_PARAMS, &link.ring, &link.end);
  if (st == VX_ERR_SHOULD_WAIT) return;
  link.asked = false;
  if (st != VX_OK) { // refused, or a reply that made no sense: ask again in a second
    link.retry_at = vx_clock_read() + 1'000'000'000;
    return;
  }
  link.up = true;
  link.gen++;
  link.tx_free = ~0ull;
  vx_port_bind(server.port, link.end, VX_TRIGGER_PEER_CLOSED, link_key(KEY_GONE), 0);
  submit((vx_sqe){.opcode = VX_NET_INFO, .user_data = TAG_INFO});
  for (uint32_t s = 0; s < VX_NET_SLOTS; s++)
    submit((vx_sqe){.opcode = VX_NET_RX, .user_data = TAG_RX | s, .target = s});
}

// Everything the driver has completed: frames into the stack, slots back.
// Whether there was anything.
static bool link_drain(void) {
  bool any = false;
  for (vx_cqe c; link.up && link.ring.base && vx_ring_consume(&link.ring, &c) == VX_OK;) {
    any = true;
    uint64_t tag = c.user_data & ~0xffff'ffffull;
    uint32_t slot = (uint32_t)c.user_data;
    if (tag == TAG_TX && slot < 64) {
      link.tx_free |= 1ull << slot;
    } else if (tag == TAG_RX && slot < VX_NET_SLOTS) {
      const uint8_t *frame =
          c.result > 0 ? vx_ring_peer_bytes(&link.ring, c.aux2, (uint64_t)c.result) : nullptr;
      if (frame && stack_up) vx_net_input(&stack, frame, (size_t)c.result, vx_clock_read());
      submit((vx_sqe){.opcode = VX_NET_RX, .user_data = TAG_RX | slot, .target = slot}); // offered again
    } else if (tag == TAG_INFO && c.result == 0 && !stack_up) {
      uint8_t mac[6];
      for (int i = 0; i < 6; i++) mac[i] = (uint8_t)(c.aux2 >> (8 * i));
      vx_net_init(&stack, mac, c.aux, (uint32_t)vx_clock_read() ^ (uint32_t)c.aux2, send_frame, nullptr);
      stack_up = true;
      vx_net_dhcp_start(&stack, vx_clock_read());
    }
  }
  if (link.up && link.ring.broken) link_down(); // it broke the protocol
  return any;
}

static void event(void *ctx, const vx_packet *pk) {
  (void)ctx;
  if (pk->key == KEY_ANSWER) {
    link.answer_armed = false;
    if (link.asked) link_answer();
  } else if (pk->key == link_key(KEY_GONE)) {
    if (link.up) link_down();
  } else if (pk->key == link_key(KEY_BELL)) {
    link.bell_armed = false;
  }
  // Frames are taken here, before the 9P connections are served again, so a
  // read waiting for a datagram sees what just came.
  if (link.up) {
    vx_ring_end_sleep(&link.ring);
    link_drain();
  }
}

static uint32_t last_addr;

static vx_instant tick(void *ctx) {
  (void)ctx;
  vx_instant now = vx_clock_read(), next = VX_INFINITE;
  if (!link.up && !link.asked && now >= link.retry_at) ask_driver();
  if (link.asked && !link.answer_armed)
    link.answer_armed =
        vx_port_bind(server.port, link.connector, VX_TRIGGER_READABLE, KEY_ANSWER, 0) == VX_OK;
  if (!link.up && !link.asked) next = link.retry_at;
  if (link.up) { // sleep only once the driver's queue is empty, and its doorbell armed
    // What is taken here came after the event pass: round again at once, so
    // a read held for a datagram is served again before we sleep.
    bool took = link_drain();
    int64_t seen = vx_counter_read(link.end);
    if (took || (link.up && !vx_ring_prepare_sleep(&link.ring))) {
      next = now;
    } else if (link.up && !link.bell_armed) {
      link.bell_armed = vx_port_bind(server.port, link.end, VX_TRIGGER_COUNTER_GE, link_key(KEY_BELL),
                                     (uint64_t)seen + 1) == VX_OK;
    }
  }
  if (stack_up) {
    vx_instant due = vx_net_poll(&stack, now);
    if (due < next) next = due;
    if (stack.addr != last_addr) { // say what the address became
      last_addr = stack.addr;
      text t = {};
      put(&t, VX_STR("netd: "));
      if (stack.addr) {
        put_ip(&t, stack.addr);
        put(&t, VX_STR("/"));
        put_u64(&t, (uint64_t)__builtin_popcount(stack.mask));
        put(&t, stack.dhcp.state == VX_DHCP_OFF ? VX_STR(", static") : VX_STR(" from dhcp"));
        put(&t, VX_STR(", gateway "));
        put_ip(&t, stack.gw);
      } else {
        put(&t, VX_STR("no address"));
      }
      put(&t, VX_STR("\n"));
      vx_print((vx_str){t.buf, t.len});
    }
  }
  return next;
}

// --- /net ---
//
// A node is its kind in the low byte, then the protocol, the conversation
// and that conversation's generation, so a fid on a conversation that has
// been closed and made again never reaches the new one.

enum : uint8_t {
  N_ROOT = 1,
  N_IPIFC,      // /ipifc
  N_IFC,        // /ipifc/0
  N_IFC_CTL,    // /ipifc/0/ctl
  N_IFC_STATUS, // /ipifc/0/status
  N_PROTO,      // /icmp, /udp
  N_CLONE,
  N_CONV, // /PROTO/N, and its files:
  N_CTL,
  N_DATA,
  N_LOCAL,
  N_REMOTE,
  N_STATUS,
  N_LISTEN, // TCP's only
};

static const struct {
  vx_str name;
  uint32_t mode;
} FILES[] = {
    [N_IFC_CTL] = {VX_STR("ctl"), 0666},   [N_IFC_STATUS] = {VX_STR("status"), 0444},
    [N_CLONE] = {VX_STR("clone"), 0666},   [N_CTL] = {VX_STR("ctl"), 0666},
    [N_DATA] = {VX_STR("data"), 0666},     [N_LOCAL] = {VX_STR("local"), 0444},
    [N_REMOTE] = {VX_STR("remote"), 0444}, [N_STATUS] = {VX_STR("status"), 0444},
    [N_LISTEN] = {VX_STR("listen"), 0666},
};

static uint32_t conv_gen[VX_NET_CONVS];  // bumped each time a conversation is made
static uint32_t conv_refs[VX_NET_CONVS]; // open fids on its files

static uint64_t node(uint8_t kind, uint8_t proto, uint32_t conv) {
  uint64_t gen = kind >= N_CONV ? conv_gen[conv % VX_NET_CONVS] : 0; // only a conversation's nodes go stale
  return kind | (uint64_t)proto << 8 | (uint64_t)conv << 16 | gen << 32;
}
static uint8_t kind_of(uint64_t n) { return (uint8_t)n; }
static uint8_t proto_of(uint64_t n) { return (uint8_t)(n >> 8); }
static uint32_t conv_of(uint64_t n) { return (uint32_t)(n >> 16 & 0xffff); }

// The conversation a node is in, if it is still the one the node was made for.
static vx_net_conv *conv_at(uint64_t n) {
  uint32_t id = conv_of(n);
  vx_net_conv *c = stack_up ? vx_net_conv_get(&stack, id) : nullptr;
  return c && c->proto == proto_of(n) && conv_gen[id] == (uint32_t)(n >> 32) ? c : nullptr;
}

// A conversation directory's last file: TCP's has listen too.
static uint32_t last_file(uint64_t dir) { return proto_of(dir) == VX_NET_TCP ? N_LISTEN : N_STATUS; }

static bool name_is(vx_str name, const char *s) {
  vx_str t = vx_cstr(s);
  return name.len == t.len && memcmp(name.ptr, t.ptr, t.len) == 0;
}

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = N_ROOT;
  return VX_OK;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  switch (kind_of(dir)) {
  case N_ROOT:
    if (name_is(name, "ipifc")) return *child = N_IPIFC, VX_OK;
    if (name_is(name, "icmp")) return *child = node(N_PROTO, VX_NET_ICMP, 0), VX_OK;
    if (name_is(name, "udp")) return *child = node(N_PROTO, VX_NET_UDP, 0), VX_OK;
    if (name_is(name, "tcp")) return *child = node(N_PROTO, VX_NET_TCP, 0), VX_OK;
    return VX_ERR_NOT_FOUND;
  case N_IPIFC:
    if (name_is(name, "0")) return *child = N_IFC, VX_OK;
    return VX_ERR_NOT_FOUND;
  case N_IFC:
    if (name_is(name, "ctl")) return *child = N_IFC_CTL, VX_OK;
    if (name_is(name, "status")) return *child = N_IFC_STATUS, VX_OK;
    return VX_ERR_NOT_FOUND;
  case N_PROTO: {
    if (name_is(name, "clone")) return *child = node(N_CLONE, proto_of(dir), 0), VX_OK;
    uint32_t id = 0;
    if (!name.len || name.len > 2 || (name.len > 1 && name.ptr[0] == '0')) return VX_ERR_NOT_FOUND;
    for (size_t i = 0; i < name.len; i++) {
      if (name.ptr[i] < '0' || name.ptr[i] > '9') return VX_ERR_NOT_FOUND;
      id = id * 10 + (uint32_t)(name.ptr[i] - '0');
    }
    if (id >= VX_NET_CONVS) return VX_ERR_NOT_FOUND;
    *child = node(N_CONV, proto_of(dir), id);
    return conv_at(*child) ? VX_OK : VX_ERR_NOT_FOUND;
  }
  case N_CONV:
    if (!conv_at(dir)) return VX_ERR_NOT_FOUND;
    for (uint32_t k = N_CTL; k <= last_file(dir); k++)
      if (name.len == FILES[k].name.len && memcmp(name.ptr, FILES[k].name.ptr, name.len) == 0) {
        *child = (dir & ~0xffull) | k;
        return VX_OK;
      }
    return VX_ERR_NOT_FOUND;
  default: return VX_ERR_NOT_FOUND;
  }
}

static vx_status fs_parent(void *ctx, uint64_t n, uint64_t *parent) {
  (void)ctx;
  uint8_t k = kind_of(n);
  if (k == N_IPIFC || k == N_PROTO)
    *parent = N_ROOT;
  else if (k == N_IFC)
    *parent = N_IPIFC;
  else if (k == N_IFC_CTL || k == N_IFC_STATUS)
    *parent = N_IFC;
  else if (k == N_CLONE || k == N_CONV)
    *parent = node(N_PROTO, proto_of(n), 0);
  else
    *parent = (n & ~0xffull) | N_CONV;
  return VX_OK;
}

static vx_status fs_stat(void *ctx, uint64_t n, p9_stat *out) {
  (void)ctx;
  static char number[4];
  uint8_t k = kind_of(n);
  bool dir = k == N_ROOT || k == N_IPIFC || k == N_IFC || k == N_PROTO || k == N_CONV;
  if (k >= N_CONV && !conv_at(n)) return VX_ERR_NOT_FOUND; // closed since
  vx_str name = VX_STR("/");
  if (k == N_IPIFC) name = VX_STR("ipifc");
  if (k == N_IFC) name = VX_STR("0");
  if (k == N_PROTO && proto_of(n) == VX_NET_ICMP) name = VX_STR("icmp");
  if (k == N_PROTO && proto_of(n) == VX_NET_UDP) name = VX_STR("udp");
  if (k == N_PROTO && proto_of(n) == VX_NET_TCP) name = VX_STR("tcp");
  if (k == N_CONV) {
    uint32_t id = conv_of(n);
    size_t len = 0;
    if (id >= 10) number[len++] = (char)('0' + id / 10);
    number[len++] = (char)('0' + id % 10);
    name = (vx_str){number, len};
  }
  if (!dir && k < sizeof FILES / sizeof FILES[0]) name = FILES[k].name;
  *out = (p9_stat){.qid = {dir ? P9_QTDIR : P9_QTFILE, 0, n},
                   .mode = dir ? P9_DMDIR | 0555 : FILES[k].mode,
                   .name = name,
                   .uid = VX_STR("net"),
                   .gid = VX_STR("net"),
                   .muid = VX_STR("net")};
  return VX_OK;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  static const char *const ROOT[] = {"ipifc", "icmp", "udp", "tcp"};
  switch (kind_of(dir)) {
  case N_ROOT: return index < 4 ? fs_walk(ctx, dir, vx_cstr(ROOT[index]), child) : VX_ERR_NOT_FOUND;
  case N_IPIFC: return index == 0 ? (*child = N_IFC, VX_OK) : VX_ERR_NOT_FOUND;
  case N_IFC: return index < 2 ? (*child = index ? N_IFC_STATUS : N_IFC_CTL, VX_OK) : VX_ERR_NOT_FOUND;
  case N_PROTO:
    if (index == 0) return *child = node(N_CLONE, proto_of(dir), 0), VX_OK;
    for (uint32_t id = 0; stack_up && id < VX_NET_CONVS; id++)
      if (stack.conv[id].proto == proto_of(dir) && --index == 0)
        return *child = node(N_CONV, proto_of(dir), id), VX_OK;
    return VX_ERR_NOT_FOUND;
  case N_CONV:
    if (!conv_at(dir) || index > last_file(dir) - N_CTL) return VX_ERR_NOT_FOUND;
    *child = (dir & ~0xffull) | (uint8_t)(N_CTL + index);
    return VX_OK;
  default: return VX_ERR_NOT_FOUND;
  }
}

static vx_status fs_open(void *ctx, uint64_t n, uint8_t mode) {
  (void)ctx;
  uint8_t k = kind_of(n);
  bool writes = (mode & 3) == P9_OWRITE || (mode & 3) == P9_ORDWR;
  if (mode & P9_ORCLOSE) return VX_ERR_ACCESS;
  if (writes && k < sizeof FILES / sizeof FILES[0] && !(FILES[k].mode & 0222)) return VX_ERR_ACCESS;
  if (k == N_CLONE && !stack_up) return VX_ERR_BAD_STATE; // no driver yet
  if (k > N_CONV && !conv_at(n)) return VX_ERR_NOT_FOUND;
  if (k == N_LISTEN) // the fid moves to a new connection (fs_clone); this open may be made again
    return conv_at(n)->tcb.state == VX_TCP_LISTEN ? VX_OK : VX_ERR_BAD_STATE;
  if (k > N_CONV) conv_refs[conv_of(n)]++;
  return VX_OK;
}

// Opening a clone file makes a conversation, and opening a listen file
// takes a connection the listener made (waiting for one); either way the fid
// becomes that conversation's ctl.
static vx_status fs_clone(void *ctx, uint64_t n, uint8_t mode, uint64_t *opened) {
  (void)ctx, (void)mode;
  uint8_t k = kind_of(n);
  if (k != N_CLONE && k != N_LISTEN) return VX_ERR_NOT_FOUND;
  uint32_t id;
  vx_status st =
      k == N_CLONE ? vx_net_conv_new(&stack, proto_of(n), &id) : vx_net_tcp_accept(&stack, conv_at(n), &id);
  if (st != VX_OK) return st;
  conv_gen[id]++;
  conv_refs[id] = 1;
  *opened = node(N_CTL, proto_of(n), id);
  return VX_OK;
}

// A conversation lasts while any of its files is open.
static void fs_clunk(void *ctx, uint64_t n, bool opened) {
  (void)ctx;
  if (!opened || kind_of(n) <= N_CONV || !conv_at(n)) return;
  uint32_t id = conv_of(n);
  if (!conv_refs[id]) return;
  conv_refs[id]--;
  if (conv_refs[id]) return;
  conv_gen[id]++; // fids that outlive it see it gone, even while TCP finishes closing it
  vx_net_conv_free(&stack, id, vx_clock_read());
}

static void ifc_status(text *t) {
  put(t, VX_STR("dev="));
  put(t, link.up ? VX_STR("ether0") : VX_STR("none"));
  put(t, VX_STR(" addr="));
  if (stack_up && stack.addr) {
    put_ip(t, stack.addr);
    put(t, VX_STR("/"));
    put_u64(t, (uint64_t)__builtin_popcount(stack.mask));
    put(t, VX_STR(" gw="));
    put_ip(t, stack.gw);
  } else {
    put(t, VX_STR("none"));
  }
  if (stack_up && stack.dhcp.state != VX_DHCP_OFF) {
    put(t, VX_STR(" dhcp"));
    if (stack.addr) {
      put(t, VX_STR(" lease="));
      put_u64(t, stack.dhcp.lease);
      put(t, VX_STR("s"));
    }
  } else if (stack_up) {
    put(t, VX_STR(" static"));
  }
  put(t, VX_STR("\n"));
}

static void addr_port(text *t, uint32_t addr, uint16_t port) {
  put_ip(t, addr);
  put(t, VX_STR("!"));
  put_u64(t, port);
  put(t, VX_STR("\n"));
}

static vx_status fs_read(void *ctx, uint64_t n, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  uint8_t k = kind_of(n);
  vx_net_conv *c = k > N_CONV ? conv_at(n) : nullptr;
  if (k > N_CONV && !c) return VX_ERR_NOT_FOUND;
  if (k == N_DATA && c->proto == VX_NET_TCP) { // what has arrived, or wait for some
    size_t got = 0;
    vx_status st = vx_net_tcp_read(&stack, c, buf, *count, &got, vx_clock_read());
    *count = (uint32_t)got;
    return st;
  }
  if (k == N_DATA) { // a datagram, or wait for one
    vx_net_datagram d;
    size_t got = 0;
    if (!vx_net_conv_read(c, &d, buf, *count, &got)) return VX_ERR_SHOULD_WAIT;
    *count = (uint32_t)got;
    return VX_OK;
  }
  text t = {};
  if (k == N_IFC_STATUS) ifc_status(&t);
  if (k == N_CTL) put_u64(&t, conv_of(n));
  if (k == N_LOCAL) addr_port(&t, stack.addr, c->lport);
  if (k == N_REMOTE) addr_port(&t, c->raddr, c->rport);
  if (k == N_STATUS && c->proto == VX_NET_TCP) {
    put(&t, vx_cstr(vx_net_tcp_state_name(c->tcb.state)));
    put(&t, VX_STR("\n"));
  } else if (k == N_STATUS && c->raddr) {
    put(&t, VX_STR("Open\n"));
  } else if (k == N_STATUS) {
    put(&t, c->lport ? VX_STR("Announced\n") : VX_STR("Closed\n"));
  }
  uint64_t left = offset < t.len ? t.len - offset : 0;
  if (*count > left) *count = (uint32_t)left;
  memcpy(buf, t.buf + offset * (*count != 0), *count);
  return VX_OK;
}

// "ADDR" or "ADDR!PORT" into its parts; port 0 if none. False if malformed.
static bool parse_addr_port(vx_str s, uint32_t *addr, uint16_t *port) {
  *port = 0;
  size_t bang = 0;
  while (bang < s.len && s.ptr[bang] != '!') bang++;
  if (!vx_net_parse_ip((vx_str){s.ptr, bang}, addr)) return false;
  uint32_t p = 0;
  for (size_t i = bang + 1; i < s.len; i++) {
    if (s.ptr[i] < '0' || s.ptr[i] > '9' || (p = p * 10 + (uint32_t)(s.ptr[i] - '0')) > 65535) return false;
  }
  if (bang < s.len && bang + 1 == s.len) return false; // "ADDR!" with no port
  *port = (uint16_t)p;
  return true;
}

// Splits a control message into words (at most 4), dropping a final newline.
static uint32_t words(const uint8_t *buf, uint32_t len, vx_str *w) {
  if (len && buf[len - 1] == '\n') len--;
  uint32_t count = 0;
  for (uint32_t i = 0; i < len && count < 4;) {
    while (i < len && buf[i] == ' ') i++;
    uint32_t start = i;
    while (i < len && buf[i] != ' ') i++;
    if (i > start) w[count++] = (vx_str){(const char *)buf + start, i - start};
  }
  return count;
}

static vx_status ifc_ctl(const vx_str *w, uint32_t n) {
  if (!stack_up) return VX_ERR_BAD_STATE;
  if (n == 1 && name_is(w[0], "dhcp")) {
    vx_net_dhcp_start(&stack, vx_clock_read());
    return VX_OK;
  }
  if ((n != 2 && n != 3) || !name_is(w[0], "add")) return VX_ERR_INVALID;
  size_t slash = 0;
  while (slash < w[1].len && w[1].ptr[slash] != '/') slash++;
  uint32_t addr, gw = 0, bits = 0;
  if (!vx_net_parse_ip((vx_str){w[1].ptr, slash}, &addr) || slash + 1 >= w[1].len || w[1].len - slash > 3)
    return VX_ERR_INVALID;
  for (size_t i = slash + 1; i < w[1].len; i++) {
    if (w[1].ptr[i] < '0' || w[1].ptr[i] > '9') return VX_ERR_INVALID;
    bits = bits * 10 + (uint32_t)(w[1].ptr[i] - '0');
  }
  if (bits < 1 || bits > 32 || (n == 3 && !vx_net_parse_ip(w[2], &gw))) return VX_ERR_INVALID;
  vx_net_set_addr(&stack, addr, bits == 32 ? 0xffff'ffff : ~(0xffff'ffffu >> bits), gw);
  return VX_OK;
}

// A TCP connect is held until the connection is made or fails: the same
// write is made again after every event, and finds the connection under way.
static vx_status tcp_connect(vx_net_conv *c, uint32_t addr, uint16_t port) {
  vx_net_tcb *t = &c->tcb;
  if (!c->raddr) {
    vx_status st = vx_net_tcp_connect(&stack, c, addr, port, vx_clock_read());
    return st == VX_OK ? VX_ERR_SHOULD_WAIT : st;
  }
  if (c->raddr != addr || c->rport != port) return VX_ERR_BAD_STATE; // connected elsewhere already
  if (t->state == VX_TCP_SYN_SENT || t->state == VX_TCP_SYN_RCVD) return VX_ERR_SHOULD_WAIT;
  if (t->state == VX_TCP_CLOSED) return t->error != VX_OK ? t->error : VX_ERR_PEER_CLOSED;
  return VX_OK;
}

static vx_status conv_ctl(vx_net_conv *c, const vx_str *w, uint32_t n) {
  uint32_t addr;
  uint16_t port;
  if (n == 1 && name_is(w[0], "hangup")) {
    if (c->proto == VX_NET_TCP) vx_net_tcp_close(&stack, c, vx_clock_read());
    return VX_OK;
  }
  if (n == 2 && name_is(w[0], "connect") && c->proto == VX_NET_TCP) {
    if (!parse_addr_port(w[1], &addr, &port) || !port) return VX_ERR_INVALID;
    return tcp_connect(c, addr, port);
  }
  if (n == 2 && name_is(w[0], "connect")) {
    if (!parse_addr_port(w[1], &addr, &port)) return VX_ERR_INVALID;
    return vx_net_conv_connect(&stack, c, addr, port);
  }
  if (n == 2 && name_is(w[0], "announce")) {
    vx_str p = w[1];
    if (p.len > 2 && p.ptr[0] == '*' && p.ptr[1] == '!') p = (vx_str){p.ptr + 2, p.len - 2};
    uint32_t v = 0;
    if (!p.len || p.len > 5) return VX_ERR_INVALID;
    for (size_t i = 0; i < p.len; i++) {
      if (p.ptr[i] < '0' || p.ptr[i] > '9') return VX_ERR_INVALID;
      v = v * 10 + (uint32_t)(p.ptr[i] - '0');
    }
    if (v > 65535) return VX_ERR_INVALID;
    if (c->proto == VX_NET_TCP) return vx_net_tcp_listen(&stack, c, (uint16_t)v);
    return vx_net_conv_announce(&stack, c, (uint16_t)v);
  }
  return VX_ERR_INVALID;
}

static vx_status fs_write(void *ctx, uint64_t n, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx, (void)offset;
  uint8_t k = kind_of(n);
  vx_net_conv *c = k > N_CONV ? conv_at(n) : nullptr;
  if (k > N_CONV && !c) return VX_ERR_NOT_FOUND;
  if (k == N_DATA && c->proto == VX_NET_TCP) { // what fits; wait only if nothing does
    size_t taken = 0;
    vx_status st = vx_net_tcp_write(&stack, c, buf, *count, &taken, vx_clock_read());
    *count = (uint32_t)taken;
    return st;
  }
  if (k == N_DATA) { // one datagram, all of it or none
    uint32_t len = *count;
    vx_status st = vx_net_conv_write(&stack, c, 0, 0, buf, len, vx_clock_read());
    *count = st == VX_OK ? len : 0;
    return st;
  }
  vx_str w[4];
  uint32_t nw = words(buf, *count, w);
  if (k == N_IFC_CTL) return ifc_ctl(w, nw);
  if (k == N_CTL) return conv_ctl(c, w, nw);
  return VX_ERR_ACCESS;
}

int vx_main(void) {
  link.connector = vx_spawn_take("srv:ether0");
  server.listen = vx_spawn_take("listen");
  if (!link.connector || !server.listen || vx_port_create(0, &server.port) != VX_OK) {
    vx_print(VX_STR("netd: FAILED: no connector to /srv/ether0, or no listen channel\n"));
    return 1;
  }
  server.fs = (p9_fs){.attach = fs_attach,
                      .walk = fs_walk,
                      .parent = fs_parent,
                      .stat = fs_stat,
                      .open = fs_open,
                      .clone = fs_clone,
                      .read = fs_read,
                      .readdir = fs_readdir,
                      .write = fs_write,
                      .clunk = fs_clunk};
  server.name = VX_STR("netd");
  server.event = event;
  server.tick = tick;
  vx_print(VX_STR("netd: serving /srv/net\n"));
  return p9_ring_serve(&server);
}
