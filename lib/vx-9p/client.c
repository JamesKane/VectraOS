// vx-9p client (docs/02 §3): one request at a time over any transport that
// can carry one message and return its reply. Pipelining (02 §3.3) comes with
// the ring transport (M2, step 4). Every reply is checked: its tag, that it
// answers the request's type, and an Rerror's text back into a vx_status.

#pragma once

#include "codec.c"

// Sends `len` bytes of request and fills `resp` (cap bytes) with the reply.
// Returns the reply's length, or 0 if the connection is gone.
typedef size_t (*p9_rpc_fn)(void *ctx, const uint8_t *req, size_t len, uint8_t *resp, size_t cap);

typedef struct p9_client {
  p9_rpc_fn rpc;
  void *ctx;
  uint8_t *tbuf, *rbuf; // each `bufsize` bytes, at least the msize asked for
  size_t bufsize;
  uint32_t msize; // negotiated
  p9_dialect dialect;
  uint32_t extensions; // negotiated
  uint16_t next_tag;
  uint32_t next_fid;
  p9_msg reply; // the last reply; its strings and data point into rbuf
} p9_client;

static vx_status p9c_call(p9_client *c, p9_msg *t) {
  if (t->type != P9_Tversion) t->tag = c->next_tag++ % P9_NOTAG; // NOTAG is Tversion's alone
  size_t n = p9_encode(t, c->tbuf, c->bufsize);
  if (!n) return VX_ERR_TOO_SMALL;
  size_t rn = c->rpc(c->ctx, c->tbuf, n, c->rbuf, c->bufsize);
  if (!rn) return VX_ERR_PEER_CLOSED;
  if (p9_decode(c->rbuf, rn, &c->reply) != VX_OK || c->reply.tag != t->tag) return VX_ERR_INVALID;
  if (c->reply.type == P9_Rerror) return p9_error_status(c->reply.ename);
  return c->reply.type == t->type + 1 ? VX_OK : VX_ERR_INVALID;
}

// Negotiates a session: 9Px with the given extensions, and an msize no larger
// than the buffers. A 9P2000 server answers 9P2000, and then extensions are 0.
[[maybe_unused]] static vx_status p9c_version(p9_client *c, uint32_t msize, uint32_t extensions) {
  char version[96];
  if (msize > c->bufsize) msize = (uint32_t)c->bufsize;
  p9_msg t = {.type = P9_Tversion, .tag = P9_NOTAG, .msize = msize};
  t.version = (vx_str){version, p9_version_format(P9_2000X, extensions, version, sizeof version)};
  vx_status e = p9c_call(c, &t);
  if (e != VX_OK) return e;
  c->dialect = p9_version_parse(c->reply.version, &c->extensions);
  c->extensions &= extensions;
  if (c->dialect == P9_UNKNOWN || c->reply.msize < P9_MIN_MSIZE || c->reply.msize > msize)
    return VX_ERR_UNSUPPORTED;
  c->msize = c->reply.msize;
  c->next_fid = 1;
  return VX_OK;
}

[[maybe_unused]] static vx_status p9c_attach(p9_client *c, vx_str aname, uint32_t *fid) {
  p9_msg t = {
      .type = P9_Tattach, .fid = c->next_fid++, .afid = P9_NOFID, .uname = VX_STR("none"), .aname = aname};
  vx_status e = p9c_call(c, &t);
  if (e == VX_OK) *fid = t.fid;
  return e;
}

[[maybe_unused]] static vx_status p9c_clunk(p9_client *c, uint32_t fid) {
  p9_msg t = {.type = P9_Tclunk, .fid = fid};
  return p9c_call(c, &t);
}

// Walks a '/'-separated path from fid to a new fid, in walks of at most 16
// names. An empty path clones the fid.
[[maybe_unused]] static vx_status p9c_walk(p9_client *c, uint32_t fid, vx_str path, uint32_t *newfid) {
  uint32_t from = fid, to = c->next_fid++;
  size_t i = 0;
  do {
    p9_msg t = {.type = P9_Twalk, .fid = from, .newfid = to};
    while (i < path.len && t.nwname < P9_MAXWELEM) {
      while (i < path.len && path.ptr[i] == '/') i++;
      size_t start = i;
      while (i < path.len && path.ptr[i] != '/') i++;
      if (i > start) t.wname[t.nwname++] = (vx_str){path.ptr + start, i - start};
    }
    vx_status e = p9c_call(c, &t);
    if (e == VX_OK && c->reply.nwqid != t.nwname) e = VX_ERR_NOT_FOUND; // stopped partway
    if (e != VX_OK) {
      if (from != fid) p9c_clunk(c, from);
      return e;
    }
    from = to; // later walks continue from the new fid, in place
  } while (i < path.len);
  *newfid = to;
  return VX_OK;
}

[[maybe_unused]] static vx_status p9c_open(p9_client *c, uint32_t fid, uint8_t mode) {
  p9_msg t = {.type = P9_Topen, .fid = fid, .mode = mode};
  return p9c_call(c, &t);
}

// Creates `name` in the directory fid, which then refers to the new file, open.
[[maybe_unused]] static vx_status p9c_create(p9_client *c, uint32_t fid, vx_str name, uint32_t perm,
                                             uint8_t mode) {
  p9_msg t = {.type = P9_Tcreate, .fid = fid, .name = name, .perm = perm, .mode = mode};
  return p9c_call(c, &t);
}

// Reads up to count bytes (at most msize - 24) at offset into buf. Returns how
// many, 0 at the end, or a negative vx_status.
[[maybe_unused]] static int64_t p9c_read(p9_client *c, uint32_t fid, uint64_t offset, void *buf,
                                         uint32_t count) {
  if (count > c->msize - P9_IOHDRSZ) count = c->msize - P9_IOHDRSZ;
  p9_msg t = {.type = P9_Tread, .fid = fid, .offset = offset, .count = count};
  vx_status e = p9c_call(c, &t);
  if (e != VX_OK) return e;
  if (c->reply.count > count) return VX_ERR_INVALID; // more than asked for
  for (uint32_t i = 0; i < c->reply.count; i++) ((uint8_t *)buf)[i] = c->reply.data.ptr[i];
  return c->reply.count;
}

// Writes up to count bytes (at most msize - 24). Returns how many, or a negative vx_status.
[[maybe_unused]] static int64_t p9c_write(p9_client *c, uint32_t fid, uint64_t offset, const void *buf,
                                          uint32_t count) {
  if (count > c->msize - P9_IOHDRSZ) count = c->msize - P9_IOHDRSZ;
  p9_msg t = {.type = P9_Twrite, .fid = fid, .offset = offset, .data = {buf, count}};
  vx_status e = p9c_call(c, &t);
  if (e != VX_OK) return e;
  return c->reply.count <= count ? (int64_t)c->reply.count : VX_ERR_INVALID;
}

// The fid's stat entry; its strings point into the client's reply buffer and
// last until the next call.
[[maybe_unused]] static vx_status p9c_stat(p9_client *c, uint32_t fid, p9_stat *out) {
  p9_msg t = {.type = P9_Tstat, .fid = fid};
  vx_status e = p9c_call(c, &t);
  if (e != VX_OK) return e;
  return p9_stat_decode(c->reply.stat.ptr, c->reply.stat.len, out);
}

[[maybe_unused]] static vx_status p9c_remove(p9_client *c, uint32_t fid) {
  p9_msg t = {.type = P9_Tremove, .fid = fid};
  return p9c_call(c, &t);
}
