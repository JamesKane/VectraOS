// libvx-fs.c: the native target's C++ std::filesystem underneath (M6 step
// 6e2e2, ADR-0033 section 2a stage 4): libc++'s vectraos branch (LLVM patch
// 0013) calls these, which libvx.c includes, over vx-ns and 9P directly; no
// POSIX in between. Paths are UTF-8 (ADR-0013), relative ones from the
// working directory (ADR-0039); symbolic links are followed in the client
// (vx_ns_follow). Each returns a vx_status (0, or negative), or a count.
//
// Hard links do not exist on VectraOS (decided 2026-10-05): link_count is 1.

#pragma once // libvx.c includes it, at its end: its namespace and file table come first

#include "../vx-ns/follow.c"

// The hooks and libvx_fs_stat are declared in libvx.h.

static constexpr uint32_t LIBVX_S_IFMT = 0170000, LIBVX_S_IFDIR = 0040000, LIBVX_S_IFLNK = 0120000,
                          LIBVX_S_IFREG = 0100000;

// A 9P2000.L server's mode's kind.
static uint32_t libvx_fs_kind_of_mode(uint32_t mode) {
  switch (mode & LIBVX_S_IFMT) {
  case LIBVX_S_IFREG: return LIBVX_FS_REGULAR;
  case LIBVX_S_IFDIR: return LIBVX_FS_DIRECTORY;
  case LIBVX_S_IFLNK: return LIBVX_FS_SYMLINK;
  default: return LIBVX_FS_OTHER;
  }
}

// A 9P stat's kind.
static uint32_t libvx_fs_kind_of_stat(uint32_t mode) {
  if (mode & P9_DMDIR) return LIBVX_FS_DIRECTORY;
  if (mode & P9_DMSYMLINK) return LIBVX_FS_SYMLINK;
  return mode & P9_DMDEVICE ? LIBVX_FS_OTHER : LIBVX_FS_REGULAR;
}

// fid's attributes into st: Tgetattr where the server has it, else Tstat.
// dev is the connection's, as the POSIX personality's st_dev (6d9a): qid
// paths are each server's own.
static vx_status libvx_fs_fill(p9_client *c, uint32_t fid, libvx_fs_stat *st) {
  uint64_t dev = vx_ns_conn_id(&libvx_ns, c);
  p9_attr a;
  if (p9c_getattr(c, fid, &a) == VX_OK) {
    *st = (libvx_fs_stat){.type = libvx_fs_kind_of_mode(a.mode),
                          .perms = a.mode & 07777,
                          .dev = dev,
                          .ino = a.qid.path,
                          .size = a.size,
                          .nlink = 1,
                          .mtime_sec = (int64_t)a.mtime_sec,
                          .mtime_nsec = (int64_t)a.mtime_nsec,
                          .atime_sec = (int64_t)a.atime_sec,
                          .atime_nsec = (int64_t)a.atime_nsec};
    return VX_OK;
  }
  p9_stat s;
  vx_status e = p9c_stat(c, fid, &s, nullptr);
  if (e == VX_OK)
    *st = (libvx_fs_stat){.type = libvx_fs_kind_of_stat(s.mode),
                          .perms = s.mode & 0777,
                          .dev = dev,
                          .ino = s.qid.path,
                          .size = s.length,
                          .nlink = 1,
                          .mtime_sec = s.mtime,
                          .atime_sec = s.atime};
  return e;
}

// path walked, its links followed (all, or with follow false all but the
// last component's): a fid on *c the caller clunks.
static vx_status libvx_fs_walk(const char *path, bool follow, p9_client **c, uint32_t *fid) {
  char p[VX_NS_MAX_PATH];
  int64_t n = vx_ns_follow(libvx_namespace(), vx_cstr(path), follow, p);
  if (n < 0) return (vx_status)n;
  return vx_ns_walk(libvx_namespace(), (vx_str){p, (size_t)n}, c, fid);
}

int __llvm_libcxx_fs_stat(const char *path, int follow, libvx_fs_stat *st) {
  p9_client *c = nullptr;
  uint32_t fid = 0;
  vx_lock(&libvx_ns_lock);
  vx_status e = libvx_fs_walk(path, follow != 0, &c, &fid);
  if (e == VX_OK) e = libvx_fs_fill(c, fid, st), p9c_clunk(c, fid);
  vx_unlock(&libvx_ns_lock);
  return e;
}

int __llvm_libcxx_fs_fstat(long handle, libvx_fs_stat *st) {
  vx_ns_file *f = libvx_file(handle);
  if (!f || !f->c) return VX_ERR_BAD_HANDLE;
  return libvx_fs_fill(f->c, f->fid, st);
}

int __llvm_libcxx_fs_mkdir(const char *path, uint32_t perms) {
  vx_ns_file f;
  vx_lock(&libvx_ns_lock);
  vx_status e = vx_ns_create(libvx_namespace(), vx_cstr(path), P9_DMDIR | (perms & 0777), P9_OREAD, &f);
  if (e == VX_OK) vx_ns_close(&f);
  vx_unlock(&libvx_ns_lock);
  return e;
}

// Removes the name itself, a link and not what it points at.
int __llvm_libcxx_fs_remove(const char *path) {
  p9_client *c = nullptr;
  uint32_t fid = 0;
  vx_lock(&libvx_ns_lock);
  vx_status e = libvx_fs_walk(path, false, &c, &fid);
  if (e == VX_OK) e = p9c_remove(c, fid); // which clunks it
  vx_unlock(&libvx_ns_lock);
  return e;
}

int __llvm_libcxx_fs_rename(const char *from, const char *to) { return libvx_rename_paths(from, to); }

int __llvm_libcxx_fs_symlink(const char *target, const char *path) {
  p9_client *c = nullptr;
  uint32_t fid = 0;
  vx_str name;
  vx_lock(&libvx_ns_lock);
  vx_status e = libvx_parent(path, &c, &fid, &name);
  if (e == VX_OK) e = p9c_symlink(c, fid, name, vx_cstr(target)), p9c_clunk(c, fid);
  vx_unlock(&libvx_ns_lock);
  return e;
}

int64_t __llvm_libcxx_fs_readlink(const char *path, char *buf, size_t cap) {
  p9_client *c = nullptr;
  uint32_t fid = 0;
  size_t n = 0;
  vx_lock(&libvx_ns_lock);
  vx_status e = libvx_fs_walk(path, false, &c, &fid);
  if (e == VX_OK) e = p9c_readlink(c, fid, buf, cap, &n), p9c_clunk(c, fid);
  vx_unlock(&libvx_ns_lock);
  return e == VX_OK ? (int64_t)n : e;
}

// a set on what path names, its links followed unless follow is false.
static vx_status libvx_fs_setattr(const char *path, bool follow, const p9_setattr *a) {
  p9_client *c = nullptr;
  uint32_t fid = 0;
  vx_lock(&libvx_ns_lock);
  vx_status e = libvx_fs_walk(path, follow, &c, &fid);
  if (e == VX_OK) e = p9c_setattr(c, fid, a), p9c_clunk(c, fid);
  vx_unlock(&libvx_ns_lock);
  return e;
}

int __llvm_libcxx_fs_truncate(const char *path, uint64_t size) {
  return libvx_fs_setattr(path, true, &(p9_setattr){.valid = P9_SETATTR_SIZE, .size = size});
}

int __llvm_libcxx_fs_ftruncate(long handle, uint64_t size) {
  vx_ns_file *f = libvx_file(handle);
  if (!f || !f->c) return VX_ERR_BAD_HANDLE;
  return p9c_setattr(f->c, f->fid, &(p9_setattr){.valid = P9_SETATTR_SIZE, .size = size});
}

int __llvm_libcxx_fs_chmod(const char *path, uint32_t perms, int follow) {
  return libvx_fs_setattr(path, follow != 0, &(p9_setattr){.valid = P9_SETATTR_MODE, .mode = perms & 07777});
}

int __llvm_libcxx_fs_fchmod(long handle, uint32_t perms) {
  vx_ns_file *f = libvx_file(handle);
  if (!f || !f->c) return VX_ERR_BAD_HANDLE;
  return p9c_setattr(f->c, f->fid, &(p9_setattr){.valid = P9_SETATTR_MODE, .mode = perms & 07777});
}

// The modification time; the access time is left as it is.
int __llvm_libcxx_fs_set_times(const char *path, int64_t mtime_sec, int64_t mtime_nsec) {
  if (mtime_sec < 0 || mtime_nsec < 0 || mtime_nsec >= 1'000'000'000) return VX_ERR_INVALID;
  return libvx_fs_setattr(path, true,
                          &(p9_setattr){.valid = P9_SETATTR_MTIME | P9_SETATTR_MTIME_SET,
                                        .mtime_sec = (uint64_t)mtime_sec,
                                        .mtime_nsec = (uint64_t)mtime_nsec});
}

int64_t __llvm_libcxx_fs_getcwd(char *buf, size_t cap) {
  size_t n = vx_getwd(buf, cap);
  return n ? (int64_t)n : VX_ERR_RANGE;
}

int __llvm_libcxx_fs_chdir(const char *path) {
  vx_lock(&libvx_ns_lock);
  vx_status e = vx_chdir(libvx_namespace(), vx_cstr(path));
  vx_unlock(&libvx_ns_lock);
  return e;
}

// path made absolute and clean, every link followed; it must be there.
int64_t __llvm_libcxx_fs_realpath(const char *path, char *buf, size_t cap) {
  char p[VX_NS_MAX_PATH];
  p9_client *c = nullptr;
  uint32_t fid = 0;
  vx_lock(&libvx_ns_lock);
  int64_t n = vx_ns_follow(libvx_namespace(), vx_cstr(path), true, p);
  vx_status e = n < 0 ? (vx_status)n : vx_ns_walk(libvx_namespace(), (vx_str){p, (size_t)n}, &c, &fid);
  if (e == VX_OK) p9c_clunk(c, fid);
  vx_unlock(&libvx_ns_lock);
  if (e != VX_OK) return e;
  if ((size_t)n >= cap) return VX_ERR_RANGE;
  memcpy(buf, p, (size_t)n);
  buf[n] = 0;
  return n;
}

// --- Directories, read entry by entry ---

static constexpr uint32_t LIBVX_FS_DIRS = 16, LIBVX_FS_DIR_BUFFER = 8192;
static struct {
  bool used;
  vx_ns_file f;
  uint32_t len, at; // what buf holds, and how far it has been read
  uint8_t *buf;
} libvx_fs_dirs[LIBVX_FS_DIRS];

int64_t __llvm_libcxx_fs_opendir(const char *path) {
  char p[VX_NS_MAX_PATH];
  vx_lock(&libvx_ns_lock);
  uint32_t d = 0;
  while (d < LIBVX_FS_DIRS && libvx_fs_dirs[d].used) d++;
  int64_t n = d < LIBVX_FS_DIRS ? vx_ns_follow(libvx_namespace(), vx_cstr(path), true, p) : VX_ERR_NO_MEMORY;
  vx_status e = n < 0 ? (vx_status)n : VX_OK;
  uint8_t *buf = e == VX_OK ? vx_heap_alloc(vx_heap_process(), LIBVX_FS_DIR_BUFFER) : nullptr;
  if (e == VX_OK && !buf) e = VX_ERR_NO_MEMORY;
  vx_ns_file f = {};
  if (e == VX_OK) e = vx_ns_open(libvx_namespace(), (vx_str){p, (size_t)n}, P9_OREAD, &f);
  if (e == VX_OK) libvx_fs_dirs[d] = (typeof(libvx_fs_dirs[0])){.used = true, .f = f, .buf = buf};
  vx_unlock(&libvx_ns_lock);
  if (e != VX_OK) vx_heap_free(vx_heap_process(), buf);
  return e == VX_OK ? (int64_t)d : e;
}

// The next entry's name and kind: 1, or 0 at the end, or a vx_status.
int __llvm_libcxx_fs_readdir(int64_t dir, char *name, size_t cap, uint32_t *type) {
  if (dir < 0 || dir >= LIBVX_FS_DIRS || !libvx_fs_dirs[dir].used) return VX_ERR_BAD_HANDLE;
  typeof(libvx_fs_dirs[0]) *d = &libvx_fs_dirs[dir];
  if (d->at == d->len) {
    int64_t n = vx_ns_read(&d->f, d->buf, LIBVX_FS_DIR_BUFFER);
    if (n <= 0) return (int)n; // 0: the end
    d->len = (uint32_t)n, d->at = 0;
  }
  size_t at = d->at;
  p9_stat s;
  if (!p9_dir_next(d->buf, d->len, &at, &s)) return VX_ERR_IO;
  d->at = (uint32_t)at;
  if (s.name.len >= cap) return VX_ERR_RANGE;
  memcpy(name, s.name.ptr, s.name.len);
  name[s.name.len] = 0;
  *type = libvx_fs_kind_of_stat(s.mode);
  return 1;
}

void __llvm_libcxx_fs_closedir(int64_t dir) {
  if (dir < 0 || dir >= LIBVX_FS_DIRS || !libvx_fs_dirs[dir].used) return;
  vx_lock(&libvx_ns_lock);
  vx_ns_close(&libvx_fs_dirs[dir].f);
  vx_heap_free(vx_heap_process(), libvx_fs_dirs[dir].buf);
  libvx_fs_dirs[dir] = (typeof(libvx_fs_dirs[0])){};
  vx_unlock(&libvx_ns_lock);
}
