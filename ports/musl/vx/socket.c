// socket.c: BSD sockets over /net (docs/01 §9), as Plan 9's APE has them.
// Part of backend.c.
//
// A socket is a conversation in netd's /net: socket() opens /net/tcp/clone
// (or udp), reads the conversation's number N from the ctl file it becomes,
// and opens /net/tcp/N/data, which the descriptor holds; the conversation
// lasts while that is open. Control goes through N/ctl, opened for each
// message as APE does: bind and listen are "announce PORT", connect is
// "connect ADDR!PORT" (held by netd until the connection is made or
// refused), shutdown is "hangup". accept opens N/listen, which waits for a
// call and becomes the new conversation's ctl. getsockname and getpeername
// read N/local and N/remote.
//
// A UDP conversation reads and writes after netd's 52-byte header ("headers"
// in its ctl, sent when the socket is made), so recvfrom learns the sender
// and sendto names the receiver; a header naming 0.0.0.0 sends to the
// connected peer.
//
// The descriptor is a file (OFD_FILE) with its socket type set, so fork and
// exec open N/data again by its path, as they do any file: the parent's open
// keeps the conversation alive meanwhile. Only IPv4 (AF_INET) for now.
//
// Waiting is poll's (poll.c): each socket has a connection of its own to
// netd, its read-ahead, attached at /net's root, which keeps one call
// outstanding: a read of N/data, whose reply reads take; for a listener, an
// open of N/listen, which accept takes; while connecting, connect's write of
// N/ctl. So a read, accept or connect that waits ends with EINTR when a
// signal comes, O_NONBLOCK and MSG_DONTWAIT give EAGAIN (connect,
// EINPROGRESS, its result later in SO_ERROR), and poll and select see a
// socket ready when the reply has come. netd holds a connection while it
// holds a call on it, so TCP data written without waiting goes on a second
// connection, written behind: the write takes what one Twrite carries and
// returns, and the socket is writable again once netd has taken all of it.
// A write to a connection that has closed raises SIGPIPE, unless
// MSG_NOSIGNAL.

static constexpr uint32_t SOCK_HEADER = 52; // netd's UDP header

// The socket a descriptor is: ENOTSOCK for any other file.
static long sock_get(int fd, ofd **out) {
  ofd *o = fd_get(fd);
  if (!o) return -EBADF;
  if (!o->sock) return -ENOTSOCK;
  *out = o;
  return 0;
}

// A status from netd as a socket call's errno.
static long sock_errno(vx_status st) {
  switch (st) {
  case VX_ERR_REFUSED: return -ECONNREFUSED;
  case VX_ERR_TIMED_OUT: return -ETIMEDOUT;
  case VX_ERR_EXISTS: return -EADDRINUSE;
  case VX_ERR_PEER_CLOSED: return -ECONNRESET;
  case VX_ERR_BAD_STATE: return -ENETDOWN; // no driver, or no address yet
  default: return vx_errno(st);
  }
}

// --- The socket's own connection to netd ---

// "tcp/N/name": a file of the conversation, from /net's root.
static size_t sock_rel(const ofd *o, const char *name, char *out) {
  size_t len = 0;
  for (size_t i = 5; i + 5 < o->path_len; i++) out[len++] = o->path[i]; // without "/net/" and "/data"
  out[len++] = '/';
  for (size_t i = 0; name[i]; i++) out[len++] = name[i];
  out[len] = 0;
  return len;
}

// A read-ahead connected to the server the socket's data file is on (netd),
// attached at its root.
static fd_readahead *sock_side(const ofd *o) {
  vx_handle connector = VX_HANDLE_NONE;
  for (uint32_t i = 0; i < VX_NS_MAX_CONNS; i++)
    if (fd_ns.conns[i].client == o->f.c) connector = fd_ns.conns[i].connector;
  fd_readahead *ra = connector ? ra_new() : nullptr;
  if (!ra) return nullptr;
  vx_status st = p9_ring_connect(connector, ra->k);
  if (st == VX_OK) st = p9c_attach(&ra->k->c, VX_STR(""), &ra->root);
  if (st != VX_OK) {
    ra_drop(ra);
    return nullptr;
  }
  return ra;
}

// A fid on the read-ahead's connection for the conversation's file name,
// opened (mode) unless it is the listen file, whose open is the call kept
// outstanding.
static vx_status sock_side_file(const ofd *o, fd_readahead *ra, const char *name, uint8_t mode) {
  char rel[VX_NS_MAX_PATH];
  size_t len = sock_rel(o, name, rel);
  vx_status st = p9c_walk(&ra->k->c, ra->root, (vx_str){rel, len}, &ra->fid);
  if (st == VX_OK && strcmp(name, "listen") != 0) st = p9c_open(&ra->k->c, ra->fid, mode);
  return st;
}

// poll.c's read-ahead for a socket: a read of N/data kept outstanding.
static bool sock_ra_start(ofd *o) {
  fd_readahead *ra = sock_side(o);
  if (!ra) return false;
  if (sock_side_file(o, ra, "data", P9_OREAD) != VX_OK) {
    ra_drop(ra);
    return false;
  }
  ra->op = RA_READ;
  o->ra = ra;
  return true;
}

// The socket's read-ahead, started for reading if it has none.
static fd_readahead *sock_reader(ofd *o) {
  if (o->ra && o->ra->op != RA_READ) return nullptr; // listening, or connecting
  if (!o->ra && !sock_ra_start(o)) return nullptr;
  return o->ra;
}

// A listener's read-ahead, with an open of N/listen outstanding: what accept
// takes, and poll waits for.
static fd_readahead *sock_listener(ofd *o) {
  if (o->ra && o->ra->op != RA_OPEN) ra_free(o);
  if (!o->ra) {
    fd_readahead *ra = sock_side(o);
    if (!ra) return nullptr;
    ra->op = RA_OPEN;
    o->ra = ra;
  }
  fd_readahead *ra = o->ra;
  if (!ra->pending && !ra->ready) { // idle: the next call
    if (sock_side_file(o, ra, "listen", 0) != VX_OK) {
      ra_free(o);
      return nullptr;
    }
    p9_msg t = {.type = P9_Topen, .fid = ra->fid, .mode = P9_ORDWR};
    ra_send(ra, &t);
  }
  return ra;
}

// The conversation's directory, "/net/tcp/N", from its data file's path.
static size_t sock_dir(const ofd *o, char *out) {
  size_t len = o->path_len - 5; // without "/data"
  memcpy(out, o->path, len);
  out[len] = 0;
  return len;
}

// Appends s (n bytes) to the path at p (len bytes), within VX_NS_MAX_PATH.
static size_t sock_cat(char *p, size_t len, const char *s, size_t n) {
  for (size_t i = 0; i < n && len < VX_NS_MAX_PATH - 1; i++) p[len++] = s[i];
  p[len] = 0;
  return len;
}

// Opens file `name` in the conversation's directory.
static vx_status sock_open(const ofd *o, const char *name, uint8_t mode, vx_ns_file *f) {
  char p[VX_NS_MAX_PATH];
  size_t len = sock_cat(p, sock_dir(o, p), "/", 1);
  len = sock_cat(p, len, name, strlen(name));
  return vx_ns_open(fd_namespace(), (vx_str){p, len}, mode, f);
}

// One control message, written to N/ctl.
static vx_status sock_ctl(const ofd *o, const char *msg, size_t len) {
  vx_ns_file ctl;
  vx_status st = sock_open(o, "ctl", P9_ORDWR, &ctl);
  if (st != VX_OK) return st;
  int64_t w = p9c_write(ctl.c, ctl.fid, 0, msg, (uint32_t)len);
  vx_ns_close(&ctl);
  return w < 0 ? (vx_status)w : VX_OK;
}

// A file of the conversation's that is text ("ADDR!PORT", N), read whole.
static long sock_text(const ofd *o, const char *name, char *buf, uint32_t cap) {
  vx_ns_file f;
  vx_status st = sock_open(o, name, P9_OREAD, &f);
  if (st != VX_OK) return vx_errno(st);
  int64_t n = p9c_read(f.c, f.fid, 0, buf, cap - 1);
  vx_ns_close(&f);
  if (n < 0) return vx_errno((vx_status)n);
  while (n && (buf[n - 1] == '\n' || buf[n - 1] == ' ')) n--;
  buf[n] = 0;
  return n;
}

// "a.b.c.d!port" from an address and port in host order.
static size_t sock_format(char *out, uint32_t addr, uint16_t port) {
  size_t len = 0;
  for (int i = 0; i < 5; i++) {
    uint32_t v = i < 4 ? (addr >> (24 - 8 * i)) & 0xff : port;
    char digits[6];
    size_t d = 0;
    do digits[d++] = (char)('0' + v % 10);
    while (v /= 10);
    while (d) out[len++] = digits[--d];
    if (i < 3) out[len++] = '.';
    if (i == 3) out[len++] = '!';
  }
  return len;
}

// "a.b.c.d!port" (or "a.b.c.d", port 0) into an address and port; false if
// it is not one.
static bool sock_parse(const char *s, uint32_t *addr, uint16_t *port) {
  uint32_t a = 0, p = 0;
  for (int i = 0; i < 4; i++) {
    uint32_t v = 0;
    int d = 0;
    while (*s >= '0' && *s <= '9' && d < 4) v = v * 10 + (uint32_t)(*s++ - '0'), d++;
    if (!d || v > 255) return false;
    a = a << 8 | v;
    if (i < 3 && *s++ != '.') return false;
  }
  if (*s == '!') {
    s++;
    int d = 0;
    while (*s >= '0' && *s <= '9' && d < 6) p = p * 10 + (uint32_t)(*s++ - '0'), d++;
    if (!d || p > 65535) return false;
  }
  if (*s) return false;
  *addr = a, *port = (uint16_t)p;
  return true;
}

// A sockaddr_in from the caller: its address and port in host order.
static long sock_addr_in(const void *sa, socklen_t len, uint32_t *addr, uint16_t *port) {
  if (!sa || len < sizeof(struct sockaddr_in)) return -EINVAL;
  const struct sockaddr_in *in = sa;
  if (in->sin_family != AF_INET) return -EAFNOSUPPORT;
  *addr = __builtin_bswap32(in->sin_addr.s_addr);
  *port = __builtin_bswap16(in->sin_port);
  return 0;
}

// Gives an address to the caller, cut to the room it has, as Linux does;
// *len becomes the whole address's size.
static void sock_give(void *sa, socklen_t *len, uint32_t addr, uint16_t port) {
  if (!sa || !len) return;
  struct sockaddr_in in = {.sin_family = AF_INET,
                           .sin_port = __builtin_bswap16(port),
                           .sin_addr = {.s_addr = __builtin_bswap32(addr)}};
  memcpy(sa, &in, *len < sizeof in ? *len : sizeof in);
  *len = sizeof in;
}

// N/local or N/remote, as an address and port.
static long sock_end(const ofd *o, const char *name, uint32_t *addr, uint16_t *port) {
  char text[64] = {};
  long n = sock_text(o, name, text, sizeof text);
  if (n < 0) return n;
  if (!sock_parse(text, addr, port)) return -EIO;
  return 0;
}

// A descriptor for conversation N of proto, its data file opened.
static long sock_install(const char *proto, const char *num, size_t num_len, int type, int flags) {
  char p[VX_NS_MAX_PATH];
  size_t len = sock_cat(p, 0, "/net/", 5);
  len = sock_cat(p, len, proto, strlen(proto));
  len = sock_cat(p, len, "/", 1);
  len = sock_cat(p, len, num, num_len);
  len = sock_cat(p, len, "/data", 5);
  vx_ns_file f;
  vx_status st = vx_ns_open(fd_namespace(), (vx_str){p, len}, P9_ORDWR, &f);
  if (st != VX_OK) return sock_errno(st);
  ofd *o = ofd_new(OFD_FILE, O_RDWR | (flags & SOCK_NONBLOCK ? O_NONBLOCK : 0));
  if (!o) {
    vx_ns_close(&f);
    return -ENFILE;
  }
  o->f = f;
  o->sock = (uint8_t)type;
  o->path_len = sock_cat(o->path, 0, p, len);
  return fd_install(o, 0, flags & SOCK_CLOEXEC);
}

// The conversation number a ctl file (open) reads as.
static long sock_number(p9_client *c, uint32_t fid, char *num, uint32_t cap) {
  int64_t n = p9c_read(c, fid, 0, num, cap);
  if (n <= 0) return n < 0 ? sock_errno((vx_status)n) : -EIO;
  while (n && (num[n - 1] == '\n' || num[n - 1] == ' ')) n--;
  for (int64_t i = 0; i < n; i++)
    if (num[i] < '0' || num[i] > '9') return -EIO;
  return n ? n : -EIO;
}

static long sock_socket(int domain, int type, int protocol) {
  int kind = type & 0xf, flags = type & ~0xf;
  if (domain != AF_INET) return -EAFNOSUPPORT;
  if (flags & ~(SOCK_NONBLOCK | SOCK_CLOEXEC)) return -EINVAL;
  const char *proto;
  if (kind == SOCK_STREAM && (protocol == 0 || protocol == IPPROTO_TCP))
    proto = "tcp";
  else if (kind == SOCK_DGRAM && (protocol == 0 || protocol == IPPROTO_UDP))
    proto = "udp";
  else
    return -EPROTONOSUPPORT;
  char clone[VX_NS_MAX_PATH];
  size_t len = sock_cat(clone, 0, "/net/", 5);
  len = sock_cat(clone, len, proto, strlen(proto));
  len = sock_cat(clone, len, "/clone", 6);
  vx_ns_file ctl;
  vx_status st = vx_ns_open(fd_namespace(), (vx_str){clone, len}, P9_ORDWR, &ctl);
  if (st == VX_ERR_NOT_FOUND) return -EAFNOSUPPORT; // no /net here
  if (st != VX_OK) return sock_errno(st);
  char num[12] = {};
  long n = sock_number(ctl.c, ctl.fid, num, sizeof num);
  if (n > 0 && kind == SOCK_DGRAM) { // datagrams after their header, both ways
    int64_t w = p9c_write(ctl.c, ctl.fid, 0, "headers", 7);
    if (w < 0) n = sock_errno((vx_status)w);
  }
  long fd = n > 0 ? sock_install(proto, num, (size_t)n, kind, flags) : n;
  vx_ns_close(&ctl); // the data file keeps the conversation
  return fd;
}

// Announces the port (0: a free one), once. TCP's listen and UDP's bind.
static long sock_announce(ofd *o, uint16_t port) {
  char msg[24] = "announce ";
  size_t len = 9;
  char digits[6];
  size_t d = 0;
  uint32_t v = port;
  do digits[d++] = (char)('0' + v % 10);
  while (v /= 10);
  while (d) msg[len++] = digits[--d];
  vx_status st = sock_ctl(o, msg, len);
  if (st == VX_ERR_BAD_STATE) return -EINVAL; // announced already
  if (st != VX_OK) return sock_errno(st);
  o->sock_bound = true;
  return 0;
}

static long sock_bind(int fd, const void *sa, socklen_t len) {
  ofd *o;
  long r = sock_get(fd, &o);
  uint32_t addr;
  uint16_t port;
  if (r == 0) r = sock_addr_in(sa, len, &addr, &port);
  if (r < 0) return r;
  if (o->sock_bound || o->sock_port) return -EINVAL;
  if (addr != INADDR_ANY && addr >> 24 != 127) { // only the interface's own, or loopback
    uint32_t mine;
    uint16_t unused;
    if (sock_end(o, "local", &mine, &unused) < 0 || mine != addr) return -EADDRNOTAVAIL;
  }
  if (o->sock == SOCK_DGRAM) return sock_announce(o, port);
  // TCP: the port is announced by listen, as Plan 9 does; netd has no way to
  // hold one for a connection made from it, so connect does not use it.
  o->sock_port = port;
  return 0;
}

static long sock_listen(int fd, int backlog) {
  (void)backlog; // netd's own
  ofd *o;
  long r = sock_get(fd, &o);
  if (r < 0) return r;
  if (o->sock != SOCK_STREAM) return -EOPNOTSUPP;
  if (o->sock_listening) return 0;
  r = sock_announce(o, o->sock_port);
  if (r == 0) o->sock_listening = true;
  return r;
}

static long sock_accept(int fd, void *sa, socklen_t *len, int flags) {
  ofd *o;
  long r = sock_get(fd, &o);
  if (r < 0) return r;
  if (flags & ~(SOCK_NONBLOCK | SOCK_CLOEXEC)) return -EINVAL;
  if (o->sock != SOCK_STREAM) return -EOPNOTSUPP;
  if (!o->sock_listening) return -EINVAL;
  fd_readahead *ra = sock_listener(o); // an open of N/listen, outstanding: it waits for a call
  if (!ra) return -ENOBUFS;
  r = ra_wait(ra, fd_key(o), false, !(o->flags & O_NONBLOCK));
  if (r < 0) return r;
  ra->ready = false; // taken: the next accept, or poll, sends another
  p9_client *c = &ra->k->c;
  if (ra->status != VX_OK) {
    p9c_clunk(c, ra->fid);
    return sock_errno(ra->status);
  }
  char num[12] = {}; // the fid is the new conversation's ctl now
  long n = sock_number(c, ra->fid, num, sizeof num);
  long nfd = n > 0 ? sock_install("tcp", num, (size_t)n, SOCK_STREAM, flags) : n;
  p9c_clunk(c, ra->fid); // once its data file is open, which keeps the conversation
  if (nfd < 0 || !sa) return nfd;
  uint32_t addr = 0;
  uint16_t port = 0;
  sock_end(fd_get((int)nfd), "remote", &addr, &port);
  sock_give(sa, len, addr, port);
  return nfd;
}

static long sock_connect_tcp(ofd *o, const char *msg, size_t len); // below, with waiting

static long sock_connect(int fd, const void *sa, socklen_t len) {
  ofd *o;
  long r = sock_get(fd, &o);
  uint32_t addr;
  uint16_t port;
  if (r == 0) r = sock_addr_in(sa, len, &addr, &port);
  if (r < 0) return r;
  if (o->sock_listening) return -EISCONN;
  if (addr == INADDR_ANY) addr = INADDR_LOOPBACK; // as Linux takes it
  if (o->sock == SOCK_STREAM && !port) return -ECONNREFUSED;
  char msg[40] = "connect ";
  size_t n = 8 + sock_format(msg + 8, addr, port);
  if (o->sock == SOCK_STREAM) return sock_connect_tcp(o, msg, n);
  vx_status st = sock_ctl(o, msg, n); // UDP's: netd never holds it
  if (st == VX_ERR_INVALID) return -EISCONN;
  if (st != VX_OK) return sock_errno(st);
  o->sock_bound = true;
  return 0;
}

static long sock_name(int fd, void *sa, socklen_t *len, bool peer) {
  ofd *o;
  long r = sock_get(fd, &o);
  if (r < 0) return r;
  if (!sa || !len) return -EFAULT;
  uint32_t addr = 0;
  uint16_t port = 0;
  r = sock_end(o, peer ? "remote" : "local", &addr, &port);
  if (r < 0) return r;
  if (peer && !addr) return -ENOTCONN;
  if (!peer && !port) { // not announced: what bind asked for, from no address
    port = o->sock_port;
    addr = 0;
  }
  sock_give(sa, len, addr, port);
  return 0;
}

// --- Connecting, without waiting ---

// Finishes a connect whose ctl write has its reply: 0, or why it failed.
static long sock_connect_done(ofd *o) {
  vx_status st = o->ra->status;
  ra_free(o); // a read-ahead for the data comes when it is wanted
  o->sock_connecting = false;
  if (st == VX_OK) o->sock_bound = true;
  if (st == VX_ERR_BAD_STATE) return -EISCONN; // connected elsewhere already
  return st == VX_OK ? 0 : sock_errno(st);
}

// Waits for a connect under way to finish (unless it must not wait): 0, or
// -EAGAIN, -EINTR, or why it failed (also kept for SO_ERROR).
static long sock_connected(ofd *o, bool block) {
  if (!o->sock_connecting) return 0;
  long w = ra_wait(o->ra, fd_key(o), false, block);
  if (w < 0) return w;
  long r = sock_connect_done(o);
  o->sock_error = (int)-r;
  return r;
}

// TCP's connect: the ctl write kept outstanding on the socket's connection,
// so a signal or O_NONBLOCK need not wait for it (EINTR, EINPROGRESS).
static long sock_connect_tcp(ofd *o, const char *msg, size_t len) {
  bool block = !(o->flags & O_NONBLOCK);
  if (o->sock_connecting) { // made again: after EINTR, or by a program asking how it went
    if (!block && !ra_poll(o->ra, false)) return -EALREADY;
    long r = sock_connected(o, block);
    if (r != -EINTR) o->sock_error = 0; // told here, not in SO_ERROR too
    return r == 0 && !block ? -EISCONN : r;
  }
  if (o->ra) ra_free(o); // a read kept outstanding before connecting
  fd_readahead *ra = sock_side(o);
  if (!ra) return -ENOBUFS;
  if (sock_side_file(o, ra, "ctl", P9_ORDWR) != VX_OK) {
    ra_drop(ra);
    return -ENOBUFS;
  }
  ra->op = RA_WRITE;
  memcpy(ra->data, msg, len);
  ra->len = (uint32_t)len;
  ra->pos = 0;
  o->ra = ra;
  ra_send_write(ra);
  o->sock_connecting = true;
  o->sock_error = 0;
  if (!block) return -EINPROGRESS;
  long r = sock_connected(o, true);
  if (r != -EINTR) o->sock_error = 0;
  return r;
}

// --- Data ---

// A UDP datagram's buffer: netd's header, then the payload. One Twrite (or
// Rread) carries it, so a datagram is at most FD_RA_MAX bytes with its header.
static uint8_t sock_dgram[FD_RA_MAX];

// A write's failure: a connection that has closed raises SIGPIPE, unless
// MSG_NOSIGNAL, and is EPIPE.
static long sock_write_errno(vx_status st, int flags) {
  if (st != VX_ERR_PEER_CLOSED) return sock_errno(st);
  if (!(flags & MSG_NOSIGNAL)) sig_raise_self(SIGPIPE);
  return -EPIPE;
}

// TCP: what was written behind goes first; then the data, waiting until
// netd has taken it all, or (without waiting) behind, as much as one Twrite
// carries.
static long sock_send_stream(ofd *o, const uint8_t *buf, size_t n, int flags) {
  bool block = !(o->flags & O_NONBLOCK) && !(flags & MSG_DONTWAIT);
  if (o->sock_shut) return sock_write_errno(VX_ERR_PEER_CLOSED, flags);
  long r = sock_connected(o, block);
  if (r < 0) return r == -EINTR || r == -EAGAIN ? r : sock_write_errno(VX_ERR_PEER_CLOSED, flags);
  if (o->wb) {
    r = ra_wait(o->wb, fd_wb_key(o), false, block);
    if (r < 0) return r;
    if (o->wb->status != VX_OK) return sock_write_errno(o->wb->status, flags); // and stays so
  }
  if (block) {
    size_t done = 0;
    while (done < n) {
      uint32_t k = n - done < (1u << 20) ? (uint32_t)(n - done) : 1u << 20;
      int64_t w = p9c_write(o->f.c, o->f.fid, 0, buf + done, k);
      if (w <= 0 && done) return (long)done;
      if (w <= 0) return w ? sock_write_errno((vx_status)w, flags) : -EIO;
      done += (size_t)w;
    }
    return (long)n;
  }
  if (!o->wb) {
    fd_readahead *wb = sock_side(o);
    if (wb && sock_side_file(o, wb, "data", P9_OWRITE) != VX_OK) {
      ra_drop(wb);
      wb = nullptr;
    }
    if (!wb) return -ENOBUFS;
    wb->op = RA_WRITE;
    o->wb = wb;
  }
  uint32_t k = n < FD_RA_MAX ? (uint32_t)n : FD_RA_MAX;
  memcpy(o->wb->data, buf, k);
  o->wb->len = k;
  o->wb->pos = 0;
  ra_send_write(o->wb);
  return k;
}

static long sock_send(ofd *o, const void *buf, size_t n, int flags, const void *sa, socklen_t salen) {
  if (o->sock == SOCK_STREAM)
    return sock_send_stream(o, buf, n, flags); // a destination is ignored, as Linux does
  uint32_t addr = 0;
  uint16_t port = 0;
  if (sa) {
    long r = sock_addr_in(sa, salen, &addr, &port);
    if (r < 0) return r;
    if (addr == INADDR_ANY) addr = INADDR_LOOPBACK;
  }
  if (n > FD_RA_MAX - SOCK_HEADER) return -EMSGSIZE;
  if (!o->sock_bound) { // from a free port, as an unbound socket sends on Linux
    uint32_t a;
    uint16_t p = 0;
    if (sock_end(o, "local", &a, &p) < 0 || !p) {
      long r = sock_announce(o, 0);
      if (r < 0) return r;
    }
    o->sock_bound = true;
  }
  uint8_t *h = sock_dgram;
  memset(h, 0, SOCK_HEADER);
  h[10] = h[11] = 0xff; // IPv4, mapped into IPv6
  h[12] = (uint8_t)(addr >> 24), h[13] = (uint8_t)(addr >> 16), h[14] = (uint8_t)(addr >> 8);
  h[15] = (uint8_t)addr;
  h[48] = (uint8_t)(port >> 8), h[49] = (uint8_t)port;
  memcpy(h + SOCK_HEADER, buf, n);
  int64_t w = p9c_write(o->f.c, o->f.fid, 0, h, (uint32_t)(SOCK_HEADER + n)); // netd never holds a datagram
  if (w == VX_ERR_BAD_STATE) return sa ? -ENETUNREACH : -EDESTADDRREQ;
  return w < 0 ? sock_errno((vx_status)w) : (long)n;
}

// A datagram's sender, from netd's header.
static void sock_give_sender(const uint8_t *h, void *sa, socklen_t *salen) {
  sock_give(sa, salen, (uint32_t)h[12] << 24 | (uint32_t)h[13] << 16 | (uint32_t)h[14] << 8 | h[15],
            (uint16_t)(h[48] << 8 | h[49]));
}

static long sock_recv(ofd *o, void *buf, size_t n, int flags, void *sa, socklen_t *salen) {
  if (flags & ~(MSG_NOSIGNAL | MSG_WAITALL | MSG_TRUNC | MSG_PEEK | MSG_DONTWAIT)) return -EOPNOTSUPP;
  bool block = !(o->flags & O_NONBLOCK) && !(flags & MSG_DONTWAIT);
  if (o->sock_listening) return -ENOTCONN;
  long r = sock_connected(o, block);
  if (r == -EINTR || r == -EAGAIN) return r;
  fd_readahead *ra = sock_reader(o);
  if (!ra) return -ENOBUFS;
  uint32_t count = n < (1u << 20) ? (uint32_t)n : 1u << 20;
  if (o->sock == SOCK_DGRAM) {
    long w = ra_wait(ra, fd_key(o), false, block);
    if (w < 0) return w;
    vx_status st = ra->status;
    if (st != VX_OK || ra->len < SOCK_HEADER) {
      ra->ready = false;
      return st != VX_OK ? sock_errno(st) : -EIO;
    }
    size_t len = ra->len - SOCK_HEADER, take = len < count ? len : count;
    memcpy(buf, ra->data + SOCK_HEADER, take);
    sock_give_sender(ra->data, sa, salen);
    if (!(flags & MSG_PEEK)) ra->ready = false, ra->pos = ra->len; // the next read sends another
    return (long)(flags & MSG_TRUNC ? len : take);                 // a datagram's rest is lost, as on Linux
  }
  size_t got = 0;
  for (;;) { // once; with MSG_WAITALL, until all of it is here or the stream ends
    long w = ra_wait(ra, fd_key(o), false, block);
    if (w < 0) return got ? (long)got : w;
    if (ra->status != VX_OK) {
      vx_status st = ra->status;
      ra->ready = false;
      return got ? (long)got : sock_errno(st);
    }
    uint32_t avail = ra->len - ra->pos, k = avail < count - got ? avail : count - (uint32_t)got;
    memcpy((uint8_t *)buf + got, ra->data + ra->pos, k);
    got += k;
    if (!(flags & MSG_PEEK)) {
      ra->pos += k;
      if (ra->pos == ra->len) ra->ready = false; // all given: the next read sends another
    }
    if (!avail || got == count || !(flags & MSG_WAITALL) || (flags & MSG_PEEK)) break; // !avail: the end
  }
  if (sa && salen) {
    uint32_t addr = 0;
    uint16_t port = 0;
    sock_end(o, "remote", &addr, &port);
    sock_give(sa, salen, addr, port);
  }
  return (long)got;
}

static long sock_sendto(int fd, const void *buf, size_t n, int flags, const void *sa, socklen_t salen) {
  ofd *o;
  long r = sock_get(fd, &o);
  if (r < 0) return r;
  if (flags & ~(MSG_NOSIGNAL | MSG_DONTROUTE | MSG_DONTWAIT)) return -EOPNOTSUPP;
  return sock_send(o, buf, n, flags, sa, salen);
}

static long sock_recvfrom(int fd, void *buf, size_t n, int flags, void *sa, socklen_t *salen) {
  ofd *o;
  long r = sock_get(fd, &o);
  return r < 0 ? r : sock_recv(o, buf, n, flags, sa, salen);
}

// --- Readiness (poll.c) ---

// Whether the read-ahead has its answer; if not, arming fd_port (under key)
// to hear when it does.
static bool sock_answered(fd_readahead *ra, uint64_t key, bool arm) {
  for (int tries = 0; tries < 2; tries++) {
    if (ra_poll(ra, false)) return true;
    if (!arm || ra->armed) return false;
    ra->armed = p9_ring_arm(ra->k, fd_port, key);
    if (ra->armed) return false;
  } // not armed: a reply may have come meanwhile
  return ra_poll(ra, false);
}

static short sock_ready(ofd *o, short events, bool arm) {
  short out = POLLOUT | POLLWRNORM, in = POLLIN | POLLRDNORM, r = 0;
  if (o->sock_listening) { // a call to take
    if (!(events & in)) return 0;
    fd_readahead *ra = sock_listener(o);
    return !ra || sock_answered(ra, fd_key(o), arm) ? (short)(events & in)
                                                    : 0; // no listener: accept just blocks
  }
  if (o->sock_connecting) {
    if (!sock_answered(o->ra, fd_key(o), arm)) return 0;
    o->sock_error = (int)-sock_connect_done(o);
  }
  if (o->sock_error) r |= POLLERR | POLLHUP;
  if (events & out) {
    if (!o->wb || sock_answered(o->wb, fd_wb_key(o), arm)) r = (short)(r | (events & out));
  }
  if (events & in) {
    fd_readahead *ra = sock_reader(o);
    if (!ra || sock_answered(ra, fd_key(o), arm))
      r = (short)(r | (events & in)); // no read-ahead: a read blocks
  }
  return r;
}

// sendmsg and recvmsg: the iovecs gathered into one datagram (or written in
// turn, on a stream), with no ancillary data.
static long sock_sendmsg(int fd, const struct msghdr *m, int flags) {
  ofd *o;
  long r = sock_get(fd, &o);
  if (r < 0) return r;
  if (m->msg_controllen) return -EOPNOTSUPP;
  size_t total = 0;
  for (size_t i = 0; i < (size_t)m->msg_iovlen; i++) total += m->msg_iov[i].iov_len;
  if (o->sock == SOCK_STREAM) {
    size_t done = 0;
    for (size_t i = 0; i < (size_t)m->msg_iovlen; i++) {
      long w = sock_sendto(fd, m->msg_iov[i].iov_base, m->msg_iov[i].iov_len, flags, nullptr, 0);
      if (w < 0) return done ? (long)done : w;
      done += (size_t)w;
    }
    return (long)done;
  }
  static uint8_t gather[FD_RA_MAX];
  if (total > sizeof gather) return -EMSGSIZE;
  size_t at = 0;
  for (size_t i = 0; i < (size_t)m->msg_iovlen; i++) {
    memcpy(gather + at, m->msg_iov[i].iov_base, m->msg_iov[i].iov_len);
    at += m->msg_iov[i].iov_len;
  }
  return sock_sendto(fd, gather, total, flags, m->msg_name, m->msg_namelen);
}

static long sock_recvmsg(int fd, struct msghdr *m, int flags) {
  ofd *o;
  long r = sock_get(fd, &o);
  if (r < 0) return r;
  static uint8_t scatter[FD_RA_MAX];
  size_t total = 0;
  for (size_t i = 0; i < (size_t)m->msg_iovlen; i++) total += m->msg_iov[i].iov_len;
  if (total > sizeof scatter) total = sizeof scatter;
  socklen_t namelen = m->msg_namelen;
  r = sock_recv(o, scatter, total, flags & ~MSG_TRUNC, m->msg_name, m->msg_name ? &namelen : nullptr);
  if (r < 0) return r;
  m->msg_namelen = m->msg_name ? namelen : 0;
  m->msg_controllen = 0;
  m->msg_flags = 0;
  size_t at = 0;
  for (size_t i = 0; i < (size_t)m->msg_iovlen && at < (size_t)r; i++) {
    size_t k = (size_t)r - at < m->msg_iov[i].iov_len ? (size_t)r - at : m->msg_iov[i].iov_len;
    memcpy(m->msg_iov[i].iov_base, scatter + at, k);
    at += k;
  }
  return r;
}

static long sock_shutdown(int fd, int how) {
  ofd *o;
  long r = sock_get(fd, &o);
  if (r < 0) return r;
  if (how != SHUT_RD && how != SHUT_WR && how != SHUT_RDWR) return -EINVAL;
  if (how == SHUT_RD || o->sock != SOCK_STREAM) return 0;
  if (o->wb) ra_wait(o->wb, fd_wb_key(o), false, true); // what was written behind goes before the FIN
  vx_status st = sock_ctl(o, "hangup", 6); // a FIN once what was written has gone; reading goes on
  if (st == VX_OK) o->sock_shut = true;
  return st == VX_OK ? 0 : sock_errno(st);
}

// The options programs set that netd has no use for are taken and ignored;
// the rest are ENOPROTOOPT.
static long sock_setsockopt(int fd, int level, int name, const void *val, socklen_t len) {
  ofd *o;
  long r = sock_get(fd, &o);
  if (r < 0) return r;
  if (!val && len) return -EFAULT;
  if (level == SOL_SOCKET && (name == SO_REUSEADDR || name == SO_REUSEPORT || name == SO_KEEPALIVE ||
                              name == SO_RCVBUF || name == SO_SNDBUF || name == SO_LINGER ||
                              name == SO_BROADCAST || name == SO_RCVTIMEO || name == SO_SNDTIMEO))
    return 0;
  if (level == IPPROTO_TCP &&
      (name == TCP_NODELAY || name == TCP_KEEPIDLE || name == TCP_KEEPINTVL || name == TCP_KEEPCNT))
    return 0;
  return -ENOPROTOOPT;
}

static long sock_getsockopt(int fd, int level, int name, void *val, socklen_t *len) {
  ofd *o;
  long r = sock_get(fd, &o);
  if (r < 0) return r;
  if (!val || !len || *len < sizeof(int)) return -EINVAL;
  if (level != SOL_SOCKET) return -ENOPROTOOPT;
  int v;
  switch (name) {
  case SO_TYPE: v = o->sock; break;
  case SO_DOMAIN: v = AF_INET; break;
  case SO_PROTOCOL: v = o->sock == SOCK_STREAM ? IPPROTO_TCP : IPPROTO_UDP; break;
  case SO_ACCEPTCONN: v = o->sock_listening; break;
  case SO_ERROR: // a connect that did not wait: how it went, once
    if (o->sock_connecting && ra_poll(o->ra, false)) o->sock_error = (int)-sock_connect_done(o);
    v = o->sock_error;
    o->sock_error = 0;
    break;
  case SO_RCVBUF:
  case SO_SNDBUF: v = 65536; break;
  default: return -ENOPROTOOPT;
  }
  memcpy(val, &v, sizeof v);
  *len = sizeof v;
  return 0;
}
