// relay: one 9P session to a server over TCP, shared by every client that
// connects (M6 step 6d4d2b), as 9front's mount driver shares one mounted
// channel among all its mounts (devmnt.c): the session is versioned once;
// each client attaches as itself; fids and tags are the relay's own on the
// wire, as they are the kernel's there, so clients number theirs as they
// like.
//
//   relay ADDRESS        (tcp!HOST!PORT, or 9p://HOST:PORT; given as arg=)
//
// It dials ADDRESS through its namespace's /net (lib/vx-ns/dial.c) and
// serves its `listen` channel as a ring server whose requests it forwards
// rather than serves (p9_ring_server's raw hook): each is decoded, its fids
// and tag swapped for the relay's, and written to the stream; a reader
// thread files each reply under its tag and wakes the server, which hands
// it back to its client with the client's tag. A client's Tversion is
// answered here, with the remote session's dialect (9P2000, say) and the
// smaller msize; it starts that client's session again, clunking its fids.
// Tflush goes on to the server, and the flushed request's reply, if it
// comes first, is dropped. A client that goes has its fids clunked.
//
// It runs while anything can reach it: its listen channel's peer (a post,
// a connector held by whoever spawned it), or a client connected already.
// If the server hangs up, the relay exits, and its clients' calls fail.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/spawn.c"
#include "../../lib/vx-9p/ring_server.c"

static constexpr uint32_t RELAY_MSIZE = P9_RING_MSIZE;
static constexpr uint32_t RELAY_CALLS =
    64; // requests in flight on the stream; a call's index is its tag there
static constexpr uint32_t RELAY_FIDS = P9_RING_MAX_CONNS * P9_MAX_FIDS; // the relay's fids, 1 to this

// A request on the stream, by its tag there.
typedef struct relay_call {
  bool used;
  bool orphan;   // its client has gone or flushed it: its reply is dropped
  bool replied;  // the reader has filed its reply (under relay_lock)
  bool flushing; // a Tflush of it is out: its tag stays taken until Rflush, answered or not
  uint8_t conn, type;
  uint16_t tag;    // the client's
  uint16_t nwname; // Twalk's: only a walk of every name makes newfid
  uint32_t newfid; // the client's fid that it makes, or P9_NOFID
  uint32_t rnew;   // and the relay's, kept until the reply says whether it was made
  uint32_t rgone;  // the relay's fid it ends (Tclunk, Tremove): free once answered
  int32_t flushes; // a Tflush's: the call it flushes, or -1
  uint32_t len;
  uint8_t reply[RELAY_MSIZE];
} relay_call;

typedef struct relay_fid {
  uint32_t local, remote; // remote 0: a free entry
} relay_fid;

static relay_call calls[RELAY_CALLS];
static relay_fid fids[P9_RING_MAX_CONNS][P9_MAX_FIDS];
static bool remote_used[RELAY_FIDS + 1];
static uint32_t remote_next = 1;
static uint32_t doomed[RELAY_FIDS], ndoomed; // the relay's fids to clunk once a call is free
static vx_mutex relay_lock;                  // the calls' replies, between the reader and the server
static _Atomic bool hungup;

static p9_ring_server server;
static vx_ns ns;
// The conversation's data file, open twice: the server's writes, and the
// reader's reads on a fid of their own, since a file server keeps the
// requests on one fid in order, and a read waiting for the stream would
// hold up every write behind it.
static vx_ns_file stream, incoming;
static p9_dialect dialect;
static uint32_t msize;
static vx_str address;

static uint32_t le32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

static void wake(void) { vx_port_post(server.port, &(vx_packet){.key = P9_KEY_USER}); }

// --- The relay's fids ---

static uint32_t remote_take(void) {
  for (uint32_t n = 0; n < RELAY_FIDS; n++) {
    uint32_t f = remote_next;
    remote_next = remote_next % RELAY_FIDS + 1;
    if (!remote_used[f]) {
      remote_used[f] = true;
      return f;
    }
  }
  return P9_NOFID;
}

static void remote_give(uint32_t f) {
  if (f && f <= RELAY_FIDS) remote_used[f] = false;
}

static relay_fid *fid_find(uint32_t conn, uint32_t local) {
  for (uint32_t i = 0; i < P9_MAX_FIDS; i++)
    if (fids[conn][i].remote && fids[conn][i].local == local) return &fids[conn][i];
  return nullptr;
}

static bool fid_put(uint32_t conn, uint32_t local, uint32_t remote) {
  for (uint32_t i = 0; i < P9_MAX_FIDS; i++)
    if (!fids[conn][i].remote) {
      fids[conn][i] = (relay_fid){local, remote};
      return true;
    }
  return false;
}

// --- The stream ---

static void hang_up(void) {
  atomic_store(&hungup, true);
  wake();
}

// Writes t to the server, with tag; false (and the relay hangs up) if the
// stream will not take it.
static bool send(p9_msg *t, uint16_t tag) {
  static uint8_t buf[RELAY_MSIZE];
  t->tag = tag;
  size_t n = p9_encode(t, buf, msize);
  if (!n) return false;
  for (size_t sent = 0; sent < n;) {
    int64_t w = vx_ns_write(&stream, buf + sent, (uint32_t)(n - sent));
    if (w <= 0) {
      hang_up();
      return false;
    }
    sent += (size_t)w;
  }
  return true;
}

static int32_t call_take(void) {
  for (uint32_t i = 0; i < RELAY_CALLS; i++)
    if (!calls[i].used) return (int32_t)i;
  return -1;
}

static void call_start(int32_t i, relay_call c) {
  c.used = true;
  vx_mutex_lock(&relay_lock);
  calls[i].used = c.used, calls[i].orphan = c.orphan, calls[i].replied = false, calls[i].flushing = false;
  calls[i].conn = c.conn, calls[i].type = c.type, calls[i].tag = c.tag, calls[i].nwname = c.nwname;
  calls[i].newfid = c.newfid, calls[i].rnew = c.rnew, calls[i].rgone = c.rgone, calls[i].flushes = c.flushes;
  vx_mutex_unlock(&relay_lock);
}

// Clunks one of the relay's fids, its reply dropped; later if no call is free.
static void clunk_remote(uint32_t rfid) {
  int32_t i = call_take();
  if (i < 0) {
    if (ndoomed < RELAY_FIDS) doomed[ndoomed++] = rfid;
    return;
  }
  call_start(i, (relay_call){.orphan = true,
                             .type = P9_Tclunk,
                             .newfid = P9_NOFID,
                             .rnew = P9_NOFID,
                             .rgone = rfid,
                             .flushes = -1});
  p9_msg t = {.type = P9_Tclunk, .fid = rfid};
  if (!send(&t, (uint16_t)i)) calls[i].used = false;
}

// Whether call i's reply did what was asked: Rwalk of every name, say.
static bool call_made(const relay_call *c) {
  if (c->len < 7 || c->reply[4] != c->type + 1) return false;
  return c->type != P9_Twalk || (c->len >= 9 && le16(c->reply + 7) == c->nwname);
}

// Lets go of answered call i: the fids its reply made or ended. For a
// Tflush, the call it flushed, whose turn it is next (retire's loop); -1
// otherwise.
static int32_t retire_one(int32_t i) {
  relay_call *c = &calls[i];
  bool made = call_made(c);
  uint32_t clunk = P9_NOFID;
  if (c->rnew != P9_NOFID) {
    if (made && !c->orphan && fid_put(c->conn, c->newfid, c->rnew))
      ; // the client's now
    else if (made)
      clunk = c->rnew; // made for no one
    else
      remote_give(c->rnew);
  }
  if (c->rgone != P9_NOFID) remote_give(c->rgone);
  int32_t flushed = c->type == P9_Tflush ? c->flushes : -1;
  c->used = false;
  if (clunk != P9_NOFID) clunk_remote(clunk);
  return flushed;
}

// A flushed call that its Rflush came for. Answered first, its reply is
// dropped (and a fid it made clunked: retire_one); unanswered, it is as if
// it had not happened, but for a fid it was ending, which is clunked again
// to be sure. -1, or a call for retire's loop to go on with.
static int32_t call_flushed(int32_t p) {
  relay_call *c = &calls[p];
  if (!c->used) return -1;
  c->flushing = false;
  vx_mutex_lock(&relay_lock);
  bool answered = c->replied;
  vx_mutex_unlock(&relay_lock);
  if (answered) return retire_one(p);
  if (c->rnew != P9_NOFID) remote_give(c->rnew);
  uint32_t gone = c->rgone;
  c->used = false;
  if (gone != P9_NOFID) clunk_remote(gone);
  return -1;
}

// Retires answered call i, and the call it flushed if it is a Tflush.
static void retire(int32_t i) {
  for (int32_t next = retire_one(i); next >= 0;) next = call_flushed(next);
}

// Retires the answered calls no client waits for, and sends the clunks
// that waited for a free call.
static void sweep(void) {
  for (uint32_t i = 0; i < RELAY_CALLS; i++) {
    vx_mutex_lock(&relay_lock);
    bool done = calls[i].used && calls[i].orphan && !calls[i].flushing && calls[i].replied;
    vx_mutex_unlock(&relay_lock);
    if (done) retire((int32_t)i);
  }
  while (ndoomed && call_take() >= 0) clunk_remote(doomed[--ndoomed]);
}

// Files each reply under its tag. Runs until the stream ends.
static void reader(void *arg) {
  vx_ns_file rd = *(vx_ns_file *)arg;
  static uint8_t buf[2 * RELAY_MSIZE];
  size_t have = 0;
  for (;;) {
    uint32_t want = sizeof buf - have > 8192 ? 8192 : (uint32_t)(sizeof buf - have);
    int64_t n = vx_ns_read(&rd, buf + have, want);
    if (n <= 0) break;
    have += (size_t)n;
    bool filed = false;
    while (have >= 7) {
      uint32_t size = le32(buf);
      if (size < 7 || size > msize) {
        hang_up(); // nothing it says from here can be matched to a call
        return;
      }
      if (have < size) break;
      uint16_t tag = le16(buf + 5);
      vx_mutex_lock(&relay_lock);
      if (tag < RELAY_CALLS && calls[tag].used && !calls[tag].replied) {
        memcpy(calls[tag].reply, buf, size);
        calls[tag].len = size, calls[tag].replied = true;
        filed = true;
      }
      vx_mutex_unlock(&relay_lock);
      memmove(buf, buf + size, have - size);
      have -= size;
    }
    if (filed) wake();
  }
  hang_up();
}

// --- The clients ---

// An error reply in the session's dialect.
static size_t refuse(uint16_t tag, vx_status st, uint8_t *resp, size_t cap) {
  p9_msg r = {.tag = tag};
  if (dialect == P9_2000L)
    r.type = P9_Rlerror, r.ecode = p9_status_errno(st);
  else
    r.type = P9_Rerror, r.ename = p9_error_text(st);
  return p9_encode(&r, resp, cap);
}

// Clunks every fid conn has, as a new session or a client gone.
static void forget(uint32_t conn) {
  for (uint32_t i = 0; i < P9_MAX_FIDS; i++)
    if (fids[conn][i].remote) {
      uint32_t r = fids[conn][i].remote;
      fids[conn][i] = (relay_fid){};
      clunk_remote(r);
    }
}

static void relay_closed(void *ctx, uint32_t conn) {
  (void)ctx;
  for (uint32_t i = 0; i < RELAY_CALLS; i++)
    if (calls[i].used && calls[i].conn == conn) calls[i].orphan = true;
  forget(conn);
  sweep();
}

static size_t version(uint32_t conn, const p9_msg *t, uint8_t *resp, size_t cap) {
  for (uint32_t i = 0; i < RELAY_CALLS; i++) // the old session's calls go unanswered
    if (calls[i].used && calls[i].conn == conn) calls[i].orphan = true;
  forget(conn);
  sweep();
  uint32_t ext;
  p9_dialect want = p9_version_parse(t->version, &ext);
  // A client gets the session's dialect if it asked for it, or for 9Px,
  // whose clients take whatever they are answered, or if the session's is
  // plain 9P2000, which every dialect's clients speak.
  bool ok = want != P9_UNKNOWN && (want == dialect || want == P9_2000X || dialect == P9_2000);
  char v[64];
  p9_msg r = {.type = P9_Rversion, .tag = t->tag, .msize = t->msize < msize ? t->msize : msize};
  r.version = ok ? (vx_str){v, p9_version_format(dialect, 0, v, sizeof v)} : VX_STR("unknown");
  return p9_encode(&r, resp, cap);
}

static size_t flush(uint32_t conn, const p9_msg *t, uint8_t *resp, size_t cap) {
  int32_t p = -1;
  for (uint32_t i = 0; i < RELAY_CALLS && p < 0; i++)
    if (calls[i].used && !calls[i].orphan && calls[i].conn == conn && calls[i].tag == t->oldtag &&
        calls[i].type != P9_Tflush)
      p = (int32_t)i;
  p9_msg r = {.type = P9_Rflush, .tag = t->tag};
  if (p < 0) return p9_encode(&r, resp, cap); // never sent, or answered: nothing to flush
  calls[p].orphan = true;
  vx_mutex_lock(&relay_lock);
  bool answered = calls[p].replied;
  vx_mutex_unlock(&relay_lock);
  if (answered) { // its reply is here and goes unread
    retire(p);
    return p9_encode(&r, resp, cap);
  }
  int32_t i = call_take();
  if (i < 0) return P9_DEFER; // asked again once a call is free
  calls[p].flushing = true;
  call_start(i, (relay_call){.conn = (uint8_t)conn,
                             .type = P9_Tflush,
                             .tag = t->tag,
                             .newfid = P9_NOFID,
                             .rnew = P9_NOFID,
                             .rgone = P9_NOFID,
                             .flushes = p});
  p9_msg u = {.type = P9_Tflush, .oldtag = (uint16_t)p};
  if (!send(&u, (uint16_t)i)) calls[i].used = false, calls[p].flushing = false;
  return P9_DEFER;
}

// A request to forward: its fids made the relay's, then sent.
static size_t forward(uint32_t conn, const p9_msg *t, uint8_t *resp, size_t cap) {
  const p9_field *f = P9_FIELDS[t->type];
  if (!f || (t->type & 1)) return refuse(t->tag, VX_ERR_UNSUPPORTED, resp, cap);
  p9_msg u = *t;
  uint32_t newfid = P9_NOFID;
  // As dial.c's attaches: a Plan 9 server refuses "none" until the session
  // has authenticated, and nothing can before keyd (M10), so a client with
  // no user (the console shell, as yet) attaches as vectra.
  if ((t->type == P9_Tattach || t->type == P9_Tauth) && (!t->uname.len || p9_str_eq(t->uname, "none")))
    u.uname = VX_STR("vectra");
  relay_fid *m;
  for (; *f; f++) {
    uint32_t *field = nullptr, local = 0;
    if (*f == P9F_FID) field = &u.fid, local = t->fid;
    if (*f == P9F_NEWFID) field = &u.newfid, local = t->newfid;
    if (*f == P9F_AFID) field = &u.afid, local = t->afid;
    if (!field) continue;
    bool makes = (*f == P9F_FID && t->type == P9_Tattach) || (*f == P9F_AFID && t->type == P9_Tauth) ||
                 (*f == P9F_NEWFID && (t->type == P9_Twalk || t->type == P9_Tjoin));
    if (*f == P9F_NEWFID && t->type == P9_Twalk && t->newfid == t->fid) {
      u.newfid = u.fid; // a walk of the fid itself
    } else if (makes) {
      if (fid_find(conn, local)) return refuse(t->tag, VX_ERR_BAD_STATE, resp, cap); // in use
      newfid = local;
    } else if (*f == P9F_AFID && local == P9_NOFID) {
      // no auth fid
    } else if ((m = fid_find(conn, local))) {
      *field = m->remote;
    } else {
      return refuse(t->tag, VX_ERR_BAD_HANDLE, resp, cap); // no such fid
    }
  }
  int32_t i = call_take();
  uint32_t rnew = newfid != P9_NOFID ? remote_take() : P9_NOFID;
  if (i < 0 || (newfid != P9_NOFID && rnew == P9_NOFID)) {
    remote_give(rnew);
    return i < 0 ? P9_DEFER : refuse(t->tag, VX_ERR_NO_MEMORY, resp, cap);
  }
  if (newfid != P9_NOFID) {
    if (t->type == P9_Tattach) u.fid = rnew;
    if (t->type == P9_Tauth) u.afid = rnew;
    if (t->type == P9_Twalk || t->type == P9_Tjoin) u.newfid = rnew;
  }
  uint32_t rgone = P9_NOFID;
  if (t->type == P9_Tclunk || t->type == P9_Tremove) { // the client's fid goes now, the relay's once answered
    m = fid_find(conn, t->fid);
    rgone = m->remote;
    *m = (relay_fid){};
  }
  call_start(i, (relay_call){.conn = (uint8_t)conn,
                             .type = t->type,
                             .tag = t->tag,
                             .nwname = t->nwname,
                             .newfid = newfid,
                             .rnew = rnew,
                             .rgone = rgone,
                             .flushes = -1});
  if (!send(&u, (uint16_t)i)) {
    calls[i].used = false;
    remote_give(rnew);
    return refuse(t->tag, VX_ERR_PEER_CLOSED, resp, cap);
  }
  return P9_DEFER;
}

static size_t relay_raw(void *ctx, uint32_t conn, const uint8_t *req, size_t len, uint8_t *resp, size_t cap) {
  (void)ctx;
  p9_msg t;
  if (p9_decode(req, len, &t) != VX_OK || t.type & 1)
    return refuse(len >= 7 ? le16(req + 5) : P9_NOTAG, VX_ERR_INVALID, resp, cap);
  for (uint32_t i = 0; i < RELAY_CALLS; i++) { // asked again: one already sent
    relay_call *c = &calls[i];
    if (!c->used || c->orphan || c->conn != conn || c->tag != t.tag || c->type != t.type) continue;
    vx_mutex_lock(&relay_lock);
    bool answered = c->replied;
    vx_mutex_unlock(&relay_lock);
    if (!answered) return P9_DEFER;
    size_t n = c->len <= cap ? c->len : 0;
    memcpy(resp, c->reply, n);
    if (c->type == P9_Tflush) { // Rflush, whatever the server answered
      p9_msg r = {.type = P9_Rflush, .tag = t.tag};
      n = p9_encode(&r, resp, cap);
    }
    resp[5] = (uint8_t)t.tag, resp[6] = (uint8_t)(t.tag >> 8);
    retire((int32_t)i);
    return n;
  }
  if (t.type == P9_Tversion) return version(conn, &t, resp, cap);
  if (t.type == P9_Tflush) return flush(conn, &t, resp, cap);
  return forward(conn, &t, resp, cap);
}

static void relay_event(void *ctx, const vx_packet *pk) {
  (void)ctx, (void)pk;
  if (atomic_load(&hungup)) {
    vx_print(VX_STR("relay: "));
    vx_print(address);
    vx_print(VX_STR(" hung up\n"));
    vx_exits("hungup");
  }
  sweep();
  server.again = true; // held requests whose replies came
}

const char *vx_main(void) {
  server.listen = vx_spawn_take("listen");
  if (!server.listen) return "no listen channel";
  if (vx_spawn.argc < 1) return VX_USAGE;
  address = vx_spawn.args[0];
  if (vx_ns_from_spawn(&ns) != VX_OK) return "no namespace";
  p9_client *c;
  vx_str src;
  vx_status st = vx_ns_dial(&ns, address, &c, &src);
  if (st != VX_OK) {
    vx_print(VX_STR("relay: cannot dial "));
    vx_print(address);
    vx_print(VX_STR(": "));
    vx_print(p9_error_text(st));
    vx_print(VX_STR("\n"));
    return "cannot dial";
  }
  // The dialed connection's stream, now the relay's: nothing calls through c again.
  stream = ((vx_ns_dialed *)c)->data;
  dialect = c->dialect, msize = c->msize < RELAY_MSIZE ? c->msize : RELAY_MSIZE;
  const vx_ns_dialed *d = (const vx_ns_dialed *)c;
  if (vx_ns_open(&ns, (vx_str){d->data_path, d->data_path_len}, P9_OREAD, &incoming) != VX_OK)
    return "cannot open the stream again";
  if (vx_port_create(0, &server.port) != VX_OK) return "no port";
  static vx_thread t;
  if (vx_thread_spawn(&t, reader, &incoming, 0) != VX_OK) return "no reader thread";
  char v[64];
  vx_print(VX_STR("relay: "));
  vx_print(src);
  vx_print(VX_STR(" as "));
  vx_print((vx_str){v, p9_version_format(dialect, 0, v, sizeof v)});
  vx_print(VX_STR("\n"));
  server.name = VX_STR("relay");
  server.raw = relay_raw;
  server.closed = relay_closed;
  server.event = relay_event;
  server.linger = true;
  p9_ring_serve(&server);
  return nullptr; // nothing can reach it any more
}
