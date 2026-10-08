// vx-ns's file calls as 09 has them (§5.5; ADR-0004 libvx v0, M6 step
// 6e4d1): a table of open files on the process's namespace (vx_ns_process),
// each a vx_fd of an index and a generation. Opening, closing and walking
// take the namespace's lock; a file's reads and writes take its slot's, so
// threads using different files do not wait on each other, and the 9P
// client is shared between them (6d4). Symbolic links are followed here, in
// the client (follow.c); servers walk names only.

#pragma once

#include <stdarg.h>
#include <stdckdint.h>

#include "../../abi/vx/file.h"
#include "follow.c"
#include "proc.c"

static constexpr uint32_t VX_FILES = 256;

typedef struct vx_file_slot {
  uint32_t gen;       // odd while open
  bool append;        // VX_OAPPEND where the server cannot: each write at the length it reports
  bool server_append; // VX_OAPPEND by the server (9Px's Tdesc): each write at its current offset
  vx_lock_t lock;
  vx_ns_file f;
  char *path; // the resolved path it was opened by (on the process heap), for vx_watch
  size_t path_len;
} vx_file_slot;

static vx_file_slot vx_files[VX_FILES];
static vx_lock_t vx_files_lock;

// A failed call's status, with its detail in vx_errstr: what and why.
static vx_status vx_file_fail(const char *what, vx_str path, vx_status st) {
  char buf[VX_ERRMAX];
  vx_str why = p9_error_text(st);
  size_t n =
      vx_bfmt((vx_bytes){(uint8_t *)buf, sizeof buf}, "%s %.*s: %.*s", what, VX_FMT(path), VX_FMT(why));
  vx_err_set((vx_str){buf, n});
  return st;
}

// A new slot for f, opened by path: its vx_fd, or a negative status (f closed).
static vx_fd vx_file_add(vx_ns_file *f, vx_str path, bool append, bool server_append) {
  char *copy = vx_heap_alloc(vx_heap_process(), path.len ? path.len : 1);
  if (copy) memcpy(copy, path.ptr, path.len);
  vx_lock(&vx_files_lock);
  uint32_t i = 0;
  while (i < VX_FILES && (vx_files[i].gen & 1)) i++;
  if (i == VX_FILES) {
    vx_unlock(&vx_files_lock);
    vx_ns_close(f);
    vx_heap_free(vx_heap_process(), copy);
    return vx_file_fail("open", VX_STR("a file"), VX_ERR_NO_MEMORY);
  }
  vx_file_slot *s = &vx_files[i];
  s->gen++;
  if (!(s->gen & 1)) s->gen++; // odd: open
  s->f = *f, s->append = append, s->server_append = server_append;
  s->path = copy, s->path_len = copy ? path.len : 0;
  vx_fd fd = (vx_fd)((s->gen & 0x7f'ffff) << 8 | i);
  vx_unlock(&vx_files_lock);
  return fd;
}

// fd's slot, locked, or nullptr: the standard streams are not here.
static vx_file_slot *vx_file_get(vx_fd fd) {
  if (fd < 256) return nullptr;
  vx_file_slot *s = &vx_files[(uint32_t)fd & 0xff];
  vx_lock(&s->lock);
  if (!(s->gen & 1) || (s->gen & 0x7f'ffff) != ((uint32_t)fd >> 8)) {
    vx_unlock(&s->lock);
    return nullptr;
  }
  return s;
}

// path with its links followed (with follow false, all but the last
// component's), into buf; under vx_ns_proc_lock.
static vx_status vx_file_resolve(vx_str path, bool follow, char buf[VX_NS_MAX_PATH], vx_str *out) {
  int64_t n = vx_ns_follow(vx_ns_process(), path, follow, buf);
  if (n < 0) return (vx_status)n;
  *out = (vx_str){buf, (size_t)n};
  return VX_OK;
}

static uint8_t vx_file_p9mode(vx_mode mode) { return (uint8_t)(mode & (3 | VX_OTRUNC | VX_ORCLOSE)); }

// Writes at the end, by the server (9Px's append) where it can.
static bool vx_file_server_append(vx_ns_file *f) { return f->c && p9c_append(f->c, f->fid, true) == VX_OK; }

VX_API vx_fd vx_open(vx_str path, vx_mode mode) {
  char buf[VX_NS_MAX_PATH];
  vx_str p;
  vx_ns_file f;
  vx_lock(&vx_ns_proc_lock);
  vx_status st = vx_file_resolve(path, true, buf, &p);
  if (st == VX_OK) st = vx_ns_open(vx_ns_process(), p, vx_file_p9mode(mode), &f);
  vx_unlock(&vx_ns_proc_lock);
  if (st != VX_OK) return vx_file_fail("open", path, st);
  bool server = (mode & VX_OAPPEND) && vx_file_server_append(&f);
  return vx_file_add(&f, p, (mode & VX_OAPPEND) && !server, server);
}

VX_API vx_fd vx_create(vx_str path, vx_mode mode, uint32_t perm) {
  char buf[VX_NS_MAX_PATH];
  vx_str p;
  vx_ns_file f;
  vx_ns *ns;
  vx_lock(&vx_ns_proc_lock);
  ns = vx_ns_process();
  vx_status resolved = vx_file_resolve(path, false, buf, &p);
  vx_status st = resolved == VX_OK ? vx_ns_create(ns, p, perm, vx_file_p9mode(mode), &f) : resolved;
  if (resolved == VX_OK && st == VX_ERR_EXISTS && !(mode & VX_OEXCL) &&
      !(perm & VX_DMDIR)) // there: emptied, as Plan 9's create
    st = vx_ns_open(ns, p, vx_file_p9mode(mode) | VX_OTRUNC, &f);
  vx_unlock(&vx_ns_proc_lock);
  if (st != VX_OK) return vx_file_fail("create", path, st);
  bool server = (mode & VX_OAPPEND) && vx_file_server_append(&f);
  return vx_file_add(&f, p, (mode & VX_OAPPEND) && !server, server);
}

VX_API vx_status vx_close(vx_fd fd) {
  vx_file_slot *s = vx_file_get(fd);
  if (!s) return fd >= 0 && fd < 3 ? VX_OK : vx_file_fail("close", VX_STR("a file"), VX_ERR_BAD_HANDLE);
  vx_ns_file f = s->f;
  char *path = s->path;
  vx_lock(&vx_files_lock);
  s->gen++; // even: free, and fd stale
  s->f = (vx_ns_file){};
  s->path = nullptr, s->path_len = 0;
  vx_unlock(&vx_files_lock);
  vx_unlock(&s->lock);
  vx_lock(&vx_ns_proc_lock);
  vx_ns_close(&f);
  vx_unlock(&vx_ns_proc_lock);
  vx_heap_free(vx_heap_process(), path);
  return VX_OK;
}

static uint32_t vx_file_count(size_t n) { return n > UINT32_MAX ? UINT32_MAX : (uint32_t)n; }

VX_API int64_t vx_read(vx_fd fd, vx_bytes buf) {
  if (fd == VX_STDIN) return vx_stdin_read(buf.ptr, vx_file_count(buf.len));
  vx_file_slot *s = vx_file_get(fd);
  if (!s) return vx_file_fail("read", VX_STR("a file"), VX_ERR_BAD_HANDLE);
  int64_t n = vx_ns_read(&s->f, buf.ptr, vx_file_count(buf.len));
  vx_unlock(&s->lock);
  return n < 0 ? vx_file_fail("read", VX_STR("a file"), (vx_status)n) : n;
}

// The file's length, by the server's word.
static int64_t vx_file_length(vx_ns_file *f) {
  p9_stat st;
  if (!f->c) return VX_ERR_UNSUPPORTED;
  vx_status e = p9c_stat(f->c, f->fid, &st, nullptr);
  return e == VX_OK ? (int64_t)st.length : e;
}

VX_API int64_t vx_write(vx_fd fd, vx_str data) {
  if (fd == VX_STDOUT || fd == VX_STDERR) {
    (fd == VX_STDOUT ? vx_print : vx_eprint)(data);
    return (int64_t)data.len;
  }
  vx_file_slot *s = vx_file_get(fd);
  if (!s) return vx_file_fail("write", VX_STR("a file"), VX_ERR_BAD_HANDLE);
  int64_t n = 0;
  if (s->append && (n = vx_file_length(&s->f)) >= 0) s->f.offset = (uint64_t)n;
  if (n >= 0 && s->server_append) // at the server's offset, which it moves to the end first (posix.md)
    n = p9c_write(s->f.c, s->f.fid, P9_OFFSET_CURRENT, data.ptr, vx_file_count(data.len));
  else if (n >= 0)
    n = vx_ns_write(&s->f, data.ptr, vx_file_count(data.len));
  vx_unlock(&s->lock);
  return n < 0 ? vx_file_fail("write", VX_STR("a file"), (vx_status)n) : n;
}

VX_API int64_t vx_pread(vx_fd fd, vx_bytes buf, uint64_t off) {
  vx_file_slot *s = vx_file_get(fd);
  if (!s) return vx_file_fail("read", VX_STR("a file"), VX_ERR_BAD_HANDLE);
  int64_t n = s->f.c && !s->f.dev ? p9c_read(s->f.c, s->f.fid, off, buf.ptr, vx_file_count(buf.len))
                                  : VX_ERR_UNSUPPORTED;
  vx_unlock(&s->lock);
  return n < 0 ? vx_file_fail("read", VX_STR("a file"), (vx_status)n) : n;
}

VX_API int64_t vx_pwrite(vx_fd fd, vx_str data, uint64_t off) {
  vx_file_slot *s = vx_file_get(fd);
  if (!s) return vx_file_fail("write", VX_STR("a file"), VX_ERR_BAD_HANDLE);
  int64_t n = s->f.c && !s->f.dev ? p9c_write(s->f.c, s->f.fid, off, data.ptr, vx_file_count(data.len))
                                  : VX_ERR_UNSUPPORTED;
  vx_unlock(&s->lock);
  return n < 0 ? vx_file_fail("write", VX_STR("a file"), (vx_status)n) : n;
}

VX_API int64_t vx_seek(vx_fd fd, int64_t off, uint32_t whence) {
  vx_file_slot *s = vx_file_get(fd);
  if (!s) return vx_file_fail("seek", VX_STR("a file"), VX_ERR_BAD_HANDLE);
  int64_t base = 0;
  if (whence == VX_SEEK_CUR) base = (int64_t)s->f.offset;
  if (whence == VX_SEEK_END) base = vx_file_length(&s->f);
  int64_t at = base;
  if (whence > VX_SEEK_END || base < 0 || ckd_add(&at, base, off) || at < 0)
    at = base < 0 ? base : VX_ERR_INVALID;
  if (at >= 0) s->f.offset = (uint64_t)at;
  vx_unlock(&s->lock);
  return at < 0 ? vx_file_fail("seek", VX_STR("a file"), (vx_status)at) : at;
}

// --- What a file is ---

VX_API vx_dir vx_dir_keep(void) {
  return (vx_dir){.qid = {UINT64_MAX, UINT32_MAX, 0xff},
                  .dev = UINT64_MAX,
                  .mode = UINT32_MAX,
                  .length = UINT64_MAX,
                  .atime = VX_INFINITE,
                  .mtime = VX_INFINITE};
}

static vx_str vx_file_copy(vx_arena *a, vx_str s) {
  if (!s.len) return VX_STR("");
  char *p = vx_push(a, s.len, 1);
  if (!p) return VX_STR("");
  memcpy(p, s.ptr, s.len);
  return (vx_str){p, s.len};
}

// A 9P stat entry as a vx_dir, its strings copied into a.
static void vx_file_dir_of(const p9_stat *s, uint64_t dev, vx_arena *a, vx_dir *out) {
  *out = (vx_dir){.name = vx_file_copy(a, s->name),
                  .uid = vx_file_copy(a, s->uid),
                  .gid = vx_file_copy(a, s->gid),
                  .muid = vx_file_copy(a, s->muid),
                  .qid = {s->qid.path, s->qid.version, s->qid.type},
                  .dev = dev,
                  .mode = s->mode,
                  .length = s->length,
                  .atime = (vx_instant)s->atime * 1'000'000'000,
                  .mtime = (vx_instant)s->mtime * 1'000'000'000};
}

// fid's vx_dir: Tstat's, with Tgetattr's nanosecond times where the server
// has it. 9P2000.L carries no names: the name is the path's last element,
// the owners numbers.
static vx_status vx_file_fill(p9_client *c, uint32_t fid, vx_str path, vx_arena *a, vx_dir *out) {
  static thread_local p9_stat_text keep;
  p9_stat s;
  bool dotl = c->dialect == P9_2000L;
  vx_status st = p9c_stat(c, fid, &s, dotl ? nullptr : &keep);
  if (st != VX_OK) return st;
  vx_file_dir_of(&s, vx_ns_conn_id(vx_ns_process(), c), a, out);
  p9_attr at;
  if (((c->extensions & P9_EXT_POSIX) || dotl) && p9c_getattr(c, fid, &at) == VX_OK) {
    out->atime = (vx_instant)(at.atime_sec * 1'000'000'000 + at.atime_nsec);
    out->mtime = (vx_instant)(at.mtime_sec * 1'000'000'000 + at.mtime_nsec);
    if (dotl) {
      out->uid = vx_fmt(a, "%u", at.uid);
      out->gid = vx_fmt(a, "%u", at.gid);
    }
  }
  if (!out->name.len) {
    size_t slash = path.len;
    while (slash > 0 && path.ptr[slash - 1] != '/') slash--;
    out->name = vx_file_copy(a, vx_str_cut(path, slash, path.len));
  }
  return VX_OK;
}

static vx_status vx_file_stat(vx_str path, bool follow, vx_arena *a, vx_dir *out) {
  char buf[VX_NS_MAX_PATH];
  vx_str p;
  p9_client *c = nullptr;
  uint32_t fid = 0;
  vx_lock(&vx_ns_proc_lock);
  vx_status st = vx_file_resolve(path, follow, buf, &p);
  if (st == VX_OK) st = vx_ns_walk(vx_ns_process(), p, &c, &fid);
  if (st == VX_OK) {
    st = vx_file_fill(c, fid, p, a, out);
    p9c_clunk(c, fid);
  }
  vx_unlock(&vx_ns_proc_lock);
  return st == VX_OK ? VX_OK : vx_file_fail("stat", path, st);
}

VX_API vx_status vx_stat(vx_str path, vx_arena *a, vx_dir *out) { return vx_file_stat(path, true, a, out); }
VX_API vx_status vx_lstat(vx_str path, vx_arena *a, vx_dir *out) { return vx_file_stat(path, false, a, out); }

VX_API vx_status vx_fstat(vx_fd fd, vx_arena *a, vx_dir *out) {
  vx_file_slot *s = vx_file_get(fd);
  if (!s) return vx_file_fail("stat", VX_STR("a file"), VX_ERR_BAD_HANDLE);
  vx_status st = s->f.c && !s->f.dev ? VX_OK : VX_ERR_UNSUPPORTED;
  if (st == VX_OK) {
    vx_lock(&vx_ns_proc_lock);
    st = vx_file_fill(s->f.c, s->f.fid, VX_STR(""), a, out);
    vx_unlock(&vx_ns_proc_lock);
  }
  vx_unlock(&s->lock);
  return st == VX_OK ? VX_OK : vx_file_fail("stat", VX_STR("a file"), st);
}

// Twstat, or Tsetattr where the server has it and only the mode, length and
// times change (it keeps nanoseconds; a 9P stat seconds).
VX_API vx_status vx_wstat(vx_str path, const vx_dir *d) {
  char buf[VX_NS_MAX_PATH];
  vx_str p;
  p9_client *c = nullptr;
  uint32_t fid = 0;
  vx_lock(&vx_ns_proc_lock);
  vx_status st = vx_file_resolve(path, true, buf, &p);
  if (st == VX_OK) st = vx_ns_walk(vx_ns_process(), p, &c, &fid);
  if (st == VX_OK) {
    bool names = d->name.len || d->uid.len || d->gid.len;
    if (!names && ((c->extensions & P9_EXT_POSIX) || c->dialect == P9_2000L)) {
      p9_setattr sa = {};
      if (d->mode != UINT32_MAX) sa.valid |= P9_SETATTR_MODE, sa.mode = d->mode & 07777;
      if (d->length != UINT64_MAX) sa.valid |= P9_SETATTR_SIZE, sa.size = d->length;
      if (d->mtime != VX_INFINITE) {
        sa.valid |= P9_SETATTR_MTIME | P9_SETATTR_MTIME_SET;
        sa.mtime_sec = (uint64_t)(d->mtime / 1'000'000'000),
        sa.mtime_nsec = (uint64_t)(d->mtime % 1'000'000'000);
      }
      if (d->atime != VX_INFINITE) {
        sa.valid |= P9_SETATTR_ATIME | P9_SETATTR_ATIME_SET;
        sa.atime_sec = (uint64_t)(d->atime / 1'000'000'000),
        sa.atime_nsec = (uint64_t)(d->atime % 1'000'000'000);
      }
      st = sa.valid ? p9c_setattr(c, fid, &sa) : VX_OK;
    } else {
      p9_stat w = p9_stat_untouched();
      w.name = d->name, w.uid = d->uid, w.gid = d->gid;
      w.mode = d->mode, w.length = d->length;
      if (d->mtime != VX_INFINITE) w.mtime = (uint32_t)(d->mtime / 1'000'000'000);
      if (d->atime != VX_INFINITE) w.atime = (uint32_t)(d->atime / 1'000'000'000);
      st = p9c_wstat(c, fid, &w);
    }
    p9c_clunk(c, fid);
  }
  vx_unlock(&vx_ns_proc_lock);
  return st == VX_OK ? VX_OK : vx_file_fail("wstat", path, st);
}

VX_API int64_t vx_dirread(vx_fd fd, vx_arena *a, vx_dir **out) {
  *out = nullptr;
  vx_file_slot *s = vx_file_get(fd);
  if (!s) return vx_file_fail("read", VX_STR("a directory"), VX_ERR_BAD_HANDLE);
  vx_arena *tmp = vx_scratch(&a, 1);
  vx_mark m = vx_arena_mark(tmp);
  static constexpr uint32_t CHUNK = 16 * 1024;
  uint8_t *buf = vx_push(tmp, CHUNK, 8);
  vx_dir *list = nullptr; // in tmp, after buf: one after another
  int64_t n = 0, got = 0;
  uint64_t dev = s->f.c ? vx_ns_conn_id(vx_ns_process(), s->f.c) : 0;
  while (buf && (got = vx_ns_read(&s->f, buf, CHUNK)) > 0) {
    p9_stat e;
    for (size_t at = 0; p9_dir_next(buf, (size_t)got, &at, &e);) {
      vx_dir *d = vx_push(tmp, sizeof *d, alignof(vx_dir));
      if (!d) break;
      if (!list) list = d;
      vx_file_dir_of(&e, dev, a, d);
      n++;
    }
  }
  vx_unlock(&s->lock);
  if (got < 0 || !buf) {
    vx_arena_pop(tmp, m);
    return vx_file_fail("read", VX_STR("a directory"), got < 0 ? (vx_status)got : VX_ERR_NO_MEMORY);
  }
  if (n) {
    *out = vx_push(a, (size_t)n * sizeof(vx_dir), alignof(vx_dir));
    if (*out) memcpy(*out, list, (size_t)n * sizeof(vx_dir));
  }
  vx_arena_pop(tmp, m);
  return n && !*out ? vx_file_fail("read", VX_STR("a directory"), VX_ERR_NO_MEMORY) : n;
}

// --- Names ---

VX_API vx_status vx_remove(vx_str path) {
  char buf[VX_NS_MAX_PATH];
  vx_str p;
  p9_client *c = nullptr;
  uint32_t fid = 0;
  vx_lock(&vx_ns_proc_lock);
  vx_status st = vx_file_resolve(path, false, buf, &p);
  if (st == VX_OK) st = vx_ns_walk(vx_ns_process(), p, &c, &fid);
  if (st == VX_OK) st = p9c_remove(c, fid); // which clunks it
  vx_unlock(&vx_ns_proc_lock);
  return st == VX_OK ? VX_OK : vx_file_fail("remove", path, st);
}

// path's directory walked, and its last element; under vx_ns_proc_lock.
static vx_status vx_file_parent(vx_str path, p9_client **c, uint32_t *fid, vx_str *name) {
  size_t slash = path.len;
  while (slash > 0 && path.ptr[slash - 1] != '/') slash--;
  *name = vx_str_cut(path, slash, path.len);
  if (!name->len) return VX_ERR_INVALID;
  vx_str dir = VX_STR("."); // a name alone: in the current directory
  if (slash) dir = (vx_str){path.ptr, slash > 1 ? slash - 1 : 1};
  return vx_ns_walk(vx_ns_process(), dir, c, fid);
}

// Within one server: by Trenameat where it has it, else by Twstat within one
// directory, what is there removed first, as musl's back end does.
static vx_status vx_file_rename(p9_client *c, uint32_t f1, vx_str n1, uint32_t f2, vx_str n2, bool same_dir) {
  if ((c->extensions & P9_EXT_POSIX) || c->dialect == P9_2000L) return p9c_renameat(c, f1, n1, f2, n2);
  if (!same_dir) return VX_ERR_UNSUPPORTED;
  vx_status st = p9c_rename_wstat(c, f1, n1, n2);
  uint32_t there = 0;
  if (st == VX_ERR_EXISTS && p9c_walk(c, f1, n2, &there) == VX_OK && p9c_remove(c, there) == VX_OK)
    st = p9c_rename_wstat(c, f1, n1, n2);
  return st;
}

VX_API vx_status vx_rename(vx_str from, vx_str to) {
  char b1[VX_NS_MAX_PATH], b2[VX_NS_MAX_PATH];
  vx_str p1, p2, n1 = {}, n2 = {};
  p9_client *c1 = nullptr, *c2 = nullptr;
  uint32_t f1 = 0, f2 = 0;
  vx_lock(&vx_ns_proc_lock);
  vx_status st = vx_file_resolve(from, false, b1, &p1);
  if (st == VX_OK) st = vx_file_resolve(to, false, b2, &p2);
  vx_status s1 = st == VX_OK ? vx_file_parent(p1, &c1, &f1, &n1) : st;
  vx_status s2 = s1 == VX_OK ? vx_file_parent(p2, &c2, &f2, &n2) : s1;
  if (s2 == VX_OK) {
    size_t d1 = (size_t)(n1.ptr - p1.ptr), d2 = (size_t)(n2.ptr - p2.ptr);
    bool same_dir = d1 == d2 && memcmp(p1.ptr, p2.ptr, d1) == 0;
    st = c1 == c2 ? vx_file_rename(c1, f1, n1, f2, n2, same_dir) : VX_ERR_UNSUPPORTED;
  } else {
    st = s2;
  }
  if (s1 == VX_OK) p9c_clunk(c1, f1);
  if (s2 == VX_OK) p9c_clunk(c2, f2);
  vx_unlock(&vx_ns_proc_lock);
  return st == VX_OK ? VX_OK : vx_file_fail("rename", from, st);
}

VX_API vx_status vx_symlink(vx_str target, vx_str path) {
  char buf[VX_NS_MAX_PATH];
  vx_str p, name = {};
  p9_client *c = nullptr;
  uint32_t fid = 0;
  vx_lock(&vx_ns_proc_lock);
  vx_status st = vx_file_resolve(path, false, buf, &p);
  vx_status walked = st == VX_OK ? vx_file_parent(p, &c, &fid, &name) : st;
  st = walked == VX_OK ? p9c_symlink(c, fid, name, target) : walked;
  if (walked == VX_OK) p9c_clunk(c, fid);
  vx_unlock(&vx_ns_proc_lock);
  return st == VX_OK ? VX_OK : vx_file_fail("symlink", path, st);
}

VX_API vx_status vx_readlink(vx_str path, vx_arena *a, vx_str *target) {
  char buf[VX_NS_MAX_PATH], link[VX_NS_MAX_PATH];
  vx_str p;
  size_t len = 0;
  p9_client *c = nullptr;
  uint32_t fid = 0;
  vx_lock(&vx_ns_proc_lock);
  vx_status st = vx_file_resolve(path, false, buf, &p);
  if (st == VX_OK) st = vx_ns_walk(vx_ns_process(), p, &c, &fid);
  if (st == VX_OK) {
    st = p9c_readlink(c, fid, link, sizeof link, &len);
    p9c_clunk(c, fid);
  }
  vx_unlock(&vx_ns_proc_lock);
  if (st != VX_OK) return vx_file_fail("readlink", path, st);
  *target = vx_file_copy(a, (vx_str){link, len});
  return VX_OK;
}

VX_API vx_status vx_sync(vx_fd fd) {
  vx_file_slot *s = vx_file_get(fd);
  if (!s) return vx_file_fail("sync", VX_STR("a file"), VX_ERR_BAD_HANDLE);
  vx_status st = s->f.c && !s->f.dev ? p9c_fsync(s->f.c, s->f.fid) : VX_ERR_UNSUPPORTED;
  vx_unlock(&s->lock);
  return st == VX_OK ? VX_OK : vx_file_fail("sync", VX_STR("a file"), st);
}

// --- Mapped files (01 §5) ---

VX_API vx_status vx_map(vx_fd fd, uint64_t off, size_t len, uint32_t prot, void **addr) {
  *addr = nullptr;
  if (!len || (off & 4095) || (prot & ~(uint32_t)(VX_MAP_WRITE | VX_MAP_EXEC)) ||
      (prot == (VX_MAP_WRITE | VX_MAP_EXEC)))
    return vx_file_fail("map", VX_STR("a file"), VX_ERR_INVALID); // W^X (01 §11)
  vx_file_slot *s = vx_file_get(fd);
  if (!s) return vx_file_fail("map", VX_STR("a file"), VX_ERR_BAD_HANDLE);
  uint32_t p9prot =
      P9_PROT_READ | (prot & VX_MAP_WRITE ? P9_PROT_WRITE : 0) | (prot & VX_MAP_EXEC ? P9_PROT_EXEC : 0);
  size_t size = (len + 4095) & ~(size_t)4095;
  vx_handle vmo = VX_HANDLE_NONE;
  uint64_t from = 0, avail = 0, at = 0;
  vx_status st = s->f.c && !s->f.dev ? p9c_map(s->f.c, s->f.fid, off, size, p9prot, &vmo, &from, &avail)
                                     : VX_ERR_UNSUPPORTED;
  vx_unlock(&s->lock);
  if (st == VX_OK) {
    st = vx_as_map(vx_self, vmo, from, avail < size ? avail : size, prot | VX_MAP_SHARED, &at);
    vx_handle_close(vmo); // the mapping keeps it
  }
  if (st != VX_OK) return vx_file_fail("map", VX_STR("a file"), st);
  *addr = (void *)at;
  return VX_OK;
}

VX_API vx_status vx_unmap(void *addr, size_t len) {
  return vx_as_unmap(vx_self, (uint64_t)addr, (len + 4095) & ~(size_t)4095);
}

// --- ctl ---

VX_API vx_status vx_ctl(vx_str path, const char *fmt, ...) {
  char msg[VX_ERRMAX * 8];
  va_list ap;
  va_start(ap, fmt);
  size_t n = vx_vbfmt((vx_bytes){(uint8_t *)msg, sizeof msg}, fmt, ap);
  va_end(ap);
  vx_fd fd = vx_open(path, VX_OWRITE);
  if (fd < 0) return (vx_status)fd;
  int64_t w = vx_write(fd, (vx_str){msg, n});
  vx_close(fd);
  if (w >= 0 && (size_t)w != n) return vx_file_fail("ctl", path, VX_ERR_IO);
  return w < 0 ? (vx_status)w : VX_OK;
}
