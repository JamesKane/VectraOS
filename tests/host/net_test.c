// net_test.c: lib/vx-net against a scripted peer. The stack's frames are
// captured, and the peer's are built here: a DHCP exchange to a lease, its
// renewal and its expiry; ARP answers and lookups, with the packet that waited
// sent once the lookup is answered; ICMP echo both ways; UDP conversations;
// and frames that must be refused (bad checksums, fragments, lengths that lie).

#include <string.h>

#include "check.h"
#include "../../lib/vx-net/net.c"

static const uint8_t MAC[6] = {0x52, 0x54, 0, 0x12, 0x34, 0x56};
static const uint8_t HOST_MAC[6] = {0x52, 0x55, 10, 0, 2, 2};
static constexpr uint32_t GUEST = 0x0a00'020f, HOST = 0x0a00'0202, DNS = 0x0a00'0203;

static uint8_t sent[16][VX_ETHER_MAX_FRAME];
static size_t sent_len[16], sent_count;

static void capture(void *ctx, const uint8_t *frame, size_t len) {
  (void)ctx;
  if (sent_count < 16) {
    memcpy(sent[sent_count], frame, len);
    sent_len[sent_count++] = len;
  }
}

static vx_net net;
static uint8_t in[VX_ETHER_MAX_FRAME];

// --- The peer's frames ---

static size_t eth(const uint8_t dst[6], uint16_t type) {
  memcpy(in, dst, 6);
  memcpy(in + 6, HOST_MAC, 6);
  net_put16(in + 12, type);
  return 14;
}

static size_t ip_packet(uint32_t src, uint32_t dst, uint8_t proto, const uint8_t *payload, size_t len) {
  eth(MAC, 0x0800);
  uint8_t *ip = in + 14;
  memset(ip, 0, 20);
  ip[0] = 0x45;
  net_put16(ip + 2, (uint32_t)(20 + len));
  ip[8] = 64, ip[9] = proto;
  net_put32(ip + 12, src);
  net_put32(ip + 16, dst);
  net_put16(ip + 10, net_fold(net_sum(0, ip, 20)));
  memcpy(ip + 20, payload, len);
  return 34 + len;
}

static size_t udp_packet(uint32_t src, uint16_t sport, uint32_t dst, uint16_t dport, const uint8_t *data,
                         size_t len) {
  static uint8_t u[1500];
  net_put16(u, sport);
  net_put16(u + 2, dport);
  net_put16(u + 4, (uint32_t)(8 + len));
  net_put16(u + 6, 0);
  memcpy(u + 8, data, len);
  uint16_t sum = net_fold(net_sum(net_pseudo(src, dst, 17, (uint32_t)(8 + len)), u, 8 + len));
  net_put16(u + 6, sum ? sum : 0xffff);
  return ip_packet(src, dst, 17, u, 8 + len);
}

static size_t arp_packet(uint16_t op, uint32_t spa, const uint8_t tha[6], uint32_t tpa,
                         const uint8_t dst[6]) {
  eth(dst, 0x0806);
  uint8_t *a = in + 14;
  net_put16(a, 1);
  net_put16(a + 2, 0x0800);
  a[4] = 6, a[5] = 4;
  net_put16(a + 6, op);
  memcpy(a + 8, HOST_MAC, 6);
  net_put32(a + 14, spa);
  memcpy(a + 18, tha, 6);
  net_put32(a + 24, tpa);
  return 42;
}

// A DHCP reply of this type for transaction xid, offering GUEST.
static size_t dhcp_reply(uint8_t type, uint32_t xid, uint32_t lease, bool truncated) {
  uint8_t b[300] = {};
  b[0] = 2, b[1] = 1, b[2] = 6;
  net_put32(b + 4, xid);
  net_put32(b + 16, GUEST);
  memcpy(b + 28, MAC, 6);
  net_put32(b + 236, 0x6382'5363);
  size_t o = 240;
  b[o++] = 53, b[o++] = 1, b[o++] = type;
  b[o++] = 54, b[o++] = 4, net_put32(b + o, HOST), o += 4;
  b[o++] = 1, b[o++] = 4, net_put32(b + o, 0xffff'ff00), o += 4;
  b[o++] = 3, b[o++] = 4, net_put32(b + o, HOST), o += 4;
  b[o++] = 6, b[o++] = 4, net_put32(b + o, DNS), o += 4;
  b[o++] = 51, b[o++] = 4, net_put32(b + o, lease), o += 4;
  if (truncated) {
    b[o++] = 12, b[o++] = 200; // a host name that runs past the end
    return udp_packet(HOST, 67, NET_BROADCAST, 68, b, o);
  }
  b[o++] = 255;
  return udp_packet(HOST, 67, NET_BROADCAST, 68, b, o);
}

// --- What the stack sent ---

static const uint8_t *last(void) { return sent_count ? sent[sent_count - 1] : nullptr; }

// The DHCP message type in a sent DHCP frame, or 0.
static uint8_t dhcp_type(const uint8_t *f, uint32_t *xid) {
  if (net_get16(f + 12) != 0x0800 || f[23] != 17 || net_get16(f + 36) != 67) return 0;
  const uint8_t *b = f + 42;
  *xid = net_get32(b + 4);
  return b[240] == 53 ? b[242] : 0;
}

static bool checksums_ok(const uint8_t *f, size_t len) {
  const uint8_t *ip = f + 14;
  size_t total = net_get16(ip + 2);
  if (14 + total > len || net_fold(net_sum(0, ip, 20)) != 0) return false;
  uint32_t src = net_get32(ip + 12), dst = net_get32(ip + 16);
  if (ip[9] == 1) return net_fold(net_sum(0, ip + 20, total - 20)) == 0;
  if (ip[9] == 17)
    return net_fold(net_sum(net_pseudo(src, dst, 17, (uint32_t)(total - 20)), ip + 20, total - 20)) == 0;
  return false;
}

// A new conversation; a failure is a failed check, and the slot is still safe to use.
static vx_net_conv *new_conv(uint8_t proto, uint32_t *id) {
  uint32_t i = 0;
  CHECK(vx_net_conv_new(&net, proto, &i) == VX_OK);
  if (id) *id = i;
  return &net.conv[i];
}

static void test_addresses(void) {
  uint32_t ip;
  char buf[16];
  CHECK(vx_net_parse_ip(VX_STR("10.0.2.15"), &ip) && ip == GUEST);
  CHECK(vx_net_parse_ip(VX_STR("255.255.255.255"), &ip) && ip == NET_BROADCAST);
  CHECK(!vx_net_parse_ip(VX_STR("10.0.2"), &ip) && !vx_net_parse_ip(VX_STR("10.0.2.256"), &ip));
  CHECK(!vx_net_parse_ip(VX_STR("10.0.2.15 "), &ip) && !vx_net_parse_ip(VX_STR("1.2.3.0004"), &ip));
  CHECK(!vx_net_parse_ip(VX_STR(""), &ip) && !vx_net_parse_ip(VX_STR("1..2.3"), &ip));
  size_t n = vx_net_format_ip(GUEST, buf);
  CHECK(n == 9 && memcmp(buf, "10.0.2.15", 9) == 0);
  n = vx_net_format_ip(0xc0a8'0064, buf);
  CHECK(n == 13 && memcmp(buf, "192.168.0.100", 13) == 0);
}

static void test_dhcp(void) {
  vx_instant now = 1000 * NET_SECOND;
  vx_net_init(&net, MAC, 1500, 42, capture, nullptr);
  sent_count = 0;
  vx_net_dhcp_start(&net, now);
  uint32_t xid = 0;
  CHECK(sent_count == 1 && dhcp_type(last(), &xid) == DHCP_DISCOVER && checksums_ok(last(), sent_len[0]));
  CHECK(memcmp(last(), NET_BROADCAST_MAC, 6) == 0 && net_get32(last() + 30) == NET_BROADCAST);

  // An offer for another transaction, or whose options run past the end, is ignored.
  vx_net_input(&net, in, dhcp_reply(DHCP_OFFER, xid + 1, 86400, false), now);
  vx_net_input(&net, in, dhcp_reply(DHCP_OFFER, xid, 86400, true), now);
  CHECK(sent_count == 1 && net.dhcp.state == VX_DHCP_SELECTING);

  // No answer: DISCOVER again, after 4 s, then 8 s.
  CHECK(vx_net_poll(&net, now) == now + 4 * NET_SECOND);
  CHECK(vx_net_poll(&net, now + 4 * NET_SECOND) == now + 12 * NET_SECOND && sent_count == 2);
  now += 4 * NET_SECOND;

  vx_net_input(&net, in, dhcp_reply(DHCP_OFFER, xid, 86400, false), now);
  uint32_t rxid = 0;
  CHECK(sent_count == 3 && dhcp_type(last(), &rxid) == DHCP_REQUEST && rxid == xid);
  CHECK(net.dhcp.state == VX_DHCP_REQUESTING && net.addr == 0);
  vx_net_input(&net, in, dhcp_reply(DHCP_ACK, xid, 86400, false), now);
  CHECK(net.dhcp.state == VX_DHCP_BOUND && net.addr == GUEST && net.mask == 0xffff'ff00 && net.gw == HOST);
  CHECK(net.dns == DNS && net.dhcp.lease == 86400);
  CHECK(vx_net_poll(&net, now) == now + 43200 * NET_SECOND); // T1: half the lease

  // At T1, a REQUEST to the server itself: its MAC first, by ARP; the request waits for the answer.
  now += 43200 * NET_SECOND;
  sent_count = 0;
  vx_net_poll(&net, now);
  CHECK(sent_count == 1 && net_get16(last() + 12) == 0x0806 && net_get32(last() + 38) == HOST);
  CHECK(net.dhcp.state == VX_DHCP_RENEWING);
  vx_net_input(&net, in, arp_packet(2, HOST, MAC, GUEST, MAC), now);
  CHECK(sent_count == 2 && dhcp_type(last(), &rxid) == DHCP_REQUEST && memcmp(last(), HOST_MAC, 6) == 0);
  CHECK(net_get32(last() + 42 + 12) == GUEST &&
        checksums_ok(last(), sent_len[1])); // ciaddr: the address renewed
  vx_net_input(&net, in, dhcp_reply(DHCP_ACK, rxid, 86400, false), now);
  CHECK(net.dhcp.state == VX_DHCP_BOUND && net.addr == GUEST);

  // No answer to renewals until the lease runs out: the address goes, and DISCOVER starts over.
  now += 43200 * NET_SECOND;
  vx_net_poll(&net, now);
  for (int i = 0; i < 20000 && net.dhcp.state != VX_DHCP_SELECTING; i++) now = vx_net_poll(&net, now);
  CHECK(net.dhcp.state == VX_DHCP_SELECTING && net.addr == 0);

  // A NAK while asking starts over too.
  vx_net_input(&net, in, dhcp_reply(DHCP_OFFER, net.dhcp.xid, 86400, false), now);
  CHECK(net.dhcp.state == VX_DHCP_REQUESTING);
  vx_net_input(&net, in, dhcp_reply(DHCP_NAK, net.dhcp.xid, 86400, false), now);
  CHECK(net.dhcp.state == VX_DHCP_SELECTING);
}

static void configured(void) {
  vx_net_init(&net, MAC, 1500, 7, capture, nullptr);
  vx_net_set_addr(&net, GUEST, 0xffff'ff00, HOST);
  sent_count = 0;
}

static void test_arp(void) {
  configured();
  vx_instant now = NET_SECOND;
  vx_net_input(&net, in, arp_packet(1, HOST, (const uint8_t[6]){}, GUEST, NET_BROADCAST_MAC), now);
  CHECK(sent_count == 1 && net_get16(last() + 20) == 2 && memcmp(last(), HOST_MAC, 6) == 0);
  CHECK(memcmp(last() + 22, MAC, 6) == 0 && net_get32(last() + 28) == GUEST &&
        net_get32(last() + 38) == HOST);
  CHECK(net_arp_slot(&net, HOST, false) &&
        net_arp_slot(&net, HOST, false)->resolved); // learned from the request

  // Another host's request: no answer, nothing learned (RFC 826).
  configured();
  vx_net_input(&net, in, arp_packet(1, HOST, (const uint8_t[6]){}, 0x0a00'0209, NET_BROADCAST_MAC), now);
  CHECK(sent_count == 0 && !net_arp_slot(&net, HOST, false));

  // A lookup nobody answers: three requests in all, a second apart, then the packet is dropped.
  vx_net_conv *c = new_conv(VX_NET_UDP, nullptr);
  CHECK(vx_net_conv_connect(&net, c, 0x0a00'0209, 53) == VX_OK);
  CHECK(vx_net_conv_write(&net, c, 0, 0, (const uint8_t *)"q", 1, now) == VX_OK && sent_count == 1);
  for (vx_instant next; (next = vx_net_poll(&net, now)) != NET_NEVER;) now = next;
  CHECK(sent_count == 3 && !net_arp_slot(&net, 0x0a00'0209, false) && net.stats.dropped == 1);

  // Off the subnet: the gateway's MAC.
  vx_net_input(&net, in, arp_packet(2, HOST, MAC, GUEST, MAC), now);
  sent_count = 0;
  CHECK(vx_net_conv_write(&net, c, 0x0808'0808, 53, (const uint8_t *)"q", 1, now) == VX_OK);
  CHECK(sent_count == 1 && memcmp(last(), HOST_MAC, 6) == 0 && net_get32(last() + 30) == 0x0808'0808);
}

static void test_icmp(void) {
  configured();
  vx_instant now = NET_SECOND;
  vx_net_input(&net, in, arp_packet(2, HOST, MAC, GUEST, MAC), now);
  uint8_t echo[16] = {8, 0, 0, 0, 0x12, 0x34, 0, 1, 'p', 'i', 'n', 'g', 'p', 'o', 'n', 'g'};
  net_put16(echo + 2, net_fold(net_sum(0, echo, sizeof echo)));
  sent_count = 0;
  vx_net_input(&net, in, ip_packet(HOST, GUEST, 1, echo, sizeof echo), now);
  CHECK(sent_count == 1 && last()[34] == 0 && net_get16(last() + 38) == 0x1234 &&
        checksums_ok(last(), sent_len[0]));
  CHECK(memcmp(last() + 42, "pingpong", 8) == 0 && net_get32(last() + 30) == HOST);

  // A corrupted request, and one to another address, get nothing.
  echo[9] ^= 1;
  vx_net_input(&net, in, ip_packet(HOST, GUEST, 1, echo, sizeof echo), now);
  echo[9] ^= 1;
  vx_net_input(&net, in, ip_packet(HOST, 0x0a00'0209, 1, echo, sizeof echo), now);
  CHECK(sent_count == 1 && net.stats.bad == 1);

  // A ping from a conversation: its identifier is the conversation's port; the reply comes back to it.
  vx_net_conv *c = new_conv(VX_NET_ICMP, nullptr);
  CHECK(vx_net_conv_connect(&net, c, HOST, 0) == VX_OK && c->lport);
  uint8_t req[12] = {8, 0, 0, 0, 0, 0, 0, 7, 'a', 'b', 'c', 'd'};
  CHECK(vx_net_conv_write(&net, c, 0, 0, req, sizeof req, now) == VX_OK && sent_count == 2);
  CHECK(net_get16(last() + 38) == c->lport && checksums_ok(last(), sent_len[1]));
  uint8_t reply[12];
  memcpy(reply, last() + 34, 12);
  reply[0] = 0;
  net_put16(reply + 2, 0);
  net_put16(reply + 2, net_fold(net_sum(0, reply, 12)));
  vx_net_input(&net, in, ip_packet(HOST, GUEST, 1, reply, 12), now);
  vx_net_datagram d;
  uint8_t buf[64];
  size_t got = 0;
  CHECK(vx_net_conv_read(c, &d, buf, sizeof buf, &got) && got == 12 && d.addr == HOST && buf[0] == 0 &&
        net_get16(buf + 6) == 7);
  CHECK(!vx_net_conv_read(c, &d, buf, sizeof buf, &got));

  // A reply with another identifier is not this conversation's.
  net_put16(reply + 4, (uint32_t)(c->lport + 1));
  net_put16(reply + 2, 0);
  net_put16(reply + 2, net_fold(net_sum(0, reply, 12)));
  vx_net_input(&net, in, ip_packet(HOST, GUEST, 1, reply, 12), now);
  CHECK(!vx_net_conv_read(c, &d, buf, sizeof buf, &got));
}

static void test_udp(void) {
  configured();
  vx_instant now = NET_SECOND;
  uint32_t a = 0, b = 0;
  vx_net_conv *ca = new_conv(VX_NET_UDP, &a), *cb = new_conv(VX_NET_UDP, &b);
  CHECK(vx_net_conv_announce(&net, ca, 7777) == VX_OK);
  CHECK(vx_net_conv_announce(&net, cb, 7777) == VX_ERR_EXISTS);
  CHECK(vx_net_conv_announce(&net, cb, 0) == VX_OK && cb->lport >= 49152);

  vx_net_input(&net, in, udp_packet(HOST, 5000, GUEST, 7777, (const uint8_t *)"hello", 5), now);
  vx_net_datagram d;
  uint8_t buf[64];
  size_t got = 0;
  CHECK(vx_net_conv_read(ca, &d, buf, sizeof buf, &got) && got == 5 && memcmp(buf, "hello", 5) == 0);
  CHECK(d.addr == HOST && d.port == 5000);

  // A bad checksum, a length past the packet, and a fragment are refused.
  size_t len = udp_packet(HOST, 5000, GUEST, 7777, (const uint8_t *)"hello", 5);
  in[len - 1] ^= 1;
  vx_net_input(&net, in, len, now);
  len = udp_packet(HOST, 5000, GUEST, 7777, (const uint8_t *)"hello", 5);
  net_put16(in + 38, 200);
  vx_net_input(&net, in, len, now);
  len = udp_packet(HOST, 5000, GUEST, 7777, (const uint8_t *)"hello", 5);
  net_put16(in + 20, 0x2000); // more fragments
  net_put16(in + 24, 0);
  net_put16(in + 24, net_fold(net_sum(0, in + 14, 20)));
  vx_net_input(&net, in, len, now);
  CHECK(!vx_net_conv_read(ca, &d, buf, sizeof buf, &got) && net.stats.bad == 2);

  // An IP length longer than the frame, and a header that claims to be longer than the packet.
  len = udp_packet(HOST, 5000, GUEST, 7777, (const uint8_t *)"hello", 5);
  vx_net_input(&net, in, len - 3, now);
  CHECK(!vx_net_conv_read(ca, &d, buf, sizeof buf, &got) && net.stats.bad == 3);

  // Connected: only from there.
  CHECK(vx_net_conv_connect(&net, ca, HOST, 6000) == VX_OK);
  vx_net_input(&net, in, udp_packet(HOST, 5000, GUEST, 7777, (const uint8_t *)"other", 5), now);
  vx_net_input(&net, in, udp_packet(HOST, 6000, GUEST, 7777, (const uint8_t *)"peer", 4), now);
  CHECK(vx_net_conv_read(ca, &d, buf, sizeof buf, &got) && got == 4 && d.port == 6000);
  CHECK(!vx_net_conv_read(ca, &d, buf, sizeof buf, &got));

  // A full queue drops; a short read loses the rest of its datagram only.
  static uint8_t big[1000];
  for (int i = 0; i < 20; i++)
    vx_net_input(&net, in, udp_packet(HOST, 6000, GUEST, 7777, big, sizeof big), now);
  CHECK(ca->dropped > 0);
  int count = 0;
  while (vx_net_conv_read(ca, &d, buf, 3, &got)) count++, CHECK(got == 3 && d.len == 1000);
  CHECK(count == 20 - (int)ca->dropped && ca->used == 0);

  // Sending: the payload, from our port, with a checksum the peer accepts.
  vx_net_input(&net, in, arp_packet(2, HOST, MAC, GUEST, MAC), now);
  sent_count = 0;
  CHECK(vx_net_conv_write(&net, ca, 0, 0, (const uint8_t *)"out", 3, now) == VX_OK && sent_count == 1);
  CHECK(net_get16(last() + 34) == 7777 && net_get16(last() + 36) == 6000 &&
        checksums_ok(last(), sent_len[0]));
  CHECK(vx_net_conv_write(&net, ca, 0, 0, big, 1473, now) == VX_ERR_RANGE); // past the MTU

  vx_net_conv_free(&net, a);
  CHECK(!vx_net_conv_get(&net, a) && vx_net_conv_get(&net, b));
}

int main(void) {
  test_addresses();
  test_dhcp();
  test_arp();
  test_icmp();
  test_udp();
  return check_result();
}
