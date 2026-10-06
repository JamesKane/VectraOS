// poll.c: poll, ppoll, select and pselect6, on the one port (docs/01 §9).
// Part of backend.c.
//
// Each description knows when it can be read or written:
//   a file or directory      always, as POSIX has it
//   a pipe's reader          its channel has a message, or its writers have
//                            gone (READABLE and PEER_CLOSED on fd_port)
//   a pipe's writer          always, unless its reader has gone (POLLERR)
//   a terminal, the console  written always; read once a read kept
//                            outstanding has its reply (the read-ahead, on a
//                            connection of its own; its doorbell on fd_port)
//   a socket                 as a terminal, read; listening, read once an open
//                            of its listen file kept outstanding has its reply;
//                            connecting, written once connect's ctl write has;
//                            written once data written behind has gone
//                            (socket.c)
// A wait is one port_wait on fd_port, until something armed fires, the
// deadline passes, or a signal comes.

// --- Read-ahead ---

// --- The read-aheads' connections (6d4d1) ---
//
// Apart from the namespace's, so the reads a server holds for long never
// starve its other calls: a pool for each server, six read-aheads to a
// connection, one of them big (a datagram's read or a write behind, a whole
// message each), so their calls and replies always fit its arenas. A
// connection is made when the pool has none with room, and goes with its
// last read-ahead.
static constexpr uint32_t RA_POOL = 16, RA_USERS = 6;
static struct ra_pool {
  vx_handle connector; // whose server; borrowed (the namespace's, or the console's)
  p9_conn *k;          // in a page of its own; nullptr: free
  uint32_t users;
  bool big;
} ra_pools[RA_POOL];

static constexpr uint64_t RA_CONN_SIZE = (sizeof(p9_conn) + 4095) & ~4095ull;

// A connection to the server behind connector with room for one more
// read-ahead (big, or not): its index in *pool. nullptr if none can be made.
static p9_conn *ra_pool_take(vx_handle connector, bool big, uint32_t *pool) {
  int free = -1;
  for (uint32_t i = 0; i < RA_POOL; i++) {
    struct ra_pool *p = &ra_pools[i];
    if (!p->k) {
      if (free < 0) free = (int)i;
      continue;
    }
    if (p->connector != connector || p->k->dead || p->users == RA_USERS || (big && p->big)) continue;
    p->users++, p->big = p->big || big;
    *pool = i;
    return p->k;
  }
  if (free < 0) return nullptr;
  vx_handle vmo;
  uint64_t at = 0;
  if (vx_vmo_create(RA_CONN_SIZE, 0, &vmo) != VX_OK) return nullptr;
  vx_status st = vx_as_map(vx_self, vmo, 0, RA_CONN_SIZE, VX_MAP_WRITE, &at);
  vx_handle_close(vmo);
  if (st != VX_OK) return nullptr;
  p9_conn *k = (p9_conn *)at;
  if (p9_ring_connect(connector, k) != VX_OK) {
    vx_as_unmap(vx_self, at, RA_CONN_SIZE);
    return nullptr;
  }
  ra_pools[free] = (struct ra_pool){.connector = connector, .k = k, .users = 1, .big = big};
  *pool = (uint32_t)free;
  return k;
}

static void ra_pool_close(struct ra_pool *p) {
  p9_ring_disconnect(p->k);
  vx_as_unmap(vx_self, (uint64_t)p->k, RA_CONN_SIZE);
  *p = (struct ra_pool){};
}

static void ra_pool_give(uint32_t pool, bool big) {
  struct ra_pool *p = &ra_pools[pool];
  if (big) p->big = false;
  if (p->users) p->users--;
  if (!p->users) ra_pool_close(p);
}

// After a fork: the connections' rings were not copied; let go of the rest.
static void ra_pools_forget(void) {
  for (uint32_t i = 0; i < RA_POOL; i++)
    if (ra_pools[i].k) ra_pool_close(&ra_pools[i]);
}

static constexpr uint64_t RA_SIZE = (sizeof(fd_readahead) + 4095) & ~4095ull;

// A read-ahead on the pool's connection to connector's server: big, or not;
// key is its owner's on fd_port.
static fd_readahead *ra_new(vx_handle connector, bool big, uint64_t key) {
  vx_handle vmo;
  uint64_t at = 0;
  if (!connector || vx_vmo_create(RA_SIZE, 0, &vmo) != VX_OK) return nullptr;
  vx_status st = vx_as_map(vx_self, vmo, 0, RA_SIZE, VX_MAP_WRITE, &at);
  vx_handle_close(vmo);
  if (st != VX_OK) return nullptr;
  fd_readahead *ra = (fd_readahead *)at;
  uint32_t pool = 0;
  ra->k = ra_pool_take(connector, big, &pool);
  if (!ra->k) {
    vx_as_unmap(vx_self, at, RA_SIZE);
    return nullptr;
  }
  ra->pool = pool + 1, ra->big = big, ra->key = key;
  ra->count = big ? FD_RA_MAX : FD_RA_READ;
  return ra;
}

// Lets go of a read-ahead: its call still outstanding (flushed), its fids,
// its place on the pool's connection.
static void ra_drop(fd_readahead *ra) {
  if (ra->pending) p9_ring_cancel(ra->k, ra->tag);
  if (ra->fid) p9c_clunk(&ra->k->c, ra->fid);
  if (ra->root) p9c_clunk(&ra->k->c, ra->root);
  if (ra->pool) ra_pool_give(ra->pool - 1, ra->big);
  vx_as_unmap(vx_self, (uint64_t)ra, RA_SIZE);
}

// A forked child's: the connection is not there to talk to (ra_pools_forget).
static void ra_forget(fd_readahead *ra) { vx_as_unmap(vx_self, (uint64_t)ra, RA_SIZE); }

static void ra_free(ofd *o) {
  fd_readahead *ra = o->ra;
  o->ra = nullptr;
  ra_drop(ra);
}

static bool sock_ra_start(ofd *o); // socket.c

// A read-ahead on the pool's connection, and a fid on it: for a terminal,
// the same open file, joined by token (posix); for the console, its cons file.
static bool ra_start(ofd *o) {
  if (o->sock) return sock_ra_start(o);
  vx_handle connector = VX_HANDLE_NONE;
  bool tty = o->kind == OFD_FILE;
  if (tty) {
    for (uint32_t i = 0; i < VX_NS_MAX_CONNS; i++)
      if (fd_ns.conns[i].client == o->f.c) connector = fd_ns.conns[i].connector;
  } else {
    connector = vx_console.connector;
  }
  fd_readahead *ra = ra_new(connector, false, fd_key(o));
  if (!ra) return false;
  uint8_t token[16];
  uint32_t root = 0;
  vx_status st = VX_OK;
  if (tty) {
    st = p9c_share(o->f.c, o->f.fid, 1, token);
    if (st == VX_OK) st = p9c_join(&ra->k->c, token, &ra->fid);
  } else {
    st = p9c_attach(&ra->k->c, VX_STR(""), &root);
    if (st == VX_OK) st = p9c_walk(&ra->k->c, root, VX_STR("cons"), &ra->fid);
    if (st == VX_OK) st = p9c_open(&ra->k->c, ra->fid, P9_OREAD);
    if (root) p9c_clunk(&ra->k->c, root);
  }
  o->ra = ra;
  if (st != VX_OK) {
    ra_free(o);
    return false;
  }
  return true;
}

// Sends the call (t) on the read-ahead's connection, outstanding until
// ra_poll takes its reply. A call that cannot be sent is answered at once,
// with why.
static void ra_send(fd_readahead *ra, p9_msg *t) {
  vx_status st = p9_ring_send(ra->k, t, fd_port, ra->key);
  ra->ready = st != VX_OK;
  ra->pending = st == VX_OK;
  ra->status = st;
  ra->tag = t->tag;
}

// A write's rest, from ra->pos: what the server did not take yet.
static void ra_send_write(fd_readahead *ra) {
  p9_msg t = {.type = P9_Twrite, .fid = ra->fid, .data = {ra->data + ra->pos, ra->len - ra->pos}};
  ra_send(ra, &t);
}

// Takes the reply to the call outstanding, if it has come; for a read, sends
// one if none is outstanding. True once there is an answer: bytes, the end of
// the file, or an error (a read); the open or write done, or why not. A write
// the server took only part of goes on with the rest. Idle (no call), true.
static bool ra_poll(fd_readahead *ra, bool tty) {
  if (ra->ready || (ra->op == RA_READ && ra->pos < ra->len)) return true;
  if (!ra->pending && ra->op != RA_READ) return true;
  if (!ra->pending) {
    p9_msg t = {.type = P9_Tread, .fid = ra->fid, .offset = tty ? P9_OFFSET_CURRENT : 0, .count = ra->count};
    ra_send(ra, &t);
    if (ra->ready) return true;
  }
  p9_msg r;
  vx_status st = p9_ring_receive(ra->k, ra->tag, &r);
  if (st == VX_ERR_SHOULD_WAIT) return false;
  vx_ring_end_sleep(&ra->k->ring);
  ra->pending = false;
  ra->status = st;
  if (ra->op == RA_WRITE) {
    if (st == VX_OK && r.count && r.count <= ra->len - ra->pos) ra->pos += r.count;
    if (st == VX_OK && ra->pos < ra->len) { // the rest, as the server makes room
      ra_send_write(ra);
      return ra->ready;
    }
    ra->ready = true;
    return true;
  }
  ra->ready = true;
  ra->pos = 0;
  ra->len = 0;
  if (st == VX_OK && r.type == P9_Rread) {
    ra->len = r.count < FD_RA_MAX ? r.count : FD_RA_MAX;
    memcpy(ra->data, r.data.ptr, ra->len);
  }
  return true;
}

// Waits for the read-ahead's answer (ra_poll), its doorbell on fd_port under
// key: 0; -EAGAIN if it must not wait; -EINTR if a signal came (the call
// stays outstanding).
static long ra_wait_until(fd_readahead *ra, uint64_t key, bool tty, bool block, int64_t deadline) {
  while (!ra_poll(ra, tty)) {
    if (!block) return -EAGAIN;
    if (!ra->armed) ra->armed = p9_ring_arm(ra->k, fd_port, key);
    if (!ra->armed) continue; // a reply may be there already
    long w = fd_wait(deadline);
    if (w == -EINTR) return w;
    if (w == -ETIMEDOUT) return -EAGAIN; // SO_RCVTIMEO's, as Linux answers it
  }
  return 0;
}

static long ra_wait(fd_readahead *ra, uint64_t key, bool tty, bool block) {
  return ra_wait_until(ra, key, tty, block, VX_INFINITE);
}

// Before a fork, a spawn or an exec: a terminal's or the console's read kept
// outstanding, with nothing in hand yet, is let go with its connection, so
// the input it waits for goes to the child that reads next, not to this
// process's call, served first. (What it holds already stays this process's,
// as stdio's buffer does.) The next poll sends another.
static void fd_quiet_reads(void) {
  for (int i = 0; i < FD_MAX; i++) {
    ofd *o = &fd_ofds[i];
    if (o->kind == OFD_FREE || !o->ra || o->sock || o->ra->op != RA_READ) continue;
    if (ra_poll(o->ra, o->kind == OFD_FILE) && (o->ra->ready || o->ra->pos < o->ra->len)) continue;
    ra_free(o);
  }
}

static void ra_arm(ofd *o) {
  if (!o->ra->armed) o->ra->armed = p9_ring_arm(o->ra->k, fd_port, fd_key(o));
}

// A read through the read-ahead: what it holds, or what its outstanding read
// brings. A signal ends the wait (EINTR); the read stays outstanding.
static long ra_read(ofd *o, void *buf, uint32_t count, bool block) {
  fd_readahead *ra = o->ra;
  long w = ra_wait(ra, fd_key(o), o->kind == OFD_FILE, block);
  if (w < 0) return w;
  if (ra->status != VX_OK) {
    ra->ready = false;
    return vx_errno(ra->status); // ptyd's "interrupted" is EINTR
  }
  uint32_t n = ra->len - ra->pos;
  if (n > count) n = count;
  memcpy(buf, ra->data + ra->pos, n);
  ra->pos += n;
  if (ra->pos == ra->len) ra->ready = false; // all given: the next read sends another
  return n;
}

// --- Readiness ---

static short sock_ready(ofd *o, short events, bool arm); // socket.c

// What fd is ready for, of `events`; arming fd_port to hear of the rest.
static short fd_ready(int fd, short events, bool arm) {
  ofd *o = fd_get(fd);
  if (!o) return POLLNVAL;
  short out = POLLOUT | POLLWRNORM, in = POLLIN | POLLRDNORM, r = 0;
  switch (o->kind) {
  case OFD_PIPE_IN: {
    if (o->msg_pos < o->msg_len || o->ended) return (short)(events & in);
    vx_msg_size size;
    vx_status st = vx_channel_read(o->pipe, nullptr, 0, nullptr, 0, &size); // a look, taking nothing
    if (st == VX_ERR_TOO_SMALL) return (short)(events & in);
    if (st == VX_ERR_PEER_CLOSED) return (short)(POLLHUP | (events & in));
    if (arm && (events & in)) pipe_arm(o);
    return 0;
  }
  case OFD_PIPE_OUT: {
    vx_msg_size size;
    if (vx_channel_read(o->pipe, nullptr, 0, nullptr, 0, &size) == VX_ERR_PEER_CLOSED) return POLLERR;
    return (short)(events & out);
  }
  case OFD_CONSOLE:
  case OFD_FILE:
    if (o->sock) return sock_ready(o, events, arm);
    r = (short)(events & out);
    if (!(events & in)) return r;
    if (o->kind == OFD_FILE && !o->tty) return (short)(r | (events & in));
    if (!o->ra && !ra_start(o)) return (short)(r | (events & in)); // no read-ahead: a read just blocks
    if (ra_poll(o->ra, o->kind == OFD_FILE)) return (short)(r | (events & in));
    if (arm) ra_arm(o);
    return r;
  default: return POLLNVAL;
  }
}

// Every fd's readiness, arming what is not ready, until one is, the deadline
// passes, or a signal comes.
static long fd_poll(struct pollfd *fds, nfds_t n, int64_t deadline) {
  if (n > (nfds_t)FD_MAX * 4) return -EINVAL;
  for (;;) {
    long ready = 0;
    for (nfds_t i = 0; i < n; i++) {
      fds[i].revents = fds[i].fd < 0 ? 0 : fd_ready(fds[i].fd, fds[i].events, true);
      if (fds[i].revents) ready++;
    }
    if (ready || vx_clock_read() >= deadline) return ready;
    long w = fd_wait(deadline);
    if (w == -EINTR) return w;
  }
}

// --- The calls ---

// The deadline, kept when the call is made again after a signal; or -EINVAL
// for a timeout that is not one (a negative time, nanoseconds past 999999999).
static int64_t poll_deadline(const struct timespec *ts) {
  if (sig_restarting) return sig_call_deadline;
  sig_call_deadline = VX_INFINITE;
  if (ts && time_deadline(ts, false, &sig_call_deadline) < 0) return -EINVAL;
  return sig_call_deadline;
}

// ppoll and pselect6's mask: in place for the wait, and for the handlers a
// signal it lets through runs (as sigsuspend's); the old one after.
static long poll_masked(struct pollfd *fds, nfds_t n, const struct timespec *ts, const uint64_t *mask) {
  int64_t deadline = poll_deadline(ts);
  if (deadline == -EINVAL) return -EINVAL;
  if (!mask) return fd_poll(fds, n, deadline);
  uint64_t was = sig_mask;
  sig_mask = *mask & ~SIG_UNBLOCKABLE;
  long r = (sig_pending | be_me()->pending) & ~sig_mask ? -EINTR : fd_poll(fds, n, deadline);
  if (r == -EINTR) sig_deliver_pending();
  sig_mask = was;
  return r;
}

#ifdef SYS_poll // x86_64's; aarch64 has ppoll only
static long sys_poll(struct pollfd *fds, nfds_t n, int timeout_ms) {
  struct timespec ts = {timeout_ms / 1000, (long)(timeout_ms % 1000) * 1'000'000};
  return poll_masked(fds, n, timeout_ms < 0 ? nullptr : &ts, nullptr);
}
#endif

// select and pselect6: fd_sets as pollfds, and back.
static long sys_select(int nfds, fd_set *rd, fd_set *wr, fd_set *ex, const struct timespec *ts,
                       const uint64_t *mask) {
  if (nfds < 0 || nfds > FD_SETSIZE) return -EINVAL;
  if (nfds > FD_MAX) nfds = FD_MAX;
  struct pollfd fds[FD_MAX];
  nfds_t n = 0;
  for (int fd = 0; fd < nfds; fd++) {
    short events = 0;
    if (rd && FD_ISSET(fd, rd)) events |= POLLIN;
    if (wr && FD_ISSET(fd, wr)) events |= POLLOUT;
    if (ex && FD_ISSET(fd, ex)) events |= POLLPRI;
    if (!events) continue;
    if (!fd_valid(fd)) return -EBADF;
    fds[n++] = (struct pollfd){.fd = fd, .events = events};
  }
  long r = poll_masked(fds, n, ts, mask);
  if (r < 0) return r;
  for (int fd = 0; fd < nfds; fd++) { // only the first nfds bits: a caller's set may be no larger
    if (rd) FD_CLR(fd, rd);
    if (wr) FD_CLR(fd, wr);
    if (ex) FD_CLR(fd, ex);
  }
  // Each in the sets it was asked for: a hang-up or error is readable and
  // writable, as Linux has it; for a descriptor watched only for exceptions,
  // exceptional, so the wait it ended is not taken for a timeout.
  long count = 0;
  for (nfds_t i = 0; i < n; i++) {
    short got = fds[i].revents, asked = fds[i].events;
    bool in = (asked & POLLIN) && (got & (POLLIN | POLLHUP | POLLERR));
    bool out = (asked & POLLOUT) && (got & (POLLOUT | POLLERR));
    bool exc = (asked & POLLPRI) && (got & (POLLPRI | (asked == POLLPRI ? POLLHUP | POLLERR : 0)));
    if (in) FD_SET(fds[i].fd, rd), count++;
    if (out) FD_SET(fds[i].fd, wr), count++;
    if (exc) FD_SET(fds[i].fd, ex), count++;
  }
  return count;
}
