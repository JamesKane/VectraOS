// vx-net: the first-party TCP/IP stack netd runs (docs/04 §5 M3), as pure
// computation: the caller hands it each Ethernet frame that arrives and the
// time, calls vx_net_poll when the deadline it returned comes, and gives it a
// function that sends a frame. Nothing here makes a system call, so the host
// tests and the fuzzer drive it as netd does.
//
// Ethernet, ARP, IPv4 (no fragments: they are dropped, and nothing sent is
// bigger than the MTU), ICMP echo, UDP, a DHCP client (RFC 2131), and TCP
// (tcp.c).
//
// Conversations are Plan 9's (02 §5): numbered endpoints, each one protocol,
// a local port, and a remote address once connected. Datagrams that arrive
// for one queue in it until read; a full queue drops them, as a full socket
// buffer does. An ICMP conversation's port is the echo identifier, as in
// Plan 9.
//
// Every frame is hostile: lengths are checked against what arrived before
// anything is read, checksums are verified, and nothing a peer sends grows
// a table past its fixed size.

#pragma once

#include "../../abi/vx/abi.h"
#if __STDC_HOSTED__
#include <string.h> // host tests
#else
#include "../vx-mem/mem.h"
#endif

static constexpr uint32_t VX_ETHER_MAX_FRAME = 1514; // 14 bytes of Ethernet header, 1500 of IP
static constexpr uint32_t VX_NET_CONVS = 32;
static constexpr uint32_t VX_NET_CONV_QUEUE = 8192; // bytes of datagrams a conversation holds
static constexpr uint32_t VX_NET_ARP_ENTRIES = 16;

enum : uint8_t { VX_NET_ICMP = 1, VX_NET_TCP = 6, VX_NET_UDP = 17 }; // conversation protocols, by IP number

typedef enum vx_net_dhcp_state : uint8_t {
  VX_DHCP_OFF,        // a static address, or none
  VX_DHCP_SELECTING,  // DISCOVER sent
  VX_DHCP_REQUESTING, // REQUEST sent for an offer
  VX_DHCP_BOUND,
  VX_DHCP_RENEWING,  // past T1: REQUEST to the server
  VX_DHCP_REBINDING, // past T2: REQUEST to anyone
} vx_net_dhcp_state;

typedef struct vx_net_dhcp {
  vx_net_dhcp_state state;
  uint32_t xid, offered, server;
  uint32_t lease; // seconds, as granted
  vx_instant next, t1, t2, expires;
  uint32_t backoff; // seconds until the next retransmission
} vx_net_dhcp;

// A datagram as a conversation queues it.
typedef struct vx_net_datagram {
  uint32_t addr; // where it came from
  uint16_t port;
  uint16_t len; // payload bytes, after this header in the queue
} vx_net_datagram;

typedef enum vx_tcp_state : uint8_t {
  VX_TCP_CLOSED,
  VX_TCP_LISTEN,
  VX_TCP_SYN_SENT,
  VX_TCP_SYN_RCVD,
  VX_TCP_ESTABLISHED,
  VX_TCP_FIN_WAIT_1,
  VX_TCP_FIN_WAIT_2,
  VX_TCP_CLOSING,
  VX_TCP_TIME_WAIT,
  VX_TCP_CLOSE_WAIT,
  VX_TCP_LAST_ACK,
} vx_tcp_state;

static constexpr uint32_t VX_TCP_BUF = 65535; // each way: a window that needs no scaling of ours

// A TCP connection's state (RFC 793 names). Sequence numbers are mod 2^32.
typedef struct vx_net_tcb {
  vx_tcp_state state;
  bool orphan;       // the application let go: the stack frees it once closed
  bool fin_queued;   // the application closed its side: a FIN follows the data
  bool fin_received; // reads end once rbuf is empty
  bool ack_now, timing, in_recovery;
  bool measured;   // srtt and rttvar hold a sample (a fast link can measure 0)
  bool accepted;   // a listener's connection that its application has taken
  vx_status error; // why it closed: REFUSED, PEER_CLOSED (reset) or TIMED_OUT
  uint32_t parent; // the listener that made it, plus one; 0 if none

  uint32_t iss, snd_una, snd_nxt, snd_max, snd_wnd, snd_wl1, snd_wl2;
  uint32_t sbuf_seq; // the sequence number of sbuf's first byte
  uint8_t snd_shift; // the peer's window scale
  uint8_t dupacks, retries, persist_shift;
  uint16_t mss; // the most a segment we send carries
  uint32_t cwnd, ssthresh, recover;
  uint32_t rtt_seq;
  vx_instant rtt_start, srtt, rttvar, rto;
  vx_instant rto_at, persist_at,
      linger_at; // NET_NEVER when off; linger: TIME_WAIT, or an orphan's FIN_WAIT_2

  uint32_t irs, rcv_nxt;
  uint32_t shead, slen, rhead, rlen; // the two rings: where the bytes start, and how many
  uint8_t sbuf[VX_TCP_BUF];          // written, not yet acknowledged
  uint8_t rbuf[VX_TCP_BUF];          // received in order, not yet read
} vx_net_tcb;

typedef struct vx_net_conv {
  uint8_t proto; // 0: free
  uint16_t lport, rport;
  uint32_t raddr; // 0 until connected
  uint8_t queue[VX_NET_CONV_QUEUE];
  uint32_t head, used; // a byte ring of vx_net_datagram headers, each followed by its payload
  uint64_t dropped;
  vx_net_tcb tcb; // TCP's
} vx_net_conv;

typedef struct vx_net_arp {
  uint32_t ip;
  uint8_t mac[6];
  bool resolved;
  uint8_t tries;   // requests sent while unresolved
  vx_instant when; // resolved: when it expires; unresolved: when to ask again
  uint16_t queued; // bytes of the one IP packet waiting for it, or 0
  uint8_t packet[1500];
} vx_net_arp;

typedef struct vx_net {
  void *ctx;
  void (*send)(void *ctx, const uint8_t *frame, size_t len); // one whole Ethernet frame
  uint8_t mac[6];
  uint32_t mtu;

  // The interface: addresses in host order; addr 0 until configured.
  uint32_t addr, mask, gw, dns;

  vx_net_dhcp dhcp;

  vx_net_arp arp[VX_NET_ARP_ENTRIES];
  vx_net_conv conv[VX_NET_CONVS];
  uint16_t next_port;
  uint32_t seed; // for transaction IDs and ports: not secret, only varied

  struct {
    uint64_t in, out, dropped, bad;
  } stats;
  uint8_t frame[VX_ETHER_MAX_FRAME]; // the one being built
} vx_net;

// --- Bytes on the wire: network order ---

static uint16_t net_get16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t net_get32(const uint8_t *p) {
  return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
static void net_put16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 8), p[1] = (uint8_t)v; }
static void net_put32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24), p[1] = (uint8_t)(v >> 16), p[2] = (uint8_t)(v >> 8), p[3] = (uint8_t)v;
}

// The Internet checksum's running sum (RFC 1071), folded by net_fold.
static uint32_t net_sum(uint32_t sum, const uint8_t *p, size_t len) {
  for (size_t i = 0; i + 1 < len; i += 2) sum += net_get16(p + i);
  if (len & 1) sum += (uint32_t)p[len - 1] << 8;
  return sum;
}
static uint16_t net_fold(uint32_t sum) {
  while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
  return (uint16_t)~sum;
}
// The UDP and TCP pseudo-header's sum.
static uint32_t net_pseudo(uint32_t src, uint32_t dst, uint8_t proto, uint32_t len) {
  return (src >> 16) + (src & 0xffff) + (dst >> 16) + (dst & 0xffff) + proto + len;
}

static const uint8_t NET_BROADCAST_MAC[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
static constexpr uint32_t NET_BROADCAST = 0xffff'ffff;
static constexpr vx_instant NET_SECOND = 1'000'000'000;
static constexpr vx_instant NET_NEVER = INT64_MAX;

static uint32_t net_random(vx_net *n) { // xorshift32: varied, not secret
  uint32_t x = n->seed ? n->seed : 0x9e37'79b9;
  x ^= x << 13, x ^= x >> 17, x ^= x << 5;
  return n->seed = x;
}

// --- Addresses as text: "10.0.2.15" ---

// Parses a dotted quad; false unless all of s is one.
[[maybe_unused]] static bool vx_net_parse_ip(vx_str s, uint32_t *out) {
  uint32_t v = 0;
  size_t i = 0;
  for (int part = 0; part < 4; part++) {
    if (part) {
      if (i >= s.len || s.ptr[i] != '.') return false;
      i++;
    }
    uint32_t octet = 0;
    size_t digits = 0;
    for (; i < s.len && s.ptr[i] >= '0' && s.ptr[i] <= '9' && digits < 3; i++, digits++)
      octet = octet * 10 + (uint32_t)(s.ptr[i] - '0');
    if (!digits || octet > 255) return false;
    v = v << 8 | octet;
  }
  if (i != s.len) return false;
  *out = v;
  return true;
}

// Writes a dotted quad into buf (16 bytes); its length.
[[maybe_unused]] static size_t vx_net_format_ip(uint32_t ip, char *buf) {
  size_t n = 0;
  for (int part = 3; part >= 0; part--) {
    uint32_t octet = ip >> (8 * part) & 0xff;
    if (octet >= 100) buf[n++] = (char)('0' + octet / 100);
    if (octet >= 10) buf[n++] = (char)('0' + octet / 10 % 10);
    buf[n++] = (char)('0' + octet % 10);
    if (part) buf[n++] = '.';
  }
  return n;
}

// --- Sending ---

static void net_ether_send(vx_net *n, const uint8_t dst[6], uint16_t type, size_t payload) {
  memcpy(n->frame, dst, 6);
  memcpy(n->frame + 6, n->mac, 6);
  net_put16(n->frame + 12, type);
  size_t len = 14 + payload;
  if (len < 60) { // Ethernet's minimum, padded with zeros
    memset(n->frame + len, 0, 60 - len);
    len = 60;
  }
  n->stats.out++;
  n->send(n->ctx, n->frame, len);
}

static void net_arp_send(vx_net *n, uint16_t op, const uint8_t tha[6], uint32_t tpa, const uint8_t dst[6]) {
  uint8_t *a = n->frame + 14;
  net_put16(a, 1);          // Ethernet
  net_put16(a + 2, 0x0800); // IPv4
  a[4] = 6, a[5] = 4;
  net_put16(a + 6, op);
  memcpy(a + 8, n->mac, 6);
  net_put32(a + 14, n->addr);
  memcpy(a + 18, tha, 6);
  net_put32(a + 24, tpa);
  net_ether_send(n, dst, 0x0806, 28);
}

// Fills in an IPv4 header at frame + 14 for `len` bytes of payload.
static void net_ip_header(vx_net *n, uint8_t proto, uint32_t src, uint32_t dst, size_t len) {
  uint8_t *ip = n->frame + 14;
  ip[0] = 0x45, ip[1] = 0;
  net_put16(ip + 2, (uint32_t)(20 + len));
  net_put16(ip + 4, net_random(n) & 0xffff);
  net_put16(ip + 6, 0x4000); // don't fragment
  ip[8] = 64, ip[9] = proto;
  net_put16(ip + 10, 0);
  net_put32(ip + 12, src);
  net_put32(ip + 16, dst);
  net_put16(ip + 10, net_fold(net_sum(0, ip, 20)));
}

// The ARP entry for ip, or a free (or the oldest) one to reuse for it.
static vx_net_arp *net_arp_slot(vx_net *n, uint32_t ip, bool make) {
  vx_net_arp *victim = &n->arp[0];
  for (uint32_t i = 0; i < VX_NET_ARP_ENTRIES; i++) {
    if (n->arp[i].ip == ip) return &n->arp[i];
    if (!n->arp[i].ip || (victim->ip && n->arp[i].when < victim->when)) victim = &n->arp[i];
  }
  if (!make) return nullptr;
  *victim = (vx_net_arp){.ip = ip};
  return victim;
}

// Sends the IP packet built at frame + 14 (len bytes, header included) to its
// next hop: at once if its MAC is known, or else after ARP finds it.
static void net_ip_route(vx_net *n, uint32_t dst, size_t len, vx_instant now) {
  if (dst == NET_BROADCAST || (n->mask != NET_BROADCAST && n->addr && dst == (n->addr | ~n->mask))) {
    net_ether_send(n, NET_BROADCAST_MAC, 0x0800, len);
    return;
  }
  uint32_t hop = (dst & n->mask) == (n->addr & n->mask) ? dst : n->gw;
  if (!hop || !n->addr) {
    n->stats.dropped++; // no route
    return;
  }
  vx_net_arp *e = net_arp_slot(n, hop, true);
  if (e->resolved && e->when > now) {
    net_ether_send(n, e->mac, 0x0800, len);
    return;
  }
  if (e->resolved) *e = (vx_net_arp){.ip = hop}; // expired: ask again
  if (e->queued) n->stats.dropped++;             // one packet waits; the newest replaces it
  memcpy(e->packet, n->frame + 14, len);
  e->queued = (uint16_t)len;
  if (!e->tries) {
    e->tries = 1;
    e->when = now + NET_SECOND;
    net_arp_send(n, 1, (const uint8_t[6]){}, hop, NET_BROADCAST_MAC);
  }
}

// Sends a UDP datagram from `src` (an address, or 0 for none yet).
static vx_status net_udp_out(vx_net *n, uint32_t src, uint16_t sport, uint32_t dst, uint16_t dport,
                             const uint8_t *data, size_t len, vx_instant now) {
  if (len > n->mtu - 28) return VX_ERR_RANGE;
  uint8_t *u = n->frame + 34;
  memmove(u + 8, data, len); // data may already be in place
  net_put16(u, sport);
  net_put16(u + 2, dport);
  net_put16(u + 4, (uint32_t)(8 + len));
  net_put16(u + 6, 0);
  uint16_t sum = net_fold(net_sum(net_pseudo(src, dst, 17, (uint32_t)(8 + len)), u, 8 + len));
  net_put16(u + 6, sum ? sum : 0xffff);
  net_ip_header(n, 17, src, dst, 8 + len);
  net_ip_route(n, dst, 28 + len, now);
  return VX_OK;
}

// --- Conversations ---

[[maybe_unused]] static vx_net_conv *vx_net_conv_get(vx_net *n, uint32_t id) {
  return id < VX_NET_CONVS && n->conv[id].proto ? &n->conv[id] : nullptr;
}

static bool net_port_used(vx_net *n, uint8_t proto, uint16_t port) {
  for (uint32_t i = 0; i < VX_NET_CONVS; i++)
    if (n->conv[i].proto == proto && n->conv[i].lport == port) return true;
  return false;
}

// A new conversation of this protocol, its number in *id.
[[maybe_unused]] static vx_status vx_net_conv_new(vx_net *n, uint8_t proto, uint32_t *id) {
  if (proto != VX_NET_ICMP && proto != VX_NET_UDP && proto != VX_NET_TCP) return VX_ERR_INVALID;
  for (uint32_t i = 0; i < VX_NET_CONVS; i++) {
    if (n->conv[i].proto) continue;
    n->conv[i].proto = proto;
    n->conv[i].lport = n->conv[i].rport = 0;
    n->conv[i].raddr = 0;
    n->conv[i].head = n->conv[i].used = 0;
    n->conv[i].dropped = 0;
    memset(&n->conv[i].tcb, 0, offsetof(vx_net_tcb, sbuf)); // the state, not the rings
    n->conv[i].tcb.rto_at = n->conv[i].tcb.persist_at = n->conv[i].tcb.linger_at = NET_NEVER; // no timers
    *id = i;
    return VX_OK;
  }
  return VX_ERR_NO_MEMORY;
}

static void net_tcp_free(vx_net *n, vx_net_conv *c, vx_instant now);

// The application let go of a conversation. A TCP connection stays until it
// has closed (tcp.c).
[[maybe_unused]] static void vx_net_conv_free(vx_net *n, uint32_t id, vx_instant now) {
  if (id >= VX_NET_CONVS) return;
  if (n->conv[id].proto == VX_NET_TCP)
    net_tcp_free(n, &n->conv[id], now);
  else
    n->conv[id].proto = 0;
}

// A local port nothing of this protocol uses, from the dynamic range.
static uint16_t net_free_port(vx_net *n, uint8_t proto) {
  for (uint32_t tries = 0; tries < 16384; tries++) {
    if (n->next_port < 49152) n->next_port = (uint16_t)(49152 + net_random(n) % 16384);
    uint16_t port = n->next_port++;
    if (!net_port_used(n, proto, port)) return port;
  }
  return 0;
}

// Binds a conversation's local port: 0 picks a free one.
[[maybe_unused]] static vx_status vx_net_conv_announce(vx_net *n, vx_net_conv *c, uint16_t port) {
  if (c->lport) return VX_ERR_BAD_STATE;
  if (port && net_port_used(n, c->proto, port)) return VX_ERR_EXISTS;
  if (!port && !(port = net_free_port(n, c->proto))) return VX_ERR_NO_MEMORY;
  c->lport = port;
  return VX_OK;
}

// Connects a conversation to a remote address (and port, for UDP); it then
// receives only from there, and sends there.
[[maybe_unused]] static vx_status vx_net_conv_connect(vx_net *n, vx_net_conv *c, uint32_t addr,
                                                      uint16_t port) {
  if (c->raddr || !addr || (c->proto == VX_NET_UDP && !port)) return VX_ERR_INVALID;
  if (!c->lport) {
    vx_status st = vx_net_conv_announce(n, c, 0);
    if (st != VX_OK) return st;
  }
  c->raddr = addr;
  c->rport = port;
  return VX_OK;
}

static void net_conv_queue(vx_net_conv *c, uint32_t addr, uint16_t port, const uint8_t *data, size_t len) {
  if (len > UINT16_MAX || sizeof(vx_net_datagram) + len > VX_NET_CONV_QUEUE - c->used) {
    c->dropped++;
    return;
  }
  vx_net_datagram d = {.addr = addr, .port = port, .len = (uint16_t)len};
  uint32_t at = (c->head + c->used) % VX_NET_CONV_QUEUE;
  for (size_t i = 0; i < sizeof d; i++) c->queue[(at + i) % VX_NET_CONV_QUEUE] = ((const uint8_t *)&d)[i];
  at = (uint32_t)((at + sizeof d) % VX_NET_CONV_QUEUE);
  size_t first = len < VX_NET_CONV_QUEUE - at ? len : VX_NET_CONV_QUEUE - at;
  memcpy(c->queue + at, data, first);
  memcpy(c->queue, data + first, len - first);
  c->used += (uint32_t)(sizeof d + len);
}

// Takes the next datagram: its header in *d and up to cap bytes of its payload
// in buf (the rest is lost, as a short read of a datagram loses it). False if
// none is queued.
[[maybe_unused]] static bool vx_net_conv_read(vx_net_conv *c, vx_net_datagram *d, uint8_t *buf, size_t cap,
                                              size_t *got) {
  if (!c->used) return false;
  for (size_t i = 0; i < sizeof *d; i++) ((uint8_t *)d)[i] = c->queue[(c->head + i) % VX_NET_CONV_QUEUE];
  uint32_t at = (uint32_t)((c->head + sizeof *d) % VX_NET_CONV_QUEUE);
  size_t n = d->len < cap ? d->len : cap;
  size_t first = n < VX_NET_CONV_QUEUE - at ? n : VX_NET_CONV_QUEUE - at;
  memcpy(buf, c->queue + at, first);
  memcpy(buf + first, c->queue, n - first);
  c->head = (uint32_t)((c->head + sizeof *d + d->len) % VX_NET_CONV_QUEUE);
  c->used -= (uint32_t)(sizeof *d + d->len);
  *got = n;
  return true;
}

// Sends on a connected conversation (or, with addr and port, an announced UDP
// one). UDP: data is the payload. ICMP: data is the whole message, type and
// code first; the identifier becomes the conversation's port and the
// checksum is filled in.
[[maybe_unused]] static vx_status vx_net_conv_write(vx_net *n, vx_net_conv *c, uint32_t addr, uint16_t port,
                                                    const uint8_t *data, size_t len, vx_instant now) {
  if (!addr) addr = c->raddr, port = c->rport;
  if (!addr || !c->lport) return VX_ERR_BAD_STATE;
  if (!n->addr) return VX_ERR_BAD_STATE; // no address yet
  if (c->proto == VX_NET_UDP) return net_udp_out(n, n->addr, c->lport, addr, port, data, len, now);
  if (len < 8 || len > n->mtu - 20) return VX_ERR_INVALID;
  uint8_t *m = n->frame + 34;
  memcpy(m, data, len);
  net_put16(m + 2, 0);
  net_put16(m + 4, c->lport);
  net_put16(m + 2, net_fold(net_sum(0, m, len)));
  net_ip_header(n, 1, n->addr, addr, len);
  net_ip_route(n, addr, 20 + len, now);
  return VX_OK;
}

#include "tcp.c"

// --- DHCP (RFC 2131) ---

enum : uint8_t { DHCP_DISCOVER = 1, DHCP_OFFER, DHCP_REQUEST, DHCP_DECLINE, DHCP_ACK, DHCP_NAK };

static void net_dhcp_send(vx_net *n, uint8_t type, vx_instant now) {
  uint8_t *b = n->frame + 42; // after the Ethernet, IP and UDP headers
  memset(b, 0, 240);
  b[0] = 1, b[1] = 1, b[2] = 6; // a request; Ethernet addresses
  net_put32(b + 4, n->dhcp.xid);
  bool renewing = n->dhcp.state == VX_DHCP_RENEWING || n->dhcp.state == VX_DHCP_REBINDING;
  if (renewing)
    net_put32(b + 12, n->addr); // ciaddr
  else
    net_put16(b + 10, 0x8000); // answer by broadcast: we have no address yet
  memcpy(b + 28, n->mac, 6);
  net_put32(b + 236, 0x6382'5363); // the magic cookie
  size_t o = 240;
  b[o++] = 53, b[o++] = 1, b[o++] = type;
  if (type == DHCP_REQUEST && !renewing) {
    b[o++] = 50, b[o++] = 4, net_put32(b + o, n->dhcp.offered), o += 4; // the requested address
    b[o++] = 54, b[o++] = 4, net_put32(b + o, n->dhcp.server), o += 4;  // the server chosen
  }
  b[o++] = 55, b[o++] = 4, b[o++] = 1, b[o++] = 3, b[o++] = 6, b[o++] = 51; // mask, router, DNS, lease
  b[o++] = 255;
  while (o < 300) b[o++] = 0; // BOOTP's minimum
  bool unicast = n->dhcp.state == VX_DHCP_RENEWING;
  uint32_t src = renewing ? n->addr : 0;
  net_udp_out(n, src, 68, unicast ? n->dhcp.server : NET_BROADCAST, 67, b, o, now);
}

// Starts DHCP from the beginning: forgets any address and sends DISCOVER.
[[maybe_unused]] static void vx_net_dhcp_start(vx_net *n, vx_instant now) {
  n->addr = n->gw = n->dns = 0;
  n->mask = 0;
  n->dhcp = (vx_net_dhcp){.state = VX_DHCP_SELECTING, .xid = net_random(n), .backoff = 4};
  n->dhcp.next = now + 4 * NET_SECOND;
  net_dhcp_send(n, DHCP_DISCOVER, now);
}

// A static address: DHCP stops.
[[maybe_unused]] static void vx_net_set_addr(vx_net *n, uint32_t addr, uint32_t mask, uint32_t gw) {
  n->dhcp.state = VX_DHCP_OFF;
  n->addr = addr, n->mask = mask, n->gw = gw;
}

static void net_dhcp_input(vx_net *n, const uint8_t *b, size_t len, vx_instant now) {
  if (len < 240 || b[0] != 2 || net_get32(b + 4) != n->dhcp.xid || memcmp(b + 28, n->mac, 6) != 0 ||
      net_get32(b + 236) != 0x6382'5363)
    return;
  uint8_t type = 0;
  uint32_t server = 0, mask = 0, router = 0, dns = 0, lease = 0, t1 = 0, t2 = 0;
  for (size_t o = 240; o < len && b[o] != 255;) { // options: code, length, value
    if (b[o] == 0) {
      o++;
      continue;
    }
    if (o + 2 > len || o + 2 + b[o + 1] > len) return; // runs past the end
    uint8_t code = b[o], olen = b[o + 1];
    const uint8_t *v = b + o + 2;
    if (code == 53 && olen == 1) type = v[0];
    if (olen >= 4) {
      uint32_t x = net_get32(v);
      if (code == 54) server = x;
      if (code == 1) mask = x;
      if (code == 3) router = x;
      if (code == 6) dns = x;
      if (code == 51) lease = x;
      if (code == 58) t1 = x;
      if (code == 59) t2 = x;
    }
    o += 2 + olen;
  }
  uint32_t yiaddr = net_get32(b + 16);
  if (n->dhcp.state == VX_DHCP_SELECTING && type == DHCP_OFFER && yiaddr && server) {
    n->dhcp.offered = yiaddr;
    n->dhcp.server = server;
    n->dhcp.state = VX_DHCP_REQUESTING;
    n->dhcp.backoff = 4;
    n->dhcp.next = now + 4 * NET_SECOND;
    net_dhcp_send(n, DHCP_REQUEST, now);
    return;
  }
  bool asking = n->dhcp.state == VX_DHCP_REQUESTING || n->dhcp.state == VX_DHCP_RENEWING ||
                n->dhcp.state == VX_DHCP_REBINDING;
  if (!asking) return;
  if (type == DHCP_NAK) {
    vx_net_dhcp_start(n, now);
    return;
  }
  if (type != DHCP_ACK || !yiaddr) return;
  // A mask must be contiguous ones; without one, the class-free default is /24.
  if (!mask || (~mask & (~mask + 1))) mask = 0xffff'ff00;
  if (lease < 60) lease = 60; // a server's zero or tiny lease would make us ask forever
  n->addr = yiaddr, n->mask = mask, n->gw = router, n->dns = dns;
  n->dhcp.state = VX_DHCP_BOUND;
  if (server) n->dhcp.server = server;
  n->dhcp.lease = lease;
  if (!t1 || t1 >= lease) t1 = lease / 2;
  if (!t2 || t2 >= lease || t2 <= t1) t2 = lease / 8 * 7;
  n->dhcp.t1 = now + (vx_instant)t1 * NET_SECOND;
  n->dhcp.t2 = now + (vx_instant)t2 * NET_SECOND;
  n->dhcp.expires = now + (vx_instant)lease * NET_SECOND;
  n->dhcp.next = n->dhcp.t1;
}

// --- Receiving ---

static void net_arp_input(vx_net *n, const uint8_t *a, size_t len, vx_instant now) {
  if (len < 28 || net_get16(a) != 1 || net_get16(a + 2) != 0x0800 || a[4] != 6 || a[5] != 4) return;
  uint16_t op = net_get16(a + 6);
  uint32_t spa = net_get32(a + 14), tpa = net_get32(a + 24);
  if (!spa || (a[8] & 1)) return; // a probe, or a multicast sender: nothing to learn
  bool for_us = n->addr && tpa == n->addr;
  // RFC 826: update an entry we have; make one only if the packet is for us.
  vx_net_arp *e = net_arp_slot(n, spa, for_us);
  if (e) {
    memcpy(e->mac, a + 8, 6);
    e->resolved = true;
    e->tries = 0;
    e->when = now + 600 * NET_SECOND;
    if (e->queued) {
      memcpy(n->frame + 14, e->packet, e->queued);
      size_t queued = e->queued;
      e->queued = 0;
      net_ether_send(n, e->mac, 0x0800, queued);
    }
  }
  if (for_us && op == 1) net_arp_send(n, 2, a + 8, spa, a + 8);
}

static void net_deliver(vx_net *n, uint8_t proto, uint16_t lport, uint32_t src, uint16_t sport,
                        const uint8_t *data, size_t len) {
  for (uint32_t i = 0; i < VX_NET_CONVS; i++) {
    vx_net_conv *c = &n->conv[i];
    if (c->proto != proto || c->lport != lport) continue;
    if (c->raddr && (c->raddr != src || (proto == VX_NET_UDP && c->rport != sport))) continue;
    net_conv_queue(c, src, sport, data, len);
    return;
  }
  n->stats.dropped++; // nobody listening
}

static void net_icmp_input(vx_net *n, uint32_t src, uint32_t dst, const uint8_t *m, size_t len,
                           vx_instant now) {
  if (len < 8 || net_fold(net_sum(0, m, len)) != 0) {
    n->stats.bad++;
    return;
  }
  if (m[0] == 8 && m[1] == 0 && dst == n->addr) { // an echo request for us: the same back, as a reply
    uint8_t *r = n->frame + 34;
    memmove(r, m, len);
    r[0] = 0;
    net_put16(r + 2, 0);
    net_put16(r + 2, net_fold(net_sum(0, r, len)));
    net_ip_header(n, 1, n->addr, src, len);
    net_ip_route(n, src, 20 + len, now);
    return;
  }
  if (m[0] == 0) net_deliver(n, VX_NET_ICMP, net_get16(m + 4), src, 0, m, len); // a reply, by identifier
}

static void net_udp_input(vx_net *n, uint32_t src, uint32_t dst, const uint8_t *u, size_t len,
                          vx_instant now) {
  if (len < 8 || net_get16(u + 4) < 8 || net_get16(u + 4) > len) {
    n->stats.bad++;
    return;
  }
  len = net_get16(u + 4); // the IP payload may be padded
  if (net_get16(u + 6) && net_fold(net_sum(net_pseudo(src, dst, 17, (uint32_t)len), u, len)) != 0) {
    n->stats.bad++;
    return;
  }
  uint16_t sport = net_get16(u), dport = net_get16(u + 2);
  if (dport == 68 && sport == 67) {
    net_dhcp_input(n, u + 8, len - 8, now);
    return;
  }
  if (!n->addr || (dst != n->addr && dst != NET_BROADCAST)) return;
  net_deliver(n, VX_NET_UDP, dport, src, sport, u + 8, len - 8);
}

static void net_ip_input(vx_net *n, const uint8_t *ip, size_t len, vx_instant now) {
  if (len < 20 || ip[0] >> 4 != 4) goto bad;
  size_t hlen = (size_t)(ip[0] & 15) * 4, total = net_get16(ip + 2);
  if (hlen < 20 || total < hlen || total > len || net_fold(net_sum(0, ip, hlen)) != 0) goto bad;
  if (net_get16(ip + 6) & 0x3fff) { // a fragment (more to come, or an offset): not reassembled
    n->stats.dropped++;
    return;
  }
  uint32_t src = net_get32(ip + 12), dst = net_get32(ip + 16);
  bool ours = dst == NET_BROADCAST || (n->addr && (dst == n->addr || dst == (n->addr | ~n->mask)));
  bool dhcp = n->dhcp.state != VX_DHCP_OFF && ip[9] == 17; // an offer may come to the address it offers
  if (!ours && !dhcp) return;
  if (ip[9] == 1)
    net_icmp_input(n, src, dst, ip + hlen, total - hlen, now);
  else if (ip[9] == 17)
    net_udp_input(n, src, dst, ip + hlen, total - hlen, now);
  else if (ip[9] == 6)
    net_tcp_input(n, src, dst, ip + hlen, total - hlen, now);
  return;
bad:
  n->stats.bad++;
}

// One Ethernet frame that arrived (without its FCS).
[[maybe_unused]] static void vx_net_input(vx_net *n, const uint8_t *frame, size_t len, vx_instant now) {
  n->stats.in++;
  if (len < 14 || len > VX_ETHER_MAX_FRAME) {
    n->stats.bad++;
    return;
  }
  if (memcmp(frame, n->mac, 6) != 0 && memcmp(frame, NET_BROADCAST_MAC, 6) != 0) return; // not ours
  uint16_t type = net_get16(frame + 12);
  if (type == 0x0806) net_arp_input(n, frame + 14, len - 14, now);
  if (type == 0x0800) net_ip_input(n, frame + 14, len - 14, now);
}

// Does what is due by now (retransmissions, renewals, expiries) and returns
// when to be called again.
[[maybe_unused]] static vx_instant vx_net_poll(vx_net *n, vx_instant now) {
  vx_instant next = NET_NEVER;
  for (uint32_t i = 0; i < VX_NET_ARP_ENTRIES; i++) {
    vx_net_arp *e = &n->arp[i];
    if (!e->ip || e->resolved) continue;
    if (e->when <= now) {
      if (e->tries == 3) { // nobody answered: give up, and drop what waited
        if (e->queued) n->stats.dropped++;
        *e = (vx_net_arp){};
        continue;
      }
      e->tries++;
      e->when = now + NET_SECOND;
      net_arp_send(n, 1, (const uint8_t[6]){}, e->ip, NET_BROADCAST_MAC);
    }
    if (e->when < next) next = e->when;
  }
  for (uint32_t i = 0; i < VX_NET_CONVS; i++) {
    if (n->conv[i].proto != VX_NET_TCP) continue;
    vx_instant due = net_tcp_poll(n, &n->conv[i], now);
    if (due < next) next = due;
  }
  if (n->dhcp.state == VX_DHCP_OFF) return next;
  bool bound = n->dhcp.state == VX_DHCP_BOUND || n->dhcp.state == VX_DHCP_RENEWING ||
               n->dhcp.state == VX_DHCP_REBINDING;
  // The lease ran out, and the address goes; or the offer's server stopped
  // answering (RFC 2131 §4.4.1): start again.
  bool unanswered = n->dhcp.next <= now && n->dhcp.state == VX_DHCP_REQUESTING && n->dhcp.backoff >= 32;
  if ((bound && now >= n->dhcp.expires) || unanswered) {
    vx_net_dhcp_start(n, now);
  } else if (n->dhcp.next <= now) {
    if (n->dhcp.state == VX_DHCP_BOUND || (n->dhcp.state == VX_DHCP_RENEWING && now >= n->dhcp.t2)) {
      n->dhcp.state = n->dhcp.state == VX_DHCP_BOUND ? VX_DHCP_RENEWING : VX_DHCP_REBINDING;
      n->dhcp.xid = net_random(n);
      n->dhcp.backoff = 4;
    } else if (n->dhcp.backoff < 64) {
      n->dhcp.backoff *= 2;
    }
    net_dhcp_send(n, n->dhcp.state == VX_DHCP_SELECTING ? DHCP_DISCOVER : DHCP_REQUEST, now);
    n->dhcp.next = now + (vx_instant)n->dhcp.backoff * NET_SECOND;
    if (bound) {
      vx_instant limit = n->dhcp.state == VX_DHCP_RENEWING ? n->dhcp.t2 : n->dhcp.expires;
      if (n->dhcp.next > limit) n->dhcp.next = limit;
    }
  }
  return n->dhcp.next < next ? n->dhcp.next : next;
}

// Sets up a stack for an interface. Its address comes from vx_net_dhcp_start
// or vx_net_set_addr.
[[maybe_unused]] static void vx_net_init(vx_net *n, const uint8_t mac[6], uint32_t mtu, uint32_t seed,
                                         void (*send)(void *ctx, const uint8_t *frame, size_t len),
                                         void *ctx) {
  memset(n, 0, sizeof *n);
  memcpy(n->mac, mac, 6);
  n->mtu = mtu > 1500 || mtu < 576 ? 1500 : mtu;
  n->seed = seed;
  n->send = send;
  n->ctx = ctx;
}
