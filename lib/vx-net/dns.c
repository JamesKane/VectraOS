// vx-net DNS: a stub resolver (RFC 1035), part of net.c, which includes it.
//
// A records only, from the server DHCP named (or one set by hand), over UDP
// from a random port with a random ID, so an off-path forger must guess
// both. Answers are cached for their TTL (5 s to a day); failures for 10 s.
// A lookup does not wait: vx_net_resolve answers SHOULD_WAIT while the query
// is out, and the caller asks again later, as netd does for a held write.
//
// A reply is hostile. Every length is checked against what arrived; names
// follow compression pointers only backwards, so they cannot loop; the
// question must be the one asked; and only A records for the name asked, or
// for a name a CNAME chain (at most 8 long) leads to from it, are taken.

static constexpr uint8_t DNS_TRIES = 3;
static constexpr vx_instant DNS_NEGATIVE = 10 * NET_SECOND;

// Normalizes a name for asking and comparing: lower case, no final dot.
// False unless it is one: labels of 1 to 63 letters, digits, '-' or '_', and
// 253 characters in all.
static bool dns_normalize(vx_str in, char *out, uint8_t *len) {
  if (in.len && in.ptr[in.len - 1] == '.') in.len--;
  if (!in.len || in.len > 253) return false;
  size_t label = 0;
  for (size_t i = 0; i < in.len; i++) {
    char c = in.ptr[i];
    if (c == '.') {
      if (!label) return false;
      label = 0;
    } else {
      bool ok =
          (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
      if (!ok || ++label > 63) return false;
      if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    }
    out[i] = c;
  }
  if (!label) return false;
  *len = (uint8_t)in.len;
  return true;
}

// Reads the name at `at` in message m, following compression pointers (each
// must point before where it was found), as normalized text. False if it is
// malformed. *end is where the name ends in place.
static bool dns_name(const uint8_t *m, size_t len, size_t at, char *out, uint8_t *outlen, size_t *end) {
  size_t n = 0, limit = at;
  bool jumped = false;
  for (int steps = 0; steps < 128; steps++) {
    if (at >= len) return false;
    uint8_t l = m[at];
    if ((l & 0xc0) == 0xc0) { // a pointer: two bytes, to somewhere earlier
      if (at + 1 >= len) return false;
      size_t to = (size_t)(l & 0x3f) << 8 | m[at + 1];
      if (!jumped) *end = at + 2;
      if (to >= limit) return false;
      jumped = true;
      at = limit = to;
      continue;
    }
    if (l & 0xc0) return false; // the reserved label types
    if (!l) {
      if (!jumped) *end = at + 1;
      if (n) n--; // the last dot
      *outlen = (uint8_t)n;
      return true;
    }
    if (at + 1 + l > len || n + l + 1 > 254) return false;
    for (size_t i = 0; i < l; i++) {
      char c = (char)m[at + 1 + i];
      out[n++] = c >= 'A' && c <= 'Z' ? (char)(c - 'A' + 'a') : c;
    }
    out[n++] = '.';
    at += 1 + l;
  }
  return false;
}

static bool dns_same(const char *a, uint8_t alen, const char *b, uint8_t blen) {
  return alen == blen && memcmp(a, b, alen) == 0;
}

// One resource record, read in place.
typedef struct dns_record {
  char name[256];
  uint8_t nlen;
  uint16_t type, class, rdlen;
  uint32_t ttl;
  size_t rdata;
} dns_record;

// Reads the record at *at, and moves *at past it. False if it runs past the message.
static bool dns_record_next(const uint8_t *m, size_t len, size_t *at, dns_record *r) {
  size_t next;
  if (!dns_name(m, len, *at, r->name, &r->nlen, &next) || next + 10 > len) return false;
  r->type = net_get16(m + next);
  r->class = net_get16(m + next + 2);
  r->ttl = net_get32(m + next + 4);
  r->rdlen = net_get16(m + next + 8);
  r->rdata = next + 10;
  if (r->rdata + r->rdlen > len) return false;
  *at = r->rdata + r->rdlen;
  return true;
}

static bool dns_in_chain(char chain[][256], const uint8_t *chain_len, uint32_t links, const dns_record *r) {
  for (uint32_t k = 0; k < links; k++)
    if (dns_same(r->name, r->nlen, chain[k], chain_len[k])) return true;
  return false;
}

static void dns_send(vx_net *n, vx_net_dns *e, vx_instant now) {
  uint8_t q[12 + 255 + 4] = {};
  net_put16(q, e->id);
  net_put16(q + 2, 0x0100); // a standard query; recursion desired
  net_put16(q + 4, 1);      // one question
  size_t at = 12, start = 0;
  for (size_t i = 0; i <= e->len; i++) {
    if (i == e->len || e->name[i] == '.') {
      q[at++] = (uint8_t)(i - start);
      memcpy(q + at, e->name + start, i - start);
      at += i - start;
      start = i + 1;
    }
  }
  q[at++] = 0;
  net_put16(q + at, 1);     // A
  net_put16(q + at + 2, 1); // IN
  at += 4;
  net_udp_out(n, n->addr, e->port, e->server, 53, q, at, now);
  e->next = now + (NET_SECOND << e->tries);
  e->tries++;
}

// A reply to one of our queries, if it is one: true if it was taken.
static bool net_dns_input(vx_net *n, uint32_t src, uint16_t dport, const uint8_t *m, size_t len,
                          vx_instant now) {
  vx_net_dns *e = nullptr;
  for (uint32_t i = 0; i < VX_DNS_ENTRIES; i++)
    if (n->dns_cache[i].pending && n->dns_cache[i].port == dport && n->dns_cache[i].server == src)
      e = &n->dns_cache[i];
  if (!e) return false;
  if (len < 12 || net_get16(m) != e->id || !(m[2] & 0x80) || net_get16(m + 4) != 1)
    return true; // not its answer
  // The question must be ours.
  char name[256];
  uint8_t nlen;
  size_t at;
  if (!dns_name(m, len, 12, name, &nlen, &at) || at + 4 > len || !dns_same(name, nlen, e->name, e->len) ||
      net_get16(m + at) != 1 || net_get16(m + at + 2) != 1)
    return true;
  at += 4;
  uint8_t rcode = m[3] & 15;
  e->pending = false;
  if (rcode) {
    e->status = rcode == 3 ? VX_ERR_NOT_FOUND : VX_ERR_REFUSED; // NXDOMAIN; the server failed or refused
    e->expires = now + DNS_NEGATIVE;
    return true;
  }
  // The names that lead to the answer: ours, then each CNAME target from it,
  // in whatever order the records come.
  static char chain[8][256];
  uint8_t chain_len[8];
  uint32_t links = 1;
  memcpy(chain[0], e->name, e->len);
  chain_len[0] = e->len;
  uint16_t answers = net_get16(m + 6);
  uint32_t ttl = 86400;
  dns_record r;
  for (uint32_t grew = 1; grew && links < 8;) {
    grew = 0;
    size_t walk = at;
    for (uint16_t a = 0; a < answers && dns_record_next(m, len, &walk, &r); a++) {
      if (r.class != 1 || r.type != 5 || !dns_in_chain(chain, chain_len, links, &r)) continue;
      char target[256];
      uint8_t tlen;
      size_t ignore;
      if (!dns_name(m, len, r.rdata, target, &tlen, &ignore)) continue;
      bool known = false;
      for (uint32_t k = 0; k < links; k++) known = known || dns_same(target, tlen, chain[k], chain_len[k]);
      if (known || links == 8) continue;
      memcpy(chain[links], target, tlen);
      chain_len[links++] = tlen;
      if (r.ttl < ttl) ttl = r.ttl;
      grew = 1;
    }
  }
  e->count = 0;
  size_t walk = at;
  for (uint16_t a = 0; a < answers && e->count < VX_DNS_ADDRS && dns_record_next(m, len, &walk, &r); a++) {
    if (r.class != 1 || r.type != 1 || r.rdlen != 4 || !dns_in_chain(chain, chain_len, links, &r)) continue;
    e->addrs[e->count++] = net_get32(m + r.rdata);
    if (r.ttl < ttl) ttl = r.ttl;
  }
  if (!e->count) {
    e->status = VX_ERR_NOT_FOUND; // the name has no address
    e->expires = now + DNS_NEGATIVE;
    return true;
  }
  if (ttl < 5) ttl = 5;
  e->status = VX_OK;
  e->expires = now + (vx_instant)ttl * NET_SECOND;
  return true;
}

// Retransmissions, and giving up. Returns the next deadline.
static vx_instant net_dns_poll(vx_net *n, vx_instant now) {
  vx_instant next = NET_NEVER;
  for (uint32_t i = 0; i < VX_DNS_ENTRIES; i++) {
    vx_net_dns *e = &n->dns_cache[i];
    if (!e->pending) continue;
    if (e->next <= now) {
      if (e->tries >= DNS_TRIES || !n->addr) {
        e->pending = false;
        e->status = VX_ERR_TIMED_OUT;
        e->expires = now + DNS_NEGATIVE;
        continue;
      }
      dns_send(n, e, now);
    }
    if (e->next < next) next = e->next;
  }
  return next;
}

// The addresses of `name` (a dotted quad is its own): up to cap of them in
// addrs, how many in *count. SHOULD_WAIT while the query is out: ask again
// after the stack has had its input and timers. NOT_FOUND: no such name, or
// no address; TIMED_OUT: no answer; BAD_STATE: no address or DNS server yet.
[[maybe_unused]] static vx_status vx_net_resolve(vx_net *n, vx_str name, uint32_t *addrs, uint32_t cap,
                                                 uint32_t *count, vx_instant now) {
  *count = 0;
  uint32_t ip;
  if (vx_net_parse_ip(name, &ip)) {
    if (cap) addrs[0] = ip, *count = 1;
    return VX_OK;
  }
  char norm[256];
  uint8_t len;
  if (!dns_normalize(name, norm, &len)) return VX_ERR_INVALID;
  vx_net_dns *e = nullptr, *victim = nullptr;
  for (uint32_t i = 0; i < VX_DNS_ENTRIES; i++) {
    vx_net_dns *d = &n->dns_cache[i];
    if (d->len && dns_same(d->name, d->len, norm, len)) e = d;
    bool reusable = !d->pending;
    if (reusable && (!victim || !d->len || d->expires < victim->expires)) victim = d;
  }
  if (e && e->pending) return VX_ERR_SHOULD_WAIT;
  if (e && e->expires > now) {
    if (e->status != VX_OK) return e->status;
    for (uint32_t i = 0; i < e->count && i < cap; i++) addrs[i] = e->addrs[i];
    *count = e->count < cap ? e->count : cap;
    return VX_OK;
  }
  if (!n->addr || !n->dns) return VX_ERR_BAD_STATE;
  if (!e) e = victim;
  if (!e) return VX_ERR_NO_MEMORY; // every entry is a query in flight
  *e = (vx_net_dns){.len = len, .pending = true, .server = n->dns};
  memcpy(e->name, norm, len);
  e->id = (uint16_t)net_random(n);
  e->port = net_free_port(n, VX_NET_UDP);
  dns_send(n, e, now);
  return VX_ERR_SHOULD_WAIT;
}
