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
// A wait is one port_wait on fd_port, until something armed fires, the
// deadline passes, or a signal comes.

// --- Read-ahead ---

static fd_readahead *ra_new(void) {
  vx_handle vmo;
  uint64_t at = 0;
  uint64_t size = (sizeof(fd_readahead) + sizeof(p9_conn) + 4095) & ~4095ull;
  if (vx_vmo_create(size, 0, &vmo) != VX_OK) return nullptr;
  vx_status st = vx_as_map(vx_self, vmo, 0, size, VX_MAP_WRITE, &at);
  vx_handle_close(vmo);
  if (st != VX_OK) return nullptr;
  fd_readahead *ra = (fd_readahead *)at;
  ra->k = (p9_conn *)(at + ((sizeof(fd_readahead) + 15) & ~15ull));
  return ra;
}

static void ra_free(ofd *o) {
  fd_readahead *ra = o->ra;
  o->ra = nullptr;
  if (ra->k->end) p9_ring_disconnect(ra->k);
  vx_as_unmap(vx_self, (uint64_t)ra, (sizeof(fd_readahead) + sizeof(p9_conn) + 4095) & ~4095ull);
}

// A connection of the read-ahead's own, and a fid on it: for a terminal, the
// same open file, joined by token (posix); for the console, its cons file.
static bool ra_start(ofd *o) {
  fd_readahead *ra = ra_new();
  if (!ra) return false;
  vx_handle connector = VX_HANDLE_NONE;
  bool tty = o->kind == OFD_FILE;
  if (tty) {
    for (uint32_t i = 0; i < VX_NS_MAX_CONNS; i++)
      if (fd_ns.conns[i].client == o->f.c) connector = fd_ns.conns[i].connector;
  } else {
    connector = vx_console.connector;
  }
  uint8_t token[16];
  uint32_t root = 0;
  vx_status st = connector ? p9_ring_connect(connector, ra->k) : VX_ERR_NOT_FOUND;
  if (st == VX_OK && tty) {
    st = p9c_share(o->f.c, o->f.fid, 1, token);
    if (st == VX_OK) st = p9c_join(&ra->k->c, token, &ra->fid);
  } else if (st == VX_OK) {
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

// Sends the read if none is outstanding, and takes its reply if it has come.
// True once there is something to give: bytes, the end of the file, or an
// error.
static bool ra_poll(fd_readahead *ra, bool tty) {
  if (ra->ready || ra->pos < ra->len) return true;
  if (!ra->pending) {
    p9_msg t = {.type = P9_Tread, .fid = ra->fid, .offset = tty ? P9_OFFSET_CURRENT : 0, .count = FD_RA_MAX};
    vx_status st = p9_ring_send(ra->k, &t);
    if (st != VX_OK) {
      ra->ready = true;
      ra->status = st;
      return true;
    }
    ra->pending = true;
    ra->tag = t.tag;
  }
  p9_msg r;
  vx_status st = p9_ring_receive(ra->k, ra->tag, &r);
  if (st == VX_ERR_SHOULD_WAIT) return false;
  vx_ring_end_sleep(&ra->k->ring);
  ra->pending = false;
  ra->ready = true;
  ra->status = st;
  ra->pos = 0;
  ra->len = 0;
  if (st == VX_OK && r.type == P9_Rread) {
    ra->len = r.count < FD_RA_MAX ? r.count : FD_RA_MAX;
    memcpy(ra->data, r.data.ptr, ra->len);
  }
  return true;
}

static void ra_arm(ofd *o) {
  if (!o->ra->armed) o->ra->armed = p9_ring_arm(o->ra->k, fd_port, fd_key(o));
}

// A read through the read-ahead: what it holds, or what its outstanding read
// brings. A signal ends the wait (EINTR); the read stays outstanding.
static long ra_read(ofd *o, void *buf, uint32_t count, bool block) {
  fd_readahead *ra = o->ra;
  bool tty = o->kind == OFD_FILE;
  while (!ra_poll(ra, tty)) {
    if (!block) return -EAGAIN;
    ra_arm(o);
    if (!o->ra->armed) continue; // a reply may be there already
    long w = fd_wait(VX_INFINITE);
    if (w == -EINTR) return w;
  }
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

static int64_t poll_deadline(const struct timespec *ts) {
  static int64_t deadline; // kept when the call is made again after a signal
  if (sig_restarting) return deadline;
  deadline = VX_INFINITE;
  if (ts) time_deadline(ts, false, &deadline);
  return deadline;
}

// ppoll and pselect6's mask: in place for the wait, and for the handlers a
// signal it lets through runs (as sigsuspend's); the old one after.
static long poll_masked(struct pollfd *fds, nfds_t n, const struct timespec *ts, const uint64_t *mask) {
  int64_t deadline = poll_deadline(ts);
  if (!mask) return fd_poll(fds, n, deadline);
  uint64_t was = sig_mask;
  sig_mask = *mask & ~SIG_UNBLOCKABLE;
  long r = sig_pending & ~sig_mask ? -EINTR : fd_poll(fds, n, deadline);
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
  if (rd) FD_ZERO(rd);
  if (wr) FD_ZERO(wr);
  if (ex) FD_ZERO(ex);
  long count = 0;
  for (nfds_t i = 0; i < n; i++) {
    short got = fds[i].revents;
    if (rd && (got & (POLLIN | POLLHUP | POLLERR))) FD_SET(fds[i].fd, rd), count++;
    if (wr && (got & (POLLOUT | POLLERR))) FD_SET(fds[i].fd, wr), count++;
    if (ex && (got & POLLPRI)) FD_SET(fds[i].fd, ex), count++;
  }
  return count;
}
