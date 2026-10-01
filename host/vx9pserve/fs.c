// vx9pserve's file server: a host directory as a p9_fs (lib/vx-9p/server.c),
// for VectraOS to mount over TCP (docs/04 §5 M3). Linux only.
//
// Nothing outside the directory can be reached. vx-9p's framework keeps a
// walk inside the attach root and refuses names with '/', "." and ".."; here,
// every path is opened one component at a time with openat and O_NOFOLLOW,
// from a descriptor on the root, so a symbolic link anywhere (even one
// swapped in after a walk) is refused, never followed. Symbolic links are not
// listed or walked to at all.
//
// A node is a path relative to the root, numbered the first time it is
// walked to; the number is its qid path, stable for as long as the server
// runs. Reads and writes open the file each time: the server keeps no
// descriptors but the root's.

#pragma once

#ifndef _GNU_SOURCE
#define _GNU_SOURCE // openat, O_PATH; must come before any system header
#endif
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../../lib/vx-9p/server.c"

typedef struct hostfs {
  int root;     // O_PATH descriptor on the served directory
  char **paths; // node n's path, relative to the root ("" for the root): n from 1
  uint64_t count, cap;
  char name[256]; // the last stat's name
} hostfs;

static vx_status hostfs_errno(int e) {
  switch (e) {
  case ENOENT:
  case ENOTDIR:
  case ELOOP: return VX_ERR_NOT_FOUND; // a symbolic link is as good as absent
  case EACCES:
  case EPERM:
  case EROFS: return VX_ERR_ACCESS;
  case EEXIST:
  case ENOTEMPTY: return VX_ERR_EXISTS;
  case EISDIR: return VX_ERR_BAD_STATE;
  case ENOMEM:
  case ENOSPC: return VX_ERR_NO_MEMORY;
  default: return VX_ERR_INVALID;
  }
}

// Opens a node's path: each directory on the way with O_NOFOLLOW, then the
// last component with `flags` (and O_NOFOLLOW). With last == nullptr, the
// parent directory's descriptor comes back, and *last points at the final
// name in path (for fstatat, mkdirat, unlinkat). -1 and errno on failure.
static int hostfs_openpath(const hostfs *h, const char *path, int flags, mode_t mode, const char **last) {
  int dir = dup(h->root);
  if (dir < 0) return -1;
  const char *p = path;
  for (;;) {
    const char *slash = strchr(p, '/');
    if (!slash) break;
    char comp[256];
    size_t n = (size_t)(slash - p);
    if (n == 0 || n >= sizeof comp) {
      close(dir);
      errno = ENOENT;
      return -1;
    }
    memcpy(comp, p, n);
    comp[n] = 0;
    int next = openat(dir, comp, O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    close(dir);
    if (next < 0) return -1;
    dir = next;
    p = slash + 1;
  }
  if (last) {
    *last = p;
    return dir;
  }
  int fd = openat(dir, *p ? p : ".", flags | O_NOFOLLOW | O_CLOEXEC, mode); // "": the root itself
  int saved = errno;
  close(dir);
  errno = saved;
  return fd;
}

// lstat of a node's path, without following anything.
static int hostfs_lstat(const hostfs *h, const char *path, struct stat *st) {
  if (!*path) return fstat(h->root, st);
  const char *last;
  int dir = hostfs_openpath(h, path, 0, 0, &last);
  if (dir < 0) return -1;
  int r = fstatat(dir, last, st, AT_SYMLINK_NOFOLLOW);
  int saved = errno;
  close(dir);
  errno = saved;
  return r;
}

// The node for a path: the one it already has, or a new one.
static uint64_t hostfs_node(hostfs *h, const char *path) {
  for (uint64_t i = 1; i <= h->count; i++)
    if (strcmp(h->paths[i - 1], path) == 0) return i;
  if (h->count == h->cap) {
    h->cap = h->cap ? h->cap * 2 : 64;
    char **grown = realloc(h->paths, h->cap * sizeof *grown);
    if (!grown) return 0;
    h->paths = grown;
  }
  char *copy = strdup(path);
  if (!copy) return 0;
  h->paths[h->count++] = copy;
  return h->count;
}

static const char *hostfs_path(const hostfs *h, uint64_t node) {
  return node && node <= h->count ? h->paths[node - 1] : nullptr;
}

static vx_status hostfs_attach(void *ctx, vx_str aname, uint64_t *root) {
  hostfs *h = ctx;
  if (aname.len) return VX_ERR_NOT_FOUND; // one tree: the directory
  *root = hostfs_node(h, "");
  return *root ? VX_OK : VX_ERR_NO_MEMORY;
}

static vx_status hostfs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  hostfs *h = ctx;
  const char *base = hostfs_path(h, dir);
  if (!base || name.len > 255) return VX_ERR_NOT_FOUND;
  char path[4096];
  int n = snprintf(path, sizeof path, "%s%s%.*s", base, *base ? "/" : "", (int)name.len, name.ptr);
  if (n < 0 || (size_t)n >= sizeof path || memchr(name.ptr, 0, name.len)) return VX_ERR_NOT_FOUND;
  struct stat st;
  if (hostfs_lstat(h, path, &st) != 0) return hostfs_errno(errno);
  if (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode))
    return VX_ERR_NOT_FOUND; // links, devices, sockets: not here
  *child = hostfs_node(h, path);
  return *child ? VX_OK : VX_ERR_NO_MEMORY;
}

static vx_status hostfs_parent(void *ctx, uint64_t node, uint64_t *parent) {
  hostfs *h = ctx;
  const char *path = hostfs_path(h, node);
  if (!path || !*path) return VX_ERR_NOT_FOUND;
  char up[4096];
  const char *slash = strrchr(path, '/');
  size_t n = slash ? (size_t)(slash - path) : 0;
  memcpy(up, path, n);
  up[n] = 0;
  *parent = hostfs_node(h, up);
  return *parent ? VX_OK : VX_ERR_NO_MEMORY;
}

static vx_status hostfs_stat(void *ctx, uint64_t node, p9_stat *out) {
  hostfs *h = ctx;
  const char *path = hostfs_path(h, node);
  struct stat st;
  if (!path) return VX_ERR_NOT_FOUND;
  if (hostfs_lstat(h, path, &st) != 0) return hostfs_errno(errno);
  bool dir = S_ISDIR(st.st_mode);
  const char *slash = strrchr(path, '/');
  const char *name = slash ? slash + 1 : path;
  snprintf(h->name, sizeof h->name, "%s", *path ? name : "/");
  *out = (p9_stat){.qid = {dir ? P9_QTDIR : P9_QTFILE, (uint32_t)st.st_mtime, node},
                   .mode = (dir ? P9_DMDIR : 0) | (st.st_mode & 0777),
                   .atime = (uint32_t)st.st_atime,
                   .mtime = (uint32_t)st.st_mtime,
                   .length = dir ? 0 : (uint64_t)st.st_size,
                   .name = (vx_str){h->name, strlen(h->name)},
                   .uid = VX_STR("host"),
                   .gid = VX_STR("host"),
                   .muid = VX_STR("host")};
  return VX_OK;
}

static int hostfs_flags(uint8_t mode) {
  int access = O_RDONLY;
  if ((mode & 3) == P9_OWRITE) access = O_WRONLY;
  if ((mode & 3) == P9_ORDWR) access = O_RDWR;
  return access | ((mode & P9_OTRUNC) ? O_TRUNC : 0);
}

static vx_status hostfs_open(void *ctx, uint64_t node, uint8_t mode) {
  hostfs *h = ctx;
  const char *path = hostfs_path(h, node);
  if (!path || (mode & P9_ORCLOSE)) return path ? VX_ERR_ACCESS : VX_ERR_NOT_FOUND;
  struct stat st;
  if (hostfs_lstat(h, path, &st) != 0) return hostfs_errno(errno);
  if (S_ISDIR(st.st_mode)) return VX_OK; // the framework allows directories only to be read
  int fd = hostfs_openpath(h, path, hostfs_flags(mode), 0, nullptr); // checks permission; truncates if asked
  if (fd < 0) return hostfs_errno(errno);
  close(fd);
  return VX_OK;
}

static vx_status hostfs_read(void *ctx, uint64_t node, uint64_t offset, uint8_t *buf, uint32_t *count) {
  hostfs *h = ctx;
  const char *path = hostfs_path(h, node);
  int fd = path ? hostfs_openpath(h, path, O_RDONLY, 0, nullptr) : -1;
  if (fd < 0) return path ? hostfs_errno(errno) : VX_ERR_NOT_FOUND;
  ssize_t n = offset > INT64_MAX ? 0 : pread(fd, buf, *count, (off_t)offset);
  int saved = errno;
  close(fd);
  if (n < 0) return hostfs_errno(saved);
  *count = (uint32_t)n;
  return VX_OK;
}

static vx_status hostfs_write(void *ctx, uint64_t node, uint64_t offset, const uint8_t *buf,
                              uint32_t *count) {
  hostfs *h = ctx;
  const char *path = hostfs_path(h, node);
  int fd = path ? hostfs_openpath(h, path, O_WRONLY, 0, nullptr) : -1;
  if (fd < 0) return path ? hostfs_errno(errno) : VX_ERR_NOT_FOUND;
  ssize_t n = offset > INT64_MAX ? -1 : pwrite(fd, buf, *count, (off_t)offset);
  int saved = errno;
  close(fd);
  if (n < 0) return hostfs_errno(saved);
  *count = (uint32_t)n;
  return VX_OK;
}

// The index-th entry of a directory, skipping ".", ".." and anything that is
// neither a file nor a directory.
static vx_status hostfs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  hostfs *h = ctx;
  const char *path = hostfs_path(h, dir);
  int fd = path ? hostfs_openpath(h, path, O_RDONLY | O_DIRECTORY, 0, nullptr) : -1;
  if (fd < 0) return path ? hostfs_errno(errno) : VX_ERR_NOT_FOUND;
  DIR *d = fdopendir(fd);
  if (!d) {
    close(fd);
    return VX_ERR_NO_MEMORY;
  }
  vx_status st = VX_ERR_NOT_FOUND;
  for (struct dirent *e; (e = readdir(d));) {
    if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
    if (e->d_type != DT_REG && e->d_type != DT_DIR) continue;
    if (index-- == 0) {
      st = hostfs_walk(ctx, dir, (vx_str){e->d_name, strlen(e->d_name)}, child);
      break;
    }
  }
  closedir(d);
  return st;
}

static vx_status hostfs_create(void *ctx, uint64_t dir, vx_str name, uint32_t perm, uint8_t mode,
                               uint64_t *node) {
  hostfs *h = ctx;
  const char *base = hostfs_path(h, dir);
  if (!base || name.len > 255 || memchr(name.ptr, 0, name.len)) return VX_ERR_INVALID;
  char path[4096];
  int n = snprintf(path, sizeof path, "%s%s%.*s", base, *base ? "/" : "", (int)name.len, name.ptr);
  if (n < 0 || (size_t)n >= sizeof path) return VX_ERR_INVALID;
  const char *last;
  int parent = hostfs_openpath(h, path, 0, 0, &last);
  if (parent < 0) return hostfs_errno(errno);
  int r;
  if (perm & P9_DMDIR) {
    r = mkdirat(parent, last, perm & 0777);
  } else {
    r = openat(parent, last, hostfs_flags(mode) | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, perm & 0666);
    if (r >= 0) r = close(r);
  }
  int saved = errno;
  close(parent);
  if (r != 0) return hostfs_errno(saved);
  *node = hostfs_node(h, path);
  return *node ? VX_OK : VX_ERR_NO_MEMORY;
}

static vx_status hostfs_remove(void *ctx, uint64_t node) {
  hostfs *h = ctx;
  const char *path = hostfs_path(h, node);
  if (!path || !*path) return VX_ERR_ACCESS; // not the root
  struct stat st;
  if (hostfs_lstat(h, path, &st) != 0) return hostfs_errno(errno);
  const char *last;
  int parent = hostfs_openpath(h, path, 0, 0, &last);
  if (parent < 0) return hostfs_errno(errno);
  int r = unlinkat(parent, last, S_ISDIR(st.st_mode) ? AT_REMOVEDIR : 0);
  int saved = errno;
  close(parent);
  return r == 0 ? VX_OK : hostfs_errno(saved);
}

// A server for the directory at `dir`; false if it cannot be opened.
static bool hostfs_init(hostfs *h, p9_server *s, const char *dir, uint32_t max_msize) {
  *h = (hostfs){.root = open(dir, O_PATH | O_DIRECTORY | O_CLOEXEC)};
  if (h->root < 0) return false;
  *s = (p9_server){.fs = {.ctx = h,
                          .attach = hostfs_attach,
                          .walk = hostfs_walk,
                          .parent = hostfs_parent,
                          .stat = hostfs_stat,
                          .open = hostfs_open,
                          .read = hostfs_read,
                          .readdir = hostfs_readdir,
                          .write = hostfs_write,
                          .create = hostfs_create,
                          .remove = hostfs_remove},
                   .max_msize = max_msize};
  return true;
}
