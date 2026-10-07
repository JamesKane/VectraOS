// vx-9p client (docs/02 §3), over any transport: a serial one that carries
// one message and returns its reply (a TCP stream, a host test's loopback),
// or a pipelined one with several calls in flight (the ring, ring.c). Every
// reply is checked: its tag, that it answers the request's type, and an
// Rerror's text back into a vx_status.
//
// Each call has its own buffers for the length of the call (a p9_xfer): with
// a pipelined transport, so several threads can use one connection; with a
// serial one, the client's own pair, under the transport's lock if it has
// one. A call's reply is decoded where it landed, and what the caller keeps
// of it is copied out before the buffers go back (M6 step 6d4a).

#pragma once

#include "codec.c"

// Sends `len` bytes of request and fills `resp` (cap bytes) with the reply.
// Returns the reply's length, or 0 if the connection is gone.
typedef size_t (*p9_rpc_fn)(void *ctx, const uint8_t *req, size_t len, uint8_t *resp, size_t cap);

// One call's buffers and handles, the transport's for the length of the call.
typedef struct p9_xfer {
  uint8_t *req, *resp; // the request is encoded at req, and the reply lands at resp (one buffer, maybe)
  size_t cap;          // each, at least the msize
  uint16_t tag;        // the transport's choice (P9_NOTAG for Tversion)
  // The handle the reply carried (Rmap's VMO): the call that wants it takes
  // it, and the transport closes one not taken.
  vx_handle handle;
  // A handle for the request to carry (dref's VMO), which the transport
  // moves to the server, or closes if it cannot.
  vx_handle send_handle;
} p9_xfer;

// A transport with several calls in flight: a call's buffers from begin
// (waiting for some if all are in use; nullptr once the connection is gone),
// the call (the reply's length, or a negative vx_status: PEER_CLOSED,
// INTERRUPTED or TIMED_OUT for a call the transport flushed), and the
// buffers back with end.
typedef struct p9_pipe {
  p9_xfer *(*begin)(void *ctx, bool version);
  int64_t (*call)(void *ctx, p9_xfer *x, size_t len);
  void (*end)(void *ctx, p9_xfer *x);
} p9_pipe;

// Who a client attaches as when it names no one: the program's user (its
// spawn message's user=, which vx-ns sets here), or "none".
static vx_str p9c_user;

typedef struct p9_client {
  // A serial transport: rpc, with tbuf and rbuf (each `bufsize` bytes, at
  // least the msize asked for), and a lock if threads share it (take or
  // release; optional).
  p9_rpc_fn rpc;
  void *ctx;
  uint8_t *tbuf, *rbuf;
  size_t bufsize;
  void (*lock)(void *ctx, bool take);
  // Or a pipelined one, with ctx, instead.
  const p9_pipe *pipe;
  uint32_t msize; // negotiated
  p9_dialect dialect;
  uint32_t extensions; // negotiated
  uint16_t next_tag;   // a serial transport's
  uint32_t next_fid;   // taken atomically: threads share a connection
  vx_str uname;        // who attaches; empty: p9c_user, or "none"
  p9_xfer serial;      // a serial transport's one call
  // 9P2000.L (6d4c2): the directories open on it, whose reads are Treaddir
  // made into stat entries, each with the cookie and offset to go on from.
  uint32_t dirs_lock; // a spin lock: threads share a connection
  struct {
    uint32_t fid; // 0: free
    uint64_t cookie, at;
  } dirs[16];
} p9_client;

// A reply, decoded where it landed; its strings and data are the call's
// buffers', until p9c_done.
typedef struct p9_rcall {
  p9_msg r;
  p9_xfer *x;
} p9_rcall;

static uint32_t p9c_fid(p9_client *c) { return __atomic_fetch_add(&c->next_fid, 1, __ATOMIC_RELAXED); }

static p9_xfer *p9c_begin(p9_client *c, bool version) {
  if (c->pipe) return c->pipe->begin(c->ctx, version);
  if (c->lock) c->lock(c->ctx, true);
  c->serial = (p9_xfer){.req = c->tbuf, .resp = c->rbuf, .cap = c->bufsize};
  c->serial.tag = version ? P9_NOTAG : c->next_tag++ % P9_NOTAG; // NOTAG is Tversion's alone
  return &c->serial;
}

// The call's buffers back.
static void p9c_done(p9_client *c, p9_rcall *rc) {
  if (!rc->x) return;
  if (c->pipe)
    c->pipe->end(c->ctx, rc->x);
  else if (c->lock)
    c->lock(c->ctx, false);
  rc->x = nullptr;
}

// Sends t, with `send` for the request to carry (or VX_HANDLE_NONE), and
// waits for its reply, in rc->r until p9c_done, which the caller calls
// whatever this returns.
static vx_status p9c_rpc(p9_client *c, p9_msg *t, p9_rcall *rc, vx_handle send) {
  p9_xfer *x = rc->x = p9c_begin(c, t->type == P9_Tversion);
  if (!x) return VX_ERR_PEER_CLOSED; // a pipelined connection, gone (and send with it, the caller's)
  x->send_handle = send;
  t->tag = x->tag;
  size_t n = p9_encode(t, x->req, x->cap);
  if (!n) return VX_ERR_TOO_SMALL;
  int64_t rn = c->pipe ? c->pipe->call(c->ctx, x, n) : (int64_t)c->rpc(c->ctx, x->req, n, x->resp, x->cap);
  if (rn == 0) return VX_ERR_PEER_CLOSED;
  if (rn < 0) return (vx_status)rn;
  if (p9_decode(x->resp, (size_t)rn, &rc->r) != VX_OK || rc->r.tag != t->tag) return VX_ERR_INVALID;
  if (rc->r.type == P9_Rerror) return p9_error_status(rc->r.ename);
  if (rc->r.type == P9_Rlerror) return p9_errno_status(rc->r.ecode); // 9P2000.L's: an errno
  return rc->r.type == t->type + 1 ? VX_OK : VX_ERR_INVALID;
}

// A call whose reply says nothing the caller keeps.
static vx_status p9c_call(p9_client *c, p9_msg *t) {
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, t, &rc, VX_HANDLE_NONE);
  p9c_done(c, &rc);
  return e;
}

// --- 9P2000.L's directory reads (6d4c2) ---

static bool p9c_dotl(const p9_client *c) { return c->dialect == P9_2000L; }

static void p9c_dirs_lock(p9_client *c) {
  while (__atomic_exchange_n(&c->dirs_lock, 1, __ATOMIC_ACQUIRE)) {}
}
static void p9c_dirs_unlock(p9_client *c) { __atomic_store_n(&c->dirs_lock, 0, __ATOMIC_RELEASE); }

// fid's slot in the table, or -1; with add, a free one taken for it.
static int p9c_dir_slot(p9_client *c, uint32_t fid, bool add) {
  int free = -1;
  for (int i = 0; i < 16; i++) {
    if (c->dirs[i].fid == fid) return i;
    if (!c->dirs[i].fid && free < 0) free = i;
  }
  if (add && free >= 0) c->dirs[free].fid = fid, c->dirs[free].cookie = c->dirs[free].at = 0;
  return add ? free : -1;
}

static void p9c_dir_note(p9_client *c, uint32_t fid, bool dir) {
  p9c_dirs_lock(c);
  int i = p9c_dir_slot(c, fid, dir);
  if (!dir && i >= 0) c->dirs[i].fid = 0;
  p9c_dirs_unlock(c);
}

// One Tversion of dialect d: what the server answers, in c.
static vx_status p9c_version_as(p9_client *c, uint32_t msize, p9_dialect d, uint32_t extensions) {
  char version[96];
  p9_msg t = {.type = P9_Tversion, .tag = P9_NOTAG, .msize = msize};
  t.version = (vx_str){version, p9_version_format(d, extensions, version, sizeof version)};
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  if (e == VX_OK) {
    c->dialect = p9_version_parse(rc.r.version, &c->extensions);
    c->extensions &= extensions;
    if (c->dialect == P9_UNKNOWN || rc.r.msize < P9_MIN_MSIZE || rc.r.msize > msize)
      e = VX_ERR_UNSUPPORTED;
    else
      c->msize = rc.r.msize, c->next_fid = 1;
  }
  p9c_done(c, &rc);
  return e;
}

// Negotiates a session: 9Px with the given extensions, and an msize no larger
// than the buffers. A 9P2000 server answers 9P2000, and then extensions are
// 0. One that answers "unknown" is asked for 9P2000.L (diod, QEMU's virtfs:
// Linux's dialect), then for plain 9P2000 (02 §3.1).
[[maybe_unused]] static vx_status p9c_version(p9_client *c, uint32_t msize, uint32_t extensions) {
  if (msize > c->bufsize) msize = (uint32_t)c->bufsize;
  vx_status e = p9c_version_as(c, msize, P9_2000X, extensions);
  if (e == VX_ERR_UNSUPPORTED && c->dialect == P9_UNKNOWN) e = p9c_version_as(c, msize, P9_2000L, 0);
  if (e == VX_ERR_UNSUPPORTED && c->dialect == P9_UNKNOWN) e = p9c_version_as(c, msize, P9_2000, 0);
  return e;
}

// Attaches to aname: the new fid, and the root's qid if qid is not nullptr.
[[maybe_unused]] static vx_status p9c_attach_qid(p9_client *c, vx_str aname, uint32_t *fid, p9_qid *qid) {
  vx_str uname = p9c_user.len ? p9c_user : VX_STR("none");
  if (c->uname.len) uname = c->uname;
  p9_msg t = {.type = P9_Tattach, .fid = p9c_fid(c), .afid = P9_NOFID, .uname = uname, .aname = aname};
  if (p9c_dotl(c)) t.has_n_uname = true, t.n_uname = P9_NONUNAME; // by name, as there are no numbers to give
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  if (e == VX_OK) *fid = t.fid;
  if (e == VX_OK && qid) *qid = rc.r.qid;
  p9c_done(c, &rc);
  return e;
}

[[maybe_unused]] static vx_status p9c_attach(p9_client *c, vx_str aname, uint32_t *fid) {
  return p9c_attach_qid(c, aname, fid, nullptr);
}

[[maybe_unused]] static vx_status p9c_clunk(p9_client *c, uint32_t fid) {
  p9_msg t = {.type = P9_Tclunk, .fid = fid};
  if (p9c_dotl(c)) p9c_dir_note(c, fid, false);
  return p9c_call(c, &t);
}

// Walks a '/'-separated path from fid to a new fid, in walks of at most 16
// names. An empty path clones the fid.
[[maybe_unused]] static vx_status p9c_walk(p9_client *c, uint32_t fid, vx_str path, uint32_t *newfid) {
  uint32_t from = fid, to = p9c_fid(c);
  size_t i = 0;
  do {
    p9_msg t = {.type = P9_Twalk, .fid = from, .newfid = to};
    while (i < path.len && t.nwname < P9_MAXWELEM) {
      while (i < path.len && path.ptr[i] == '/') i++;
      size_t start = i;
      while (i < path.len && path.ptr[i] != '/') i++;
      if (i > start) t.wname[t.nwname++] = (vx_str){path.ptr + start, i - start};
    }
    p9_rcall rc = {};
    vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
    if (e == VX_OK && rc.r.nwqid != t.nwname) e = VX_ERR_NOT_FOUND; // stopped partway
    p9c_done(c, &rc);
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
  p9_msg t = {.type = P9_Twalk, .fid = fid, .newfid = p9c_fid(c), .nwname = count};
  for (uint16_t i = 0; i < count; i++) t.wname[i] = names[i];
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  if (e == VX_OK) {
    *nwqid = rc.r.nwqid <= count ? rc.r.nwqid : 0;
    for (uint16_t i = 0; i < *nwqid; i++) qids[i] = rc.r.wqid[i];
    if (*nwqid == count) *newfid = t.newfid;
  }
  p9c_done(c, &rc);
  return e;
}

// Linux's open flags from a 9P mode (9P2000.L's Tlopen and Tlcreate).
static uint32_t p9c_flags_of_mode(uint8_t mode) {
  uint32_t flags = 0; // O_RDONLY, for OREAD and OEXEC
  if ((mode & 3) == P9_OWRITE) flags = 1;
  if ((mode & 3) == P9_ORDWR) flags = 2;
  if (mode & P9_OTRUNC) flags |= P9_L_O_TRUNC;
  return flags;
}

// Tlopen: Topen in 9P2000.L's words; a directory open is noted for its reads.
static vx_status p9c_lopen(p9_client *c, uint32_t fid, uint8_t mode) {
  if (mode & P9_ORCLOSE) return VX_ERR_UNSUPPORTED; // .L has no remove-on-close
  p9_msg t = {.type = P9_Tlopen, .fid = fid, .lflags = p9c_flags_of_mode(mode)};
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  if (e == VX_OK) p9c_dir_note(c, fid, rc.r.qid.type & P9_QTDIR);
  p9c_done(c, &rc);
  return e;
}

[[maybe_unused]] static vx_status p9c_open(p9_client *c, uint32_t fid, uint8_t mode) {
  if (p9c_dotl(c)) return p9c_lopen(c, fid, mode);
  p9_msg t = {.type = P9_Topen, .fid = fid, .mode = mode};
  return p9c_call(c, &t);
}

// Creates `name` in the directory fid, which then refers to the new file,
// open. Under 9P2000.L a file is Tlcreate's, and a directory Tmkdir's, then
// walked to and opened.
[[maybe_unused]] static vx_status p9c_create(p9_client *c, uint32_t fid, vx_str name, uint32_t perm,
                                             uint8_t mode) {
  if (p9c_dotl(c) && (perm & ~(P9_DMDIR | 0777))) return VX_ERR_UNSUPPORTED; // DMAPPEND and the rest
  if (p9c_dotl(c) && (perm & P9_DMDIR)) {
    p9_msg t = {.type = P9_Tmkdir, .fid = fid, .name = name, .lmode = perm & 0777};
    vx_status e = p9c_call(c, &t);
    if (e != VX_OK) return e;
    p9_msg w = {.type = P9_Twalk, .fid = fid, .newfid = fid, .nwname = 1, .wname = {name}};
    if ((e = p9c_call(c, &w)) != VX_OK) return e;
    return p9c_lopen(c, fid, mode);
  }
  if (p9c_dotl(c)) {
    if (mode & P9_ORCLOSE) return VX_ERR_UNSUPPORTED;
    p9_msg t = {.type = P9_Tlcreate,
                .fid = fid,
                .name = name,
                .lflags = p9c_flags_of_mode(mode),
                .lmode = perm & 0777};
    return p9c_call(c, &t);
  }
  p9_msg t = {.type = P9_Tcreate, .fid = fid, .name = name, .perm = perm, .mode = mode};
  return p9c_call(c, &t);
}

// Reads up to count bytes (at most msize - 24) at offset into buf. Returns how
// many, 0 at the end, or a negative vx_status.
// A Treaddir entry's type as a 9P mode: the type, and permissions it does
// not carry (any reader may stat the file for its own).
static uint32_t p9c_mode_of_dirent(uint8_t type) {
  if (type == P9_DT_DIR) return P9_DMDIR | 0755;
  if (type == P9_DT_LNK) return P9_DMSYMLINK | 0777;
  return 0644;
}

// POSIX's file type as 9P's mode bits.
static uint32_t p9c_type_bits(uint32_t type) {
  if (type == P9_S_IFDIR) return P9_DMDIR;
  if (type == P9_S_IFLNK) return P9_DMSYMLINK;
  if (type == P9_S_IFCHR) return P9_DMDEVICE;
  return 0;
}

// A directory's read under 9P2000.L: Treaddir from the cookie the last read
// ended at, its entries written into buf as 9P2000's stat entries (whole,
// as a directory read has them), each with its type in its mode and nothing
// else; offset 0, or where the last read ended (9P2000's rule).
static int64_t p9c_readdir_as_stat(p9_client *c, int slot, uint64_t offset, uint8_t *buf, uint32_t count) {
  p9c_dirs_lock(c);
  uint32_t fid = c->dirs[slot].fid;
  uint64_t cookie = c->dirs[slot].cookie, at = c->dirs[slot].at;
  p9c_dirs_unlock(c);
  if (offset == 0) cookie = at = 0;
  if (offset != at) return VX_ERR_RANGE;
  // A dirent is 24 bytes and its name; a stat entry 49 and the name: ask
  // for what will fit made over.
  uint32_t ask = count / 2 < c->msize - P9_IOHDRSZ ? count / 2 : c->msize - P9_IOHDRSZ;
  p9_msg t = {.type = P9_Treaddir, .fid = fid, .offset = cookie, .count = ask};
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  uint32_t used = 0;
  bool overflow = false; // an entry did not fit
  if (e == VX_OK) {
    p9_in in = {.buf = rc.r.data.ptr, .len = rc.r.data.len};
    while (in.pos < in.len && !in.failed) {
      p9_qid q = p9_get_qid(&in);
      uint64_t next = p9_get(&in, 8);
      uint8_t type = (uint8_t)p9_get(&in, 1);
      vx_str name = p9_get_str(&in);
      if (in.failed) break;
      p9_stat st = {.qid = q, .mode = p9c_mode_of_dirent(type), .name = name};
      size_t n = p9_stat_encode(&st, buf + used, count - used);
      if (!n) {
        overflow = true;
        break;
      }
      used += (uint32_t)n, cookie = next;
    }
    if (used == 0 && overflow) e = VX_ERR_TOO_SMALL; // not one entry fits, the last one too
  }
  p9c_done(c, &rc);
  if (e != VX_OK) return e;
  p9c_dirs_lock(c);
  if (c->dirs[slot].fid == fid) c->dirs[slot].cookie = cookie, c->dirs[slot].at = at + used;
  p9c_dirs_unlock(c);
  return used;
}

[[maybe_unused]] static int64_t p9c_read(p9_client *c, uint32_t fid, uint64_t offset, void *buf,
                                         uint32_t count) {
  if (p9c_dotl(c)) {
    p9c_dirs_lock(c);
    int slot = p9c_dir_slot(c, fid, false);
    p9c_dirs_unlock(c);
    if (slot >= 0) return p9c_readdir_as_stat(c, slot, offset, buf, count);
  }
  if (count > c->msize - P9_IOHDRSZ) count = c->msize - P9_IOHDRSZ;
  p9_msg t = {.type = P9_Tread, .fid = fid, .offset = offset, .count = count};
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  int64_t n = e;
  if (e == VX_OK && rc.r.count > count) n = VX_ERR_INVALID; // more than asked for
  if (e == VX_OK && rc.r.count <= count) {
    for (uint32_t i = 0; i < rc.r.count; i++) ((uint8_t *)buf)[i] = rc.r.data.ptr[i];
    n = rc.r.count;
  }
  p9c_done(c, &rc);
  return n;
}

// Writes up to count bytes (at most msize - 24). Returns how many, or a negative vx_status.
[[maybe_unused]] static int64_t p9c_write(p9_client *c, uint32_t fid, uint64_t offset, const void *buf,
                                          uint32_t count) {
  if (count > c->msize - P9_IOHDRSZ) count = c->msize - P9_IOHDRSZ;
  p9_msg t = {.type = P9_Twrite, .fid = fid, .offset = offset, .data = {buf, count}};
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  int64_t n = e;
  if (e == VX_OK) n = rc.r.count <= count ? (int64_t)rc.r.count : VX_ERR_INVALID;
  p9c_done(c, &rc);
  return n;
}

// Room for a stat entry's strings, which p9c_stat copies there.
typedef struct p9_stat_text {
  uint8_t bytes[1024];
} p9_stat_text;

// The fid's stat entry. Its strings are in *keep, or empty if keep is
// nullptr (TOO_SMALL if they do not fit).
static vx_status p9c_getattr(p9_client *c, uint32_t fid, p9_attr *out);

[[maybe_unused]] static vx_status p9c_stat(p9_client *c, uint32_t fid, p9_stat *out, p9_stat_text *keep) {
  if (p9c_dotl(c)) { // 9P2000.L has no Tstat: Tgetattr's, without a name (it carries none)
    (void)keep;
    p9_attr a;
    vx_status e = p9c_getattr(c, fid, &a);
    if (e != VX_OK) return e;
    uint32_t bits = p9c_type_bits(a.mode & P9_S_IFMT);
    *out = (p9_stat){.qid = a.qid,
                     .mode = bits | (a.mode & 0777),
                     .atime = (uint32_t)a.atime_sec,
                     .mtime = (uint32_t)a.mtime_sec,
                     .length = a.size};
    return VX_OK;
  }
  p9_msg t = {.type = P9_Tstat, .fid = fid};
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  if (e == VX_OK && keep && rc.r.stat.len > sizeof keep->bytes) e = VX_ERR_TOO_SMALL;
  if (e == VX_OK && keep) {
    for (size_t i = 0; i < rc.r.stat.len; i++) keep->bytes[i] = rc.r.stat.ptr[i];
    e = p9_stat_decode(keep->bytes, rc.r.stat.len, out);
  } else if (e == VX_OK) {
    e = p9_stat_decode(rc.r.stat.ptr, rc.r.stat.len, out);
    out->name = out->uid = out->gid = out->muid = (vx_str){};
  }
  p9c_done(c, &rc);
  return e;
}

// A stat entry that changes nothing: every field "don't touch" (all ones, or
// empty), for Twstat to change only what the caller then sets.
[[maybe_unused]] static p9_stat p9_stat_untouched(void) {
  return (p9_stat){.type = 0xffff,
                   .dev = UINT32_MAX,
                   .qid = {0xff, UINT32_MAX, UINT64_MAX},
                   .mode = UINT32_MAX,
                   .atime = UINT32_MAX,
                   .mtime = UINT32_MAX,
                   .length = UINT64_MAX};
}

// Twstat: what w's fields say, all or none (p9_stat_untouched for the rest).
[[maybe_unused]] static vx_status p9c_wstat(p9_client *c, uint32_t fid, const p9_stat *w) {
  uint8_t entry[512];
  size_t n = p9_stat_encode(w, entry, sizeof entry);
  if (!n) return VX_ERR_TOO_SMALL;
  p9_msg t = {.type = P9_Twstat, .fid = fid, .stat = {entry, n}};
  return p9c_call(c, &t);
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
  if (!(c->extensions & P9_EXT_XATTR) && !p9c_dotl(c)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tgetattr, .fid = fid, .mask = P9_GETATTR_BASIC};
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  if (e == VX_OK) *out = rc.r.attr;
  p9c_done(c, &rc);
  return e;
}

// Without the xattr extension, as Twstat (a 9P2000 server: 9front, u9fs):
// the mode's permission bits, the size, and times given; an owner, a group
// or a time "now" is UNSUPPORTED there (the caller gives the time).
[[maybe_unused]] static vx_status p9c_setattr(p9_client *c, uint32_t fid, const p9_setattr *a) {
  if ((c->extensions & P9_EXT_XATTR) || p9c_dotl(c)) {
    p9_msg t = {.type = P9_Tsetattr, .fid = fid, .setattr = *a};
    return p9c_call(c, &t);
  }
  constexpr uint32_t can = P9_SETATTR_MODE | P9_SETATTR_SIZE | P9_SETATTR_ATIME | P9_SETATTR_ATIME_SET |
                           P9_SETATTR_MTIME | P9_SETATTR_MTIME_SET;
  if ((a->valid & ~can) || ((a->valid & P9_SETATTR_ATIME) && !(a->valid & P9_SETATTR_ATIME_SET)) ||
      ((a->valid & P9_SETATTR_MTIME) && !(a->valid & P9_SETATTR_MTIME_SET)))
    return VX_ERR_UNSUPPORTED;
  p9_stat w = p9_stat_untouched();
  if (a->valid & P9_SETATTR_MODE) {
    p9_stat cur;
    vx_status e = p9c_stat(c, fid, &cur, nullptr); // its type bits stay
    if (e != VX_OK) return e;
    w.mode = (cur.mode & ~0777u) | (a->mode & 0777);
  }
  if (a->valid & P9_SETATTR_SIZE) w.length = a->size;
  if (a->valid & P9_SETATTR_ATIME_SET) w.atime = (uint32_t)a->atime_sec;
  if (a->valid & P9_SETATTR_MTIME_SET) w.mtime = (uint32_t)a->mtime_sec;
  return p9c_wstat(c, fid, &w);
}

// Renames dir's entry oldname to newname in the same directory, by Twstat:
// a 9P2000 server's rename. Unlike POSIX's, it fails if newname is there.
[[maybe_unused]] static vx_status p9c_rename_wstat(p9_client *c, uint32_t dir, vx_str oldname,
                                                   vx_str newname) {
  uint32_t fid;
  vx_status e = p9c_walk(c, dir, oldname, &fid);
  if (e != VX_OK) return e;
  p9_stat w = p9_stat_untouched();
  w.name = newname;
  e = p9c_wstat(c, fid, &w);
  p9c_clunk(c, fid);
  return e;
}

// Renames olddir's entry oldname to newname in newdir, both on this connection.
[[maybe_unused]] static vx_status p9c_renameat(p9_client *c, uint32_t olddir, vx_str oldname, uint32_t newdir,
                                               vx_str newname) {
  if (!(c->extensions & P9_EXT_POSIX) && !p9c_dotl(c)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Trenameat, .fid = olddir, .name = oldname, .newfid = newdir, .name2 = newname};
  return p9c_call(c, &t);
}

[[maybe_unused]] static vx_status p9c_symlink(p9_client *c, uint32_t dir, vx_str name, vx_str target) {
  if (!(c->extensions & P9_EXT_POSIX) && !p9c_dotl(c)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tsymlink, .fid = dir, .name = name, .name2 = target};
  return p9c_call(c, &t);
}

// A symbolic link's target, copied into buf (cap bytes, TOO_SMALL if it
// does not fit): *len its length.
[[maybe_unused]] static vx_status p9c_readlink(p9_client *c, uint32_t fid, char *buf, size_t cap,
                                               size_t *len) {
  if (!(c->extensions & P9_EXT_POSIX) && !p9c_dotl(c)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Treadlink, .fid = fid};
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  if (e == VX_OK && rc.r.name2.len > cap) e = VX_ERR_TOO_SMALL;
  if (e == VX_OK) {
    for (size_t i = 0; i < rc.r.name2.len; i++) buf[i] = rc.r.name2.ptr[i];
    *len = rc.r.name2.len;
  }
  p9c_done(c, &rc);
  return e;
}

// notify (docs/proto/notify.md): waits for events on what fid names, those
// in mask, and copies them (kind[1] name[s] each) into buf: their length,
// or a status. The first call on a fid starts the watch; its clunk ends it.
[[maybe_unused]] static int64_t p9c_notify(p9_client *c, uint32_t fid, uint64_t mask, void *buf,
                                           uint32_t cap) {
  if (!(c->extensions & P9_EXT_NOTIFY)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tnotify, .fid = fid, .mask = mask};
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  int64_t n = e;
  if (e == VX_OK && rc.r.count > cap) n = VX_ERR_TOO_SMALL;
  if (e == VX_OK && rc.r.count <= cap) {
    for (uint32_t i = 0; i < rc.r.count; i++) ((uint8_t *)buf)[i] = rc.r.data.ptr[i];
    n = rc.r.count;
  }
  p9c_done(c, &rc);
  return n;
}

[[maybe_unused]] static vx_status p9c_fsync(p9_client *c, uint32_t fid) {
  if (!(c->extensions & P9_EXT_POSIX) && !p9c_dotl(c))
    return VX_OK; // a server without it has no later to write at
  p9_msg t = {.type = P9_Tfsync, .fid = fid};
  return p9c_call(c, &t);
}

// An open file shared between connections (posix): a token for `holds`
// joins of it.
[[maybe_unused]] static vx_status p9c_share(p9_client *c, uint32_t fid, uint32_t holds, uint8_t token[16]) {
  if (!(c->extensions & P9_EXT_POSIX)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tshare, .fid = fid, .holds = holds};
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  if (e == VX_OK) memcpy(token, rc.r.token, 16);
  p9c_done(c, &rc);
  return e;
}

// A new fid, open on the open file a token names (on this connection's server).
[[maybe_unused]] static vx_status p9c_join(p9_client *c, const uint8_t token[16], uint32_t *fid) {
  if (!(c->extensions & P9_EXT_POSIX)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tjoin, .newfid = p9c_fid(c)};
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
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  if (e == VX_OK) *at = rc.r.offset;
  p9c_done(c, &rc);
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
  if (!(c->extensions & P9_EXT_POSIX) && !p9c_dotl(c)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tlock,
              .fid = fid,
              .lock_type = type,
              .start = start,
              .length = length,
              .proc_id = proc_id,
              .client_id = VX_STR("")};
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  if (e == VX_OK) *status = rc.r.status;
  p9c_done(c, &rc);
  return e;
}

// The first lock that would stop one of `type` over the range: its type,
// range and owner in *l (its client_id empty), or P9_LOCK_UNLOCK as its type
// when none would.
[[maybe_unused]] static vx_status p9c_getlock(p9_client *c, uint32_t fid, uint8_t type, uint64_t start,
                                              uint64_t length, uint32_t proc_id, p9_msg *l) {
  if (!(c->extensions & P9_EXT_POSIX) && !p9c_dotl(c)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tgetlock,
              .fid = fid,
              .lock_type = type,
              .start = start,
              .length = length,
              .proc_id = proc_id,
              .client_id = VX_STR("")};
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  if (e == VX_OK) *l = rc.r, l->client_id = (vx_str){};
  p9c_done(c, &rc);
  return e;
}

// Tmap (docs/proto/map.md): a VMO for the file's [offset, offset + length),
// the fid open as the mapping needs, where in it the range starts, and how
// many bytes it has from there (less than length past the file's end).
[[maybe_unused]] static vx_status p9c_map(p9_client *c, uint32_t fid, uint64_t offset, uint64_t length,
                                          uint32_t prot, vx_handle *vmo, uint64_t *vmo_offset,
                                          uint64_t *avail) {
  if (!(c->extensions & P9_EXT_MAP)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Tmap, .fid = fid, .offset = offset, .length = length, .prot = prot};
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  if (e == VX_OK && !rc.x->handle) e = VX_ERR_INVALID; // an Rmap without its VMO
  if (e == VX_OK) {
    *vmo = rc.x->handle, *vmo_offset = rc.r.offset, *avail = rc.r.length;
    rc.x->handle = VX_HANDLE_NONE; // taken
  }
  p9c_done(c, &rc);
  return e;
}
