// dns_test.c: lib/vx-net's DNS stub resolver against hand-built replies:
// answers, the cache and its TTLs, CNAME chains in any order with compressed
// names, NXDOMAIN, retries and giving up; and replies that must be ignored:
// the wrong ID, port, server or question, and names that loop or run past
// the end of the message.

#include <string.h>

#include "check.h"
#include "../../lib/vx-net/net.c"

static const uint8_t MAC[6] = {0x52, 0x54, 0, 0x12, 0x34, 0x56}, PEER_MAC[6] = {0x52, 0x55, 10, 0, 2, 2};
static constexpr uint32_t GUEST = 0x0a00'020f, GW = 0x0a00'0202, DNS = 0x0a00'0203;

static vx_net net;
static vx_instant now;
static uint8_t last[VX_ETHER_MAX_FRAME];
static size_t last_len, sent;

static void capture(void *ctx, const uint8_t *frame, size_t len) {
  (void)ctx;
  memcpy(last, frame, len);
  last_len = len;
  sent++;
}

static void setup(void) {
  now = 1000 * NET_SECOND;
  vx_net_init(&net, MAC, 1500, 5, capture, nullptr);
  vx_net_set_addr(&net, GUEST, 0xffff'ff00, GW);
  net.dns = DNS;
  // The DNS server's MAC is known: queries go at once.
  uint8_t arp[42] = {};
  memcpy(arp, MAC, 6);
  memcpy(arp + 6, PEER_MAC, 6);
  net_put16(arp + 12, 0x0806);
  net_put16(arp + 14, 1), net_put16(arp + 16, 0x0800), arp[18] = 6, arp[19] = 4, net_put16(arp + 20, 2);
  memcpy(arp + 22, PEER_MAC, 6);
  net_put32(arp + 28, DNS);
  memcpy(arp + 32, MAC, 6);
  net_put32(arp + 38, GUEST);
  vx_net_input(&net, arp, sizeof arp, now);
  sent = 0;
}

// The last query sent: its ID, source port and name (as text).
static bool query(uint16_t *id, uint16_t *port, char *name) {
  if (!sent || net_get16(last + 12) != 0x0800 || last[23] != 17 || net_get16(last + 36) != 53) return false;
  *port = net_get16(last + 34);
  const uint8_t *m = last + 42;
  *id = net_get16(m);
  size_t at = 12, n = 0;
  while (m[at]) {
    memcpy(name + n, m + at + 1, m[at]);
    n += m[at];
    at += 1 + m[at];
    name[n++] = '.';
  }
  name[n ? n - 1 : 0] = 0;
  return net_get16(m + at + 1) == 1 && net_get16(m + at + 3) == 1;
}

// --- Building a reply ---

static uint8_t msg[1024];
static size_t mlen;

static void put_name(const char *name) {
  for (const char *p = name; *p;) {
    const char *dot = strchr(p, '.');
    size_t l = dot ? (size_t)(dot - p) : strlen(p);
    msg[mlen++] = (uint8_t)l;
    memcpy(msg + mlen, p, l);
    mlen += l;
    p += l + (dot != nullptr);
  }
  msg[mlen++] = 0;
}

static void begin(uint16_t id, uint8_t rcode, uint16_t answers, const char *qname) {
  memset(msg, 0, sizeof msg);
  net_put16(msg, id);
  msg[2] = 0x81, msg[3] = (uint8_t)(0x80 | rcode); // a response; recursion available
  net_put16(msg + 4, 1);
  net_put16(msg + 6, answers);
  mlen = 12;
  put_name(qname);
  net_put16(msg + mlen, 1), net_put16(msg + mlen + 2, 1);
  mlen += 4;
}

// A record's owner: a name, or (pointer >= 0) a pointer to one.
static void record(const char *owner, int pointer, uint16_t type, uint32_t ttl, const uint8_t *rdata,
                   uint16_t rdlen) {
  if (pointer >= 0)
    msg[mlen++] = (uint8_t)(0xc0 | pointer >> 8), msg[mlen++] = (uint8_t)pointer;
  else
    put_name(owner);
  net_put16(msg + mlen, type), net_put16(msg + mlen + 2, 1), net_put32(msg + mlen + 4, ttl);
  net_put16(msg + mlen + 8, rdlen);
  memcpy(msg + mlen + 10, rdata, rdlen);
  mlen += 10 + rdlen;
}

// Delivers the reply, from `server` to `port`.
static void reply(uint32_t server, uint16_t port) {
  static uint8_t f[1500];
  memcpy(f, MAC, 6);
  memcpy(f + 6, PEER_MAC, 6);
  net_put16(f + 12, 0x0800);
  uint8_t *ip = f + 14, *u = f + 34;
  memset(ip, 0, 20);
  ip[0] = 0x45, ip[8] = 64, ip[9] = 17;
  net_put16(ip + 2, (uint32_t)(28 + mlen));
  net_put32(ip + 12, server);
  net_put32(ip + 16, GUEST);
  net_put16(ip + 10, net_fold(net_sum(0, ip, 20)));
  net_put16(u, 53), net_put16(u + 2, port), net_put16(u + 4, (uint32_t)(8 + mlen)), net_put16(u + 6, 0);
  memcpy(u + 8, msg, mlen);
  vx_net_input(&net, f, 42 + mlen, now);
}

static vx_status resolve(const char *name, uint32_t *addrs, uint32_t *count) {
  return vx_net_resolve(&net, (vx_str){name, strlen(name)}, addrs, 4, count, now);
}

static void test_names(void) {
  setup();
  uint32_t a[4], n;
  CHECK(resolve("10.0.2.2", a, &n) == VX_OK && n == 1 && a[0] == GW && sent == 0); // no query
  CHECK(resolve("", a, &n) == VX_ERR_INVALID && resolve("a..b", a, &n) == VX_ERR_INVALID);
  CHECK(resolve("a b", a, &n) == VX_ERR_INVALID && resolve(".", a, &n) == VX_ERR_INVALID);
  CHECK(resolve("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.com", a, &n) ==
        VX_ERR_INVALID); // 64
  CHECK(sent == 0);
  net.dns = 0;
  CHECK(resolve("host.example", a, &n) == VX_ERR_BAD_STATE); // no server
}

static void test_answer_and_cache(void) {
  setup();
  uint32_t a[4], n;
  uint16_t id = 0, port = 0;
  char name[256];
  CHECK(resolve("Host.Example.", a, &n) == VX_ERR_SHOULD_WAIT);
  CHECK(query(&id, &port, name) && strcmp(name, "host.example") == 0 && port >= 49152);
  CHECK(resolve("host.example", a, &n) == VX_ERR_SHOULD_WAIT && sent == 1); // in flight: not asked twice

  // Forgeries are ignored: another ID, another port, another server, another question.
  uint8_t addr[4] = {1, 2, 3, 4};
  begin((uint16_t)(id + 1), 0, 1, "host.example");
  record(nullptr, 12, 1, 60, addr, 4);
  reply(DNS, port);
  begin(id, 0, 1, "host.example");
  record(nullptr, 12, 1, 60, addr, 4);
  reply(DNS, (uint16_t)(port + 1));
  reply(GW, port);
  begin(id, 0, 1, "other.example");
  record(nullptr, 12, 1, 60, addr, 4);
  reply(DNS, port);
  CHECK(resolve("host.example", a, &n) == VX_ERR_SHOULD_WAIT);

  begin(id, 0, 1, "HOST.example"); // a server may change the case
  record(nullptr, 12, 1, 60, addr, 4);
  reply(DNS, port);
  CHECK(resolve("host.example", a, &n) == VX_OK && n == 1 && a[0] == 0x0102'0304);
  size_t before = sent;
  now += 59 * NET_SECOND;
  CHECK(resolve("host.example", a, &n) == VX_OK && sent == before); // from the cache
  now += 2 * NET_SECOND;
  CHECK(resolve("host.example", a, &n) == VX_ERR_SHOULD_WAIT && sent == before + 1); // expired: asked again
}

static void test_cname_chain(void) {
  setup();
  uint32_t a[4], n;
  uint16_t id = 0, port = 0;
  char name[256];
  CHECK(resolve("www.example", a, &n) == VX_ERR_SHOULD_WAIT && query(&id, &port, name));
  // The A records come before the CNAME that makes them relevant, and one A
  // is for a name off the chain.
  uint8_t a1[4] = {5, 6, 7, 8}, a2[4] = {5, 6, 7, 9}, evil[4] = {6, 6, 6, 6};
  begin(id, 0, 4, "www.example");
  record("web.example", -1, 1, 300, a1, 4);
  size_t web = 12 + 13 + 4; // where web.example's name starts: after the question
  record(nullptr, (int)web, 1, 30, a2, 4);
  record("evil.example", -1, 1, 300, evil, 4);
  uint8_t target[16];
  size_t t = 0;
  target[t++] = 0xc0, target[t++] = (uint8_t)web; // the CNAME's target: compressed
  record(nullptr, 12, 5, 300, target, (uint16_t)t);
  reply(DNS, port);
  CHECK(resolve("www.example", a, &n) == VX_OK && n == 2 && a[0] == 0x0506'0708 && a[1] == 0x0506'0709);
  now += 31 * NET_SECOND;
  CHECK(resolve("www.example", a, &n) == VX_ERR_SHOULD_WAIT); // the shortest TTL on the chain ruled
}

static void test_failures(void) {
  setup();
  uint32_t a[4], n;
  uint16_t id = 0, port = 0;
  char name[256];
  // NXDOMAIN: not found, remembered for a while.
  CHECK(resolve("nothing.invalid", a, &n) == VX_ERR_SHOULD_WAIT && query(&id, &port, name));
  begin(id, 3, 0, "nothing.invalid");
  reply(DNS, port);
  size_t before = sent;
  CHECK(resolve("nothing.invalid", a, &n) == VX_ERR_NOT_FOUND && sent == before);
  now += 11 * NET_SECOND;
  CHECK(resolve("nothing.invalid", a, &n) == VX_ERR_SHOULD_WAIT);

  // A name with no address (NOERROR, no answers) is not found either.
  CHECK(resolve("empty.example", a, &n) == VX_ERR_SHOULD_WAIT && query(&id, &port, name));
  begin(id, 0, 0, "empty.example");
  reply(DNS, port);
  CHECK(resolve("empty.example", a, &n) == VX_ERR_NOT_FOUND);

  // No answer: asked three times (after 1 s, then 2 s), then timed out. A
  // fresh stack, so no other query's retries are counted.
  setup();
  CHECK(resolve("silent.example", a, &n) == VX_ERR_SHOULD_WAIT);
  before = sent;
  for (vx_instant next; resolve("silent.example", a, &n) == VX_ERR_SHOULD_WAIT;) {
    next = vx_net_poll(&net, now);
    if (next == NET_NEVER) break;
    now = next;
    vx_net_poll(&net, now);
  }
  CHECK(resolve("silent.example", a, &n) == VX_ERR_TIMED_OUT && sent == before + 2);
}

static void test_hostile(void) {
  setup();
  uint32_t a[4], n;
  uint16_t id = 0, port = 0;
  char name[256];
  CHECK(resolve("loop.example", a, &n) == VX_ERR_SHOULD_WAIT && query(&id, &port, name));
  uint8_t addr[4] = {9, 9, 9, 9};
  // An answer whose owner points at itself, and one that points forward: not taken.
  begin(id, 0, 2, "loop.example");
  size_t self = mlen;
  record(nullptr, (int)self, 1, 60, addr, 4);
  record(nullptr, 1000, 1, 60, addr, 4);
  reply(DNS, port);
  CHECK(resolve("loop.example", a, &n) == VX_ERR_NOT_FOUND); // answered, but nothing usable
  // A question whose name runs past the end: ignored, still waiting.
  CHECK(resolve("cut.example", a, &n) == VX_ERR_SHOULD_WAIT && query(&id, &port, name));
  begin(id, 0, 1, "cut.example");
  mlen = 16; // cut inside the name
  reply(DNS, port);
  CHECK(resolve("cut.example", a, &n) == VX_ERR_SHOULD_WAIT);
  // More answers claimed than there are: the ones there are count.
  begin(id, 0, 50, "cut.example");
  record(nullptr, 12, 1, 60, addr, 4);
  reply(DNS, port);
  CHECK(resolve("cut.example", a, &n) == VX_OK && n == 1 && a[0] == 0x0909'0909);
}

int main(void) {
  test_names();
  test_answer_and_cache();
  test_cname_chain();
  test_failures();
  test_hostile();
  return check_result();
}
