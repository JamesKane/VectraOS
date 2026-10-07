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
// server's device has done something (lib/vx-9p/ring_server.c), dropping it
// if a Tflush names it. Everything else completes as it arrives, so a Tflush
// finds nothing else to cancel.
//
// This file also does, for every file server (M6 step 6d4c1): ORCLOSE, the
// file removed as its last fid goes (a file server without remove refuses
// it); DMAPPEND, a write at the end whatever its offset (a file whose qid
// says QTAPPEND); and Twstat, mapped onto the file server's setattr and
// rename. DMEXCL is the file server's, which counts its opens; one that
// cannot keep DMAPPEND or DMEXCL in a mode refuses a create that asks.

#pragma once

#include <stdckdint.h>

#include "codec.c"
#include "../vx-rand/drbg.c"
#include "../vx-utf/utf.h"

typedef struct p9_fs {
  void *ctx;
  vx_status (*attach)(void *ctx, vx_str aname, uint64_t *root);
  // Optional: attach, told who attaches (Tattach's uname); used instead of
  // attach when set. Advisory until keyd (M10): a client can name anyone.
  vx_status (*attach_as)(void *ctx, vx_str aname, vx_str uname, uint64_t *root);
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
  // Optional (M6 step 6d5c): a fid has come to hold the node (+1), at an
  // attach, a walk, a create, a clone or a join, or let it go (-1), when it
  // is clunked or moves on; exactly paired, unlike clunk, which is told of
  // nodes no fid held. fsd counts the fids on each snapshot with it.
  void (*fid_node)(void *ctx, uint64_t node, int delta);
  // The posix and xattr extensions (docs/proto/posix.md), each optional: a
  // server without one refuses its message. Rgetattr needs nothing new: it
  // is made from stat.
  vx_status (*setattr)(void *ctx, uint64_t node, const p9_setattr *a);
  vx_status (*rename)(void *ctx, uint64_t olddir, vx_str oldname, uint64_t newdir, vx_str newname);
  vx_status (*symlink)(void *ctx, uint64_t dir, vx_str name, vx_str target, uint64_t *node);
  vx_status (*readlink)(void *ctx, uint64_t node, vx_str *target); // its bytes last until the next call
  // Optional: Tfsync, answered when it returns. A server that writes before
  // Rwrite has none; one that commits later (fsd) commits here.
  vx_status (*fsync)(void *ctx, uint64_t node);
  // The map extension (docs/proto/map.md), optional: a VMO for the file's
  // [offset, offset + length), with rights for prot and no more, where in
  // it the range starts, and how many bytes it has from there (the rest of
  // the range is past the file). The handle becomes the framework's, which
  // the transport hands to the client.
  vx_status (*map)(void *ctx, uint64_t node, uint64_t offset, uint64_t length, uint32_t prot, vx_handle *vmo,
                   uint64_t *vmo_offset, uint64_t *avail);
  // The dref extension (docs/proto/dref.md), optional: a file's bytes
  // copied into, or from, the client's VMO at roffset; *count as Tread's
  // and Twrite's. The VMO stays the framework's.
  vx_status (*read_ref)(void *ctx, uint64_t node, uint64_t offset, vx_handle vmo, uint64_t roffset,
                        uint32_t *count);
  vx_status (*write_ref)(void *ctx, uint64_t node, uint64_t offset, vx_handle vmo, uint64_t roffset,
                         uint32_t *count);
  // The srv extension (docs/proto/srv.md, M6 step 6d4d2a): an open whose
  // reply carries a handle (srvfs's connector; *out left VX_HANDLE_NONE for a
  // file with none to give), and a write that carries one (a post's), which
  // the file server takes. Both optional.
  vx_status (*open_handle)(void *ctx, uint64_t node, uint8_t mode, vx_handle *out);
  vx_status (*write_handle)(void *ctx, uint64_t node, vx_handle h);
} p9_fs;

enum : uint32_t { P9_MAX_FIDS = 256 }; // per connection, for now

// --- Open files and locks shared between connections (posix) ---
//
// An open fid on a server with the posix extension has an open file, kept
// here: its node, mode, offset and O_APPEND, shared by every fid that joins
// it, on any of the server's connections (docs/proto/posix.md). Tshare gives
// a token for it, good for `holds` joins within P9_HOLD_TIME of the last
// Tshare (or of its last fid's going, which a hold outlives so long): holds a
// client never used run out then, open file or not. A Tshare with no holds
// outstanding makes a new token, so an old one never joins again. Locks are POSIX's:
// byte ranges, owned by a connection and a process id, and let go when the
// owner lets go of any fid on the file.

enum : uint32_t { P9_MAX_OPEN_FILES = 256, P9_MAX_LOCKS = 256, P9_MAX_HOLDS = 64 };
static constexpr int64_t P9_HOLD_TIME = 10'000'000'000; // ns

typedef struct p9_open_file {
  bool used, append, shared;
  bool orclose; // opened with ORCLOSE: removed when its last fid goes
  uint8_t mode;
  uint64_t node, offset;
  uint32_t fids, holds;
  int64_t hold_until;
  uint8_t token[16];
} p9_open_file;

typedef struct p9_lock {
  bool used;
  uint8_t type;              // P9_LOCK_READ or P9_LOCK_WRITE
  uint64_t node, start, end; // [start, end); end UINT64_MAX: to the end of the file
  const void *conn;          // the owner: a connection and a process on it
  uint32_t proc_id;
} p9_lock;

// notify's watches (docs/proto/notify.md, M6 step 6e1d): a fid's, with the
// events queued for it since its last Tnotify was answered.
static constexpr uint32_t P9_MAX_WATCHES = 64, P9_WATCH_EVENTS = 32, P9_WATCH_NAME = 128;

typedef struct p9_event {
  uint8_t kind, len;
  char name[P9_WATCH_NAME];
} p9_event;

typedef struct p9_watch {
  bool used, lost;
  const void *conn; // the p9_server whose fid it is
  uint32_t fid;
  uint64_t node, mask;
  uint32_t head, count; // the queue, a ring in ev
  p9_event ev[P9_WATCH_EVENTS];
} p9_watch;

typedef struct p9_shared {
  p9_open_file files[P9_MAX_OPEN_FILES];
  p9_lock locks[P9_MAX_LOCKS];
  p9_watch watches[P9_MAX_WATCHES];
  uint32_t nwatches;
  bool again;           // an event was queued: a held Tnotify may be answered (ring_server)
  vx_drbg random;       // tokens; unseeded: Tshare is refused
  int64_t (*now)(void); // nanoseconds; null: holds never run out
} p9_shared;

typedef struct p9_fid {
  uint32_t fid;
  bool used, open;
  uint8_t mode;
  uint32_t file;       // its open file in p9_shared, plus 1; 0 for none
  uint64_t node, root; // root: where it was attached; `..` stops there
  p9_qid qid;
  uint64_t dir_offset; // a directory read continues only from here
  uint32_t dir_index;  // the next entry to read
  bool orclose;        // opened with ORCLOSE, and no open file shares it: removed as it is clunked
} p9_fid;

typedef struct p9_server {
  p9_fs fs;
  uint32_t max_msize; // the largest this server accepts
  uint32_t supported; // the 9Px extensions it implements
  uint32_t msize;     // negotiated; 0 until Tversion
  p9_dialect dialect;
  uint32_t extensions; // negotiated
  p9_fid fids[P9_MAX_FIDS];
  p9_shared *shared;  // the server's open files and locks, for posix; may be null
  char version[96];   // Rversion's string
  uint8_t stat[1024]; // Rstat's entry
} p9_server;

// The handles of the call being served, each thread's own: a call is served
// by one thread from start to finish, whether or not it lets the server go
// meanwhile (ring_server.c's p9_release, M6 step 6d5a), and other calls on
// the connection may be served then. The request's (dref's VMO), set by the
// transport, VX_HANDLE_NONE when it carried none; the reply's (Rmap's VMO),
// for the transport to pass on. Both the transport's to close.
static thread_local vx_handle p9_request_handle, p9_reply_handle;

// While not 0, the file server's calls keep the server's lock (ring_server.c's
// p9_release refuses): what is done in more than one call is then one step,
// as an append's end and its write, or a read at an open file's offset and
// the offset's moving on (M6 step 6d5b).
static thread_local uint32_t p9_keep_lock;

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

static int64_t p9_now(const p9_shared *sh) { return sh->now ? sh->now() : 0; }

static bool p9_file_live(const p9_shared *sh, const p9_open_file *o) {
  return o->used && (o->fids || (o->holds && (!sh->now || p9_now(sh) < o->hold_until)));
}

// Lets go of the owner's locks on node in [start, end): cut, shortened or
// split. False, with nothing changed, when a split finds no free slot.
static bool p9_unlock(p9_shared *sh, const void *conn, uint32_t proc_id, bool any_proc, uint64_t node,
                      uint64_t start, uint64_t end) {
  uint32_t free_slots = 0;
  for (uint32_t i = 0; i < P9_MAX_LOCKS; i++) free_slots += !sh->locks[i].used;
  for (uint32_t i = 0; i < P9_MAX_LOCKS; i++) {
    p9_lock *l = &sh->locks[i];
    if (!l->used || l->node != node || l->conn != conn || (!any_proc && l->proc_id != proc_id)) continue;
    if (l->end <= start || l->start >= end) continue;
    if (l->start < start && l->end > end) { // the middle: two pieces
      if (!free_slots) return false;
      for (uint32_t k = 0; k < P9_MAX_LOCKS; k++)
        if (!sh->locks[k].used) {
          sh->locks[k] = *l;
          sh->locks[k].start = end;
          free_slots--;
          break;
        }
      l->end = start;
    } else if (l->start < start) {
      l->end = start;
    } else if (l->end > end) {
      l->start = end;
    } else {
      l->used = false;
      free_slots++;
    }
  }
  return true;
}

static void p9_fid_holds(p9_server *s, uint64_t node, int delta) {
  if (s->fs.fid_node) s->fs.fid_node(s->fs.ctx, node, delta);
}

// --- notify (docs/proto/notify.md) ---
//
// Events are made here, where every change the framework serves passes, on
// every connection: a create, write, remove, rename, setattr or symlink.
// One queued wakes the held Tnotify that waits for it (p9_shared.again).

// Queues kind (name: the entry's, for a directory's watch) for node's watches.
static void p9_notify(p9_shared *sh, uint64_t node, uint8_t kind, vx_str name) {
  if (!sh || !sh->nwatches) return;
  for (uint32_t i = 0; i < P9_MAX_WATCHES; i++) {
    p9_watch *w = &sh->watches[i];
    if (!w->used || w->node != node || !(w->mask & kind)) continue;
    if (w->count == P9_WATCH_EVENTS) {
      w->lost = true; // full: the watcher reads again what it watches
      continue;
    }
    p9_event *e = &w->ev[(w->head + w->count++) % P9_WATCH_EVENTS];
    e->kind = kind, e->len = (uint8_t)(name.len < P9_WATCH_NAME ? name.len : P9_WATCH_NAME - 1);
    if (e->len) memcpy(e->name, name.ptr, e->len);
    sh->again = true;
  }
}

// node's directory and its name there: a change to a file is its
// directory's watchers' too. False if it has none (a root), or none is known.
static bool p9_notify_parent(p9_server *s, uint64_t node, uint64_t *parent, char name[P9_WATCH_NAME],
                             uint8_t *len) {
  p9_stat st;
  if (!s->shared || !s->shared->nwatches || !s->fs.parent || s->fs.parent(s->fs.ctx, node, parent) != VX_OK ||
      *parent == node || s->fs.stat(s->fs.ctx, node, &st) != VX_OK)
    return false;
  *len = (uint8_t)(st.name.len < P9_WATCH_NAME ? st.name.len : P9_WATCH_NAME - 1);
  memcpy(name, st.name.ptr, *len);
  return true;
}

// kind for node, and for its directory under its name.
static void p9_notify_up(p9_server *s, uint64_t node, uint8_t kind) {
  if (!s->shared || !s->shared->nwatches) return;
  p9_notify(s->shared, node, kind, (vx_str){});
  uint64_t parent;
  char name[P9_WATCH_NAME];
  uint8_t len;
  if (p9_notify_parent(s, node, &parent, name, &len)) p9_notify(s->shared, parent, kind, (vx_str){name, len});
}

// The file server's changes, each with its events.
static vx_status p9_fs_create(p9_server *s, uint64_t dir, vx_str name, uint32_t perm, uint8_t mode,
                              uint64_t *node) {
  vx_status e = s->fs.create(s->fs.ctx, dir, name, perm, mode, node);
  if (e == VX_OK) p9_notify(s->shared, dir, P9_NOTIFY_CREATE, name);
  return e;
}

static vx_status p9_fs_write(p9_server *s, uint64_t node, uint64_t offset, const uint8_t *buf,
                             uint32_t *count) {
  vx_status e = s->fs.write(s->fs.ctx, node, offset, buf, count);
  if (e == VX_OK) p9_notify_up(s, node, P9_NOTIFY_MODIFY);
  return e;
}

static vx_status p9_fs_remove(p9_server *s, uint64_t node) {
  uint64_t parent;
  char name[P9_WATCH_NAME];
  uint8_t len;
  bool up = p9_notify_parent(s, node, &parent, name, &len); // before: it is gone after
  vx_status e = s->fs.remove(s->fs.ctx, node);
  if (e == VX_OK) p9_notify(s->shared, node, P9_NOTIFY_REMOVE, (vx_str){});
  if (e == VX_OK && up) p9_notify(s->shared, parent, P9_NOTIFY_REMOVE, (vx_str){name, len});
  return e;
}

static vx_status p9_fs_rename(p9_server *s, uint64_t from, vx_str oldname, uint64_t to, vx_str newname) {
  vx_status e = s->fs.rename(s->fs.ctx, from, oldname, to, newname);
  if (e == VX_OK) p9_notify(s->shared, from, P9_NOTIFY_MOVED_FROM, oldname);
  if (e == VX_OK) p9_notify(s->shared, to, P9_NOTIFY_MOVED_TO, newname);
  return e;
}

static vx_status p9_fs_setattr(p9_server *s, uint64_t node, const p9_setattr *a) {
  vx_status e = s->fs.setattr(s->fs.ctx, node, a);
  if (e == VX_OK) p9_notify_up(s, node, P9_NOTIFY_ATTRIB);
  return e;
}

static void p9_watch_drop(p9_server *s, uint32_t fid) {
  p9_shared *sh = s->shared;
  for (uint32_t i = 0; sh && sh->nwatches && i < P9_MAX_WATCHES; i++)
    if (sh->watches[i].used && sh->watches[i].conn == s && sh->watches[i].fid == fid) {
      sh->watches[i].used = false;
      sh->nwatches--;
    }
}

// Tnotify: fid's watch, made at its first, its mask from this one; its
// events, as many as fit, or SHOULD_WAIT (held: an event wakes it).
static vx_status p9_serve_notify(p9_server *s, const p9_msg *t, p9_msg *r, uint8_t *out, uint32_t room) {
  p9_shared *sh = s->shared;
  if (!(s->extensions & P9_EXT_NOTIFY) || !sh) return VX_ERR_UNSUPPORTED;
  p9_fid *f = p9_fid_find(s, t->fid);
  if (!f) return VX_ERR_BAD_HANDLE;
  p9_watch *w = nullptr, *free_slot = nullptr;
  for (uint32_t i = 0; i < P9_MAX_WATCHES && !w; i++) {
    p9_watch *x = &sh->watches[i];
    if (x->used && x->conn == s && x->fid == t->fid) w = x;
    if (!x->used && !free_slot) free_slot = x;
  }
  if (!w && !free_slot) return VX_ERR_NO_MEMORY;
  if (!w)
    *(w = free_slot) = (p9_watch){.used = true, .conn = s, .fid = t->fid, .node = f->node}, sh->nwatches++;
  w->mask = t->mask;
  uint32_t n = 0;
  if (w->lost && room >= 3) out[n++] = P9_NOTIFY_LOST, out[n++] = 0, out[n++] = 0, w->lost = false;
  while (w->count && n + 3u + w->ev[w->head].len <= room) {
    const p9_event *e = &w->ev[w->head];
    out[n++] = e->kind, out[n++] = e->len, out[n++] = 0; // name[s]: len[2], then its bytes
    memcpy(out + n, e->name, e->len), n += e->len;
    w->head = (w->head + 1) % P9_WATCH_EVENTS, w->count--;
  }
  if (!n) return VX_ERR_SHOULD_WAIT;
  r->data = (vx_bytes){out, n};
  return VX_OK;
}

static void p9_fid_drop(p9_server *s, p9_fid *f) {
  p9_watch_drop(s, f->fid); // its watch goes with it
  p9_fid_holds(s, f->node, -1);
  bool remove = f->orclose;
  if (f->file && s->shared) {
    p9_open_file *o = &s->shared->files[f->file - 1];
    remove = remove || (o->orclose && o->fids == 1); // its last fid
  }
  if (remove && s->fs.remove) p9_fs_remove(s, f->node); // ORCLOSE; it may already be gone
  if (s->fs.clunk) s->fs.clunk(s->fs.ctx, f->node, f->open);
  if (f->file && s->shared) {
    p9_open_file *o = &s->shared->files[f->file - 1];
    if (o->fids) o->fids--;
    if (!o->fids && o->holds) o->hold_until = p9_now(s->shared) + P9_HOLD_TIME;
    if (!p9_file_live(s->shared, o)) o->used = false;
  }
  // POSIX: any close lets go, of a fid with an open file of its own or not
  // (a directory's; one opened when the table was full).
  if (f->open && s->shared) p9_unlock(s->shared, s, 0, true, f->node, 0, UINT64_MAX);
  *f = (p9_fid){};
}

// A new open file for a fid just opened: 0 if there is no room.
static uint32_t p9_file_new(p9_shared *sh, uint64_t node, uint8_t mode) {
  for (uint32_t i = 0; i < P9_MAX_OPEN_FILES; i++) {
    p9_open_file *o = &sh->files[i];
    if (p9_file_live(sh, o)) continue;
    *o = (p9_open_file){
        .used = true, .append = mode & P9_OAPPEND, .mode = mode & ~P9_OAPPEND, .node = node, .fids = 1};
    return i + 1;
  }
  return 0;
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
  p9_fid_holds(s, f->node, -1);
  f->node = node;
  p9_fid_holds(s, node, 1);
  f->qid = qid;
  return VX_OK;
}

// A name the file server may see: not empty, not ".", no '/'.
// A name a client may walk to, create or rename to: never empty, ".", or
// holding a '/'; and UTF-8 with no control characters (ADR-0013), so a server
// is safe from a client that does not use vx-ns.
static bool p9_good_name(vx_str n) {
  if (n.len == 0 || (n.len == 1 && n.ptr[0] == '.')) return false;
  for (size_t i = 0; i < n.len; i++)
    if (n.ptr[i] == '/') return false;
  return vx_utf_name(n.ptr, n.len);
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
    if ((e = s->fs.stat(s->fs.ctx, child, &st)) == VX_ERR_NOT_FOUND) { // gone since it was listed (6d5b)
      f->dir_index++;
      continue;
    }
    if (e != VX_OK) return e;
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

// Writes at the offset given, or at the open file's (P9_OFFSET_CURRENT): its
// end if it appends, which is atomic, the server's lock kept for the whole
// of it (p9_keep_lock).
static vx_status p9_write_at(p9_server *s, p9_fid *f, p9_msg *t, p9_msg *r);

static vx_status p9_write(p9_server *s, p9_fid *f, p9_msg *t, p9_msg *r) {
  bool keep = (f->qid.type & P9_QTAPPEND) || t->offset == P9_OFFSET_CURRENT;
  p9_keep_lock += keep;
  vx_status e = p9_write_at(s, f, t, r);
  p9_keep_lock -= keep;
  return e;
}

static vx_status p9_write_at(p9_server *s, p9_fid *f, p9_msg *t, p9_msg *r) {
  p9_open_file *o = f->file && s->shared ? &s->shared->files[f->file - 1] : nullptr;
  uint64_t offset = t->offset;
  if (f->qid.type & P9_QTAPPEND) { // DMAPPEND: at the end, whatever the offset
    p9_stat st;
    vx_status e = s->fs.stat(s->fs.ctx, f->node, &st);
    if (e != VX_OK) return e;
    offset = st.length;
  } else if (offset == P9_OFFSET_CURRENT) {
    if (!o) return VX_ERR_INVALID;
    offset = o->offset;
    if (o->append) {
      p9_stat st;
      vx_status e = s->fs.stat(s->fs.ctx, f->node, &st);
      if (e != VX_OK) return e;
      offset = st.length;
    }
  }
  vx_status e = p9_fs_write(s, f->node, offset, t->data.ptr, &t->count);
  if (e != VX_OK) return e;
  if (o && t->offset == P9_OFFSET_CURRENT) o->offset = offset + t->count;
  r->count = t->count;
  return VX_OK;
}

static bool p9_locks_conflict(const p9_lock *l, const void *conn, uint32_t proc_id, uint64_t node,
                              uint8_t type, uint64_t start, uint64_t end) {
  return l->used && l->node == node && (l->conn != conn || l->proc_id != proc_id) && l->start < end &&
         start < l->end && (type == P9_LOCK_WRITE || l->type == P9_LOCK_WRITE);
}

// Tlock and Tgetlock: POSIX's byte-range locks.
static vx_status p9_serve_lock(p9_server *s, const p9_fid *f, const p9_msg *t, p9_msg *r) {
  p9_shared *sh = s->shared;
  if (!sh || !f->open) return VX_ERR_BAD_STATE;
  uint64_t start = t->start, end = t->length ? t->start + t->length : UINT64_MAX;
  if (t->length && end < start) return VX_ERR_RANGE;
  if (t->lock_type > P9_LOCK_UNLOCK) return VX_ERR_INVALID;
  if (t->type == P9_Tgetlock) {
    *r = (p9_msg){.type = r->type,
                  .tag = r->tag,
                  .lock_type = P9_LOCK_UNLOCK,
                  .start = t->start,
                  .length = t->length,
                  .proc_id = t->proc_id,
                  .client_id = t->client_id};
    for (uint32_t i = 0; i < P9_MAX_LOCKS && t->lock_type != P9_LOCK_UNLOCK; i++) {
      const p9_lock *l = &sh->locks[i];
      if (!p9_locks_conflict(l, s, t->proc_id, f->node, t->lock_type, start, end)) continue;
      r->lock_type = l->type;
      r->start = l->start;
      r->length = l->end == UINT64_MAX ? 0 : l->end - l->start;
      r->proc_id = l->proc_id;
      r->client_id = VX_STR("");
      break;
    }
    return VX_OK;
  }
  // Any open fid may take either lock: fcntl's rule, a read lock on a file
  // open for reading and a write lock on one open for writing, is the
  // client's, as Linux's kernel keeps it; flock has none (M6 step 6d9a).
  r->status = P9_LOCK_SUCCESS;
  for (uint32_t i = 0; i < P9_MAX_LOCKS && t->lock_type != P9_LOCK_UNLOCK; i++)
    if (p9_locks_conflict(&sh->locks[i], s, t->proc_id, f->node, t->lock_type, start, end)) {
      r->status = P9_LOCK_BLOCKED; // the client waits and asks again (F_SETLKW)
      return VX_OK;
    }
  // The room it needs, found before anything changes, so an error leaves the
  // caller's locks as they were: a slot for the new lock, and one more if it
  // falls inside one of its own, which then splits in two.
  uint32_t free_slots = 0, need = t->lock_type != P9_LOCK_UNLOCK;
  for (uint32_t i = 0; i < P9_MAX_LOCKS; i++) {
    const p9_lock *l = &sh->locks[i];
    free_slots += !l->used;
    if (l->used && l->node == f->node && l->conn == s && l->proc_id == t->proc_id && l->start < start &&
        l->end > end)
      need++;
  }
  if (free_slots < need) {
    r->status = P9_LOCK_ERROR;
    return VX_OK;
  }
  uint32_t slot;
  if (!p9_unlock(sh, s, t->proc_id, false, f->node, start, end)) { // its own, replaced
    r->status = P9_LOCK_ERROR;
    return VX_OK;
  }
  if (t->lock_type == P9_LOCK_UNLOCK) return VX_OK;
  for (slot = 0; slot < P9_MAX_LOCKS && sh->locks[slot].used; slot++) {}
  if (slot == P9_MAX_LOCKS) {
    r->status = P9_LOCK_ERROR;
    return VX_OK;
  }
  sh->locks[slot] = (p9_lock){.used = true,
                              .type = t->lock_type,
                              .node = f->node,
                              .start = start,
                              .end = end,
                              .conn = s,
                              .proc_id = t->proc_id};
  return VX_OK;
}

// Tshare, Tjoin, Tseek and Tdesc: an open file shared between connections.
static vx_status p9_serve_share(p9_server *s, p9_fid *f, const p9_msg *t, p9_msg *r) {
  p9_shared *sh = s->shared;
  if (!sh) return VX_ERR_UNSUPPORTED;
  if (t->type == P9_Tjoin) {
    p9_open_file *o = nullptr;
    for (uint32_t i = 0; i < P9_MAX_OPEN_FILES && !o; i++) {
      p9_open_file *c = &sh->files[i];
      if (!p9_file_live(sh, c) || !c->shared || !c->holds || (sh->now && p9_now(sh) >= c->hold_until))
        continue;
      uint8_t diff = 0; // the whole token, every time
      for (size_t k = 0; k < sizeof c->token; k++) diff |= (uint8_t)(c->token[k] ^ t->token[k]);
      if (!diff) o = c;
    }
    if (!o) return VX_ERR_NOT_FOUND;
    p9_fid *n = p9_fid_new(s, t->newfid);
    if (!n) return VX_ERR_BAD_STATE;
    vx_status e = s->fs.open(s->fs.ctx, o->node, (o->mode & ~(P9_OTRUNC | P9_ORCLOSE | P9_OJOIN)) | P9_OJOIN);
    if (e != VX_OK) {
      *n = (p9_fid){};
      return e;
    }
    if ((e = p9_qid_of(s, o->node, &n->qid)) != VX_OK) {
      if (s->fs.clunk) s->fs.clunk(s->fs.ctx, o->node, true); // the open just made, let go
      *n = (p9_fid){};
      return e;
    }
    o->holds--;
    o->fids++;
    n->node = n->root = o->node;
    p9_fid_holds(s, n->node, 1);
    n->open = true;
    n->mode = o->mode;
    n->file = (uint32_t)(o - sh->files) + 1;
    r->qid = n->qid;
    r->iounit = s->msize - P9_IOHDRSZ;
    return VX_OK;
  }
  if (!f->file) return VX_ERR_BAD_STATE; // not open, or a directory
  p9_open_file *o = &sh->files[f->file - 1];
  switch (t->type) {
  case P9_Tshare:
    if (!sh->random.seeded) return VX_ERR_UNSUPPORTED;        // no token that cannot be guessed
    if (sh->now && p9_now(sh) >= o->hold_until) o->holds = 0; // run out, unused
    if (!t->holds || t->holds > P9_MAX_HOLDS || o->holds + t->holds > P9_MAX_HOLDS) return VX_ERR_RANGE;
    // A new token whenever none is outstanding (its holds used or run out), so
    // a token once given is never good again after its holds are gone.
    if (!o->shared || !o->holds) vx_drbg_read(&sh->random, o->token, sizeof o->token);
    o->shared = true;
    o->holds += t->holds;
    o->hold_until = p9_now(sh) + P9_HOLD_TIME;
    for (size_t k = 0; k < sizeof o->token; k++) r->token[k] = o->token[k];
    return VX_OK;
  case P9_Tseek: {
    int64_t base = 0;
    if (t->whence == 1) base = (int64_t)o->offset;
    if (t->whence == 2) {
      p9_stat st;
      vx_status e = s->fs.stat(s->fs.ctx, o->node, &st);
      if (e != VX_OK) return e;
      base = (int64_t)st.length;
    }
    int64_t at;
    if (t->whence > 2 || ckd_add(&at, base, (int64_t)t->offset) || at < 0) return VX_ERR_INVALID;
    o->offset = (uint64_t)at;
    r->offset = o->offset;
    return VX_OK;
  }
  case P9_Tdesc: o->append = t->desc_flags & 1; return VX_OK;
  default: return VX_ERR_UNSUPPORTED;
  }
}

// A stat's mode as POSIX has it, for Rgetattr.
static uint32_t p9_posix_mode(uint32_t mode) {
  uint32_t type = P9_S_IFREG;
  if (mode & P9_DMDIR) type = P9_S_IFDIR;
  if (mode & P9_DMSYMLINK) type = P9_S_IFLNK;
  if (mode & P9_DMDEVICE) type = P9_S_IFCHR;
  return type | (mode & 07777);
}

static bool p9_new_name_ok(vx_str name) {
  return p9_good_name(name) && !(name.len == 2 && name.ptr[0] == '.' && name.ptr[1] == '.');
}

// The posix and xattr extensions' messages (docs/proto/posix.md): each only
// once its extension is negotiated.
static vx_status p9_serve_posix(p9_server *s, const p9_msg *t, p9_msg *r) {
  bool xattr = t->type == P9_Tgetattr || t->type == P9_Tsetattr;
  bool linux_has = t->type != P9_Tshare && t->type != P9_Tjoin && t->type != P9_Tseek && t->type != P9_Tdesc;
  bool dotl = s->dialect == P9_2000L && linux_has; // 9P2000.L's own messages, which these extensions borrow
  if (!dotl && !(s->extensions & (xattr ? P9_EXT_XATTR : P9_EXT_POSIX))) return VX_ERR_UNSUPPORTED;
  if (t->type == P9_Tjoin) return p9_serve_share(s, nullptr, t, r);
  p9_fid *f = p9_fid_find(s, t->fid);
  if (!f) return VX_ERR_BAD_HANDLE;
  switch (t->type) {
  case P9_Tlock:
  case P9_Tgetlock: return p9_serve_lock(s, f, t, r);
  case P9_Tshare:
  case P9_Tseek:
  case P9_Tdesc: return p9_serve_share(s, f, t, r);
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
  case P9_Tsetattr: return s->fs.setattr ? p9_fs_setattr(s, f->node, &t->setattr) : VX_ERR_ACCESS;
  case P9_Trenameat: {
    p9_fid *to = p9_fid_find(s, t->newfid);
    if (!to) return VX_ERR_BAD_HANDLE;
    if (!(f->qid.type & P9_QTDIR) || !(to->qid.type & P9_QTDIR)) return VX_ERR_INVALID;
    if (!p9_new_name_ok(t->name) || !p9_new_name_ok(t->name2)) return VX_ERR_INVALID;
    if (!s->fs.rename) return VX_ERR_ACCESS;
    return p9_fs_rename(s, f->node, t->name, to->node, t->name2);
  }
  case P9_Tsymlink: {
    uint64_t node;
    if (!(f->qid.type & P9_QTDIR) || !p9_new_name_ok(t->name)) return VX_ERR_INVALID;
    if (!s->fs.symlink) return VX_ERR_ACCESS;
    vx_status e = s->fs.symlink(s->fs.ctx, f->node, t->name, t->name2, &node);
    if (e == VX_OK) p9_notify(s->shared, f->node, P9_NOTIFY_CREATE, t->name);
    if (e != VX_OK) return e;
    e = p9_qid_of(s, node, &r->qid);
    if (s->fs.clunk) s->fs.clunk(s->fs.ctx, node, false); // no fid holds it, whether its qid came or not
    return e;
  }
  case P9_Treadlink: return s->fs.readlink ? s->fs.readlink(s->fs.ctx, f->node, &r->name2) : VX_ERR_INVALID;
  case P9_Tfsync: return s->fs.fsync ? s->fs.fsync(s->fs.ctx, f->node) : VX_OK;
  default: return VX_ERR_UNSUPPORTED; // Tlink: no server has hard links
  }
}

// Tmap (docs/proto/map.md): only on a fid open for reading, and for
// writing too if the mapping writes, as POSIX's mmap asks of a descriptor.
static vx_status p9_serve_map(p9_server *s, const p9_msg *t, p9_msg *r) {
  if (!(s->extensions & P9_EXT_MAP) || !s->fs.map) return VX_ERR_UNSUPPORTED;
  p9_fid *f = p9_fid_find(s, t->fid);
  if (!f) return VX_ERR_BAD_HANDLE;
  uint8_t mode = f->mode & 3;
  uint64_t end;
  if (!f->open || (f->qid.type & P9_QTDIR) || mode == P9_OWRITE) return VX_ERR_ACCESS;
  if ((t->prot & P9_PROT_WRITE) && mode != P9_ORDWR) return VX_ERR_ACCESS;
  if (!t->length || (t->prot & ~(P9_PROT_READ | P9_PROT_WRITE | P9_PROT_EXEC)) ||
      ((t->prot & P9_PROT_WRITE) && (t->prot & P9_PROT_EXEC)))
    return VX_ERR_INVALID; // W^X (01 §11)
  if (ckd_add(&end, t->offset, t->length)) return VX_ERR_RANGE;
  vx_handle vmo = VX_HANDLE_NONE;
  vx_status e = s->fs.map(s->fs.ctx, f->node, t->offset, t->length, t->prot, &vmo, &r->offset, &r->length);
  if (e == VX_OK) p9_reply_handle = vmo;
  return e;
}

// Treadref and Twriteref (docs/proto/dref.md): Tread and Twrite, open
// files' offsets and appending too, with the data in the request's VMO.
static vx_status p9_serve_dref(p9_server *s, const p9_msg *t, p9_msg *r) {
  bool read = t->type == P9_Treadref;
  if (!(s->extensions & P9_EXT_DREF) || !(read ? s->fs.read_ref : s->fs.write_ref)) return VX_ERR_UNSUPPORTED;
  p9_fid *f = p9_fid_find(s, t->fid);
  if (!f) return VX_ERR_BAD_HANDLE;
  uint8_t mode = f->mode & 3;
  if (!f->open || (f->qid.type & P9_QTDIR)) return VX_ERR_ACCESS;
  if (read ? mode == P9_OWRITE : mode != P9_OWRITE && mode != P9_ORDWR) return VX_ERR_ACCESS;
  if (!p9_request_handle) return VX_ERR_INVALID; // no VMO came with it
  p9_open_file *o = f->file && s->shared ? &s->shared->files[f->file - 1] : nullptr;
  uint64_t offset = t->offset;
  if (offset == P9_OFFSET_CURRENT) {
    if (!o) return VX_ERR_INVALID;
    offset = o->offset;
    if (!read && o->append) {
      p9_stat st;
      vx_status e = s->fs.stat(s->fs.ctx, f->node, &st);
      if (e != VX_OK) return e;
      offset = st.length;
    }
  }
  uint32_t count = t->count;
  p9_keep_lock += t->offset == P9_OFFSET_CURRENT; // the offset, and its moving on, one step
  vx_status e = (read ? s->fs.read_ref : s->fs.write_ref)(s->fs.ctx, f->node, offset, p9_request_handle,
                                                          t->roffset, &count);
  p9_keep_lock -= t->offset == P9_OFFSET_CURRENT;
  if (e != VX_OK) return e;
  if (!read) p9_notify_up(s, f->node, P9_NOTIFY_MODIFY);
  if (o && t->offset == P9_OFFSET_CURRENT) o->offset = offset + count;
  r->count = count;
  return VX_OK;
}

// Twstat (stat(5)): the entry's fields that are not "don't touch" (all
// ones, or an empty string) are changed, all of them or none:
//   - name: a rename in the file's own directory (not of an attach root);
//   - length, mode (its permission bits; DMDIR as it is), mtime and atime:
//     the file server's setattr;
//   - type, dev, qid and muid may not change, nor uid (no chown in 9P);
//     gid only to what it is; DMAPPEND and DMEXCL only at create.
// The rename goes first, and back if setattr then fails. Nothing to change
// asks the file to be written out (fsync), as 9P has it.
static vx_status p9_serve_wstat(p9_server *s, const p9_fid *f, const p9_msg *t) {
  p9_stat w, cur;
  if (p9_stat_decode(t->stat.ptr, t->stat.len, &w) != VX_OK) return VX_ERR_INVALID;
  vx_status e = s->fs.stat(s->fs.ctx, f->node, &cur);
  if (e != VX_OK) return e;
  char old[256]; // the name, kept: the file server's strings last until its next call
  if (cur.name.len >= sizeof old) return VX_ERR_RANGE;
  memcpy(old, cur.name.ptr, cur.name.len);
  vx_str oldname = {old, cur.name.len};
  bool same_gid = !w.gid.len || (w.gid.len == cur.gid.len && !memcmp(w.gid.ptr, cur.gid.ptr, w.gid.len));
  bool same_uid = !w.uid.len || (w.uid.len == cur.uid.len && !memcmp(w.uid.ptr, cur.uid.ptr, w.uid.len));
  bool keep_qid =
      (w.qid.type == 0xff && w.qid.version == UINT32_MAX && w.qid.path == UINT64_MAX) ||
      (w.qid.type == cur.qid.type && w.qid.version == cur.qid.version && w.qid.path == cur.qid.path);
  if ((w.type != 0xffff && w.type != cur.type) || (w.dev != UINT32_MAX && w.dev != cur.dev) || !keep_qid ||
      w.muid.len)
    return VX_ERR_INVALID;
  if (!same_uid || !same_gid) return VX_ERR_ACCESS;
  p9_setattr a = {};
  if (w.mode != UINT32_MAX) {
    if ((w.mode ^ cur.mode) & P9_DMDIR) return VX_ERR_INVALID;
    if ((w.mode ^ cur.mode) & (P9_DMAPPEND | P9_DMEXCL | P9_DMSYMLINK | P9_DMDEVICE))
      return VX_ERR_UNSUPPORTED;
    a.valid |= P9_SETATTR_MODE, a.mode = w.mode & 0777;
  }
  if (w.length != UINT64_MAX) {
    if ((cur.mode & P9_DMDIR) && w.length != cur.length) return VX_ERR_INVALID;
    if (!(cur.mode & P9_DMDIR)) a.valid |= P9_SETATTR_SIZE, a.size = w.length;
  }
  if (w.mtime != UINT32_MAX) a.valid |= P9_SETATTR_MTIME | P9_SETATTR_MTIME_SET, a.mtime_sec = w.mtime;
  if (w.atime != UINT32_MAX) a.valid |= P9_SETATTR_ATIME | P9_SETATTR_ATIME_SET, a.atime_sec = w.atime;
  bool rename = w.name.len && (w.name.len != oldname.len || memcmp(w.name.ptr, old, oldname.len) != 0);
  if (!rename && !a.valid) return s->fs.fsync ? s->fs.fsync(s->fs.ctx, f->node) : VX_OK;
  if ((a.valid && !s->fs.setattr) || (rename && !s->fs.rename)) return VX_ERR_ACCESS;
  uint64_t dir = 0;
  if (rename) {
    if (f->node == f->root || !p9_new_name_ok(w.name))
      return f->node == f->root ? VX_ERR_ACCESS : VX_ERR_INVALID;
    if ((e = s->fs.parent(s->fs.ctx, f->node, &dir)) != VX_OK) return e;
    uint64_t there;
    if (s->fs.walk(s->fs.ctx, dir, w.name, &there) == VX_OK) { // 9P's rename replaces nothing
      if (s->fs.clunk) s->fs.clunk(s->fs.ctx, there, false);
      return VX_ERR_EXISTS;
    }
    if ((e = p9_fs_rename(s, dir, oldname, dir, w.name)) != VX_OK) return e;
  }
  if (a.valid && (e = p9_fs_setattr(s, f->node, &a)) != VX_OK) {
    if (rename) s->fs.rename(s->fs.ctx, dir, w.name, dir, oldname); // none of it, then
    return e;
  }
  return VX_OK;
}

// --- 9P2000.L (M6 step 6d4c2) ---
//
// Linux's dialect, for its `mount -t 9p` and the servers it speaks to. Its
// Tlopen and Tlcreate are Topen and Tcreate with Linux's flags (p9_serve
// turns them into those); its Tgetattr, Tsetattr, Trenameat, Tsymlink,
// Treadlink, Tfsync, Tlock and Tgetlock are the posix and xattr extensions'
// (which borrowed them); the rest are here. Errors go back as Rlerror, an
// errno.

// A 9P open mode from Linux's open flags.
static uint8_t p9_mode_of_flags(uint32_t flags) {
  uint8_t mode = P9_OREAD;
  if ((flags & P9_L_O_ACCMODE) == 1) mode = P9_OWRITE;
  if ((flags & P9_L_O_ACCMODE) == 2) mode = P9_ORDWR;
  if (flags & P9_L_O_TRUNC) mode |= P9_OTRUNC;
  return mode; // O_APPEND: Linux's client writes at the end itself
}

static uint8_t p9_dirent_type(uint32_t mode) {
  if (mode & P9_DMDIR) return P9_DT_DIR;
  if (mode & P9_DMSYMLINK) return P9_DT_LNK;
  if (mode & P9_DMDEVICE) return P9_DT_CHR;
  return P9_DT_REG;
}

// Rreaddir's entries from the cookie offset (an entry's index): qid[13]
// offset[8] type[1] name[s], each entry's offset the next one's cookie.
static vx_status p9_readdir_l(p9_server *s, const p9_fid *f, uint64_t cookie, uint8_t *out, uint32_t cap,
                              uint32_t *count) {
  uint32_t used = 0;
  for (uint64_t i = cookie; i < UINT32_MAX; i++) {
    uint64_t child;
    vx_status e = s->fs.readdir(s->fs.ctx, f->node, (uint32_t)i, &child);
    if (e == VX_ERR_NOT_FOUND) break;
    if (e != VX_OK) return e;
    p9_stat st;
    if ((e = s->fs.stat(s->fs.ctx, child, &st)) == VX_ERR_NOT_FOUND) continue; // gone since it was listed
    if (e != VX_OK) return e;
    p9_out o = {.buf = out + used, .cap = cap - used};
    p9_put_qid(&o, st.qid);
    p9_put(&o, i + 1, 8);
    p9_put(&o, p9_dirent_type(st.mode), 1);
    p9_put_str(&o, st.name);
    if (o.failed) {
      if (used == 0) return VX_ERR_TOO_SMALL; // not even one entry fits the count asked for
      break;
    }
    used += (uint32_t)o.len;
  }
  *count = used;
  return VX_OK;
}

// Tmkdir, Tunlinkat, Trename, Treaddir and Tstatfs.
static vx_status p9_serve_l(p9_server *s, const p9_msg *t, p9_msg *r, uint8_t *resp, size_t cap) {
  p9_fid *f = p9_fid_find(s, t->fid);
  if (!f) return VX_ERR_BAD_HANDLE;
  switch (t->type) {
  case P9_Tmkdir: {
    if (!(f->qid.type & P9_QTDIR) || !p9_new_name_ok(t->name)) return VX_ERR_INVALID;
    if (!s->fs.create) return VX_ERR_ACCESS;
    uint64_t node;
    vx_status e = p9_fs_create(s, f->node, t->name, P9_DMDIR | (t->lmode & 0777), P9_OREAD, &node);
    if (e != VX_OK) return e;
    e = p9_qid_of(s, node, &r->qid);
    if (s->fs.clunk) s->fs.clunk(s->fs.ctx, node, true); // the create opened it; no fid holds it
    return e;
  }
  case P9_Tunlinkat: {
    if (!(f->qid.type & P9_QTDIR) || !p9_new_name_ok(t->name)) return VX_ERR_INVALID;
    if (!s->fs.remove) return VX_ERR_ACCESS;
    uint64_t child;
    vx_status e = s->fs.walk(s->fs.ctx, f->node, t->name, &child);
    if (e != VX_OK) return e;
    p9_stat st;
    if ((e = s->fs.stat(s->fs.ctx, child, &st)) == VX_OK) {
      bool dir = st.mode & P9_DMDIR;
      if (dir != !!(t->lflags & P9_L_AT_REMOVEDIR))
        e = dir ? VX_ERR_ACCESS : VX_ERR_NOT_FOUND; // EISDIR, ENOTDIR as errno has them
      else
        e = p9_fs_remove(s, child);
    }
    if (s->fs.clunk) s->fs.clunk(s->fs.ctx, child, false);
    return e;
  }
  case P9_Trename: {
    p9_fid *to = p9_fid_find(s, t->newfid);
    if (!to) return VX_ERR_BAD_HANDLE;
    if (!(to->qid.type & P9_QTDIR) || !p9_new_name_ok(t->name)) return VX_ERR_INVALID;
    if (!s->fs.rename) return VX_ERR_ACCESS;
    if (f->node == f->root) return VX_ERR_ACCESS;
    p9_stat st;
    uint64_t dir;
    vx_status e = s->fs.stat(s->fs.ctx, f->node, &st);
    if (e != VX_OK) return e;
    char old[256];
    if (st.name.len >= sizeof old) return VX_ERR_RANGE;
    memcpy(old, st.name.ptr, st.name.len);
    if ((e = s->fs.parent(s->fs.ctx, f->node, &dir)) != VX_OK) return e;
    return p9_fs_rename(s, dir, (vx_str){old, st.name.len}, to->node, t->name);
  }
  case P9_Treaddir: {
    if (!f->open || !(f->qid.type & P9_QTDIR)) return VX_ERR_ACCESS;
    uint32_t room = s->msize - P9_IOHDRSZ;
    if (cap < 11) return VX_ERR_TOO_SMALL;
    if (cap - 11 < room) room = (uint32_t)(cap - 11);
    uint32_t count = t->count < room ? t->count : room;
    vx_status e = p9_readdir_l(s, f, t->offset, resp + 11, count, &count);
    if (e == VX_OK) r->data = (vx_bytes){resp + 11, count};
    return e;
  }
  case P9_Tstatfs: // what Linux's statfs asks for; the file servers keep no such numbers
    r->statfs = (p9_statfs){.type = 0x01021997, .bsize = 4096, .namelen = 255}; // V9FS_MAGIC
    return VX_OK;
  default: return VX_ERR_UNSUPPORTED;
  }
}

static constexpr size_t P9_DEFER = SIZE_MAX; // p9_serve: no reply yet; serve the request again later

// Handles one request (`len` bytes, one whole message) and writes the reply
// into resp. Returns the reply's length; 0 if the request was too broken to
// answer, in which case the transport should hang up; or P9_DEFER.
[[maybe_unused]] static size_t p9_serve(p9_server *s, const uint8_t *req, size_t len, uint8_t *resp,
                                        size_t cap) {
  p9_msg t, r = {};
  bool dotl = s->dialect == P9_2000L;
  if (p9_decode(req, len, &t) != VX_OK) {
    // A .L request this server does not know (Txattrwalk, Tmknod): Rlerror,
    // as Linux's client expects, not a hang-up.
    bool whole = len >= 7 && (req[0] | req[1] << 8 | req[2] << 16 | (uint32_t)req[3] << 24) == len;
    if (!dotl || !whole || req[4] % 2 || P9_FIELDS[req[4]]) return 0;
    r = (p9_msg){.type = P9_Rlerror, .tag = (uint16_t)(req[5] | req[6] << 8), .ecode = 95}; // EOPNOTSUPP
    return p9_encode(&r, resp, cap);
  }
  if (t.type % 2 || t.type == P9_Rerror || t.type == P9_Rlerror) return 0; // only T-messages come to a server
  r.type = (p9_type)(t.type + 1);
  r.tag = t.tag;
  if (dotl && t.type == P9_Tlopen) { // Topen, in Linux's words; Rlopen is Ropen's shape
    t.type = P9_Topen, t.mode = p9_mode_of_flags(t.lflags);
  } else if (dotl && t.type == P9_Tlcreate) { // Tcreate, likewise; a file, never a directory (Tmkdir)
    t.type = P9_Tcreate, t.perm = t.lmode & 0777, t.mode = p9_mode_of_flags(t.lflags);
  }
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
      else if ((e = s->fs.attach_as ? s->fs.attach_as(s->fs.ctx, t.aname, t.uname, &f->node)
                                    : s->fs.attach(s->fs.ctx, t.aname, &f->node)) == VX_OK)
        e = p9_qid_of(s, f->node, &r.qid);
      if (e == VX_OK)
        f->root = f->node, f->qid = r.qid, p9_fid_holds(s, f->node, 1);
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
      if (n == f) p9_fid_holds(s, f->node, -1);
      uint64_t root = f->root;
      *n = (p9_fid){.fid = t.newfid, .used = true, .node = node, .root = root, .qid = qid};
      p9_fid_holds(s, node, 1);
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
      if ((t.mode & P9_ORCLOSE) && !s->fs.remove) {
        e = VX_ERR_ACCESS; // nothing here is removed
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
          e = p9_fs_create(s, f->node, t.name, t.perm, t.mode & ~(P9_OAPPEND | P9_OJOIN), &node);
        if (e == VX_OK) {
          if (s->fs.clunk) s->fs.clunk(s->fs.ctx, f->node, false);
          p9_fid_holds(s, f->node, -1);
          f->node = node;
          p9_fid_holds(s, node, 1);
          e = p9_qid_of(s, node, &f->qid);
        }
      } else {
        bool writes = (t.mode & 3) == P9_OWRITE || (t.mode & 3) == P9_ORDWR || (t.mode & P9_OTRUNC);
        if ((f->qid.type & P9_QTDIR) && writes)
          e = VX_ERR_ACCESS; // directories are only read
        else
          e = open_node(s, f, t.mode & ~(P9_OAPPEND | P9_OJOIN));
      }
      if (e != VX_OK) break;
      if ((s->extensions & P9_EXT_POSIX) && s->shared && !(f->qid.type & P9_QTDIR)) {
        f->file = p9_file_new(s->shared, f->node, t.mode);
        if (!f->file) { // the server's table of open files is full: the open fails, now
          if (s->fs.clunk) s->fs.clunk(s->fs.ctx, f->node, true);
          e = VX_ERR_NO_MEMORY;
          break;
        }
      }
      if (t.type == P9_Topen && (s->extensions & P9_EXT_SRV) && s->fs.open_handle) {
        vx_handle h = VX_HANDLE_NONE; // srv: the reply carries it (a connector)
        e = s->fs.open_handle(s->fs.ctx, f->node, t.mode, &h);
        if (e != VX_OK) {
          if (f->file)
            s->shared->files[f->file - 1] = (p9_open_file){}, f->file = 0; // its open file, given back
          if (s->fs.clunk) s->fs.clunk(s->fs.ctx, f->node, true);
          break;
        }
        p9_reply_handle = h; // none, for a file that has no handle to give
      }
      f->open = true;
      f->mode = t.mode & ~(P9_OAPPEND | P9_OJOIN);
      if ((t.mode & P9_ORCLOSE) && f->file)
        s->shared->files[f->file - 1].orclose = true; // the open file's, which forks share
      else
        f->orclose = t.mode & P9_ORCLOSE;
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
      p9_open_file *o = f->file && s->shared ? &s->shared->files[f->file - 1] : nullptr;
      uint64_t offset = t.offset;
      if (offset == P9_OFFSET_CURRENT && !o) {
        e = VX_ERR_INVALID; // no open file keeps an offset for it
        break;
      }
      bool keep = o && offset == P9_OFFSET_CURRENT; // the offset, and its moving on, one step
      if (keep) offset = o->offset;
      p9_keep_lock += keep;
      if (f->qid.type & P9_QTDIR)
        e = p9_read_dir(s, f, offset, resp + 11, count, &count);
      else
        e = s->fs.read(s->fs.ctx, f->node, offset, resp + 11, &count);
      p9_keep_lock -= keep;
      if (e == VX_OK && keep) o->offset = offset + count;
      r.data = (vx_bytes){resp + 11, count};
      break;
    }
    case P9_Twrite:
      if (!(f = p9_fid_find(s, t.fid))) {
        e = VX_ERR_BAD_HANDLE;
      } else if (!f->open || ((f->mode & 3) != P9_OWRITE && (f->mode & 3) != P9_ORDWR) || !s->fs.write) {
        e = VX_ERR_ACCESS;
      } else if (t.count > s->msize - P9_IOHDRSZ) {
        e = VX_ERR_TOO_SMALL;
      } else if (p9_request_handle && (s->extensions & P9_EXT_SRV) && s->fs.write_handle) {
        e = s->fs.write_handle(s->fs.ctx, f->node, p9_request_handle); // srv: a post; the file server's now
        p9_request_handle = VX_HANDLE_NONE;
        r.count = t.count;
      } else {
        e = p9_write(s, f, &t, &r);
      }
      break;
    case P9_Tclunk:
    case P9_Tremove:
      if (!(f = p9_fid_find(s, t.fid))) {
        e = VX_ERR_BAD_HANDLE;
        break;
      }
      if (t.type == P9_Tremove) {
        e = s->fs.remove ? p9_fs_remove(s, f->node) : VX_ERR_ACCESS;
        f->orclose = false; // removed already, or not to be
        if (f->file && s->shared) s->shared->files[f->file - 1].orclose = false;
      }
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
    case P9_Twstat:
      if (!(f = p9_fid_find(s, t.fid)))
        e = VX_ERR_BAD_HANDLE;
      else
        e = p9_serve_wstat(s, f, &t);
      break;
    case P9_Tgetattr:
    case P9_Tsetattr:
    case P9_Trenameat:
    case P9_Tsymlink:
    case P9_Treadlink:
    case P9_Tfsync:
    case P9_Tlink:
    case P9_Tlock:
    case P9_Tgetlock:
    case P9_Tshare:
    case P9_Tjoin:
    case P9_Tseek:
    case P9_Tdesc: e = p9_serve_posix(s, &t, &r); break;
    case P9_Tmap: e = p9_serve_map(s, &t, &r); break;
    case P9_Tnotify: { // its events go where Rread's data does
      uint32_t room = s->msize - P9_IOHDRSZ;
      if (cap < 11) return 0;
      if (cap - 11 < room) room = (uint32_t)(cap - 11);
      e = p9_serve_notify(s, &t, &r, resp + 11, room);
      break;
    }
    case P9_Tmkdir:
    case P9_Tunlinkat:
    case P9_Trename:
    case P9_Treaddir:
    case P9_Tstatfs: e = dotl ? p9_serve_l(s, &t, &r, resp, cap) : VX_ERR_UNSUPPORTED; break;
    case P9_Treadref:
    case P9_Twriteref: e = p9_serve_dref(s, &t, &r); break;
    default: return 0;
    }
  }
  if (e == VX_ERR_SHOULD_WAIT &&
      (t.type == P9_Tread || t.type == P9_Twrite || t.type == P9_Topen || t.type == P9_Tnotify))
    return P9_DEFER; // held, and served again (a Tnotify when an event is queued)
  if (e != VX_OK && s->dialect == P9_2000L)
    r = (p9_msg){.type = P9_Rlerror, .tag = t.tag, .ecode = p9_status_errno(e)};
  else if (e != VX_OK)
    r = (p9_msg){.type = P9_Rerror, .tag = t.tag, .ename = p9_error_text(e)};
  return p9_encode(&r, resp, cap);
}
