// net_fuzz.c: arbitrary frames into lib/vx-net. The input is frames, each a
// big-endian 16-bit length and its bytes, with time passing between them. Two
// stacks take each: one in the middle of DHCP, one configured with an ICMP and
// a UDP conversation open, a TCP listener on 7777 and a TCP connect under way
// to 10.0.2.2!80. Whatever arrives, every frame sent must be a legal
// Ethernet frame whose IP header checksum holds, and no queue may grow past
// its size.

#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-net/net.c"

static void check_sent(void *ctx, const uint8_t *frame, size_t len) {
  (void)ctx;
  if (len < 60 || len > VX_ETHER_MAX_FRAME) abort();
  if (net_get16(frame + 12) == 0x0800) {
    size_t total = net_get16(frame + 16);
    if (frame[14] != 0x45 || total < 20 || 14 + total > len || net_fold(net_sum(0, frame + 14, 20)) != 0)
      abort();
  }
}

static void check_stack(const vx_net *n) {
  for (uint32_t i = 0; i < VX_NET_CONVS; i++) {
    const vx_net_conv *c = &n->conv[i];
    if (c->used > VX_NET_CONV_QUEUE || c->head >= VX_NET_CONV_QUEUE) abort();
    const vx_net_tcb *t = &c->tcb;
    if (t->rlen > VX_TCP_BUF || t->slen > VX_TCP_BUF || t->rhead >= VX_TCP_BUF || t->shead >= VX_TCP_BUF)
      abort();
    if (c->proto == VX_NET_TCP && t->state > VX_TCP_LAST_ACK) abort();
  }
  for (uint32_t i = 0; i < VX_NET_ARP_ENTRIES; i++)
    if (n->arp[i].queued > sizeof n->arp[i].packet) abort();
}

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  static vx_net dhcp, up;
  static const uint8_t mac[6] = {0x52, 0x54, 0, 0x12, 0x34, 0x56};
  vx_instant now = 1'000'000'000;
  vx_net_init(&dhcp, mac, 1500, 1, check_sent, nullptr);
  vx_net_dhcp_start(&dhcp, now);
  vx_net_init(&up, mac, 1500, 2, check_sent, nullptr);
  vx_net_set_addr(&up, 0x0a00'020f, 0xffff'ff00, 0x0a00'0202);
  uint32_t icmp = 0, udp = 0;
  vx_net_conv_new(&up, VX_NET_ICMP, &icmp);
  vx_net_conv_connect(&up, &up.conv[icmp], 0x0a00'0202, 0);
  vx_net_conv_new(&up, VX_NET_UDP, &udp);
  vx_net_conv_announce(&up, &up.conv[udp], 7777);
  uint32_t listener = 0, dial = 0;
  vx_net_conv_new(&up, VX_NET_TCP, &listener);
  vx_net_tcp_listen(&up, &up.conv[listener], 7777);
  vx_net_conv_new(&up, VX_NET_TCP, &dial);
  vx_net_tcp_connect(&up, &up.conv[dial], 0x0a00'0202, 80, now);

  for (size_t at = 0; at + 2 <= size;) {
    size_t len = net_get16(data + at);
    at += 2;
    if (len > size - at) len = size - at;
    vx_net_input(&dhcp, data + at, len, now);
    vx_net_input(&up, data + at, len, now);
    at += len;
    now += (vx_instant)(len & 0xff) * 100'000'000; // time passes: retransmissions and expiries happen
    vx_net_poll(&dhcp, now);
    vx_net_poll(&up, now);
    check_stack(&dhcp);
    check_stack(&up);
    // What the listener made can be taken, read from and written to.
    uint32_t id;
    static uint8_t stream[512];
    size_t moved;
    if (vx_net_tcp_accept(&up, &up.conv[listener], &id) == VX_OK) {
      vx_net_tcp_read(&up, &up.conv[id], stream, sizeof stream, &moved, now);
      vx_net_tcp_write(&up, &up.conv[id], stream, sizeof stream, &moved, now);
    }
  }
  // Whatever queued reads back whole.
  vx_net_datagram d;
  static uint8_t buf[VX_NET_CONV_QUEUE];
  size_t got;
  for (uint32_t i = 0; i < VX_NET_CONVS; i++)
    while (vx_net_conv_read(&up.conv[i], &d, buf, sizeof buf, &got))
      if (got != d.len) abort();
  return 0;
}
