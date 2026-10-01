// vx-9p server framework (docs/02 §2, §3): one request in, one reply out, no
// transport. A file server supplies p9_fs, operations on its own opaque node
// IDs; this file keeps the fid table and owns everything a hostile client
// could abuse:
//
//  - the attach root: each fid remembers the root it was attached at, `..`
//    there stays there, and `..` elsewhere goes through the file server's
//    parent operation, so a walk can never leave the root (02 §2);
//  - names: ".", "", and names holding '/' are refused before the file
//    server sees them;
//  - fids: every message's fid must exist, newfids must be free, open fids
//    cannot walk, and only open fids read or write in their mode;
//  - sizes: msize is negotiated, and reads and writes are clamped to it;
//  - directory reads: whole stat entries, at offset 0 or where the last read
//    ended (9P2000's rule).
//
// A read or write the file server cannot do yet (a console with no input
// typed), or an open (a listen file with no call yet, through the clone
// hook), answers SHOULD_WAIT; p9_serve then returns P9_DEFER, without a reply,
// and the transport holds the request and serves it again when the file
// server's device has done something (lib/vx-9p/ring_server.c). Everything else
// completes as it arrives, so Tflush has nothing to cancel.

#pragma once

#include "codec.c"

typedef struct p9_fs {
  void *ctx;
  vx_status (*attach)(void *ctx, vx_str aname, uint64_t *root);
  vx_status (*walk)(void *ctx, uint64_t dir, vx_str name,
                    uint64_t *child);                              // never ".", "..", or a name with '/'
  vx_status (*parent)(void *ctx, uint64_t node, uint64_t *parent); // only below an attach root
  vx_status (*stat)(void *ctx, uint64_t node, p9_stat *out);       // its strings may live until the next call
  vx_status (*open)(void *ctx, uint64_t node, uint8_t mode);
  // Optional: after an open, a clone file (02 §5) makes a new node, and the
  // fid moves there, opened. NOT_FOUND: the node is not a clone file.
  // SHOULD_WAIT: not yet (a listen file before a call comes); the open is
  // held and made again, so open must do nothing that cannot be repeated.
  vx_status (*clone)(void *ctx, uint64_t node, uint8_t mode, uint64_t *opened);
  vx_status (*read)(void *ctx, uint64_t node, uint64_t offset, uint8_t *buf,
                    uint32_t *count);                                             // files; or SHOULD_WAIT
  vx_status (*readdir)(void *ctx, uint64_t dir, uint32_t index, uint64_t *child); // NOT_FOUND past the end
  vx_status (*write)(void *ctx, uint64_t node, uint64_t offset, const uint8_t *buf,
                     uint32_t *count); // or null
  vx_status (*create)(void *ctx, uint64_t dir, vx_str name, uint32_t perm, uint8_t mode,
                      uint64_t *node);                  // or null
  vx_status (*remove)(void *ctx, uint64_t node);        // or null
  void (*clunk)(void *ctx, uint64_t node, bool opened); // optional: a fid let the node go
  // The posix and xattr extensions (docs/proto/posix.md), each optional: a
  // server without one refuses its message. Rgetattr needs nothing new: it
  // is made from stat.
  vx_status (*setattr)(void *ctx, uint64_t node, const p9_setattr *a);
  vx_status (*rename)(void *ctx, uint64_t olddir, vx_str oldname, uint64_t newdir, vx_str newname);
  vx_status (*symlink)(void *ctx, uint64_t dir, vx_str name, vx_str target, uint64_t *node);
  vx_status (*readlink)(void *ctx, uint64_t node, vx_str *target); // its bytes last until the next call
} p9_fs;

enum : uint32_t { P9_MAX_FIDS = 256 }; // per connection, for now

typedef struct p9_fid {
  uint32_t fid;
  bool used, open;
  uint8_t mode;
  uint64_t node, root; // root: where it was attached; `..` stops there
  p9_qid qid;
  uint64_t dir_offset; // a directory read continues only from here
  uint32_t dir_index;  // the next entry to read
} p9_fid;

typedef struct p9_server {
  p9_fs fs;
  uint32_t max_msize; // the largest this server accepts
  uint32_t supported; // the 9Px extensions it implements
  uint32_t msize;     // negotiated; 0 until Tversion
  p9_dialect dialect;
  uint32_t extensions; // negotiated
  p9_fid fids[P9_MAX_FIDS];
  char version[96];   // Rversion's string
  uint8_t stat[1024]; // Rstat's entry
} p9_server;

static p9_fid *p9_fid_find(p9_server *s, uint32_t fid) {
  for (uint32_t i = 0; i < P9_MAX_FIDS; i++)
    if (s->fids[i].used && s->fids[i].fid == fid) return &s->fids[i];
  return nullptr;
}

static p9_fid *p9_fid_new(p9_server *s, uint32_t fid) {
  if (fid == P9_NOFID || p9_fid_find(s, fid)) return nullptr;
  for (uint32_t i = 0; i < P9_MAX_FIDS; i++) {
    if (s->fids[i].used) continue;
    s->fids[i] = (p9_fid){.fid = fid, .used = true};
    return &s->fids[i];
  }
  return nullptr;
}

static void p9_fid_drop(p9_server *s, p9_fid *f) {
  if (s->fs.clunk) s->fs.clunk(s->fs.ctx, f->node, f->open);
  *f = (p9_fid){};
}

static vx_status p9_qid_of(p9_server *s, uint64_t node, p9_qid *qid) {
  p9_stat st;
  vx_status e = s->fs.stat(s->fs.ctx, node, &st);
  if (e == VX_OK) *qid = st.qid;
  return e;
}

// Opens a fid's node. A clone file moves the fid to the node it makes, as
// opening /net/tcp/clone moves it to the new conversation's ctl (02 §5).
static vx_status open_node(p9_server *s, p9_fid *f, uint8_t mode) {
  vx_status e = s->fs.open(s->fs.ctx, f->node, mode);
  uint64_t node;
  if (e != VX_OK || !s->fs.clone) return e;
  if ((e = s->fs.clone(s->fs.ctx, f->node, mode, &node)) != VX_OK) return e == VX_ERR_NOT_FOUND ? VX_OK : e;
  p9_qid qid;
  if ((e = p9_qid_of(s, node, &qid)) != VX_OK) {
    if (s->fs.clunk) s->fs.clunk(s->fs.ctx, node, true); // opened, and let go at once
    return e;
  }
  if (s->fs.clunk) s->fs.clunk(s->fs.ctx, f->node, false);
  f->node = node;
  f->qid = qid;
  return VX_OK;
}

// A name the file server may see: not empty, not ".", no '/'.
static bool p9_good_name(vx_str n) {
  if (n.len == 0 || (n.len == 1 && n.ptr[0] == '.')) return false;
  for (size_t i = 0; i < n.len; i++)
    if (n.ptr[i] == '/') return false;
  return true;
}

// Walks one step from `node`, keeping inside `root`.
static vx_status p9_step(p9_server *s, uint64_t root, uint64_t node, vx_str name, uint64_t *next) {
  if (name.len == 2 && name.ptr[0] == '.' && name.ptr[1] == '.') {
    if (node == root) {
      *next = root; // `..` at the attach root is the root
      return VX_OK;
    }
    return s->fs.parent(s->fs.ctx, node, next);
  }
  if (!p9_good_name(name)) return VX_ERR_INVALID;
  return s->fs.walk(s->fs.ctx, node, name, next);
}

// Fills `out` (cap bytes) with whole stat entries from a directory fid.
static vx_status p9_read_dir(p9_server *s, p9_fid *f, uint64_t offset, uint8_t *out, uint32_t cap,
                             uint32_t *count) {
  if (offset == 0)
    f->dir_index = 0, f->dir_offset = 0;
  else if (offset != f->dir_offset)
    return VX_ERR_RANGE;
  uint32_t used = 0;
  for (;;) {
    uint64_t child;
    vx_status e = s->fs.readdir(s->fs.ctx, f->node, f->dir_index, &child);
    if (e == VX_ERR_NOT_FOUND) break;
    if (e != VX_OK) return e;
    p9_stat st;
    if ((e = s->fs.stat(s->fs.ctx, child, &st)) != VX_OK) return e;
    size_t n = p9_stat_encode(&st, out + used, cap - used);
    if (!n) {
      if (used == 0) return VX_ERR_TOO_SMALL; // not even one entry fits the count asked for
      break;
    }
    used += (uint32_t)n;
    f->dir_index++;
  }
  f->dir_offset += used;
  *count = used;
  return VX_OK;
}

// A stat's mode as POSIX has it, for Rgetattr.
static uint32_t p9_posix_mode(uint32_t mode) {
  uint32_t type = P9_S_IFREG;
  if (mode & P9_DMDIR) type = P9_S_IFDIR;
  if (mode & P9_DMSYMLINK) type = P9_S_IFLNK;
  return type | (mode & 07777);
}

static bool p9_new_name_ok(vx_str name) {
  return p9_good_name(name) && !(name.len == 2 && name.ptr[0] == '.' && name.ptr[1] == '.');
}

// The posix and xattr extensions' messages (docs/proto/posix.md): each only
// once its extension is negotiated.
static vx_status p9_serve_posix(p9_server *s, const p9_msg *t, p9_msg *r) {
  bool xattr = t->type == P9_Tgetattr || t->type == P9_Tsetattr;
  if (!(s->extensions & (xattr ? P9_EXT_XATTR : P9_EXT_POSIX))) return VX_ERR_UNSUPPORTED;
  p9_fid *f = p9_fid_find(s, t->fid);
  if (!f) return VX_ERR_BAD_HANDLE;
  switch (t->type) {
  case P9_Tgetattr: {
    p9_stat st;
    vx_status e = s->fs.stat(s->fs.ctx, f->node, &st);
    if (e != VX_OK) return e;
    bool dir = st.mode & P9_DMDIR;
    r->attr = (p9_attr){.valid = P9_GETATTR_BASIC,
                        .qid = st.qid,
                        .mode = p9_posix_mode(st.mode),
                        .nlink = dir ? 2 : 1,
                        .size = st.length,
                        .blksize = 4096,
                        .blocks = (st.length + 511) / 512,
                        .atime_sec = st.atime,
                        .mtime_sec = st.mtime,
                        .ctime_sec = st.mtime,
                        .data_version = st.qid.version};
    return VX_OK;
  }
  case P9_Tsetattr: return s->fs.setattr ? s->fs.setattr(s->fs.ctx, f->node, &t->setattr) : VX_ERR_ACCESS;
  case P9_Trenameat: {
    p9_fid *to = p9_fid_find(s, t->newfid);
    if (!to) return VX_ERR_BAD_HANDLE;
    if (!(f->qid.type & P9_QTDIR) || !(to->qid.type & P9_QTDIR)) return VX_ERR_INVALID;
    if (!p9_new_name_ok(t->name) || !p9_new_name_ok(t->name2)) return VX_ERR_INVALID;
    if (!s->fs.rename) return VX_ERR_ACCESS;
    return s->fs.rename(s->fs.ctx, f->node, t->name, to->node, t->name2);
  }
  case P9_Tsymlink: {
    uint64_t node;
    if (!(f->qid.type & P9_QTDIR) || !p9_new_name_ok(t->name)) return VX_ERR_INVALID;
    if (!s->fs.symlink) return VX_ERR_ACCESS;
    vx_status e = s->fs.symlink(s->fs.ctx, f->node, t->name, t->name2, &node);
    if (e == VX_OK) e = p9_qid_of(s, node, &r->qid);
    if (e == VX_OK && s->fs.clunk) s->fs.clunk(s->fs.ctx, node, false); // no fid holds it
    return e;
  }
  case P9_Treadlink: return s->fs.readlink ? s->fs.readlink(s->fs.ctx, f->node, &r->name2) : VX_ERR_INVALID;
  case P9_Tfsync: return VX_OK;       // every server's writes are done when Rwrite is sent
  default: return VX_ERR_UNSUPPORTED; // Tlink: no server has hard links
  }
}

static constexpr size_t P9_DEFER = SIZE_MAX; // p9_serve: no reply yet; serve the request again later

// Handles one request (`len` bytes, one whole message) and writes the reply
// into resp. Returns the reply's length; 0 if the request was too broken to
// answer, in which case the transport should hang up; or P9_DEFER.
[[maybe_unused]] static size_t p9_serve(p9_server *s, const uint8_t *req, size_t len, uint8_t *resp,
                                        size_t cap) {
  p9_msg t, r = {};
  if (p9_decode(req, len, &t) != VX_OK) return 0;
  if (t.type % 2 || t.type == P9_Rerror) return 0; // only T-messages come to a server
  r.type = (p9_type)(t.type + 1);
  r.tag = t.tag;
  vx_status e = VX_OK;
  p9_fid *f = nullptr;

  if (t.type != P9_Tversion && !s->msize) {
    e = VX_ERR_BAD_STATE; // nothing before Tversion
  } else {
    switch (t.type) {
    case P9_Tversion: {
      for (uint32_t i = 0; i < P9_MAX_FIDS; i++)
        if (s->fids[i].used) p9_fid_drop(s, &s->fids[i]); // a new session
      uint32_t ext;
      s->dialect = p9_version_parse(t.version, &ext);
      s->extensions = ext & s->supported;
      s->msize = t.msize < s->max_msize ? t.msize : s->max_msize;
      if (s->msize < P9_MIN_MSIZE) {
        s->msize = 0;
        e = VX_ERR_TOO_SMALL;
        break;
      }
      r.msize = s->msize;
      r.version =
          (vx_str){s->version, p9_version_format(s->dialect, s->extensions, s->version, sizeof s->version)};
      if (s->dialect == P9_UNKNOWN) s->msize = 0; // "unknown": the client may try again
      break;
    }
    case P9_Tauth: e = VX_ERR_UNSUPPORTED; break; // tokens come with keyd (02 §3.4)
    case P9_Tattach:
      if (t.afid != P9_NOFID)
        e = VX_ERR_UNSUPPORTED;
      else if (!(f = p9_fid_new(s, t.fid)))
        e = VX_ERR_BAD_STATE;
      else if ((e = s->fs.attach(s->fs.ctx, t.aname, &f->node)) == VX_OK)
        e = p9_qid_of(s, f->node, &r.qid);
      if (e == VX_OK)
        f->root = f->node, f->qid = r.qid;
      else if (f)
        *f = (p9_fid){};
      break;
    case P9_Tflush: break;
    case P9_Twalk: {
      if (!(f = p9_fid_find(s, t.fid))) {
        e = VX_ERR_BAD_HANDLE;
        break;
      }
      if (f->open || (t.newfid != t.fid && p9_fid_find(s, t.newfid)) || t.newfid == P9_NOFID) {
        e = VX_ERR_BAD_STATE;
        break;
      }
      uint64_t node = f->node;
      p9_qid qid = f->qid;
      for (uint16_t i = 0; i < t.nwname; i++) {
        uint64_t next;
        vx_status step = p9_step(s, f->root, node, t.wname[i], &next);
        if (step == VX_OK) step = p9_qid_of(s, next, &qid);
        if (step != VX_OK) {
          if (i == 0) e = step; // nothing walked: an error; otherwise the qids so far, and no newfid
          break;
        }
        node = next;
        r.wqid[r.nwqid++] = qid;
      }
      if (e != VX_OK || r.nwqid != t.nwname) break;
      p9_fid *n = t.newfid == t.fid ? f : p9_fid_new(s, t.newfid);
      if (!n) {
        e = VX_ERR_NO_MEMORY; // too many fids
        break;
      }
      if (n == f && s->fs.clunk) s->fs.clunk(s->fs.ctx, f->node, false); // walked fids are never open
      uint64_t root = f->root;
      *n = (p9_fid){.fid = t.newfid, .used = true, .node = node, .root = root, .qid = qid};
      break;
    }
    case P9_Topen:
    case P9_Tcreate: {
      if (!(f = p9_fid_find(s, t.fid))) {
        e = VX_ERR_BAD_HANDLE;
        break;
      }
      if (f->open) {
        e = VX_ERR_BAD_STATE;
        break;
      }
      if (t.type == P9_Tcreate) {
        uint64_t node;
        bool dotdot = t.name.len == 2 && t.name.ptr[0] == '.' && t.name.ptr[1] == '.';
        if (!(f->qid.type & P9_QTDIR) || !p9_good_name(t.name) || dotdot)
          e = VX_ERR_INVALID;
        else if (!s->fs.create)
          e = VX_ERR_ACCESS;
        else
          e = s->fs.create(s->fs.ctx, f->node, t.name, t.perm, t.mode, &node);
        if (e == VX_OK) {
          if (s->fs.clunk) s->fs.clunk(s->fs.ctx, f->node, false);
          f->node = node;
          e = p9_qid_of(s, node, &f->qid);
        }
      } else {
        bool writes = (t.mode & 3) == P9_OWRITE || (t.mode & 3) == P9_ORDWR || (t.mode & P9_OTRUNC);
        if ((f->qid.type & P9_QTDIR) && writes)
          e = VX_ERR_ACCESS; // directories are only read
        else
          e = open_node(s, f, t.mode);
      }
      if (e != VX_OK) break;
      f->open = true;
      f->mode = t.mode;
      r.qid = f->qid;
      r.iounit = s->msize - P9_IOHDRSZ;
      break;
    }
    case P9_Tread: {
      if (!(f = p9_fid_find(s, t.fid))) {
        e = VX_ERR_BAD_HANDLE;
        break;
      }
      if (!f->open || (f->mode & 3) == P9_OWRITE) {
        e = VX_ERR_ACCESS;
        break;
      }
      // The data goes straight where Rread carries it: size, type, tag, count.
      uint32_t room = s->msize - P9_IOHDRSZ;
      if (cap < 11) return 0;
      if (cap - 11 < room) room = (uint32_t)(cap - 11);
      uint32_t count = t.count < room ? t.count : room;
      if (f->qid.type & P9_QTDIR)
        e = p9_read_dir(s, f, t.offset, resp + 11, count, &count);
      else
        e = s->fs.read(s->fs.ctx, f->node, t.offset, resp + 11, &count);
      r.data = (vx_bytes){resp + 11, count};
      break;
    }
    case P9_Twrite:
      if (!(f = p9_fid_find(s, t.fid)))
        e = VX_ERR_BAD_HANDLE;
      else if (!f->open || ((f->mode & 3) != P9_OWRITE && (f->mode & 3) != P9_ORDWR) || !s->fs.write)
        e = VX_ERR_ACCESS;
      else if (t.count > s->msize - P9_IOHDRSZ)
        e = VX_ERR_TOO_SMALL;
      else if ((e = s->fs.write(s->fs.ctx, f->node, t.offset, t.data.ptr, &t.count)) == VX_OK)
        r.count = t.count;
      break;
    case P9_Tclunk:
    case P9_Tremove:
      if (!(f = p9_fid_find(s, t.fid))) {
        e = VX_ERR_BAD_HANDLE;
        break;
      }
      if (t.type == P9_Tremove) e = s->fs.remove ? s->fs.remove(s->fs.ctx, f->node) : VX_ERR_ACCESS;
      p9_fid_drop(s, f); // a remove clunks the fid whether or not it worked
      break;
    case P9_Tstat: {
      p9_stat st;
      if (!(f = p9_fid_find(s, t.fid))) {
        e = VX_ERR_BAD_HANDLE;
      } else if ((e = s->fs.stat(s->fs.ctx, f->node, &st)) == VX_OK) {
        size_t n = p9_stat_encode(&st, s->stat, sizeof s->stat);
        if (!n) e = VX_ERR_TOO_SMALL;
        r.stat = (vx_bytes){s->stat, n};
      }
      break;
    }
    case P9_Twstat: e = VX_ERR_UNSUPPORTED; break; // renames and chmod: Trenameat and Tsetattr
    case P9_Tgetattr:
    case P9_Tsetattr:
    case P9_Trenameat:
    case P9_Tsymlink:
    case P9_Treadlink:
    case P9_Tfsync:
    case P9_Tlink: e = p9_serve_posix(s, &t, &r); break;
    default: return 0;
    }
  }
  if (e == VX_ERR_SHOULD_WAIT && (t.type == P9_Tread || t.type == P9_Twrite || t.type == P9_Topen))
    return P9_DEFER;
  if (e != VX_OK) r = (p9_msg){.type = P9_Rerror, .tag = t.tag, .ename = p9_error_text(e)};
  return p9_encode(&r, resp, cap);
}
