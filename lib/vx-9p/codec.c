// vx-9p codec: 9P2000 messages, stat entries and 9Px version strings
// (docs/02 §3). Builds for the target and the host.
//
// A message is one flat p9_msg holding every field any message has;
// messages.def lists which fields each type carries, in wire order, and one
// encoder and one decoder walk that list. Decoding is strict, because the bytes
// may come from a hostile peer: the size field must match the message exactly,
// every field must fit, nothing may follow the last field, a walk has at most
// 16 names, and strings may not hold NUL. Decoded strings and data point into
// the message buffer; nothing is copied.

#pragma once // server.c and client.c both include it

#include "../../abi/vx/abi.h"

typedef struct vx_bytes {
  const uint8_t *ptr;
  size_t len;
} vx_bytes;

enum : uint32_t {
  P9_MAXWELEM = 16,       // names in one walk
  P9_NOTAG = 0xffff,      // Tversion's tag
  P9_NOFID = 0xffff'ffff, // no fid (Tattach's afid without auth)
  P9_IOHDRSZ = 24,        // the Rread and Twrite overhead: a read or write carries msize - 24 bytes
  P9_MIN_MSIZE = 256,
  P9_MAX_MSIZE = 1 << 20,
};

enum : uint8_t { // qid.type and the top byte of a stat's mode
  P9_QTDIR = 0x80,
  P9_QTAPPEND = 0x40,
  P9_QTEXCL = 0x20,
  P9_QTAUTH = 0x08,
  P9_QTFILE = 0x00,
};

// A stat's mode: a directory; and 9P2000.u's link and device (a terminal, to
// the musl back end).
enum : uint32_t {
  P9_DMDIR = 0x8000'0000,
  P9_DMAPPEND = 0x4000'0000, // writes go to the end, whatever their offset
  P9_DMEXCL = 0x2000'0000,   // open by one at a time
  P9_DMSYMLINK = 0x0200'0000,
  P9_DMDEVICE = 0x0080'0000,
};

enum : uint8_t { // Topen and Tcreate modes
  P9_OREAD = 0,
  P9_OWRITE = 1,
  P9_ORDWR = 2,
  P9_OEXEC = 3,
  P9_OTRUNC = 0x10,
  P9_ORCLOSE = 0x40,
};

typedef struct p9_qid {
  uint8_t type;
  uint32_t version;
  uint64_t path;
} p9_qid;

typedef enum p9_type : uint8_t {
  P9_NONE = 0, // not a message: what a zeroed p9_msg holds
#define P9_MSG(name, num, ...) P9_##name = num,
#include "messages.def"
#undef P9_MSG
} p9_type;

typedef enum p9_field : uint8_t {
  P9F_END = 0,
#define P9_FIELD(name, kind, member) P9F_##name,
#include "fields.def"
#undef P9_FIELD
} p9_field;

// Rgetattr's attributes and Tsetattr's, as 9P2000.L has them. A mode is
// POSIX's (S_IFDIR and the rest), not 9P2000's.
typedef struct p9_attr {
  uint64_t valid; // which of the rest are set: P9_GETATTR_*
  p9_qid qid;
  uint32_t mode, uid, gid;
  uint64_t nlink, rdev, size, blksize, blocks;
  uint64_t atime_sec, atime_nsec, mtime_sec, mtime_nsec, ctime_sec, ctime_nsec, btime_sec, btime_nsec;
  uint64_t gen, data_version;
} p9_attr;

typedef struct p9_setattr {
  uint32_t valid; // which of the rest to change: P9_SETATTR_*
  uint32_t mode, uid, gid;
  uint64_t size, atime_sec, atime_nsec, mtime_sec, mtime_nsec;
} p9_setattr;

enum : uint64_t { // Linux's numbers
  P9_GETATTR_MODE = 0x1,
  P9_GETATTR_NLINK = 0x2,
  P9_GETATTR_UID = 0x4,
  P9_GETATTR_GID = 0x8,
  P9_GETATTR_RDEV = 0x10,
  P9_GETATTR_ATIME = 0x20,
  P9_GETATTR_MTIME = 0x40,
  P9_GETATTR_CTIME = 0x80,
  P9_GETATTR_INO = 0x100,
  P9_GETATTR_SIZE = 0x200,
  P9_GETATTR_BLOCKS = 0x400,
  P9_GETATTR_BASIC = 0x7ff,
};

enum : uint32_t {
  P9_SETATTR_MODE = 0x1,
  P9_SETATTR_UID = 0x2,
  P9_SETATTR_GID = 0x4,
  P9_SETATTR_SIZE = 0x8,
  P9_SETATTR_ATIME = 0x10, // to now, without ATIME_SET
  P9_SETATTR_MTIME = 0x20,
  P9_SETATTR_CTIME = 0x40,
  P9_SETATTR_ATIME_SET = 0x80, // to atime_sec and atime_nsec
  P9_SETATTR_MTIME_SET = 0x100,
};

// POSIX's file types in a p9_attr's mode.
enum : uint32_t {
  P9_S_IFMT = 0170000,
  P9_S_IFDIR = 0040000,
  P9_S_IFREG = 0100000,
  P9_S_IFLNK = 0120000,
  P9_S_IFCHR = 0020000,
};

// Rstatfs's body (9P2000.L).
typedef struct p9_statfs {
  uint32_t type, bsize;
  uint64_t blocks, bfree, bavail, files, ffree, fsid;
  uint32_t namelen;
} p9_statfs;

typedef struct p9_msg {
  p9_type type;
  uint16_t tag;
  uint32_t fid, newfid, afid, msize, iounit, perm, count;
  uint64_t offset;
  uint8_t mode;
  uint16_t oldtag;
  vx_str version, uname, aname, ename, name;
  p9_qid qid;
  uint16_t nwname, nwqid;
  vx_str wname[P9_MAXWELEM];
  p9_qid wqid[P9_MAXWELEM];
  vx_bytes data; // Rread, Twrite; its length is count
  vx_bytes stat; // Rstat, Twstat: one stat entry, its own size[2] included
  vx_str name2;
  uint32_t gid, datasync;
  uint64_t mask;
  p9_attr attr;
  p9_setattr setattr;
  uint8_t lock_type, status, whence;
  uint32_t lock_flags, proc_id, holds, desc_flags, prot;
  uint64_t roffset;
  uint64_t start, length;
  vx_str client_id;
  uint8_t token[16];
  // 9P2000.L's (6d4c2):
  uint32_t lflags, lmode, ecode;
  uint32_t n_uname; // Tattach's and Tauth's numeric user (P9_NONUNAME: none)
  bool has_n_uname; // it is on the wire (a .L or .u client's)
  p9_statfs statfs;
} p9_msg;

static constexpr uint32_t P9_NONUNAME = UINT32_MAX;
// Linux's open flags, as Tlopen and Tlcreate carry them, and Tunlinkat's.
enum : uint32_t {
  P9_L_O_ACCMODE = 3,
  P9_L_O_CREAT = 0100,
  P9_L_O_EXCL = 0200,
  P9_L_O_TRUNC = 01000,
  P9_L_O_APPEND = 02000,
  P9_L_AT_REMOVEDIR = 0x200,
};
// Rreaddir's entries' types: Linux's DT_*.
enum : uint8_t { P9_DT_REG = 8, P9_DT_DIR = 4, P9_DT_LNK = 10, P9_DT_CHR = 2 };

// Tread's and Twrite's offset that means the open file's own, which the
// server keeps and moves on (posix).
static constexpr uint64_t P9_OFFSET_CURRENT = UINT64_MAX;
// Topen's mode bit (posix): the open file's writes at P9_OFFSET_CURRENT go
// to its end.
enum : uint8_t { P9_OAPPEND = 0x80 };
// fs.open's mode bit, never a client's (the server takes it out of theirs):
// a Tjoin's open, another fid for a file already open, which may have been
// removed since.
enum : uint8_t { P9_OJOIN = 0x20 };
enum : uint8_t { P9_LOCK_READ = 0, P9_LOCK_WRITE = 1, P9_LOCK_UNLOCK = 2 };
enum : uint8_t { P9_LOCK_SUCCESS = 0, P9_LOCK_BLOCKED = 1, P9_LOCK_ERROR = 2 };

// The fields of each message type, in wire order; nullptr for a type that does not exist.
#define P9_MSG(name, num, ...) static const p9_field P9_FIELDS_##name[] = {__VA_OPT__(__VA_ARGS__, ) P9F_END};
#include "messages.def"
#undef P9_MSG

static const p9_field *const P9_FIELDS[256] = {
#define P9_MSG(name, num, ...) [num] = P9_FIELDS_##name,
#include "messages.def"
#undef P9_MSG
};

static const char *const P9_NAMES[256] = {
#define P9_MSG(name, num, ...) [num] = #name,
#include "messages.def"
#undef P9_MSG
};

// --- Encoding ---

typedef struct p9_out {
  uint8_t *buf;
  size_t cap, len;
  bool failed;
} p9_out;

static void p9_put(p9_out *o, uint64_t v, uint32_t bytes) {
  if (o->failed || o->cap - o->len < bytes) {
    o->failed = true;
    return;
  }
  for (uint32_t i = 0; i < bytes; i++) o->buf[o->len++] = (uint8_t)(v >> (8 * i));
}

static void p9_put_bytes(p9_out *o, const void *p, size_t n) {
  if (o->failed || o->cap - o->len < n) {
    o->failed = true;
    return;
  }
  for (size_t i = 0; i < n; i++) o->buf[o->len + i] = ((const uint8_t *)p)[i];
  o->len += n;
}

static void p9_put_str(p9_out *o, vx_str s) {
  if (s.len > 0xffff) o->failed = true;
  p9_put(o, s.len, 2);
  p9_put_bytes(o, s.ptr, s.len);
}

static void p9_put_qid(p9_out *o, p9_qid q) {
  p9_put(o, q.type, 1);
  p9_put(o, q.version, 4);
  p9_put(o, q.path, 8);
}

// Encodes m into buf. Returns its length, or 0 if it does not fit or is not a
// message 9P2000 has.
[[maybe_unused]] static size_t p9_encode(const p9_msg *m, uint8_t *buf, size_t cap) {
  const p9_field *f = P9_FIELDS[m->type];
  if (!f) return 0;
  p9_out o = {.buf = buf, .cap = cap};
  p9_put(&o, 0, 4); // the size, filled in below
  p9_put(&o, m->type, 1);
  p9_put(&o, m->tag, 2);
  for (; *f; f++) {
    switch (*f) {
    case P9F_FID: p9_put(&o, m->fid, 4); break;
    case P9F_NEWFID: p9_put(&o, m->newfid, 4); break;
    case P9F_AFID: p9_put(&o, m->afid, 4); break;
    case P9F_MSIZE: p9_put(&o, m->msize, 4); break;
    case P9F_IOUNIT: p9_put(&o, m->iounit, 4); break;
    case P9F_PERM: p9_put(&o, m->perm, 4); break;
    case P9F_COUNT: p9_put(&o, m->count, 4); break;
    case P9F_OFFSET: p9_put(&o, m->offset, 8); break;
    case P9F_MODE: p9_put(&o, m->mode, 1); break;
    case P9F_OLDTAG: p9_put(&o, m->oldtag, 2); break;
    case P9F_VERSION: p9_put_str(&o, m->version); break;
    case P9F_UNAME: p9_put_str(&o, m->uname); break;
    case P9F_ANAME: p9_put_str(&o, m->aname); break;
    case P9F_ENAME: p9_put_str(&o, m->ename); break;
    case P9F_NAME: p9_put_str(&o, m->name); break;
    case P9F_QID: p9_put_qid(&o, m->qid); break;
    case P9F_WNAMES:
      if (m->nwname > P9_MAXWELEM) o.failed = true;
      p9_put(&o, m->nwname, 2);
      for (uint16_t i = 0; i < m->nwname && !o.failed; i++) p9_put_str(&o, m->wname[i]);
      break;
    case P9F_WQIDS:
      if (m->nwqid > P9_MAXWELEM) o.failed = true;
      p9_put(&o, m->nwqid, 2);
      for (uint16_t i = 0; i < m->nwqid && !o.failed; i++) p9_put_qid(&o, m->wqid[i]);
      break;
    case P9F_DATA:
      if (m->data.len > UINT32_MAX) o.failed = true;
      p9_put(&o, m->data.len, 4);
      p9_put_bytes(&o, m->data.ptr, m->data.len);
      break;
    case P9F_STAT:
      if (m->stat.len > 0xffff) o.failed = true;
      p9_put(&o, m->stat.len, 2);
      p9_put_bytes(&o, m->stat.ptr, m->stat.len);
      break;
    case P9F_NAME2: p9_put_str(&o, m->name2); break;
    case P9F_GID: p9_put(&o, m->gid, 4); break;
    case P9F_MASK: p9_put(&o, m->mask, 8); break;
    case P9F_DATASYNC: p9_put(&o, m->datasync, 4); break;
    case P9F_LOCKTYPE: p9_put(&o, m->lock_type, 1); break;
    case P9F_LOCKFLAGS: p9_put(&o, m->lock_flags, 4); break;
    case P9F_START: p9_put(&o, m->start, 8); break;
    case P9F_LENGTH: p9_put(&o, m->length, 8); break;
    case P9F_PROCID: p9_put(&o, m->proc_id, 4); break;
    case P9F_CLIENTID: p9_put_str(&o, m->client_id); break;
    case P9F_STATUS: p9_put(&o, m->status, 1); break;
    case P9F_HOLDS: p9_put(&o, m->holds, 4); break;
    case P9F_TOKEN: p9_put_bytes(&o, m->token, sizeof m->token); break;
    case P9F_WHENCE: p9_put(&o, m->whence, 1); break;
    case P9F_DESCFLAGS: p9_put(&o, m->desc_flags, 4); break;
    case P9F_PROT: p9_put(&o, m->prot, 4); break;
    case P9F_ROFFSET: p9_put(&o, m->roffset, 8); break;
    case P9F_ATTR: {
      const p9_attr *a = &m->attr;
      p9_put(&o, a->valid, 8);
      p9_put_qid(&o, a->qid);
      p9_put(&o, a->mode, 4);
      p9_put(&o, a->uid, 4);
      p9_put(&o, a->gid, 4);
      const uint64_t rest[] = {a->nlink,      a->rdev,       a->size,       a->blksize,    a->blocks,
                               a->atime_sec,  a->atime_nsec, a->mtime_sec,  a->mtime_nsec, a->ctime_sec,
                               a->ctime_nsec, a->btime_sec,  a->btime_nsec, a->gen,        a->data_version};
      for (size_t i = 0; i < sizeof rest / sizeof rest[0]; i++) p9_put(&o, rest[i], 8);
      break;
    }
    case P9F_LFLAGS: p9_put(&o, m->lflags, 4); break;
    case P9F_LMODE: p9_put(&o, m->lmode, 4); break;
    case P9F_ECODE: p9_put(&o, m->ecode, 4); break;
    case P9F_NUNAME:
      if (m->has_n_uname) p9_put(&o, m->n_uname, 4);
      break;
    case P9F_STATFS: {
      const p9_statfs *sf = &m->statfs;
      p9_put(&o, sf->type, 4);
      p9_put(&o, sf->bsize, 4);
      const uint64_t rest[] = {sf->blocks, sf->bfree, sf->bavail, sf->files, sf->ffree, sf->fsid};
      for (size_t i = 0; i < sizeof rest / sizeof rest[0]; i++) p9_put(&o, rest[i], 8);
      p9_put(&o, sf->namelen, 4);
      break;
    }
    case P9F_SETATTR: {
      const p9_setattr *a = &m->setattr;
      p9_put(&o, a->valid, 4);
      p9_put(&o, a->mode, 4);
      p9_put(&o, a->uid, 4);
      p9_put(&o, a->gid, 4);
      p9_put(&o, a->size, 8);
      p9_put(&o, a->atime_sec, 8);
      p9_put(&o, a->atime_nsec, 8);
      p9_put(&o, a->mtime_sec, 8);
      p9_put(&o, a->mtime_nsec, 8);
      break;
    }
    default: o.failed = true; break;
    }
  }
  if (o.failed || o.len > UINT32_MAX) return 0;
  for (uint32_t i = 0; i < 4; i++) buf[i] = (uint8_t)(o.len >> (8 * i));
  return o.len;
}

// --- Decoding ---

typedef struct p9_in {
  const uint8_t *buf;
  size_t len, pos;
  bool failed;
} p9_in;

static uint64_t p9_get(p9_in *in, uint32_t bytes) {
  if (in->failed || in->len - in->pos < bytes) {
    in->failed = true;
    return 0;
  }
  uint64_t v = 0;
  for (uint32_t i = 0; i < bytes; i++) v |= (uint64_t)in->buf[in->pos + i] << (8 * i);
  in->pos += bytes;
  return v;
}

static const uint8_t *p9_get_bytes(p9_in *in, size_t n) {
  if (in->failed || in->len - in->pos < n) {
    in->failed = true;
    return nullptr;
  }
  const uint8_t *p = in->buf + in->pos;
  in->pos += n;
  return p;
}

static vx_str p9_get_str(p9_in *in) {
  size_t n = (size_t)p9_get(in, 2);
  const uint8_t *p = p9_get_bytes(in, n);
  for (size_t i = 0; p && i < n; i++)
    if (!p[i]) in->failed = true; // 9P strings never hold NUL
  return (vx_str){(const char *)p, p ? n : 0};
}

static p9_qid p9_get_qid(p9_in *in) {
  p9_qid q;
  q.type = (uint8_t)p9_get(in, 1);
  q.version = (uint32_t)p9_get(in, 4);
  q.path = p9_get(in, 8);
  return q;
}

// Decodes one whole message: buf holds exactly its size[4] bytes. INVALID for
// anything malformed; nothing is half-decoded.
[[maybe_unused]] static vx_status p9_decode(const uint8_t *buf, size_t len, p9_msg *m) {
  *m = (p9_msg){};
  p9_in in = {.buf = buf, .len = len};
  if (p9_get(&in, 4) != len || len < 7) return VX_ERR_INVALID;
  m->type = (p9_type)p9_get(&in, 1);
  m->tag = (uint16_t)p9_get(&in, 2);
  const p9_field *f = P9_FIELDS[m->type];
  if (!f) return VX_ERR_INVALID;
  for (; *f && !in.failed; f++) {
    switch (*f) {
    case P9F_FID: m->fid = (uint32_t)p9_get(&in, 4); break;
    case P9F_NEWFID: m->newfid = (uint32_t)p9_get(&in, 4); break;
    case P9F_AFID: m->afid = (uint32_t)p9_get(&in, 4); break;
    case P9F_MSIZE: m->msize = (uint32_t)p9_get(&in, 4); break;
    case P9F_IOUNIT: m->iounit = (uint32_t)p9_get(&in, 4); break;
    case P9F_PERM: m->perm = (uint32_t)p9_get(&in, 4); break;
    case P9F_COUNT: m->count = (uint32_t)p9_get(&in, 4); break;
    case P9F_OFFSET: m->offset = p9_get(&in, 8); break;
    case P9F_MODE: m->mode = (uint8_t)p9_get(&in, 1); break;
    case P9F_OLDTAG: m->oldtag = (uint16_t)p9_get(&in, 2); break;
    case P9F_VERSION: m->version = p9_get_str(&in); break;
    case P9F_UNAME: m->uname = p9_get_str(&in); break;
    case P9F_ANAME: m->aname = p9_get_str(&in); break;
    case P9F_ENAME: m->ename = p9_get_str(&in); break;
    case P9F_NAME: m->name = p9_get_str(&in); break;
    case P9F_QID: m->qid = p9_get_qid(&in); break;
    case P9F_WNAMES:
      m->nwname = (uint16_t)p9_get(&in, 2);
      if (m->nwname > P9_MAXWELEM) in.failed = true;
      for (uint16_t i = 0; i < m->nwname && !in.failed; i++) m->wname[i] = p9_get_str(&in);
      break;
    case P9F_WQIDS:
      m->nwqid = (uint16_t)p9_get(&in, 2);
      if (m->nwqid > P9_MAXWELEM) in.failed = true;
      for (uint16_t i = 0; i < m->nwqid && !in.failed; i++) m->wqid[i] = p9_get_qid(&in);
      break;
    case P9F_DATA:
      m->count = (uint32_t)p9_get(&in, 4);
      m->data = (vx_bytes){p9_get_bytes(&in, m->count), m->count};
      break;
    case P9F_STAT: {
      size_t n = (size_t)p9_get(&in, 2);
      m->stat = (vx_bytes){p9_get_bytes(&in, n), n};
      break;
    }
    case P9F_NAME2: m->name2 = p9_get_str(&in); break;
    case P9F_GID: m->gid = (uint32_t)p9_get(&in, 4); break;
    case P9F_MASK: m->mask = p9_get(&in, 8); break;
    case P9F_DATASYNC: m->datasync = (uint32_t)p9_get(&in, 4); break;
    case P9F_LOCKTYPE: m->lock_type = (uint8_t)p9_get(&in, 1); break;
    case P9F_LOCKFLAGS: m->lock_flags = (uint32_t)p9_get(&in, 4); break;
    case P9F_START: m->start = p9_get(&in, 8); break;
    case P9F_LENGTH: m->length = p9_get(&in, 8); break;
    case P9F_PROCID: m->proc_id = (uint32_t)p9_get(&in, 4); break;
    case P9F_CLIENTID: m->client_id = p9_get_str(&in); break;
    case P9F_STATUS: m->status = (uint8_t)p9_get(&in, 1); break;
    case P9F_HOLDS: m->holds = (uint32_t)p9_get(&in, 4); break;
    case P9F_TOKEN:
      for (size_t i = 0; i < sizeof m->token; i++) m->token[i] = (uint8_t)p9_get(&in, 1);
      break;
    case P9F_WHENCE: m->whence = (uint8_t)p9_get(&in, 1); break;
    case P9F_DESCFLAGS: m->desc_flags = (uint32_t)p9_get(&in, 4); break;
    case P9F_PROT: m->prot = (uint32_t)p9_get(&in, 4); break;
    case P9F_ROFFSET: m->roffset = p9_get(&in, 8); break;
    case P9F_ATTR: {
      p9_attr *a = &m->attr;
      a->valid = p9_get(&in, 8);
      a->qid = p9_get_qid(&in);
      a->mode = (uint32_t)p9_get(&in, 4);
      a->uid = (uint32_t)p9_get(&in, 4);
      a->gid = (uint32_t)p9_get(&in, 4);
      uint64_t *rest[] = {&a->nlink,      &a->rdev,       &a->size,       &a->blksize,    &a->blocks,
                          &a->atime_sec,  &a->atime_nsec, &a->mtime_sec,  &a->mtime_nsec, &a->ctime_sec,
                          &a->ctime_nsec, &a->btime_sec,  &a->btime_nsec, &a->gen,        &a->data_version};
      for (size_t i = 0; i < sizeof rest / sizeof rest[0]; i++) *rest[i] = p9_get(&in, 8);
      break;
    }
    case P9F_LFLAGS: m->lflags = (uint32_t)p9_get(&in, 4); break;
    case P9F_LMODE: m->lmode = (uint32_t)p9_get(&in, 4); break;
    case P9F_ECODE: m->ecode = (uint32_t)p9_get(&in, 4); break;
    case P9F_NUNAME: // the last field: a 9P2000 client sends none
      m->has_n_uname = in.len - in.pos >= 4;
      m->n_uname = m->has_n_uname ? (uint32_t)p9_get(&in, 4) : P9_NONUNAME;
      break;
    case P9F_STATFS: {
      p9_statfs *sf = &m->statfs;
      sf->type = (uint32_t)p9_get(&in, 4);
      sf->bsize = (uint32_t)p9_get(&in, 4);
      uint64_t *rest[] = {&sf->blocks, &sf->bfree, &sf->bavail, &sf->files, &sf->ffree, &sf->fsid};
      for (size_t i = 0; i < sizeof rest / sizeof rest[0]; i++) *rest[i] = p9_get(&in, 8);
      sf->namelen = (uint32_t)p9_get(&in, 4);
      break;
    }
    case P9F_SETATTR: {
      p9_setattr *a = &m->setattr;
      a->valid = (uint32_t)p9_get(&in, 4);
      a->mode = (uint32_t)p9_get(&in, 4);
      a->uid = (uint32_t)p9_get(&in, 4);
      a->gid = (uint32_t)p9_get(&in, 4);
      a->size = p9_get(&in, 8);
      a->atime_sec = p9_get(&in, 8);
      a->atime_nsec = p9_get(&in, 8);
      a->mtime_sec = p9_get(&in, 8);
      a->mtime_nsec = p9_get(&in, 8);
      break;
    }
    default: in.failed = true; break;
    }
  }
  if (in.failed || in.pos != len) return VX_ERR_INVALID;
  return VX_OK;
}

// --- Stat entries ---

typedef struct p9_stat {
  uint16_t type;
  uint32_t dev;
  p9_qid qid;
  uint32_t mode; // permissions, with P9_DMDIR for a directory
  uint32_t atime, mtime;
  uint64_t length;
  vx_str name, uid, gid, muid;
} p9_stat;

// Encodes one stat entry, its size[2] first. Returns its length, or 0.
[[maybe_unused]] static size_t p9_stat_encode(const p9_stat *s, uint8_t *buf, size_t cap) {
  p9_out o = {.buf = buf, .cap = cap};
  p9_put(&o, 0, 2);
  p9_put(&o, s->type, 2);
  p9_put(&o, s->dev, 4);
  p9_put_qid(&o, s->qid);
  p9_put(&o, s->mode, 4);
  p9_put(&o, s->atime, 4);
  p9_put(&o, s->mtime, 4);
  p9_put(&o, s->length, 8);
  p9_put_str(&o, s->name);
  p9_put_str(&o, s->uid);
  p9_put_str(&o, s->gid);
  p9_put_str(&o, s->muid);
  if (o.failed || o.len - 2 > 0xffff) return 0;
  buf[0] = (uint8_t)(o.len - 2);
  buf[1] = (uint8_t)((o.len - 2) >> 8);
  return o.len;
}

// Decodes one stat entry that fills buf exactly, size[2] included.
[[maybe_unused]] static vx_status p9_stat_decode(const uint8_t *buf, size_t len, p9_stat *s) {
  *s = (p9_stat){};
  p9_in in = {.buf = buf, .len = len};
  if (p9_get(&in, 2) + 2 != len) return VX_ERR_INVALID;
  s->type = (uint16_t)p9_get(&in, 2);
  s->dev = (uint32_t)p9_get(&in, 4);
  s->qid = p9_get_qid(&in);
  s->mode = (uint32_t)p9_get(&in, 4);
  s->atime = (uint32_t)p9_get(&in, 4);
  s->mtime = (uint32_t)p9_get(&in, 4);
  s->length = p9_get(&in, 8);
  s->name = p9_get_str(&in);
  s->uid = p9_get_str(&in);
  s->gid = p9_get_str(&in);
  s->muid = p9_get_str(&in);
  return in.failed || in.pos != len ? VX_ERR_INVALID : VX_OK;
}

// The next stat entry in what a directory read returned (len bytes), from
// *at, which moves past it. False at the end, and at an entry whose own size
// runs past what was read or does not decode: the server's bytes are not
// trusted for where the next entry starts.
[[maybe_unused]] static bool p9_dir_next(const uint8_t *buf, size_t len, size_t *at, p9_stat *out) {
  if (*at > len || len - *at < 2) return false;
  size_t size = 2 + (size_t)(buf[*at] | buf[*at + 1] << 8);
  if (size > len - *at || p9_stat_decode(buf + *at, size, out) != VX_OK) return false;
  *at += size;
  return true;
}

// --- Version negotiation (02 §3.1) ---

typedef enum p9_dialect : uint8_t {
  P9_UNKNOWN = 0,
  P9_2000,  // plain 9P2000; also what a 9P2000.L or .u client gets from a VectraOS server
  P9_2000X, // 9Px: "9P2000.x/1" and its extensions
  P9_2000L, // Linux's 9P2000.L (M6 step 6d4c2): its own messages, and errors as errno
} p9_dialect;

// 9Px's extensions, as words after the dialect: "9P2000.x/1 +dref +map".
#define P9_EXTENSIONS(X)                                                                                     \
  X(DREF, dref) X(MAP, map) X(LEASE, lease) X(NOTIFY, notify) X(XATTR, xattr) X(POSIX, posix)

enum : uint32_t {
#define P9_EXT_BIT(name, word) P9_EXT_BIT_##name,
  P9_EXTENSIONS(P9_EXT_BIT)
#undef P9_EXT_BIT
};

enum : uint32_t {
#define P9_EXT(name, word) P9_EXT_##name = 1u << P9_EXT_BIT_##name,
  P9_EXTENSIONS(P9_EXT)
#undef P9_EXT
};

enum : uint32_t { P9_PROT_READ = 1, P9_PROT_WRITE = 2, P9_PROT_EXEC = 4 }; // Tmap's prot

static const char *const P9_EXT_WORDS[] = {
#define P9_EXT_WORD(name, word) #word,
    P9_EXTENSIONS(P9_EXT_WORD)
#undef P9_EXT_WORD
};

static bool p9_str_eq(vx_str a, const char *b) {
  size_t n = 0;
  while (b[n]) n++;
  if (a.len != n) return false;
  for (size_t i = 0; i < n; i++)
    if (a.ptr[i] != b[i]) return false;
  return true;
}

// Reads a version string: its dialect and, for 9Px, the extensions it names.
// Unknown extension words are ignored, so later clients still talk to us.
[[maybe_unused]] static p9_dialect p9_version_parse(vx_str v, uint32_t *extensions) {
  *extensions = 0;
  size_t i = 0;
  while (i < v.len && v.ptr[i] != ' ') i++;
  vx_str base = {v.ptr, i};
  if (p9_str_eq(base, "9P2000.x/1")) {
    while (i < v.len) {
      while (i < v.len && v.ptr[i] == ' ') i++;
      size_t start = i;
      while (i < v.len && v.ptr[i] != ' ') i++;
      vx_str word = {v.ptr + start, i - start};
      if (word.len < 2 || word.ptr[0] != '+') continue;
      word = (vx_str){word.ptr + 1, word.len - 1};
      for (uint32_t b = 0; b < sizeof P9_EXT_WORDS / sizeof P9_EXT_WORDS[0]; b++)
        if (p9_str_eq(word, P9_EXT_WORDS[b])) *extensions |= 1u << b;
    }
    return P9_2000X;
  }
  if (p9_str_eq(base, "9P2000.L")) return P9_2000L;
  // 9P2000 itself, and any other dialect of it (".u"), are answered with 9P2000.
  if (base.len >= 6 && p9_str_eq((vx_str){base.ptr, 6}, "9P2000")) return P9_2000;
  return P9_UNKNOWN;
}

// Writes a version string for a dialect and its extensions into buf (cap
// bytes; 96 always suffices). Returns its length.
[[maybe_unused]] static size_t p9_version_format(p9_dialect d, uint32_t extensions, char *buf, size_t cap) {
  p9_out o = {.buf = (uint8_t *)buf, .cap = cap};
  if (d == P9_2000X) {
    p9_put_bytes(&o, "9P2000.x/1", 10);
    for (uint32_t b = 0; b < sizeof P9_EXT_WORDS / sizeof P9_EXT_WORDS[0]; b++) {
      if (!(extensions & (1u << b))) continue;
      size_t n = 0;
      while (P9_EXT_WORDS[b][n]) n++;
      p9_put_bytes(&o, " +", 2);
      p9_put_bytes(&o, P9_EXT_WORDS[b], n);
    }
  } else if (d == P9_2000) {
    p9_put_bytes(&o, "9P2000", 6);
  } else if (d == P9_2000L) {
    p9_put_bytes(&o, "9P2000.L", 8);
  } else {
    p9_put_bytes(&o, "unknown", 7);
  }
  return o.failed ? 0 : o.len;
}

// --- Errors ---
//
// 9P carries errors as text. A server turns a vx_status into Plan 9's wording
// where Plan 9 has one, and a client turns the text back; text it does not
// know becomes INVALID.

#define P9_ERRORS(X)                                                                                         \
  X(VX_ERR_NOT_FOUND, "file does not exist")                                                                 \
  X(VX_ERR_EXISTS, "file already exists")                                                                    \
  X(VX_ERR_ACCESS, "permission denied")                                                                      \
  X(VX_ERR_BAD_HANDLE, "unknown fid")                                                                        \
  X(VX_ERR_BAD_STATE, "fid already in use")                                                                  \
  X(VX_ERR_RANGE, "offset out of range")                                                                     \
  X(VX_ERR_NO_MEMORY, "out of memory")                                                                       \
  X(VX_ERR_UNSUPPORTED, "operation not supported")                                                           \
  X(VX_ERR_TOO_SMALL, "message too large for msize")                                                         \
  X(VX_ERR_REFUSED, "connection refused")                                                                    \
  X(VX_ERR_TIMED_OUT, "connection timed out")                                                                \
  X(VX_ERR_PEER_CLOSED, "i/o on hungup channel")                                                             \
  X(VX_ERR_INTERRUPTED, "interrupted")                                                                       \
  X(VX_ERR_NO_CHILD, "no living children")                                                                   \
  X(VX_ERR_IO, "i/o error")                                                                                  \
  X(VX_ERR_NO_SPACE, "file system full")                                                                     \
  X(VX_ERR_INVALID, "bad message")

// 9P2000.L's errors are Linux's errno numbers (Rlerror): each status's, and
// back. A number not here is EIO's.
#define P9_ERRNOS(X)                                                                                         \
  X(VX_ERR_NOT_FOUND, 2)                                                                                     \
  X(VX_ERR_EXISTS, 17)                                                                                       \
  X(VX_ERR_ACCESS, 13)                                                                                       \
  X(VX_ERR_BAD_HANDLE, 9)                                                                                    \
  X(VX_ERR_BAD_STATE, 16)                                                                                    \
  X(VX_ERR_RANGE, 34)                                                                                        \
  X(VX_ERR_NO_MEMORY, 12)                                                                                    \
  X(VX_ERR_UNSUPPORTED, 95)                                                                                  \
  X(VX_ERR_TOO_SMALL, 90)                                                                                    \
  X(VX_ERR_REFUSED, 111)                                                                                     \
  X(VX_ERR_TIMED_OUT, 110)                                                                                   \
  X(VX_ERR_PEER_CLOSED, 32)                                                                                  \
  X(VX_ERR_INTERRUPTED, 4)                                                                                   \
  X(VX_ERR_NO_CHILD, 10)                                                                                     \
  X(VX_ERR_IO, 5)                                                                                            \
  X(VX_ERR_NO_SPACE, 28)                                                                                     \
  X(VX_ERR_SHOULD_WAIT, 11)                                                                                  \
  X(VX_ERR_INVALID, 22)

// Numbers a .L server sends that mean one of these too.
#define P9_ERRNOS_HEARD(X)                                                                                   \
  X(VX_ERR_ACCESS, 1)       /* EPERM */                                                                      \
  X(VX_ERR_NOT_FOUND, 20)   /* ENOTDIR */                                                                    \
  X(VX_ERR_ACCESS, 21)      /* EISDIR */                                                                     \
  X(VX_ERR_RANGE, 36)       /* ENAMETOOLONG */                                                               \
  X(VX_ERR_UNSUPPORTED, 38) /* ENOSYS */                                                                     \
  X(VX_ERR_EXISTS, 39)      /* ENOTEMPTY */                                                                  \
  X(VX_ERR_ACCESS, 30)      /* EROFS */

[[maybe_unused]] static uint32_t p9_status_errno(vx_status st) {
#define P9_ERRNO_CASE(status, n)                                                                             \
  if (st == (status)) return n;
  P9_ERRNOS(P9_ERRNO_CASE)
#undef P9_ERRNO_CASE
  return 5;
}

[[maybe_unused]] static vx_status p9_errno_status(uint32_t n) {
#define P9_ERRNO_CASE(status, num)                                                                           \
  if (n == (num)) return status;
  P9_ERRNOS(P9_ERRNO_CASE)
  P9_ERRNOS_HEARD(P9_ERRNO_CASE)
#undef P9_ERRNO_CASE
  return VX_ERR_IO;
}

[[maybe_unused]] static vx_str p9_error_text(vx_status st) {
#define P9_ERROR_CASE(status, text)                                                                          \
  if (st == (status)) return VX_STR(text);
  P9_ERRORS(P9_ERROR_CASE)
#undef P9_ERROR_CASE
  return VX_STR("i/o error");
}

// Other servers' wordings, understood but never sent: Unix's strerror(), as
// u9fs passes it on, and u9fs's own messages (M3's interoperability test).
#define P9_ERRORS_HEARD(X)                                                                                   \
  X(VX_ERR_NOT_FOUND, "no such file or directory")                                                           \
  X(VX_ERR_NOT_FOUND, "not a directory")                                                                     \
  X(VX_ERR_EXISTS, "file exists")                                                                            \
  X(VX_ERR_EXISTS, "file or directory already exists")                                                       \
  X(VX_ERR_ACCESS, "read-only file system")                                                                  \
  X(VX_ERR_ACCESS, "is a directory")                                                                         \
  X(VX_ERR_ACCESS, "operation not permitted")                                                                \
  X(VX_ERR_BAD_HANDLE, "fid unknown or out of range")                                                        \
  X(VX_ERR_ACCESS, "exclusive use file already open")                                                        \
  X(VX_ERR_NO_SPACE, "no space left on device")

static bool p9_str_eq_nocase(vx_str a, const char *b) {
  size_t n = 0;
  for (; b[n]; n++) {
    if (n == a.len) return false;
    char c = a.ptr[n] >= 'A' && a.ptr[n] <= 'Z' ? (char)(a.ptr[n] + 32) : a.ptr[n];
    if (c != b[n]) return false;
  }
  return n == a.len;
}

[[maybe_unused]] static vx_status p9_error_status(vx_str text) {
#define P9_ERROR_MATCH(status, txt)                                                                          \
  if (p9_str_eq_nocase(text, txt)) return (status);
  P9_ERRORS(P9_ERROR_MATCH)
  P9_ERRORS_HEARD(P9_ERROR_MATCH)
#undef P9_ERROR_MATCH
  return VX_ERR_INVALID;
}
