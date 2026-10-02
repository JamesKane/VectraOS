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
// keeps the conversation alive meanwhile. Only IPv4 (AF_INET) for now; reads,
// accept and connect block, and poll's readiness and O_NONBLOCK on sockets
// come next (docs/milestones.md, step 4h2).

static constexpr uint32_t SOCK_HEADER = 52;       // netd's UDP header
static constexpr uint32_t SOCK_DGRAM_MAX = 65507; // a UDP payload, at most

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
static long sock_number(const vx_ns_file *ctl, char *num, uint32_t cap) {
  int64_t n = p9c_read(ctl->c, ctl->fid, 0, num, cap);
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
  long n = sock_number(&ctl, num, sizeof num);
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
  vx_ns_file ctl;
  vx_status st = sock_open(o, "listen", P9_ORDWR, &ctl); // waits for a call
  if (st != VX_OK) return sock_errno(st);
  char num[12] = {};
  long n = sock_number(&ctl, num, sizeof num);
  long nfd = n > 0 ? sock_install("tcp", num, (size_t)n, SOCK_STREAM, flags) : n;
  vx_ns_close(&ctl);
  if (nfd < 0 || !sa) return nfd;
  uint32_t addr = 0;
  uint16_t port = 0;
  sock_end(fd_get((int)nfd), "remote", &addr, &port);
  sock_give(sa, len, addr, port);
  return nfd;
}

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
  vx_status st = sock_ctl(o, msg, n);
  if (st == VX_ERR_BAD_STATE && o->sock == SOCK_STREAM) return -EISCONN; // connected elsewhere already
  if (st == VX_ERR_INVALID && o->sock == SOCK_DGRAM) return -EISCONN;
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

// A UDP datagram's buffer: netd's header, then the payload.
static uint8_t sock_dgram[SOCK_HEADER + SOCK_DGRAM_MAX];

static long sock_send(ofd *o, const void *buf, size_t n, const void *sa, socklen_t salen) {
  if (o->sock == SOCK_STREAM) return file_write(o, buf, n); // a destination is ignored, as Linux does
  uint32_t addr = 0;
  uint16_t port = 0;
  if (sa) {
    long r = sock_addr_in(sa, salen, &addr, &port);
    if (r < 0) return r;
    if (addr == INADDR_ANY) addr = INADDR_LOOPBACK;
  }
  if (n > SOCK_DGRAM_MAX) return -EMSGSIZE;
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
  int64_t w = p9c_write(o->f.c, o->f.fid, 0, h, (uint32_t)(SOCK_HEADER + n));
  if (w == VX_ERR_BAD_STATE) return sa ? -ENETUNREACH : -EDESTADDRREQ;
  return w < 0 ? sock_errno((vx_status)w) : (long)n;
}

static long sock_recv(ofd *o, void *buf, size_t n, int flags, void *sa, socklen_t *salen) {
  if (flags & ~(MSG_NOSIGNAL | MSG_WAITALL | MSG_TRUNC)) return -EOPNOTSUPP; // MSG_PEEK, MSG_DONTWAIT: 4h2
  uint32_t count = n < (1u << 20) ? (uint32_t)n : 1u << 20;
  if (o->sock == SOCK_STREAM) {
    size_t got = 0;
    do { // MSG_WAITALL: until it is all here, or the stream ends
      int64_t r = p9c_read(o->f.c, o->f.fid, 0, (uint8_t *)buf + got, count - (uint32_t)got);
      if (r < 0) return got ? (long)got : sock_errno((vx_status)r);
      if (r == 0) break;
      got += (size_t)r;
    } while ((flags & MSG_WAITALL) && got < count);
    if (sa && salen) {
      uint32_t addr = 0;
      uint16_t port = 0;
      sock_end(o, "remote", &addr, &port);
      sock_give(sa, salen, addr, port);
    }
    return (long)got;
  }
  int64_t r = p9c_read(o->f.c, o->f.fid, 0, sock_dgram, sizeof sock_dgram);
  if (r < 0) return sock_errno((vx_status)r);
  if (r < SOCK_HEADER) return -EIO;
  size_t len = (size_t)r - SOCK_HEADER, take = len < count ? len : count;
  memcpy(buf, sock_dgram + SOCK_HEADER, take);
  const uint8_t *h = sock_dgram;
  sock_give(sa, salen, (uint32_t)h[12] << 24 | (uint32_t)h[13] << 16 | (uint32_t)h[14] << 8 | h[15],
            (uint16_t)(h[48] << 8 | h[49]));
  return (long)(flags & MSG_TRUNC ? len : take); // a datagram's rest is lost, as on Linux
}

static long sock_sendto(int fd, const void *buf, size_t n, int flags, const void *sa, socklen_t salen) {
  ofd *o;
  long r = sock_get(fd, &o);
  if (r < 0) return r;
  if (flags & ~(MSG_NOSIGNAL | MSG_DONTROUTE)) return -EOPNOTSUPP;
  return sock_send(o, buf, n, sa, salen);
}

static long sock_recvfrom(int fd, void *buf, size_t n, int flags, void *sa, socklen_t *salen) {
  ofd *o;
  long r = sock_get(fd, &o);
  return r < 0 ? r : sock_recv(o, buf, n, flags, sa, salen);
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
  static uint8_t gather[SOCK_DGRAM_MAX];
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
  static uint8_t scatter[SOCK_DGRAM_MAX];
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
  vx_status st = sock_ctl(o, "hangup", 6); // a FIN once what was written has gone; reading goes on
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
  int v;
  if (level == SOL_SOCKET && name == SO_TYPE)
    v = o->sock;
  else if (level == SOL_SOCKET && name == SO_DOMAIN)
    v = AF_INET;
  else if (level == SOL_SOCKET && name == SO_PROTOCOL)
    v = o->sock == SOCK_STREAM ? IPPROTO_TCP : IPPROTO_UDP;
  else if (level == SOL_SOCKET && name == SO_ACCEPTCONN)
    v = o->sock_listening;
  else if (level == SOL_SOCKET && name == SO_ERROR) // a connect's result is its return, for now (4h2)
    v = 0;
  else if (level == SOL_SOCKET && (name == SO_RCVBUF || name == SO_SNDBUF))
    v = 65536;
  else
    return -ENOPROTOOPT;
  memcpy(val, &v, sizeof v);
  *len = sizeof v;
  return 0;
}
