// fd.c: file descriptors, in the process (docs/01 §9). Part of backend.c.
//
// A descriptor names an open file description, which dup and fcntl's
// F_DUPFD share: the offset and the status flags, as POSIX has them. A
// description is the console, one of the spawn message's two pipes, or a
// file or directory in the namespace, which is built from the spawn message
// the first time a path is used.
//
// One thread is all a process has until pthreads (docs/milestones.md), so
// nothing here locks yet.

static constexpr int FD_MAX = 64;
static constexpr uint32_t FD_PIPE_CHUNK = 4096; // the most a reader's message holds (vx-rt stdio)
static constexpr uint32_t FD_DIR_BUFFER = 8192; // 9P directory entries read at once

typedef enum ofd_kind : uint8_t { OFD_FREE, OFD_CONSOLE, OFD_PIPE_IN, OFD_PIPE_OUT, OFD_FILE } ofd_kind;

typedef struct ofd {
  ofd_kind kind;
  bool dir;
  uint32_t refs;
  int flags;     // O_ACCMODE, O_APPEND, O_NONBLOCK
  vx_ns_file f;  // a file's fid and offset
  uint8_t *dirs; // a directory's 9P entries read but not yet returned, in a page of their own
  uint32_t dirs_len, dirs_at;
  int64_t dir_next;          // getdents64's d_off for the next entry
  char path[VX_NS_MAX_PATH]; // cleaned and absolute: for *at calls and rewinding a directory
  size_t path_len;
} ofd;

static ofd fd_ofds[FD_MAX];
static struct {
  ofd *o;
  bool cloexec;
} fd_table[FD_MAX];

static vx_ns fd_ns;
static vx_status fd_ns_status = VX_ERR_BAD_STATE; // until it is built
static char fd_cwd[VX_NS_MAX_PATH] = "/";
static size_t fd_cwd_len = 1;

static ofd *ofd_new(ofd_kind kind, int flags) {
  for (int i = 0; i < FD_MAX; i++) {
    if (fd_ofds[i].kind != OFD_FREE) continue;
    fd_ofds[i] = (ofd){.kind = kind, .refs = 1, .flags = flags};
    return &fd_ofds[i];
  }
  return nullptr;
}

static void ofd_release(ofd *o) {
  if (--o->refs) return;
  if (o->kind == OFD_FILE) vx_ns_close(&o->f);
  if (o->dirs) vx_as_unmap(vx_self, (uint64_t)o->dirs, FD_DIR_BUFFER);
  if (o->kind == OFD_PIPE_OUT && vx_stdio.out) {
    vx_handle_close(vx_stdio.out); // the reader sees the end of the file
    vx_stdio.out = VX_HANDLE_NONE;
  }
  if (o->kind == OFD_PIPE_IN && vx_stdio.in) {
    vx_handle_close(vx_stdio.in);
    vx_stdio.in = VX_HANDLE_NONE;
  }
  o->kind = OFD_FREE;
}

// The lowest free descriptor from `low`, given o (whose reference it takes).
static long fd_install(ofd *o, int low, bool cloexec) {
  for (int fd = low < 0 ? 0 : low; fd < FD_MAX; fd++) {
    if (fd_table[fd].o) continue;
    fd_table[fd].o = o;
    fd_table[fd].cloexec = cloexec;
    return fd;
  }
  ofd_release(o);
  return -EMFILE;
}

static ofd *fd_get(int fd) { return fd >= 0 && fd < FD_MAX ? fd_table[fd].o : nullptr; }
static bool fd_valid(int fd) { return fd_get(fd) != nullptr; }

// Descriptors 0, 1 and 2 from the spawn message: the pipes it names, and the
// console for what it does not. Standard error goes to the console, so a
// pipeline's errors reach its terminal; without a console, to stdout.
static void fd_init(void) {
  vx_handle console = vx_spawn_take("console");
  if (console && vx_console_attach(console) != VX_OK) vx_print(VX_STR("vx-musl: cannot open the console\n"));
  vx_stdio.in = vx_spawn_take("stdin");
  vx_stdio.out = vx_spawn_take("stdout");
  ofd *cons = console ? ofd_new(OFD_CONSOLE, O_RDWR) : nullptr;
  ofd *in = vx_stdio.in ? ofd_new(OFD_PIPE_IN, O_RDONLY) : cons;
  ofd *out = vx_stdio.out ? ofd_new(OFD_PIPE_OUT, O_WRONLY) : cons;
  ofd *err = cons ? cons : out;
  ofd *std[3] = {in, out, err};
  for (int fd = 0; fd < 3; fd++) {
    if (!std[fd]) continue;
    if (fd_table[0].o == std[fd] || fd_table[1].o == std[fd] || fd_table[2].o == std[fd]) std[fd]->refs++;
    fd_table[fd].o = std[fd];
  }
}

// At exit: what vx_print has buffered goes out, and stdout's pipe closes.
static void fd_exit(void) {
  if (vx_console.len) vx_console_flush();
  if (vx_stdio.out) vx_handle_close(vx_stdio.out);
  vx_stdio.out = VX_HANDLE_NONE;
}

static vx_ns *fd_namespace(void) {
  if (fd_ns_status == VX_ERR_BAD_STATE) fd_ns_status = vx_ns_from_spawn(&fd_ns);
  return &fd_ns; // a namespace that failed to build has what it got, perhaps nothing
}

// path, relative to dirfd's directory or the working directory, cleaned and
// absolute into out (VX_NS_MAX_PATH bytes). Returns its length or -errno.
static long fd_path(int dirfd, const char *path, char *out) {
  size_t len = strlen(path);
  if (!len) return -ENOENT;
  const char *base = "";
  size_t base_len = 0;
  if (path[0] != '/' && dirfd == AT_FDCWD) {
    base = fd_cwd;
    base_len = fd_cwd_len;
  } else if (path[0] != '/') {
    const ofd *d = fd_get(dirfd);
    if (!d) return -EBADF;
    if (d->kind != OFD_FILE || !d->dir) return -ENOTDIR;
    base = d->path;
    base_len = d->path_len;
  }
  char joined[2 * VX_NS_MAX_PATH];
  if (base_len + 1 + len >= sizeof joined) return -ENAMETOOLONG;
  memcpy(joined, base, base_len);
  joined[base_len] = '/';
  memcpy(joined + base_len + 1, path, len + 1);
  size_t n = vx_ns_clean((vx_str){joined, base_len + 1 + len}, out, VX_NS_MAX_PATH);
  return n ? (long)n : -ENAMETOOLONG;
}

static void fd_stat_fill(struct stat *st, const p9_stat *s) {
  bool dir = s->mode & P9_DMDIR;
  *st = (struct stat){
      .st_dev = s->dev,
      .st_ino = s->qid.path,
      .st_mode = (dir ? S_IFDIR : S_IFREG) | (s->mode & 0777),
      .st_nlink = dir ? 2 : 1,
      .st_size = (off_t)s->length,
      .st_blksize = 4096,
      .st_blocks = (blkcnt_t)((s->length + 511) / 512),
      .st_atim = {.tv_sec = s->atime},
      .st_mtim = {.tv_sec = s->mtime},
      .st_ctim = {.tv_sec = s->mtime},
  };
}

// --- Reading and writing ---

static long console_write(const char *p, size_t n) {
  if (vx_console.len) vx_console_flush(); // what vx_print buffered goes first
  if (vx_console.connector) {
    if ((vx_console.open || vx_console_open() == VX_OK) && vx_console_put(p, n)) return (long)n;
    if (vx_console_open() == VX_OK && vx_console_put(p, n)) return (long)n; // the driver restarted
  }
  vx_debug_write((vx_str){p, n});
  return (long)n;
}

static long pipe_write(const uint8_t *p, size_t n) {
  static uint8_t msg[sizeof(vx_msg_header) + FD_PIPE_CHUNK];
  size_t done = 0;
  while (done < n) {
    uint32_t k = n - done < FD_PIPE_CHUNK ? (uint32_t)(n - done) : FD_PIPE_CHUNK;
    *(vx_msg_header *)msg = (vx_msg_header){};
    memcpy(msg + sizeof(vx_msg_header), p + done, k);
    vx_status st;
    for (int tries = 0;; tries++) {
      st = vx_channel_write(vx_stdio.out, msg, (uint32_t)sizeof(vx_msg_header) + k, nullptr, 0);
      if (st != VX_ERR_SHOULD_WAIT) break;
      static const _Atomic uint32_t never; // the reader is behind: wait a little
      vx_futex_wait(&never, 0, vx_clock_read() + (tries < 10 ? 100'000 : 1'000'000));
    }
    if (st != VX_OK) return done ? (long)done : vx_errno(st); // PEER_CLOSED: EPIPE
    done += k;
  }
  return (long)n;
}

static long file_write(ofd *o, const uint8_t *p, size_t n) {
  if (o->flags & O_APPEND) { // to the end as it is now: not atomic without the posix extension (step 4)
    p9_stat s;
    vx_status st = p9c_stat(o->f.c, o->f.fid, &s);
    if (st != VX_OK) return vx_errno(st);
    o->f.offset = s.length;
  }
  size_t done = 0;
  while (done < n) {
    uint32_t k = n - done < (1u << 20) ? (uint32_t)(n - done) : 1u << 20;
    int64_t w = vx_ns_write(&o->f, p + done, k);
    if (w <= 0 && done) return (long)done;
    if (w <= 0) return w ? vx_errno((vx_status)w) : -EIO;
    done += (size_t)w;
  }
  return (long)n;
}

static long fd_read(int fd, void *buf, size_t n) {
  ofd *o = fd_get(fd);
  if (!o) return -EBADF;
  if ((o->flags & O_ACCMODE) == O_WRONLY) return -EBADF;
  uint32_t count = n < (1u << 20) ? (uint32_t)n : 1u << 20;
  int64_t r;
  switch (o->kind) {
  case OFD_CONSOLE: r = vx_console_read(buf, count); break;
  case OFD_PIPE_IN: r = vx_read(buf, count); break;
  case OFD_FILE:
    if (o->dir) return -EISDIR;
    r = vx_ns_read(&o->f, buf, count);
    break;
  default: return -EBADF;
  }
  return r < 0 ? vx_errno((vx_status)r) : (long)r;
}

static long fd_write(int fd, const void *buf, size_t n) {
  ofd *o = fd_get(fd);
  if (!o || (o->flags & O_ACCMODE) == O_RDONLY) return -EBADF;
  switch (o->kind) {
  case OFD_CONSOLE: return console_write(buf, n);
  case OFD_PIPE_OUT: return pipe_write(buf, n);
  case OFD_FILE: return file_write(o, buf, n);
  default: return -EBADF;
  }
}

// Short reads are allowed, so readv stops at the first one.
static long fd_readv(int fd, const struct iovec *iov, int count) {
  if (count < 0 || count > IOV_MAX) return -EINVAL;
  long total = 0;
  for (int i = 0; i < count; i++) {
    if (!iov[i].iov_len) continue;
    long r = fd_read(fd, iov[i].iov_base, iov[i].iov_len);
    if (r < 0) return total ? total : r;
    total += r;
    if ((size_t)r < iov[i].iov_len) break;
  }
  return total;
}

// stdio's writes come as a buffer and the data after it: gathered into one
// write, so a line reaches the console or a pipe whole.
static long fd_writev(int fd, const struct iovec *iov, int count) {
  if (count < 0 || count > IOV_MAX) return -EINVAL;
  static uint8_t gather[FD_PIPE_CHUNK];
  size_t total = 0;
  for (int i = 0; i < count; i++) total += iov[i].iov_len;
  if (total <= sizeof gather) {
    size_t at = 0;
    for (int i = 0; i < count; i++) {
      memcpy(gather + at, iov[i].iov_base, iov[i].iov_len);
      at += iov[i].iov_len;
    }
    if (!total) return fd_valid(fd) ? 0 : -EBADF;
    return fd_write(fd, gather, total);
  }
  long done = 0;
  for (int i = 0; i < count; i++) {
    if (!iov[i].iov_len) continue;
    long w = fd_write(fd, iov[i].iov_base, iov[i].iov_len);
    if (w < 0) return done ? done : w;
    done += w;
    if ((size_t)w < iov[i].iov_len) break;
  }
  return done;
}

static long fd_pread(int fd, void *buf, size_t n, long offset) {
  ofd *o = fd_get(fd);
  if (!o) return -EBADF;
  if (o->kind != OFD_FILE) return -ESPIPE;
  if (o->dir) return -EISDIR;
  if (offset < 0) return -EINVAL;
  int64_t r = p9c_read(o->f.c, o->f.fid, (uint64_t)offset, buf, n < (1u << 20) ? (uint32_t)n : 1u << 20);
  return r < 0 ? vx_errno((vx_status)r) : (long)r;
}

static long fd_pwrite(int fd, const void *buf, size_t n, long offset) {
  ofd *o = fd_get(fd);
  if (!o || (o->flags & O_ACCMODE) == O_RDONLY) return -EBADF;
  if (o->kind != OFD_FILE) return -ESPIPE;
  if (offset < 0) return -EINVAL;
  int64_t w = p9c_write(o->f.c, o->f.fid, (uint64_t)offset, buf, n < (1u << 20) ? (uint32_t)n : 1u << 20);
  return w < 0 ? vx_errno((vx_status)w) : (long)w;
}

static long fd_lseek(int fd, long offset, int whence) {
  ofd *o = fd_get(fd);
  if (!o) return -EBADF;
  if (o->kind != OFD_FILE) return -ESPIPE;
  if (o->dir) { // only back to the start (rewinddir): the directory is opened again
    if (offset != 0 || whence != SEEK_SET) return -EINVAL;
    vx_ns_file f;
    vx_status st = vx_ns_open(fd_namespace(), (vx_str){o->path, o->path_len}, P9_OREAD, &f);
    if (st != VX_OK) return vx_errno(st);
    vx_ns_close(&o->f);
    o->f = f;
    o->dirs_len = o->dirs_at = 0;
    o->dir_next = 0;
    return 0;
  }
  int64_t base = 0;
  if (whence == SEEK_CUR) {
    base = (int64_t)o->f.offset;
  } else if (whence == SEEK_END) {
    p9_stat s;
    vx_status st = p9c_stat(o->f.c, o->f.fid, &s);
    if (st != VX_OK) return vx_errno(st);
    base = (int64_t)s.length;
  } else if (whence != SEEK_SET) {
    return -EINVAL;
  }
  int64_t at;
  if (ckd_add(&at, base, offset) || at < 0) return -EINVAL;
  o->f.offset = (uint64_t)at;
  return (long)at;
}

// --- Opening and closing ---

static long fd_openat(int dirfd, const char *path, int flags, mode_t mode) {
  char p[VX_NS_MAX_PATH];
  long len = fd_path(dirfd, path, p);
  if (len < 0) return len;
  int acc = flags & O_ACCMODE;
  uint8_t mode9 = P9_OREAD;
  if (acc == O_WRONLY) mode9 = P9_OWRITE;
  if (acc == O_RDWR) mode9 = P9_ORDWR;
  vx_ns *ns = fd_namespace();
  vx_ns_file f;
  vx_status st = vx_ns_open(ns, (vx_str){p, (size_t)len}, mode9 | (flags & O_TRUNC ? P9_OTRUNC : 0), &f);
  if (st == VX_OK && (flags & O_CREAT) && (flags & O_EXCL)) {
    vx_ns_close(&f);
    return -EEXIST;
  }
  if (st == VX_ERR_NOT_FOUND && (flags & O_CREAT))
    st = vx_ns_create(ns, (vx_str){p, (size_t)len}, mode & 0755, mode9, &f); // the umask is 022
  if (st != VX_OK) return vx_errno(st);
  p9_stat s;
  st = p9c_stat(f.c, f.fid, &s);
  bool dir = st == VX_OK && (s.mode & P9_DMDIR);
  if (st == VX_OK && (flags & O_DIRECTORY) && !dir) st = VX_ERR_INVALID;
  ofd *o = st == VX_OK ? ofd_new(OFD_FILE, flags & (O_ACCMODE | O_APPEND | O_NONBLOCK)) : nullptr;
  if (!o) {
    vx_ns_close(&f);
    if (st == VX_ERR_INVALID) return -ENOTDIR;
    return st != VX_OK ? vx_errno(st) : -ENFILE;
  }
  o->f = f;
  o->dir = dir;
  memcpy(o->path, p, (size_t)len);
  o->path_len = (size_t)len;
  return fd_install(o, 0, flags & O_CLOEXEC);
}

static long fd_close(int fd) {
  ofd *o = fd_get(fd);
  if (!o) return -EBADF;
  fd_table[fd].o = nullptr;
  ofd_release(o);
  return 0;
}

// dup (to the lowest free), dup2 and dup3 (to `to`, closing what was there).
static long fd_dup(int fd, int to, int flags) {
  ofd *o = fd_get(fd);
  if (!o) return -EBADF;
  if ((flags & ~O_CLOEXEC) || to >= FD_MAX) return to >= FD_MAX ? -EBADF : -EINVAL;
  o->refs++;
  if (to < 0) return fd_install(o, 0, false);
  if (fd_table[to].o) ofd_release(fd_table[to].o);
  fd_table[to].o = o;
  fd_table[to].cloexec = flags & O_CLOEXEC;
  return to;
}

// dup2 to itself changes nothing, if the descriptor is open (dup3 refuses it).
[[maybe_unused]] static long fd_dup2(int fd, int to) {
  if (fd != to) return fd_dup(fd, to, 0);
  return fd_valid(fd) ? fd : -EBADF;
}

static long fd_fcntl(int fd, int cmd, long arg) {
  ofd *o = fd_get(fd);
  if (!o) return -EBADF;
  switch (cmd) {
  case F_DUPFD:
  case F_DUPFD_CLOEXEC:
    if (arg < 0 || arg >= FD_MAX) return -EINVAL;
    o->refs++;
    return fd_install(o, (int)arg, cmd == F_DUPFD_CLOEXEC);
  case F_GETFD: return fd_table[fd].cloexec ? FD_CLOEXEC : 0;
  case F_SETFD: fd_table[fd].cloexec = arg & FD_CLOEXEC; return 0;
  case F_GETFL: return o->flags;
  case F_SETFL: o->flags = (o->flags & O_ACCMODE) | (int)(arg & (O_APPEND | O_NONBLOCK)); return 0;
  default: return -EINVAL; // locks come with the posix extension (M4 step 4)
  }
}

// --- Names ---

// Walks to path (cleaned into p, of *len bytes): true with *c and *fid,
// which the caller clunks, or false with *err, a negated errno.
static bool fd_walk(int dirfd, const char *path, p9_client **c, uint32_t *fid, char *p, size_t *len,
                    long *err) {
  long n = fd_path(dirfd, path, p);
  if (n < 0) {
    *err = n;
    return false;
  }
  *len = (size_t)n;
  vx_status st = vx_ns_walk(fd_namespace(), (vx_str){p, (size_t)n}, c, fid);
  if (st != VX_OK) {
    *err = vx_errno(st);
    return false;
  }
  return true;
}

static long fd_fstat(int fd, struct stat *st) {
  const ofd *o = fd_get(fd);
  if (!o) return -EBADF;
  if (o->kind != OFD_FILE) {
    *st = (struct stat){.st_mode = (o->kind == OFD_CONSOLE ? S_IFCHR | 0620 : S_IFIFO | 0600),
                        .st_nlink = 1,
                        .st_blksize = 4096};
    return 0;
  }
  p9_stat s;
  vx_status vst = p9c_stat(o->f.c, o->f.fid, &s);
  if (vst == VX_OK) fd_stat_fill(st, &s);
  return vx_errno(vst);
}

static long fd_fstatat(int dirfd, const char *path, struct stat *st, int flag) {
  if ((flag & AT_EMPTY_PATH) && !*path) return fd_fstat(dirfd, st);
  p9_client *c = nullptr;
  uint32_t fid = 0;
  char p[VX_NS_MAX_PATH];
  size_t len;
  long r = 0;
  if (!fd_walk(dirfd, path, &c, &fid, p, &len, &r)) return r;
  p9_stat s;
  vx_status vst = p9c_stat(c, fid, &s);
  if (vst == VX_OK) fd_stat_fill(st, &s);
  p9c_clunk(c, fid);
  return vx_errno(vst);
}

static long fd_faccessat(int dirfd, const char *path) {
  p9_client *c = nullptr;
  uint32_t fid = 0;
  char p[VX_NS_MAX_PATH];
  size_t len;
  long r = 0;
  if (!fd_walk(dirfd, path, &c, &fid, p, &len, &r)) return r;
  p9c_clunk(c, fid);
  return 0; // it exists; permissions are the server's to refuse when it is opened
}

static long fd_mkdirat(int dirfd, const char *path, mode_t mode) {
  char p[VX_NS_MAX_PATH];
  long len = fd_path(dirfd, path, p);
  if (len < 0) return len;
  vx_ns_file f;
  vx_status st =
      vx_ns_create(fd_namespace(), (vx_str){p, (size_t)len}, P9_DMDIR | (mode & 0755), P9_OREAD, &f);
  if (st == VX_OK) vx_ns_close(&f);
  return vx_errno(st);
}

static long fd_unlinkat(int dirfd, const char *path, int flag) {
  p9_client *c = nullptr;
  uint32_t fid = 0;
  char p[VX_NS_MAX_PATH];
  size_t len;
  long r = 0;
  if (!fd_walk(dirfd, path, &c, &fid, p, &len, &r)) return r;
  p9_stat s;
  vx_status st = p9c_stat(c, fid, &s);
  if (st == VX_OK && !(s.mode & P9_DMDIR) != !(flag & AT_REMOVEDIR)) {
    p9c_clunk(c, fid);
    return flag & AT_REMOVEDIR ? -ENOTDIR : -EISDIR;
  }
  if (st != VX_OK) {
    p9c_clunk(c, fid);
    return vx_errno(st);
  }
  return vx_errno(p9c_remove(c, fid)); // which clunks it
}

static long fd_getcwd(char *buf, size_t size) {
  if (size < fd_cwd_len + 1) return -ERANGE;
  memcpy(buf, fd_cwd, fd_cwd_len);
  buf[fd_cwd_len] = 0;
  return (long)fd_cwd_len + 1;
}

static long fd_chdir(const char *path) {
  p9_client *c = nullptr;
  uint32_t fid = 0;
  char p[VX_NS_MAX_PATH];
  size_t len;
  long r = 0;
  if (!fd_walk(AT_FDCWD, path, &c, &fid, p, &len, &r)) return r;
  p9_stat s;
  vx_status st = p9c_stat(c, fid, &s);
  p9c_clunk(c, fid);
  if (st != VX_OK) return vx_errno(st);
  if (!(s.mode & P9_DMDIR)) return -ENOTDIR;
  memcpy(fd_cwd, p, len);
  fd_cwd_len = len;
  return 0;
}

// --- Directories and terminals ---

// 9P directory entries, as Linux's dirent64 (musl's struct dirent is the
// same). A 9P directory can only be read on from where it was, so entries
// that do not fit the caller's buffer wait in the description's page.
static long fd_getdents(int fd, void *buf, size_t count) {
  ofd *o = fd_get(fd);
  if (!o) return -EBADF;
  if (o->kind != OFD_FILE || !o->dir) return -ENOTDIR;
  if (!o->dirs) {
    vx_handle vmo;
    uint64_t at = 0;
    vx_status st = vx_vmo_create(FD_DIR_BUFFER, 0, &vmo);
    if (st == VX_OK) {
      st = vx_as_map(vx_self, vmo, 0, FD_DIR_BUFFER, VX_MAP_WRITE, &at);
      vx_handle_close(vmo);
    }
    if (st != VX_OK) return vx_errno(st);
    o->dirs = (uint8_t *)at;
  }
  size_t written = 0;
  for (;;) {
    if (o->dirs_at == o->dirs_len) {
      int64_t n = vx_ns_read(&o->f, o->dirs, FD_DIR_BUFFER);
      if (n <= 0 && written) return (long)written;
      if (n <= 0) return n ? vx_errno((vx_status)n) : 0;
      o->dirs_len = (uint32_t)n;
      o->dirs_at = 0;
    }
    size_t at = o->dirs_at;
    p9_stat s;
    if (!p9_dir_next(o->dirs, o->dirs_len, &at, &s)) return written ? (long)written : -EIO;
    size_t name_len = s.name.len < 255 ? s.name.len : 255;
    size_t reclen = (offsetof(struct dirent, d_name) + name_len + 1 + 7) & ~(size_t)7;
    if (written + reclen > count) return written ? (long)written : -EINVAL;
    struct dirent *d = (struct dirent *)((char *)buf + written);
    d->d_ino = s.qid.path;
    d->d_off = ++o->dir_next;
    d->d_reclen = (unsigned short)reclen;
    d->d_type = s.mode & P9_DMDIR ? DT_DIR : DT_REG;
    memcpy(d->d_name, s.name.ptr, name_len);
    d->d_name[name_len] = 0;
    written += reclen;
    o->dirs_at = (uint32_t)at;
  }
}

// isatty and line buffering ask the size of the window: the console is a
// terminal, 80 by 24; nothing else is (ptyd, M4 step 4).
static long fd_ioctl(int fd, unsigned long request, void *arg) {
  const ofd *o = fd_get(fd);
  if (!o) return -EBADF;
  if (o->kind != OFD_CONSOLE || request != TIOCGWINSZ) return -ENOTTY;
  *(struct winsize *)arg = (struct winsize){.ws_row = 24, .ws_col = 80};
  return 0;
}
