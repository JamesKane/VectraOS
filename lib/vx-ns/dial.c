// vx-ns dialing: 9P over TCP (docs/02 §3.2, 04 §5 M3), through the
// namespace's own /net. A mount of tcp!HOST!PORT (or 9p://HOST:PORT) asks
// /net/cs where to dial, connects a /net/tcp conversation, and speaks 9P2000
// over its data file, each message framed by its size, as on any 9P
// stream. 9Px's extensions are for rings, so a TCP connection asks for none.
//
// A child cannot be handed a TCP connection as it is handed a ring
// connector, so its spawn records say dial=ADDRESS, and it dials its own
// (spawn.c). Within a process, mounts of one address share a connection.

#pragma once

#include "ns.c"

static constexpr uint32_t VX_NS_DIAL_MSIZE = 16384, VX_NS_DIALS = 4;

typedef struct vx_ns_dialed {
  p9_client c;
  bool used;
  char addr[VX_NS_MAX_SRC]; // as /net/cs was asked, for sharing
  uint8_t addr_len;
  vx_ns_file ctl, data;
  vx_mutex lock; // a stream carries one call at a time: threads take turns
  uint8_t tbuf[VX_NS_DIAL_MSIZE], rbuf[VX_NS_DIAL_MSIZE];
} vx_ns_dialed;

static vx_ns_dialed vx_ns_dials[VX_NS_DIALS];

static bool dial_read_all(vx_ns_file *f, uint8_t *buf, size_t len) {
  for (size_t got = 0; got < len;) {
    int64_t n = vx_ns_read(f, buf + got, (uint32_t)(len - got));
    if (n <= 0) return false; // the end of the stream, or an error
    got += (size_t)n;
  }
  return true;
}

static void vx_ns_dial_lock(void *ctx, bool take) {
  vx_ns_dialed *d = ctx;
  if (take)
    vx_mutex_lock(&d->lock);
  else
    vx_mutex_unlock(&d->lock);
}

// One 9P exchange over the stream: the request, then a reply as long as its
// size says. 0 if the connection is gone or the reply cannot be one.
static size_t vx_ns_dial_rpc(void *ctx, const uint8_t *req, size_t len, uint8_t *resp, size_t cap) {
  vx_ns_dialed *d = ctx;
  for (size_t sent = 0; sent < len;) { // a stream write may take part of it
    int64_t n = vx_ns_write(&d->data, req + sent, (uint32_t)(len - sent));
    if (n <= 0) return 0;
    sent += (size_t)n;
  }
  if (cap < 7 || !dial_read_all(&d->data, resp, 4)) return 0;
  uint32_t size =
      (uint32_t)resp[0] | (uint32_t)resp[1] << 8 | (uint32_t)resp[2] << 16 | (uint32_t)resp[3] << 24;
  if (size < 7 || size > cap || !dial_read_all(&d->data, resp + 4, size - 4)) return 0;
  return size;
}

static void dial_close(vx_ns_dialed *d) {
  vx_ns_close(&d->data);
  vx_ns_close(&d->ctl); // the conversation ends with its last file
  d->used = false;
}

// Whether c is a dialed connection; if so it is let go.
[[maybe_unused]] static bool vx_ns_dial_release(p9_client *c) {
  for (uint32_t i = 0; i < VX_NS_DIALS; i++)
    if (vx_ns_dials[i].used && &vx_ns_dials[i].c == c) {
      dial_close(&vx_ns_dials[i]);
      return true;
    }
  return false;
}

// Appends s at out[*n] (cap bytes in all); false if it does not fit.
static bool dial_put(char *out, size_t *n, size_t cap, vx_str s) {
  if (s.len > cap - *n) return false;
  for (size_t i = 0; i < s.len; i++) out[(*n)++] = s.ptr[i];
  return true;
}

// "9p://HOST:PORT" as "tcp!HOST!PORT"; anything else as it is.
static size_t dial_address(vx_str in, char *out, size_t cap) {
  vx_str scheme = VX_STR("9p://");
  if (in.len > scheme.len && memcmp(in.ptr, scheme.ptr, scheme.len) == 0) {
    vx_str rest = {in.ptr + scheme.len, in.len - scheme.len};
    size_t colon = rest.len;
    while (colon > 0 && rest.ptr[colon - 1] != ':') colon--;
    size_t n = 0;
    bool ok = colon > 1 && colon < rest.len && dial_put(out, &n, cap, VX_STR("tcp!")) &&
              dial_put(out, &n, cap, (vx_str){rest.ptr, colon - 1}) && dial_put(out, &n, cap, VX_STR("!")) &&
              dial_put(out, &n, cap, (vx_str){rest.ptr + colon, rest.len - colon});
    return ok ? n : 0;
  }
  if (in.len > cap) return 0;
  memcpy(out, in.ptr, in.len);
  return in.len;
}

// A 9P connection to addr (tcp!HOST!PORT or 9p://HOST:PORT), negotiated:
// the one this process has already, or a new one. Its address as dialed is
// in *src (what /net/cs was asked).
[[maybe_unused]] static vx_status vx_ns_dial(vx_ns *ns, vx_str addr, p9_client **c, vx_str *src) {
  char want[VX_NS_MAX_SRC];
  size_t wlen = dial_address(addr, want, sizeof want);
  if (!wlen) return VX_ERR_INVALID;
  vx_ns_dialed *d = nullptr;
  for (uint32_t i = 0; i < VX_NS_DIALS; i++) {
    vx_ns_dialed *k = &vx_ns_dials[i];
    if (k->used && k->addr_len == wlen && memcmp(k->addr, want, wlen) == 0) {
      *c = &k->c;
      *src = (vx_str){k->addr, k->addr_len};
      return VX_OK;
    }
    if (!k->used && !d) d = k;
  }
  if (!d) return VX_ERR_NO_MEMORY;

  // Where to dial: the connection server's first answer, "/net/tcp/clone ADDR!PORT".
  vx_ns_file cs;
  char line[128];
  vx_status st = vx_ns_open(ns, VX_STR("/net/cs"), P9_ORDWR, &cs);
  if (st != VX_OK) return st;
  int64_t n = vx_ns_write(&cs, want, (uint32_t)wlen);
  if (n >= 0) {
    cs.offset = 0;
    n = vx_ns_read(&cs, line, sizeof line);
  }
  vx_ns_close(&cs);
  if (n <= 0) return n < 0 ? (vx_status)n : VX_ERR_NOT_FOUND;
  size_t len = (size_t)n, space = 0;
  if (line[len - 1] == '\n') len--;
  while (space < len && line[space] != ' ') space++;
  if (space == len || space + 1 == len) return VX_ERR_INVALID;

  *d = (vx_ns_dialed){.used = true, .addr_len = (uint8_t)wlen};
  memcpy(d->addr, want, wlen);
  st = vx_ns_open(ns, (vx_str){line, space}, P9_ORDWR, &d->ctl);
  if (st != VX_OK) {
    d->used = false;
    return st;
  }
  char number[8];
  n = vx_ns_read(&d->ctl, number, sizeof number);
  char msg[96] = "connect ";
  size_t mlen = 8, dest = len - space - 1;
  if (n > 0 && dest < sizeof msg - mlen) {
    memcpy(msg + mlen, line + space + 1, dest);
    mlen += dest;
    int64_t w = vx_ns_write(&d->ctl, msg, (uint32_t)mlen); // returns once connected
    st = w < 0 ? (vx_status)w : VX_OK;
  } else {
    st = n < 0 ? (vx_status)n : VX_ERR_INVALID;
  }
  // The data file is beside the clone file: /net/tcp/N/data.
  char path[64];
  size_t dir = space;
  while (dir > 0 && line[dir - 1] != '/') dir--;
  size_t plen = 0;
  bool fits = dial_put(path, &plen, sizeof path, (vx_str){line, dir}) &&
              dial_put(path, &plen, sizeof path, (vx_str){number, n > 0 ? (size_t)n : 0}) &&
              dial_put(path, &plen, sizeof path, VX_STR("/data"));
  if (st == VX_OK && fits) {
    st = vx_ns_open(ns, (vx_str){path, plen}, P9_ORDWR, &d->data);
  } else if (st == VX_OK) {
    st = VX_ERR_INVALID;
  }
  if (st != VX_OK) {
    vx_ns_close(&d->ctl);
    d->used = false;
    return st;
  }
  // A Plan 9 server refuses "none" until a connection has authenticated; and
  // there are no user names before keyd (M10), so a dialed server sees this one.
  d->c = (p9_client){.rpc = vx_ns_dial_rpc,
                     .ctx = d,
                     .tbuf = d->tbuf,
                     .rbuf = d->rbuf,
                     .bufsize = sizeof d->tbuf,
                     .lock = vx_ns_dial_lock,
                     .uname = VX_STR("vectra")};
  st = p9c_version(&d->c, VX_NS_DIAL_MSIZE, 0);
  if (st != VX_OK) {
    dial_close(d);
    return st;
  }
  *c = &d->c;
  *src = (vx_str){d->addr, d->addr_len};
  return VX_OK;
}
