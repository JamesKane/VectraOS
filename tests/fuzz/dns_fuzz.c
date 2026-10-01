// dns_fuzz.c: arbitrary replies into lib/vx-net's DNS resolver. A query is
// put in flight, and the input becomes its reply (with the query's ID, from
// the server, to the port it was sent from), so the parser sees everything.
// Whatever arrives, at most VX_DNS_ADDRS addresses come back, and the
// resolver answers again without failing.

#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-net/net.c"

static void drop(void *ctx, const uint8_t *frame, size_t len) { (void)ctx, (void)frame, (void)len; }

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  static vx_net n;
  static const uint8_t mac[6] = {0x52, 0x54, 0, 0x12, 0x34, 0x56};
  vx_instant now = 1'000'000'000;
  vx_net_init(&n, mac, 1500, 3, drop, nullptr);
  vx_net_set_addr(&n, 0x0a00'020f, 0xffff'ff00, 0x0a00'0202);
  n.dns = 0x0a00'0203;
  uint32_t addrs[8], count;
  static const char name[] = "fuzz.example";
  if (vx_net_resolve(&n, (vx_str){name, sizeof name - 1}, addrs, 8, &count, now) != VX_ERR_SHOULD_WAIT)
    abort();
  const vx_net_dns *e = nullptr;
  for (uint32_t i = 0; i < VX_DNS_ENTRIES; i++)
    if (n.dns_cache[i].pending) e = &n.dns_cache[i];
  if (!e || size > 1400) return 0;

  static uint8_t f[1500];
  memset(f, 0, 42);
  memcpy(f, mac, 6);
  f[12] = 0x08;
  uint8_t *ip = f + 14, *u = f + 34;
  ip[0] = 0x45, ip[8] = 64, ip[9] = 17;
  net_put16(ip + 2, (uint32_t)(28 + size));
  net_put32(ip + 12, 0x0a00'0203);
  net_put32(ip + 16, 0x0a00'020f);
  net_put16(ip + 10, net_fold(net_sum(0, ip, 20)));
  net_put16(u, 53), net_put16(u + 2, e->port), net_put16(u + 4, (uint32_t)(8 + size));
  memcpy(u + 8, data, size);
  if (size >= 2) net_put16(u + 8, e->id); // its answer, as far as the ID goes
  vx_net_input(&n, f, 42 + size, now);

  vx_status st = vx_net_resolve(&n, (vx_str){name, sizeof name - 1}, addrs, 8, &count, now);
  if (count > VX_DNS_ADDRS || (st == VX_OK && !count)) abort();
  return 0;
}
