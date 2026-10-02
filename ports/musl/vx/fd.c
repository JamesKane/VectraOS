// fd.c: file descriptors, in the process (docs/01 §9). Part of backend.c.
//
// A descriptor names an open file description, which dup and fcntl's
// F_DUPFD share: the offset and the status flags, as POSIX has them. A
// description is the console, an end of a pipe, or a file or directory in
// the namespace, which is built from the spawn message the first time a path
// is used.
//
// A file on a server with the posix extension keeps its offset and O_APPEND
// in the server (docs/proto/posix.md): reads and writes at its current
// offset, lseek by Tseek. A child (fork, posix_spawn, exec) joins the same
// open file with a token, so the offset is shared as POSIX has it; a child
// that cannot opens the file again, with an offset of its own.
//
// A pipe is a channel: each write a message of a header and up to 4 KiB, as
// vx-rt's stdio has them, so pipes join POSIX programs and first-party ones.
// Its ends are shared as POSIX shares them: dup shares the description, and
// a child (fork, posix_spawn, exec) holds the same channel end, so the reader
// sees the end of the file when the last writer anywhere has closed.
//
// One thread is all a process has until pthreads (docs/milestones.md), so
// nothing here locks yet.

static constexpr int FD_MAX = 64;
static constexpr uint32_t FD_PIPE_CHUNK = 4096;  // the most a reader's message holds (vx-rt stdio)
static constexpr uint32_t FD_DIR_BUFFER = 8192;  // 9P directory entries read at once
static constexpr uint32_t FD_PIPE_BUFFER = 8192; // a reader's message, in a page of its own

typedef enum ofd_kind : uint8_t { OFD_FREE, OFD_CONSOLE, OFD_PIPE_IN, OFD_PIPE_OUT, OFD_FILE } ofd_kind;

// A read kept outstanding on a terminal or the console, on a connection of
// its own, so poll can hear when it can be read (01 §9): a ring server holds
// a whole connection while it holds a read. Once a description has one, its
// reads go through it (poll.c).
static constexpr uint32_t FD_RA_MAX = 4096;
typedef struct fd_readahead {
  p9_conn *k; // its connection
  uint32_t fid;
  bool pending, armed, ready; // a read sent; its doorbell bound; its reply here
  uint16_t tag;
  vx_status status; // the reply's: OK, or why it failed
  uint32_t len, pos;
  uint8_t data[FD_RA_MAX];
} fd_readahead;

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
  vx_handle pipe;            // a pipe's channel end
  uint8_t *msg;              // a reader's current message, in a page of its own,
  uint32_t msg_len, msg_pos; // and how much of it has been read
  bool ended;                // the writers have all gone
  bool closed_bound;         // PEER_CLOSED is bound once (it fires once)
  uint8_t token[16];         // a file's, for a forked child to join its open file (fd_before_fork)
  bool has_token;
  bool tty, master; // a terminal's slave or master (ptyd: the file is a 9P device)
  uint32_t pty;
  bool locked;     // a lock was taken through it: let go at exit, before the exit is seen
  bool read_bound; // a READABLE binding is on fd_port for its pipe
  fd_readahead *ra;
} ofd;

static ofd fd_ofds[FD_MAX];
static void ra_free(ofd *o);                                        // poll.c
static long ra_read(ofd *o, void *buf, uint32_t count, bool block); // poll.c
typedef struct fd_slot {
  ofd *o;
  bool cloexec;
} fd_slot;
static fd_slot fd_table[FD_MAX];

static vx_ns fd_ns;
static vx_handle fd_port; // where a blocked pipe read waits

// fd_port's keys: 1 + a description's index; a packet names its binding's
// trigger, and a binding that fired is gone.
static uint64_t fd_key(const ofd *o) { return 1 + (uint64_t)(o - fd_ofds); }

static void fd_noted(const vx_packet *pk, int64_t n) {
  for (int64_t i = 0; i < n; i++) {
    if (pk[i].key == 0 || pk[i].key > FD_MAX) continue;
    ofd *o = &fd_ofds[pk[i].key - 1];
    if (pk[i].trigger == VX_TRIGGER_READABLE) o->read_bound = false;
    if (pk[i].trigger == VX_TRIGGER_COUNTER_GE && o->ra) o->ra->armed = false;
  }
}

// Waits on fd_port until something armed there fires, or the deadline:
// 0, -ETIMEDOUT, or -EINTR (a signal: the caller's call ends).
static long fd_wait(int64_t deadline) {
  vx_packet pk[16];
  int64_t n = vx_port_wait(fd_port, deadline, 0, pk, 16);
  if (n == VX_ERR_INTERRUPTED) return -EINTR;
  if (n == VX_ERR_TIMED_OUT) return -ETIMEDOUT;
  if (n > 0) fd_noted(pk, n);
  return 0;
}
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
  if (o->msg) vx_as_unmap(vx_self, (uint64_t)o->msg, FD_PIPE_BUFFER);
  if (o->pipe) vx_handle_close(o->pipe); // the last writer gone: the reader sees the end of the file
  if (o->ra) ra_free(o);
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
static ofd *pipe_ofd(vx_handle end, bool reader, int flags) {
  ofd *o = ofd_new(reader ? OFD_PIPE_IN : OFD_PIPE_OUT, (reader ? O_RDONLY : O_WRONLY) | flags);
  if (o)
    o->pipe = end;
  else
    vx_handle_close(end);
  return o;
}

static void fd_place(int fd, ofd *o) {
  if (!o) return;
  if (fd_table[fd].o) ofd_release(fd_table[fd].o);
  fd_table[fd].o = o;
  fd_table[fd].cloexec = false;
}

static void fd_from_records(void); // below, with what writes them

// The descriptors the spawn message gives: fd= records from a POSIX parent
// (fd_records), or else 0, 1 and 2 from the pipes it names and the console
// for what it does not. Standard error goes to the console, so a pipeline's
// errors reach its terminal; without a console, to stdout.
static void fd_init(void) {
  vx_handle console = vx_spawn_take("console");
  if (console && vx_console_attach(console) != VX_OK) vx_print(VX_STR("vx-musl: cannot open the console\n"));
  vx_port_create(0, &fd_port);
  vx_ndb_record rec;
  if (vx_spawn_record("fd", &rec)) {
    fd_from_records();
    return;
  }
  vx_handle in_end = vx_spawn_take("stdin"), out_end = vx_spawn_take("stdout");
  ofd *cons = console ? ofd_new(OFD_CONSOLE, O_RDWR) : nullptr;
  ofd *in = in_end ? pipe_ofd(in_end, true, 0) : cons;
  ofd *out = out_end ? pipe_ofd(out_end, false, 0) : cons;
  ofd *err = cons ? cons : out;
  ofd *std[3] = {in, out, err};
  for (int fd = 0; fd < 3; fd++) {
    if (!std[fd]) continue;
    if (fd_table[0].o == std[fd] || fd_table[1].o == std[fd] || fd_table[2].o == std[fd]) std[fd]->refs++;
    fd_table[fd].o = std[fd];
  }
}

// At exit: what vx_print has buffered goes out, and this process's pipe ends
// close, so a reader sees the end of its file before the exit.
static void fd_exit(void) {
  if (vx_console.len) vx_console_flush();
  // Locks go with the process, as POSIX has it: let go now, not when the
  // server notices the connection has gone, which can be after a parent's
  // wait has returned.
  for (int i = 0; i < FD_MAX; i++)
    if (fd_ofds[i].kind == OFD_FILE && fd_ofds[i].locked) vx_ns_close(&fd_ofds[i].f);
  for (int i = 0; i < FD_MAX; i++)
    if (fd_ofds[i].kind != OFD_FREE && fd_ofds[i].pipe) {
      vx_handle_close(fd_ofds[i].pipe);
      fd_ofds[i].pipe = VX_HANDLE_NONE;
    }
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
  mode_t type = dir ? S_IFDIR : S_IFREG;
  if (s->mode & P9_DMSYMLINK) type = S_IFLNK;
  if (s->mode & P9_DMDEVICE) type = S_IFCHR;
  *st = (struct stat){
      .st_dev = s->dev,
      .st_ino = s->qid.path,
      .st_mode = type | (s->mode & 0777),
      .st_nlink = dir ? 2 : 1,
      .st_size = (off_t)s->length,
      .st_blksize = 4096,
      .st_blocks = (blkcnt_t)((s->length + 511) / 512),
      .st_atim = {.tv_sec = s->atime},
      .st_mtim = {.tv_sec = s->mtime},
      .st_ctim = {.tv_sec = s->mtime},
  };
}

// A fid's stat: Tgetattr's where the server has the xattr extension (times
// to the nanosecond, links, inode), Tstat's otherwise.
static vx_status fd_stat_fid(p9_client *c, uint32_t fid, struct stat *st) {
  p9_attr a;
  if (p9c_getattr(c, fid, &a) == VX_OK) {
    *st = (struct stat){.st_ino = a.qid.path,
                        .st_mode = a.mode,
                        .st_nlink = (nlink_t)a.nlink,
                        .st_uid = a.uid,
                        .st_gid = a.gid,
                        .st_size = (off_t)a.size,
                        .st_blksize = (blksize_t)a.blksize,
                        .st_blocks = (blkcnt_t)a.blocks,
                        .st_atim = {(time_t)a.atime_sec, (long)a.atime_nsec},
                        .st_mtim = {(time_t)a.mtime_sec, (long)a.mtime_nsec},
                        .st_ctim = {(time_t)a.ctime_sec, (long)a.ctime_nsec}};
    return VX_OK;
  }
  p9_stat s;
  vx_status e = p9c_stat(c, fid, &s);
  if (e == VX_OK) fd_stat_fill(st, &s);
  return e;
}

// --- Symbolic links ---
//
// The servers walk names only, so the client follows links (docs/proto/
// posix.md): a walk of the whole path that succeeds went through no link,
// as a link is no directory, and only its last component may be one; a walk
// that fails may have met one on the way, so its prefixes are looked at in
// turn. Only connections with the posix extension can hold links.

// Whether the path's last component is a link (1, with its target), is not
// (0), or is not there (a negated errno).
static int fd_link_at(const char *p, size_t len, char *target, size_t cap, size_t *tlen) {
  p9_client *c = nullptr;
  uint32_t fid = 0;
  vx_status st = vx_ns_walk(fd_namespace(), (vx_str){p, len}, &c, &fid);
  if (st != VX_OK) return (int)vx_errno(st);
  int r = 0;
  p9_stat s;
  if ((c->extensions & P9_EXT_POSIX) && p9c_stat(c, fid, &s) == VX_OK && (s.mode & P9_DMSYMLINK)) {
    vx_str t;
    r = -EINVAL;
    if (p9c_readlink(c, fid, &t) == VX_OK) r = t.len < cap ? 1 : -ENAMETOOLONG;
    if (r == 1) memcpy(target, t.ptr, t.len), *tlen = t.len;
  }
  p9c_clunk(c, fid);
  return r;
}

// path (cleaned, absolute, in out) with its links followed: every one, or all
// but the last component's. Returns its length or a negated errno; a path
// that is not there comes back as it is, for the caller to find so.
static long fd_resolve(int dirfd, const char *path, bool follow, char *out) {
  long n = fd_path(dirfd, path, out);
  for (int hops = 0; n > 1; hops++) {
    if (hops == 40) return -ELOOP;
    size_t limit = (size_t)n; // what may be followed: all, or up to the last component's parent
    if (!follow) {
      while (limit > 1 && out[limit - 1] != '/') limit--;
      if (limit > 1) limit--;
    }
    if (limit <= 1) return n;
    char target[VX_NS_MAX_PATH];
    size_t tlen = 0, at = limit;
    int r = fd_link_at(out, limit, target, sizeof target, &tlen);
    if (r < 0) { // not there: a link on the way, perhaps
      r = 0;
      for (at = 1; at <= limit && r == 0; at++) {
        while (at < limit && out[at] != '/') at++;
        r = fd_link_at(out, at, target, sizeof target, &tlen);
        if (r == 0 && at == limit) return n;
      }
      at--;
      if (r < 0) return n; // a component is missing: the caller finds so
    }
    if (r == 0) return n;
    // out[0, at) is a link: its target, from its directory, and the rest after it.
    char next[2 * VX_NS_MAX_PATH];
    size_t len = 0, dir = at;
    while (dir > 1 && out[dir - 1] != '/') dir--;
    if (target[0] != '/') {
      memcpy(next, out, dir);
      len = dir;
    }
    if (len + tlen + 1 + ((size_t)n - at) > sizeof next) return -ENAMETOOLONG;
    memcpy(next + len, target, tlen);
    len += tlen;
    next[len++] = '/';
    memcpy(next + len, out + at, (size_t)n - at);
    len += (size_t)n - at;
    n = (long)vx_ns_clean((vx_str){next, len}, out, VX_NS_MAX_PATH);
    if (!n) return -ENAMETOOLONG;
  }
  return n;
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

static long pipe_write(const ofd *o, const uint8_t *p, size_t n) {
  alignas(vx_msg_header) static uint8_t msg[sizeof(vx_msg_header) + FD_PIPE_CHUNK];
  size_t done = 0;
  while (done < n) {
    uint32_t k = n - done < FD_PIPE_CHUNK ? (uint32_t)(n - done) : FD_PIPE_CHUNK;
    *(vx_msg_header *)msg = (vx_msg_header){};
    memcpy(msg + sizeof(vx_msg_header), p + done, k);
    vx_status st;
    for (int tries = 0;; tries++) {
      st = vx_channel_write(o->pipe, msg, (uint32_t)sizeof(vx_msg_header) + k, nullptr, 0);
      if (st != VX_ERR_SHOULD_WAIT) break;
      if (o->flags & O_NONBLOCK) return done ? (long)done : -EAGAIN;
      static const _Atomic uint32_t never; // the reader is behind: wait a little
      vx_futex_wait(&never, 0, vx_clock_read() + (tries < 10 ? 100'000 : 1'000'000));
    }
    if (st != VX_OK) return done ? (long)done : vx_errno(st); // PEER_CLOSED: EPIPE
    done += k;
  }
  return (long)n;
}

// READABLE and PEER_CLOSED on fd_port for a pipe's reader, unless they are there.
static void pipe_arm(ofd *o) {
  if (!o->read_bound)
    o->read_bound = vx_port_bind(fd_port, o->pipe, VX_TRIGGER_READABLE, fd_key(o), 0) == VX_OK;
  if (!o->closed_bound)
    o->closed_bound = vx_port_bind(fd_port, o->pipe, VX_TRIGGER_PEER_CLOSED, fd_key(o), 0) == VX_OK;
}

// Reads what the pipe has: the rest of the current message, or the next one.
// 0 once every writer has gone and everything is read.
static long pipe_read(ofd *o, void *buf, uint32_t count) {
  if (!o->msg) {
    vx_handle vmo;
    uint64_t at = 0;
    vx_status st = vx_vmo_create(FD_PIPE_BUFFER, 0, &vmo);
    if (st == VX_OK) {
      st = vx_as_map(vx_self, vmo, 0, FD_PIPE_BUFFER, VX_MAP_WRITE, &at);
      vx_handle_close(vmo);
    }
    if (st != VX_OK) return -ENOMEM;
    o->msg = (uint8_t *)at;
  }
  while (o->msg_pos == o->msg_len && !o->ended) {
    vx_msg_size size;
    vx_status st = vx_channel_read(o->pipe, o->msg, FD_PIPE_BUFFER, nullptr, 0, &size);
    if (st == VX_OK && size.bytes >= sizeof(vx_msg_header)) {
      o->msg_len = size.bytes;
      o->msg_pos = sizeof(vx_msg_header);
    } else if (st == VX_ERR_SHOULD_WAIT) {
      if (o->flags & O_NONBLOCK) return -EAGAIN;
      pipe_arm(o);
      long w = fd_wait(VX_INFINITE); // a packet for another description only means trying again
      if (w == -EINTR) return w;
    } else if (st != VX_OK) {
      o->ended = true; // the writers have gone (or sent more than a message holds)
    }
  }
  uint32_t n = o->msg_len - o->msg_pos;
  if (n > count) n = count;
  memcpy(buf, o->msg + o->msg_pos, n);
  o->msg_pos += n;
  return n;
}

// Whether the file's offset is the server's (posix).
static bool file_shared(const ofd *o) {
  return o->kind == OFD_FILE && !o->dir && o->f.c && (o->f.c->extensions & P9_EXT_POSIX);
}

static int64_t file_offset(const ofd *o) {
  uint64_t at = o->f.offset;
  if (file_shared(o) && p9c_seek(o->f.c, o->f.fid, 0, 1, &at) != VX_OK) return -1;
  return (int64_t)at;
}

static long file_write(ofd *o, const uint8_t *p, size_t n) {
  if (file_shared(o)) { // at the open file's offset, or its end, which the server moves on
    size_t done = 0;
    while (done < n) {
      uint32_t k = n - done < (1u << 20) ? (uint32_t)(n - done) : 1u << 20;
      int64_t w = p9c_write(o->f.c, o->f.fid, P9_OFFSET_CURRENT, p + done, k);
      if (w <= 0 && done) return (long)done;
      if (w <= 0) return w ? vx_errno((vx_status)w) : -EIO;
      done += (size_t)w;
    }
    return (long)n;
  }
  if (o->flags & O_APPEND) { // to the end as it is now: not atomic without the posix extension
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
  case OFD_CONSOLE:
    if (o->ra) return ra_read(o, buf, count, !(o->flags & O_NONBLOCK));
    r = vx_console_read(buf, count);
    break;
  case OFD_PIPE_IN: return pipe_read(o, buf, count);
  case OFD_FILE:
    if (o->dir) return -EISDIR;
    if (o->ra) return ra_read(o, buf, count, !(o->flags & O_NONBLOCK));
    r = file_shared(o) ? p9c_read(o->f.c, o->f.fid, P9_OFFSET_CURRENT, buf, count)
                       : vx_ns_read(&o->f, buf, count);
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
  case OFD_PIPE_OUT: return pipe_write(o, buf, n);
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

// preadv2 and pwritev2, which musl's pread and pwrite use first: at the
// offset given, or (-1) at the file's own. RWF_NOAPPEND (0x20) is what an
// explicit offset already means here; any other flag is not supported.
static long fd_prw2(int fd, const struct iovec *iov, int count, long offset, int flags, bool write) {
  if (flags & ~0x20) return -EOPNOTSUPP;
  if (offset == -1) return write ? fd_writev(fd, iov, count) : fd_readv(fd, iov, count);
  if (count < 0 || count > IOV_MAX) return -EINVAL;
  long done = 0;
  for (int i = 0; i < count; i++) {
    if (!iov[i].iov_len) continue;
    long r = write ? fd_pwrite(fd, iov[i].iov_base, iov[i].iov_len, offset + done)
                   : fd_pread(fd, iov[i].iov_base, iov[i].iov_len, offset + done);
    if (r < 0) return done ? done : r;
    done += r;
    if ((size_t)r < iov[i].iov_len) break;
  }
  return done;
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
  if (file_shared(o)) {
    if (whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) return -EINVAL;
    uint64_t at;
    vx_status st = p9c_seek(o->f.c, o->f.fid, offset, (uint8_t)whence, &at); // SEEK_* are 0, 1, 2
    return st == VX_OK ? (long)at : vx_errno(st);
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

static void tty_note(ofd *o, bool device, uint32_t pty); // below, with the terminals

// tty_note from the fid's stat: for a file opened again or joined.
static void tty_check(ofd *o) {
  p9_stat s;
  if (p9c_stat(o->f.c, o->f.fid, &s) != VX_OK || !(s.mode & P9_DMDEVICE)) return;
  uint32_t pty = 0;
  for (size_t i = 0; i < s.name.len && s.name.ptr[i] >= '0' && s.name.ptr[i] <= '9'; i++)
    pty = pty * 10 + (uint32_t)(s.name.ptr[i] - '0');
  tty_note(o, true, pty);
}

static long fd_openat(int dirfd, const char *path, int flags, mode_t mode) {
  char p[VX_NS_MAX_PATH];
  bool excl = (flags & O_CREAT) && (flags & O_EXCL);
  // O_EXCL never follows a link in the last component: a link there, even a
  // dangling one, is a name that exists.
  long len = fd_resolve(dirfd, path, !(flags & O_NOFOLLOW) && !excl, p);
  if (len < 0) return len;
  char target[VX_NS_MAX_PATH];
  size_t target_len;
  if ((flags & O_NOFOLLOW) && fd_link_at(p, (size_t)len, target, sizeof target, &target_len) == 1)
    return -ELOOP; // the last component is a link
  int acc = flags & O_ACCMODE;
  uint8_t mode9 = P9_OREAD;
  if (acc == O_WRONLY) mode9 = P9_OWRITE;
  if (acc == O_RDWR) mode9 = P9_ORDWR;
  vx_ns *ns = fd_namespace();
  vx_ns_file f;
  vx_str name = {p, (size_t)len};
  uint8_t open9 = mode9 | (flags & O_TRUNC ? P9_OTRUNC : 0);
  // With O_EXCL, only Tcreate: the server refuses a name that exists, in the
  // same step as making it, so nothing is opened (or truncated) first.
  vx_status st = excl ? VX_ERR_NOT_FOUND : vx_ns_open(ns, name, open9, &f);
  if (st == VX_ERR_NOT_FOUND && (flags & O_CREAT)) {
    st = vx_ns_create(ns, name, mode & 0755, mode9, &f); // the umask is 022
    // Another process made it between the open and the create: open theirs.
    if (st == VX_ERR_EXISTS && !excl) st = vx_ns_open(ns, name, open9, &f);
  }
  if (st != VX_OK) return vx_errno(st);
  p9_stat s;
  st = p9c_stat(f.c, f.fid, &s);
  bool dir = st == VX_OK && (s.mode & P9_DMDIR);
  bool device = st == VX_OK && (s.mode & P9_DMDEVICE);
  uint32_t pty = 0;
  for (size_t i = 0; device && i < s.name.len && s.name.ptr[i] >= '0' && s.name.ptr[i] <= '9'; i++)
    pty = pty * 10 + (uint32_t)(s.name.ptr[i] - '0');
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
  if ((flags & O_APPEND) && file_shared(o)) p9c_append(o->f.c, o->f.fid, true); // atomic, at the server
  tty_note(o, device, pty);
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

// fcntl's POSIX locks, held by the server (posix), owned by this process.
// F_SETLKW asks again every 10 ms until it is granted or a signal comes.
static long posix_pid(void); // process.c
static long posix_getsid(long pid);

static long fd_lock(ofd *o, int cmd, struct flock *l) {
  if (o->kind != OFD_FILE || o->dir) return -EBADF;
  if (!file_shared(o)) return -ENOLCK; // no server to keep it
  if (l->l_type != F_RDLCK && l->l_type != F_WRLCK && l->l_type != F_UNLCK) return -EINVAL;
  if (cmd == F_SETLK || cmd == F_SETLKW) {
    if (l->l_type == F_RDLCK && (o->flags & O_ACCMODE) == O_WRONLY) return -EBADF;
    if (l->l_type == F_WRLCK && (o->flags & O_ACCMODE) == O_RDONLY) return -EBADF;
  }
  int64_t base = 0;
  if (l->l_whence == SEEK_CUR) base = file_offset(o);
  if (l->l_whence == SEEK_END) {
    struct stat st;
    if (fd_stat_fid(o->f.c, o->f.fid, &st) != VX_OK) return -EIO;
    base = st.st_size;
  }
  if (base < 0 || (l->l_whence != SEEK_SET && l->l_whence != SEEK_CUR && l->l_whence != SEEK_END))
    return -EINVAL;
  int64_t start = base + l->l_start, length = l->l_len;
  if (length < 0) start += length, length = -length; // the bytes before
  if (start < 0) return -EINVAL;
  uint32_t me = (uint32_t)posix_pid();
  if (cmd == F_GETLK) {
    p9_msg got;
    vx_status st =
        p9c_getlock(o->f.c, o->f.fid, (uint8_t)l->l_type, (uint64_t)start, (uint64_t)length, me, &got);
    if (st != VX_OK) return vx_errno(st);
    if (got.lock_type == P9_LOCK_UNLOCK) {
      l->l_type = F_UNLCK;
    } else {
      *l = (struct flock){.l_type = got.lock_type,
                          .l_whence = SEEK_SET,
                          .l_start = (off_t)got.start,
                          .l_len = (off_t)got.length,
                          .l_pid = (pid_t)got.proc_id};
    }
    return 0;
  }
  for (;;) {
    uint8_t status = P9_LOCK_ERROR;
    vx_status st =
        p9c_lock(o->f.c, o->f.fid, (uint8_t)l->l_type, (uint64_t)start, (uint64_t)length, me, &status);
    if (st != VX_OK) return vx_errno(st);
    if (status == P9_LOCK_SUCCESS) {
      o->locked = o->locked || l->l_type != F_UNLCK;
      return 0;
    }
    if (status != P9_LOCK_BLOCKED) return -ENOLCK;
    if (cmd == F_SETLK) return -EAGAIN;
    static const _Atomic uint32_t never;
    if (vx_futex_wait(&never, 0, vx_clock_read() + 10'000'000) == VX_ERR_INTERRUPTED) return -EINTR;
  }
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
  case F_SETFL:
    if (file_shared(o) && (o->flags & O_APPEND) != (arg & O_APPEND))
      p9c_append(o->f.c, o->f.fid, arg & O_APPEND);
    o->flags = (o->flags & O_ACCMODE) | (int)(arg & (O_APPEND | O_NONBLOCK));
    return 0;
  case F_GETLK:
  case F_SETLK:
  case F_SETLKW: return fd_lock(o, cmd, (struct flock *)arg);
  default: return -EINVAL; // open-file-description locks and the rest
  }
}

// --- Names ---

// Walks to path (cleaned into p, of *len bytes): true with *c and *fid,
// which the caller clunks, or false with *err, a negated errno.
static bool fd_walk(int dirfd, const char *path, bool follow, p9_client **c, uint32_t *fid, char *p,
                    size_t *len, long *err) {
  long n = fd_resolve(dirfd, path, follow, p);
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
  return vx_errno(fd_stat_fid(o->f.c, o->f.fid, st));
}

static long fd_fstatat(int dirfd, const char *path, struct stat *st, int flag) {
  if ((flag & AT_EMPTY_PATH) && !*path) return fd_fstat(dirfd, st);
  p9_client *c = nullptr;
  uint32_t fid = 0;
  char p[VX_NS_MAX_PATH];
  size_t len;
  long r = 0;
  if (!fd_walk(dirfd, path, !(flag & AT_SYMLINK_NOFOLLOW), &c, &fid, p, &len, &r)) return r;
  vx_status vst = fd_stat_fid(c, fid, st);
  p9c_clunk(c, fid);
  return vx_errno(vst);
}

static long fd_faccessat(int dirfd, const char *path) {
  p9_client *c = nullptr;
  uint32_t fid = 0;
  char p[VX_NS_MAX_PATH];
  size_t len;
  long r = 0;
  if (!fd_walk(dirfd, path, true, &c, &fid, p, &len, &r)) return r;
  p9c_clunk(c, fid);
  return 0; // it exists; permissions are the server's to refuse when it is opened
}

static long fd_mkdirat(int dirfd, const char *path, mode_t mode) {
  char p[VX_NS_MAX_PATH];
  long len = fd_resolve(dirfd, path, false, p);
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
  if (!fd_walk(dirfd, path, false, &c, &fid, p, &len, &r)) return r;
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
  if (!fd_walk(AT_FDCWD, path, true, &c, &fid, p, &len, &r)) return r;
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
    d->d_type = DT_REG;
    if (s.mode & P9_DMDIR) d->d_type = DT_DIR;
    if (s.mode & P9_DMSYMLINK) d->d_type = DT_LNK;
    memcpy(d->d_name, s.name.ptr, name_len);
    d->d_name[name_len] = 0;
    written += reclen;
    o->dirs_at = (uint32_t)at;
  }
}

// --- Terminals ---
//
// A terminal is a file its server marks a device: ptyd's ptmx (opened, the
// master) and pts/N (the slave). Its settings are in pts/N.ctl, beside the
// slave, read and written as one ndb record (servers/ptyd); the ioctls are
// Linux's, the POSIX personality's. The console is a terminal of 80 by 24
// that has no settings yet.

typedef struct tty_state {
  uint32_t iflag, oflag, cflag, lflag;
  uint8_t cc[32];
  uint16_t rows, cols;
  int64_t pgrp, avail;
} tty_state;

// pts/N.ctl's path: beside the slave's path, or under the master's ptmx.
static size_t tty_ctl_path(const ofd *o, char *out) {
  size_t dir = o->path_len;
  while (dir > 1 && o->path[dir - 1] != '/') dir--;
  int n = snprintf(out, VX_NS_MAX_PATH, "%.*s%s%u.ctl", (int)dir, o->path, o->master ? "pts/" : "", o->pty);
  return n > 0 && (uint32_t)n < VX_NS_MAX_PATH ? (size_t)n : 0;
}

static long tty_ctl(const ofd *o, const char *set, tty_state *st) {
  char path[VX_NS_MAX_PATH];
  size_t len = tty_ctl_path(o, path);
  vx_ns_file f;
  if (!len || vx_ns_open(fd_namespace(), (vx_str){path, len}, set ? P9_OWRITE : P9_OREAD, &f) != VX_OK)
    return -ENOTTY;
  long r = 0;
  if (set) {
    size_t n = strlen(set);
    r = vx_ns_write(&f, set, (uint32_t)n) == (int64_t)n ? 0 : -EIO;
  } else {
    static char text[512], scratch[512];
    int64_t n = vx_ns_read(&f, text, sizeof text);
    vx_ndb_reader rd = {
        .src = {text, n > 0 ? (size_t)n : 0}, .scratch = scratch, .scratch_cap = sizeof scratch};
    vx_ndb_record rec;
    if (n <= 0 || vx_ndb_next(&rd, &rec) != VX_NDB_RECORD) r = -EIO;
    uint64_t v = 0;
    *st = (tty_state){};
    if (r == 0) {
      if (vx_ndb_get_u64(&rec, "iflag", &v)) st->iflag = (uint32_t)v;
      if (vx_ndb_get_u64(&rec, "oflag", &v)) st->oflag = (uint32_t)v;
      if (vx_ndb_get_u64(&rec, "cflag", &v)) st->cflag = (uint32_t)v;
      if (vx_ndb_get_u64(&rec, "lflag", &v)) st->lflag = (uint32_t)v;
      if (vx_ndb_get_u64(&rec, "rows", &v)) st->rows = (uint16_t)v;
      if (vx_ndb_get_u64(&rec, "cols", &v)) st->cols = (uint16_t)v;
      if (vx_ndb_get_u64(&rec, "pgrp", &v)) st->pgrp = (int64_t)v;
      if (vx_ndb_get_u64(&rec, "avail", &v)) st->avail = (int64_t)v;
      vx_str cc = vx_ndb_get(&rec, "cc");
      if (cc.len == sizeof st->cc) memcpy(st->cc, cc.ptr, sizeof st->cc);
    }
  }
  vx_ns_close(&f);
  return r;
}

// Sets fields, as a record ptyd reads: key=value pairs, the cc as bytes.
static long tty_set(const ofd *o, const struct termios *t, const struct winsize *w, int64_t pgrp,
                    bool flush) {
  static char rec[512];
  vx_ndb_writer wr = {.buf = rec, .cap = sizeof rec - 1};
  if (t) {
    vx_ndb_put_u64(&wr, "iflag", t->c_iflag);
    vx_ndb_put_u64(&wr, "oflag", t->c_oflag);
    vx_ndb_put_u64(&wr, "cflag", t->c_cflag);
    vx_ndb_put_u64(&wr, "lflag", t->c_lflag);
    vx_ndb_put(&wr, "cc", (vx_str){(const char *)t->c_cc, 32});
  }
  if (w) vx_ndb_put_u64(&wr, "rows", w->ws_row), vx_ndb_put_u64(&wr, "cols", w->ws_col);
  if (pgrp >= 0) vx_ndb_put_u64(&wr, "pgrp", (uint64_t)pgrp);
  if (flush) vx_ndb_flag(&wr, "flush");
  if (!vx_ndb_end(&wr)) return -EINVAL;
  rec[wr.len] = 0;
  return tty_ctl(o, rec, nullptr);
}

static void tty_note(ofd *o, bool device, uint32_t pty) {
  if (!device) return;
  o->tty = true;
  o->pty = pty;
  o->master = o->path_len >= 5 && memcmp(o->path + o->path_len - 5, "/ptmx", 5) == 0;
}

static long fd_ioctl(int fd, unsigned long request, void *arg) {
  const ofd *o = fd_get(fd);
  if (!o) return -EBADF;
  if (o->kind == OFD_CONSOLE && request == TIOCGWINSZ) {
    *(struct winsize *)arg = (struct winsize){.ws_row = 24, .ws_col = 80};
    return 0;
  }
  if (o->kind != OFD_FILE || !o->tty) return -ENOTTY;
  tty_state st;
  long r = 0;
  switch (request) {
  case TCGETS:
  case TIOCGWINSZ:
  case TIOCGPGRP:
  case FIONREAD:
    if ((r = tty_ctl(o, nullptr, &st)) < 0) return r;
    if (request == TIOCGWINSZ)
      *(struct winsize *)arg = (struct winsize){.ws_row = st.rows, .ws_col = st.cols};
    if (request == TIOCGPGRP) *(pid_t *)arg = (pid_t)st.pgrp;
    if (request == FIONREAD) *(int *)arg = (int)st.avail;
    if (request == TCGETS) {
      struct termios *t = arg;
      *t = (struct termios){
          .c_iflag = st.iflag, .c_oflag = st.oflag, .c_cflag = st.cflag, .c_lflag = st.lflag};
      memcpy(t->c_cc, st.cc, sizeof st.cc);
      t->__c_ispeed = t->__c_ospeed = B38400;
    }
    return 0;
  case TCSETS:
  case TCSETSW: // output is never held back: nothing to drain
  case TCSETSF: return tty_set(o, arg, nullptr, -1, request == TCSETSF);
  case TIOCSWINSZ: return tty_set(o, nullptr, arg, -1, false);
  case TIOCSPGRP: return tty_set(o, nullptr, nullptr, *(const pid_t *)arg, false);
  case TCFLSH: return (long)arg == TCOFLUSH ? 0 : tty_set(o, nullptr, nullptr, -1, true);
  case TIOCGPTN: *(unsigned *)arg = o->pty; return 0;
  case TIOCGSID: *(pid_t *)arg = (pid_t)posix_getsid(0); return 0;
  case TIOCSPTLCK: // grantpt and unlockpt: a terminal is ready from the start
  case TIOCSCTTY:  // controlling terminals are not kept apart yet
  case TIOCNOTTY:
  case TCSBRK:
  case TCXONC: return 0;
  default: return -ENOTTY;
  }
}

// --- Pipes ---

static long fd_pipe2(int *fds, int flags) {
  if (flags & ~(O_CLOEXEC | O_NONBLOCK)) return -EINVAL;
  vx_handle ch[2];
  vx_status st = vx_channel_create(0, ch);
  if (st != VX_OK) return vx_errno(st);
  ofd *r = pipe_ofd(ch[0], true, flags & O_NONBLOCK), *w = pipe_ofd(ch[1], false, flags & O_NONBLOCK);
  if (!r || !w) {
    if (r) ofd_release(r);
    if (w) ofd_release(w);
    return -ENFILE;
  }
  long a = fd_install(r, 0, flags & O_CLOEXEC);
  if (a < 0) {
    ofd_release(w);
    return a;
  }
  long b = fd_install(w, 0, flags & O_CLOEXEC);
  if (b < 0) {
    fd_close((int)a);
    return b;
  }
  fds[0] = (int)a, fds[1] = (int)b;
  return 0;
}

// --- Descriptors for a child ---
//
// A child (posix_spawn, execve) is given a table of descriptors as fd=
// records in its spawn message, one per open descriptor without FD_CLOEXEC,
// and the working directory as cwd=:
//   fd=N console
//   fd=N pipe=read|write end=NAME flags=F       the same channel end, shared
//   fd=N file=PATH flags=F offset=O [dir] [token=T]   joined, or opened again
//   fd=N same=M                                 the same description as M
// A file with a token is the same open file, its offset shared; one without
// (a server without posix) is opened again, its offset the child's own.

// A file or directory at path, opened again with the description's flags
// (never creating or truncating) at offset.
static ofd *file_reopen(const char *path, size_t len, int flags, uint64_t offset) {
  int acc = flags & O_ACCMODE;
  uint8_t mode9 = P9_OREAD;
  if (acc == O_WRONLY) mode9 = P9_OWRITE;
  if (acc == O_RDWR) mode9 = P9_ORDWR;
  vx_ns_file f;
  if (vx_ns_open(fd_namespace(), (vx_str){path, len}, mode9, &f) != VX_OK) return nullptr;
  p9_stat s;
  bool dir = p9c_stat(f.c, f.fid, &s) == VX_OK && (s.mode & P9_DMDIR);
  ofd *o = ofd_new(OFD_FILE, flags & (O_ACCMODE | O_APPEND | O_NONBLOCK));
  if (!o) {
    vx_ns_close(&f);
    return nullptr;
  }
  o->f = f;
  o->dir = dir;
  if (!dir) o->f.offset = offset;
  memcpy(o->path, path, len);
  o->path_len = len;
  uint64_t at;
  if (file_shared(o)) {
    p9c_seek(o->f.c, o->f.fid, (int64_t)offset, 0, &at);
    if (flags & O_APPEND) p9c_append(o->f.c, o->f.fid, true);
  }
  tty_check(o);
  return o;
}

// The open file a token names, joined on the server path is on (the
// parent's); or, if it cannot be, the file opened again at offset.
static ofd *file_join(const char *path, size_t len, int flags, const uint8_t token[16], uint64_t offset) {
  p9_client *c = nullptr;
  uint32_t fid = 0, joined = 0;
  if (vx_ns_walk(fd_namespace(), (vx_str){path, len}, &c, &fid) == VX_OK) {
    p9c_clunk(c, fid);
    if (p9c_join(c, token, &joined) == VX_OK) {
      ofd *o = ofd_new(OFD_FILE, flags & (O_ACCMODE | O_APPEND | O_NONBLOCK));
      if (!o) {
        p9c_clunk(c, joined);
        return nullptr;
      }
      o->f = (vx_ns_file){.ns = fd_namespace(), .c = c, .fid = joined};
      memcpy(o->path, path, len);
      o->path_len = len;
      tty_check(o);
      return o;
    }
  }
  return file_reopen(path, len, flags, offset);
}

static void fd_records(const fd_slot *table, vx_ndb_writer *w, vx_handle *handles, vx_str *names,
                       uint32_t *count, uint32_t cap) {
  static char handle_names[FD_MAX][8];
  vx_ndb_put(w, "cwd", (vx_str){fd_cwd, fd_cwd_len});
  vx_ndb_end(w);
  for (int fd = 0; fd < FD_MAX; fd++) {
    const ofd *o = table[fd].o;
    if (!o || table[fd].cloexec) continue;
    int same = -1;
    for (int j = 0; j < fd && same < 0; j++)
      if (table[j].o == o && !table[j].cloexec) same = j;
    vx_ndb_put_u64(w, "fd", (uint64_t)fd);
    if (same >= 0) {
      vx_ndb_put_u64(w, "same", (uint64_t)same);
    } else if (o->kind == OFD_CONSOLE) {
      vx_ndb_flag(w, "console");
    } else if (o->kind == OFD_PIPE_IN || o->kind == OFD_PIPE_OUT) {
      char *nm = handle_names[fd];
      nm[0] = 'f', nm[1] = 'd', nm[2] = '.', nm[3] = (char)('0' + fd / 10), nm[4] = (char)('0' + fd % 10);
      if (*count < cap && o->pipe && vx_handle_dup(o->pipe, VX_RIGHTS_SAME, &handles[*count]) == VX_OK) {
        names[(*count)++] = (vx_str){nm, 5};
        vx_ndb_put(w, "pipe", o->kind == OFD_PIPE_IN ? VX_STR("read") : VX_STR("write"));
        vx_ndb_put(w, "end", (vx_str){nm, 5}); // not handle=, which declares a handle
        vx_ndb_put_u64(w, "flags", (uint64_t)o->flags);
      } else {
        w->failed = true;
      }
    } else if (o->kind == OFD_FILE) {
      vx_ndb_put(w, "file", (vx_str){o->path, o->path_len});
      vx_ndb_put_u64(w, "flags", (uint64_t)o->flags);
      int64_t at = file_offset(o);
      vx_ndb_put_u64(w, "offset", at < 0 ? 0 : (uint64_t)at);
      uint8_t token[16];
      if (file_shared(o) && p9c_share(o->f.c, o->f.fid, 1, token) == VX_OK) // the child joins it
        vx_ndb_put(w, "token", (vx_str){(const char *)token, sizeof token});
      if (o->dir) vx_ndb_flag(w, "dir");
    }
    vx_ndb_end(w);
  }
}

static void fd_from_records(void) {
  static char scratch[VX_CHANNEL_MAX_BYTES];
  vx_ndb_reader r = {.src = vx_spawn.text, .scratch = scratch, .scratch_cap = sizeof scratch};
  vx_ndb_record rec;
  while (vx_ndb_next(&r, &rec) == VX_NDB_RECORD) {
    uint64_t fd, n = 0, flags = 0, offset = 0;
    if (vx_ndb_has(&rec, "cwd")) {
      vx_str cwd = vx_ndb_get(&rec, "cwd");
      if (cwd.len && cwd.len < sizeof fd_cwd && cwd.ptr[0] == '/') {
        memcpy(fd_cwd, cwd.ptr, cwd.len);
        fd_cwd[cwd.len] = 0;
        fd_cwd_len = cwd.len;
      }
      continue;
    }
    if (!vx_ndb_get_u64(&rec, "fd", &fd) || fd >= FD_MAX) continue;
    vx_ndb_get_u64(&rec, "flags", &flags);
    vx_ndb_get_u64(&rec, "offset", &offset);
    if (vx_ndb_get_u64(&rec, "same", &n)) {
      if (n < FD_MAX && fd_table[n].o) {
        fd_table[n].o->refs++;
        fd_place((int)fd, fd_table[n].o);
      }
    } else if (vx_ndb_has(&rec, "console")) {
      fd_place((int)fd, vx_console.connector ? ofd_new(OFD_CONSOLE, O_RDWR) : nullptr);
    } else if (vx_ndb_has(&rec, "pipe")) {
      char name[8] = {};
      vx_str h = vx_ndb_get(&rec, "end");
      if (h.len >= sizeof name) continue;
      memcpy(name, h.ptr, h.len);
      vx_handle end = vx_spawn_take(name);
      bool reader = vx_ndb_get(&rec, "pipe").len == 4; // "read"
      if (end) fd_place((int)fd, pipe_ofd(end, reader, (int)flags & O_NONBLOCK));
    } else if (vx_ndb_has(&rec, "file")) {
      vx_str path = vx_ndb_get(&rec, "file"), token = vx_ndb_get(&rec, "token");
      if (path.len >= VX_NS_MAX_PATH) continue;
      ofd *o = token.len == 16 ? file_join(path.ptr, path.len, (int)flags, (const uint8_t *)token.ptr, offset)
                               : file_reopen(path.ptr, path.len, (int)flags, offset);
      fd_place((int)fd, o);
    }
  }
}

// --- After a fork ---
//
// The child has a copy of this memory, so the table is as it was, but not of
// rings: the namespace's connections and the console's are gone, and so are
// the fids its files were open on. Each is opened again by its path, at its
// offset. A directory starts again from its first entry. Pipe ends are
// shared, as POSIX has them; the port a blocked read waits on is the
// child's own.
// Before a fork: a token for each open file the child should join.
static void fd_before_fork(void) {
  for (int i = 0; i < FD_MAX; i++) {
    ofd *o = &fd_ofds[i];
    o->has_token = file_shared(o) && p9c_share(o->f.c, o->f.fid, 1, o->token) == VX_OK;
    int64_t at = o->has_token ? file_offset(o) : -1;
    if (at >= 0) o->f.offset = (uint64_t)at; // for the child, if it cannot join
  }
}

static void fd_after_fork_parent(void) {
  for (int i = 0; i < FD_MAX; i++) fd_ofds[i].has_token = false;
}

static void fd_after_fork(void) {
  if (vx_console.conn.end) p9_ring_disconnect(&vx_console.conn);
  vx_console.open = false;
  vx_handle_close(fd_port);
  vx_port_create(0, &fd_port);
  if (fd_ns_status != VX_ERR_BAD_STATE) fd_ns_status = vx_ns_after_fork(&fd_ns);
  for (int i = 0; i < FD_MAX; i++) {
    ofd *o = &fd_ofds[i];
    o->closed_bound = o->read_bound = false;
    if (o->ra) ra_free(o); // its connection's ring was not copied
    if (o->kind != OFD_FILE) continue;
    uint64_t offset = o->f.offset;
    o->f = (vx_ns_file){}; // the fid was on the old connection
    ofd *n = o->has_token ? file_join(o->path, o->path_len, o->flags, o->token, offset)
                          : file_reopen(o->path, o->path_len, o->flags, offset);
    o->has_token = false;
    if (!n) continue; // reads and writes now fail with EBADF
    o->f = n->f;
    o->dirs_len = o->dirs_at = 0;
    o->dir_next = 0;
    *n = (ofd){}; // its fid is o's now
  }
}

// --- The posix and xattr extensions: names and attributes ---

// path's parent directory, walked, and its last component's name (into p).
static long fd_parent(int dirfd, const char *path, p9_client **c, uint32_t *fid, char *p, vx_str *name) {
  long n = fd_resolve(dirfd, path, false, p);
  if (n < 0) return n;
  size_t slash = (size_t)n;
  while (slash > 0 && p[slash - 1] != '/') slash--;
  if (slash == (size_t)n) return -EINVAL; // "/"
  *name = (vx_str){p + slash, (size_t)n - slash};
  vx_str dir = {p, slash > 1 ? slash - 1 : 1};
  vx_status st = vx_ns_walk(fd_namespace(), dir, c, fid);
  if (st == VX_OK) return 0;
  long e = vx_errno(st);
  return e < 0 ? e : -EIO; // never 0: *c is set only on success
}

static long fd_status(vx_status st) { return st == VX_ERR_UNSUPPORTED ? -EPERM : vx_errno(st); }

static long fd_renameat(int olddirfd, const char *old, int newdirfd, const char *new, unsigned flags) {
  if (flags) return -EINVAL; // RENAME_NOREPLACE and the rest
  char p1[VX_NS_MAX_PATH], p2[VX_NS_MAX_PATH];
  vx_str n1, n2;
  p9_client *c1 = nullptr, *c2 = nullptr;
  uint32_t f1 = 0, f2 = 0;
  long r = fd_parent(olddirfd, old, &c1, &f1, p1, &n1);
  if (r < 0) return r;
  r = fd_parent(newdirfd, new, &c2, &f2, p2, &n2);
  if (r < 0) {
    p9c_clunk(c1, f1);
    return r;
  }
  r = c1 == c2 ? fd_status(p9c_renameat(c1, f1, n1, f2, n2)) : -EXDEV; // within one server only
  p9c_clunk(c1, f1);
  p9c_clunk(c2, f2);
  return r;
}

static long fd_symlinkat(const char *target, int dirfd, const char *path) {
  char p[VX_NS_MAX_PATH];
  vx_str name;
  p9_client *c = nullptr;
  uint32_t fid = 0;
  if (!*target) return -ENOENT;
  long r = fd_parent(dirfd, path, &c, &fid, p, &name);
  if (r < 0) return r;
  r = fd_status(p9c_symlink(c, fid, name, (vx_str){target, strlen(target)}));
  p9c_clunk(c, fid);
  return r;
}

static long fd_readlinkat(int dirfd, const char *path, char *buf, size_t size) {
  char p[VX_NS_MAX_PATH], target[VX_NS_MAX_PATH];
  long n = fd_resolve(dirfd, path, false, p);
  if (n < 0) return n;
  size_t len = 0;
  int r = fd_link_at(p, (size_t)n, target, sizeof target, &len);
  if (r <= 0) return r ? r : -EINVAL; // not a link
  if (len > size) len = size;         // cut short, as readlink does
  memcpy(buf, target, len);
  return (long)len;
}

// Tsetattr on what path names (following its links, unless told not to), or
// on an open descriptor's file (fd >= 0, path null).
static long fd_setattr(int fd, int dirfd, const char *path, bool follow, const p9_setattr *a) {
  if (!path) {
    const ofd *o = fd_get(fd);
    if (!o) return -EBADF;
    if (o->kind != OFD_FILE) return -EINVAL;
    return fd_status(p9c_setattr(o->f.c, o->f.fid, a));
  }
  p9_client *c = nullptr;
  uint32_t fid = 0;
  char p[VX_NS_MAX_PATH];
  size_t len;
  long r = 0;
  if (!fd_walk(dirfd, path, follow, &c, &fid, p, &len, &r)) return r;
  r = fd_status(p9c_setattr(c, fid, a));
  p9c_clunk(c, fid);
  return r;
}

static long fd_chmod(int fd, int dirfd, const char *path, mode_t mode) {
  return fd_setattr(fd, dirfd, path, true, &(p9_setattr){.valid = P9_SETATTR_MODE, .mode = mode & 07777});
}

static long fd_chown(int fd, int dirfd, const char *path, uid_t uid, gid_t gid, bool follow) {
  p9_setattr a = {.uid = uid, .gid = gid};
  if (uid != (uid_t)-1) a.valid |= P9_SETATTR_UID;
  if (gid != (gid_t)-1) a.valid |= P9_SETATTR_GID;
  return a.valid ? fd_setattr(fd, dirfd, path, follow, &a) : 0;
}

static long fd_truncate(int fd, const char *path, long size) {
  if (size < 0) return -EINVAL;
  return fd_setattr(fd, AT_FDCWD, path, true,
                    &(p9_setattr){.valid = P9_SETATTR_SIZE, .size = (uint64_t)size});
}

// utimensat and futimens: each time now (UTIME_NOW, or no times at all), as
// given, or left alone (UTIME_OMIT).
static long fd_utimens(int dirfd, const char *path, const struct timespec *times, int flags) {
  p9_setattr a = {};
  for (int i = 0; i < 2; i++) {
    long ns = times ? times[i].tv_nsec : UTIME_NOW;
    if (ns == UTIME_OMIT) continue;
    a.valid |= i ? P9_SETATTR_MTIME : P9_SETATTR_ATIME;
    if (ns == UTIME_NOW) continue;
    if (ns < 0 || ns >= 1'000'000'000) return -EINVAL;
    a.valid |= i ? P9_SETATTR_MTIME_SET : P9_SETATTR_ATIME_SET;
    *(i ? &a.mtime_sec : &a.atime_sec) = (uint64_t)times[i].tv_sec;
    *(i ? &a.mtime_nsec : &a.atime_nsec) = (uint64_t)ns;
  }
  if (!a.valid) return 0;
  return fd_setattr(path ? -1 : dirfd, dirfd, path, !(flags & AT_SYMLINK_NOFOLLOW), &a);
}

static long fd_fsync(int fd) {
  const ofd *o = fd_get(fd);
  if (!o) return -EBADF;
  if (o->kind != OFD_FILE) return -EINVAL;
  return vx_errno(p9c_fsync(o->f.c, o->f.fid));
}
