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
  vx_str uname; // who attaches; empty: "none"
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
  p9_msg t = {.type = P9_Tattach,
              .fid = c->next_fid++,
              .afid = P9_NOFID,
              .uname = c->uname.len ? c->uname : VX_STR("none"),
              .aname = aname};
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

// One Twalk of at most P9_MAXWELEM names from fid: the qid of each name it
// reached goes in qids, and how many in *nwqid. Only a walk that reaches every
// name makes newfid, as 9P has it. An error is the server's, for the first name.
[[maybe_unused]] static vx_status p9c_walk_names(p9_client *c, uint32_t fid, const vx_str *names,
                                                 uint16_t count, uint32_t *newfid, p9_qid *qids,
                                                 uint16_t *nwqid) {
  *nwqid = 0;
  if (count > P9_MAXWELEM) return VX_ERR_RANGE;
  p9_msg t = {.type = P9_Twalk, .fid = fid, .newfid = c->next_fid++, .nwname = count};
  for (uint16_t i = 0; i < count; i++) t.wname[i] = names[i];
  vx_status e = p9c_call(c, &t);
  if (e != VX_OK) return e;
  *nwqid = c->reply.nwqid <= count ? c->reply.nwqid : 0;
  for (uint16_t i = 0; i < *nwqid; i++) qids[i] = c->reply.wqid[i];
  if (*nwqid == count) *newfid = t.newfid;
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

// --- The posix and xattr extensions (docs/proto/posix.md) ---
//
// Each needs its extension negotiated (c->extensions); without it the call
// is UNSUPPORTED and sends nothing.

[[maybe_unused]] static vx_status p9c_getattr(p9_client *c, uint32_t fid, p9_attr *out) {
  if (!(c->extensions & P9_EXT_XATTR)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tgetattr, .fid = fid, .mask = P9_GETATTR_BASIC};
  vx_status e = p9c_call(c, &t);
  if (e == VX_OK) *out = c->reply.attr;
  return e;
}

[[maybe_unused]] static vx_status p9c_setattr(p9_client *c, uint32_t fid, const p9_setattr *a) {
  if (!(c->extensions & P9_EXT_XATTR)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tsetattr, .fid = fid, .setattr = *a};
  return p9c_call(c, &t);
}

// Renames olddir's entry oldname to newname in newdir, both on this connection.
[[maybe_unused]] static vx_status p9c_renameat(p9_client *c, uint32_t olddir, vx_str oldname, uint32_t newdir,
                                               vx_str newname) {
  if (!(c->extensions & P9_EXT_POSIX)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Trenameat, .fid = olddir, .name = oldname, .newfid = newdir, .name2 = newname};
  return p9c_call(c, &t);
}

[[maybe_unused]] static vx_status p9c_symlink(p9_client *c, uint32_t dir, vx_str name, vx_str target) {
  if (!(c->extensions & P9_EXT_POSIX)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tsymlink, .fid = dir, .name = name, .name2 = target};
  return p9c_call(c, &t);
}

// A symbolic link's target; it points into the reply buffer, until the next call.
[[maybe_unused]] static vx_status p9c_readlink(p9_client *c, uint32_t fid, vx_str *target) {
  if (!(c->extensions & P9_EXT_POSIX)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Treadlink, .fid = fid};
  vx_status e = p9c_call(c, &t);
  if (e == VX_OK) *target = c->reply.name2;
  return e;
}

[[maybe_unused]] static vx_status p9c_fsync(p9_client *c, uint32_t fid) {
  if (!(c->extensions & P9_EXT_POSIX)) return VX_OK; // a server without it has no later to write at
  p9_msg t = {.type = P9_Tfsync, .fid = fid};
  return p9c_call(c, &t);
}

// An open file shared between connections (posix): a token for `holds`
// joins of it.
[[maybe_unused]] static vx_status p9c_share(p9_client *c, uint32_t fid, uint32_t holds, uint8_t token[16]) {
  if (!(c->extensions & P9_EXT_POSIX)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tshare, .fid = fid, .holds = holds};
  vx_status e = p9c_call(c, &t);
  if (e == VX_OK) memcpy(token, c->reply.token, 16);
  return e;
}

// A new fid, open on the open file a token names (on this connection's server).
[[maybe_unused]] static vx_status p9c_join(p9_client *c, const uint8_t token[16], uint32_t *fid) {
  if (!(c->extensions & P9_EXT_POSIX)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tjoin, .newfid = c->next_fid++};
  memcpy(t.token, token, 16);
  vx_status e = p9c_call(c, &t);
  if (e == VX_OK) *fid = t.newfid;
  return e;
}

// Moves the open file's own offset (whence: set 0, current 1, end 2), and says where it is.
[[maybe_unused]] static vx_status p9c_seek(p9_client *c, uint32_t fid, int64_t offset, uint8_t whence,
                                           uint64_t *at) {
  if (!(c->extensions & P9_EXT_POSIX)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tseek, .fid = fid, .offset = (uint64_t)offset, .whence = whence};
  vx_status e = p9c_call(c, &t);
  if (e == VX_OK) *at = c->reply.offset;
  return e;
}

[[maybe_unused]] static vx_status p9c_append(p9_client *c, uint32_t fid, bool append) {
  if (!(c->extensions & P9_EXT_POSIX)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tdesc, .fid = fid, .desc_flags = append ? 1 : 0};
  return p9c_call(c, &t);
}

// A byte-range lock (P9_LOCK_*), owned by proc_id on this connection; length
// 0 is to the end. *status is P9_LOCK_SUCCESS, _BLOCKED or _ERROR.
[[maybe_unused]] static vx_status p9c_lock(p9_client *c, uint32_t fid, uint8_t type, uint64_t start,
                                           uint64_t length, uint32_t proc_id, uint8_t *status) {
  if (!(c->extensions & P9_EXT_POSIX)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tlock,
              .fid = fid,
              .lock_type = type,
              .start = start,
              .length = length,
              .proc_id = proc_id,
              .client_id = VX_STR("")};
  vx_status e = p9c_call(c, &t);
  if (e == VX_OK) *status = c->reply.status;
  return e;
}

// The first lock that would stop one of `type` over the range: its type,
// range and owner in *l, or P9_LOCK_UNLOCK as its type when none would.
[[maybe_unused]] static vx_status p9c_getlock(p9_client *c, uint32_t fid, uint8_t type, uint64_t start,
                                              uint64_t length, uint32_t proc_id, p9_msg *l) {
  if (!(c->extensions & P9_EXT_POSIX)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tgetlock,
              .fid = fid,
              .lock_type = type,
              .start = start,
              .length = length,
              .proc_id = proc_id,
              .client_id = VX_STR("")};
  vx_status e = p9c_call(c, &t);
  if (e == VX_OK) *l = c->reply;
  return e;
}
