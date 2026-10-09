// vx-9p over a ring, the server side (ring.c describes the transport).
//
// The server waits on one port for everything: READABLE on the listen channel;
// for each connection, its doorbell (COUNTER_GE) and its client going away
// (PEER_CLOSED); and whatever the file server binds there itself, such as a
// driver's Irq, with keys from P9_KEY_USER up, which go to its event hook.
//
// A request the file server cannot do yet (p9_serve's P9_DEFER) is held, and
// served again after every event, after every tick, and when the file server
// says something it did may let it go on (`again`): a request on another
// connection, say, that queued what the held one waits for. A connection
// holds up to P9_RING_DEPTH of them (M6 step 6d4a) and goes on taking new
// requests meanwhile, so replies go out in any order, as 9P allows. Two rules
// keep that safe:
//   - a request on a fid that an earlier held request is on waits behind it,
//     so writes to a pipe, say, stay in their order;
//   - Tflush of a held request drops it, unanswered, before Rflush goes out
//     (9P's rule: the flushed request's reply comes first, or never).
// A held request's bytes stay in the client's arena until it is answered,
// and are copied out again each time it is served.
//
// Threads (M6 step 6d5a), as 9front's lib9p has them (srv.c's srvrelease
// and srvacquire): requests are served one at a time, under the server's
// lock, by whichever of its threads holds it, so a file server that never
// asks for more is served as by one thread. One whose operation is to wait
// (a device's I/O) lets the lock go with p9_release, and takes it back with
// p9_acquire, its own state its own to keep safe meanwhile; another thread
// goes on serving, a parked one or a new one, up to max_threads. A request
// being served so stays among the held ones, busy: the fid rule holds for
// it, a Tflush of it waits for its reply, a Tversion for every busy one, and
// a connection that goes is closed once its last busy request is answered.

#pragma once

#include "ring.c"
#include "server.c"

static constexpr uint32_t P9_RING_MAX_CONNS = 16; // a server's connections, unless it says otherwise

// A connection's port keys carry its slot and the slot's generation, so a
// packet from a binding on a connection that has gone is never taken for one
// about its slot's next connection.
enum : uint64_t { P9_KEY_LISTEN = 0, P9_KEY_CONN_BELL = 1, P9_KEY_CONN_CLOSED = 2 };
static constexpr uint64_t P9_KEY_USER = 1ull << 62; // and up: the file server's own bindings

static uint64_t p9_conn_key(uint64_t kind, uint32_t slot, uint32_t gen) {
  return kind << 40 | (uint64_t)gen << 8 | slot;
}

// A request held for later, or being served (busy): its submission (its
// bytes stay in the client's arena), the VMO it came with, and what the
// rules above look at.
typedef struct p9_held {
  vx_sqe e;
  vx_handle handle; // dref's VMO, the server's until it is answered
  uint32_t id;      // the connection's count of requests: which one, however the others move
  uint16_t tag;
  uint16_t oldtag; // a Tflush's
  uint8_t type;
  uint64_t span; // its span's start (20 §5), from its arrival; 0 with spans off
  bool busy;     // a thread is serving it
  uint32_t fid;  // P9_NOFID: the message has none
  uint32_t made; // a Twalk's newfid: what is sent on it next waits behind the walk (7a6); else NOFID
} p9_held;

typedef struct p9_ring_server p9_ring_server;

typedef struct p9_ring_conn {
  bool used, armed;
  bool closing; // its client has gone: closed once nothing is busy
  uint32_t gen, slot;
  p9_ring_server *owner;
  uint32_t nheld; // held[0..nheld), oldest first
  uint32_t busy;  // of them
  uint32_t next_id;
  p9_held held[P9_RING_DEPTH];
  vx_ring ring;
  p9_arena out;      // the server's arena: the replies' bytes
  uint32_t released; // completions whose bytes have been given back
  vx_handle end;
  p9_server srv;
} p9_ring_conn;

static constexpr uint32_t P9_RING_MAX_THREADS = 16;

typedef struct p9_ring_server {
  p9_fs fs;
  uint32_t supported;     // 9Px extensions
  vx_str name;            // for messages
  vx_handle listen, port; // port: the file server may bind its own sources here, keyed from P9_KEY_USER
  bool listen_armed;
  void *ctx;
  void (*event)(void *ctx, const vx_packet *pk); // a packet with a key from P9_KEY_USER up
  // Optional: does what is due by now, and says when to be called again
  // (VX_INFINITE: never), as a protocol's retransmission timers need.
  vx_instant (*tick)(void *ctx);
  // Optional: a message on the listen channel that is not P9_CONNECT, with
  // the one handle it may carry (VX_HANDLE_NONE if none), which becomes the
  // hook's. procfs takes registrations this way (lib/vx-proc/proc.h).
  void (*listen_msg)(void *ctx, const void *msg, uint32_t len, vx_handle handle);
  // Set by the file server when what it just did may let a held request go
  // on: the held requests are served again before the server sleeps.
  bool again;
  // Optional, in place of fs: each request as it came, on connection `conn`
  // (its slot), for a server that forwards requests rather than serving them
  // (the relay, M6 step 6d4d2b). Returns the reply's length in resp, or
  // P9_DEFER to be asked again; the rules above hold as for fs, Tflush's
  // too. `closed` is told when a connection has gone, its held requests
  // dropped unanswered.
  size_t (*raw)(void *ctx, uint32_t conn, const uint8_t *req, size_t len, uint8_t *resp, size_t cap);
  void (*closed)(void *ctx, uint32_t conn);
  // Whether to go on serving the connections it has once the listen
  // channel's peer has gone: p9_ring_serve then returns when the last one
  // goes. Without it, it returns at once.
  bool linger;
  // The threads that may serve it, at most (6d5a): 0 or 1, the one that
  // calls p9_ring_serve; more, made as p9_release needs them, and kept.
  uint32_t max_threads;
  // Its connections: these, unless the file server gives more of its own
  // (procfs, which holds one per process) before serving. At most 256.
  p9_ring_conn *conns;
  uint32_t max_conns;
  p9_ring_conn default_conns[P9_RING_MAX_CONNS];
  p9_shared shared; // the open files and locks all its connections share (posix)
  // The threads (the server's lock held for these): serving, or waiting for
  // work, rather than let go or parked.
  vx_lock_t lock;
  uint32_t running, threads, parked, tickets;
  _Atomic uint32_t unpark; // a parked thread's futex: a ticket is there to take
  bool stopping;
  bool deaf;         // the listen channel's peer has gone, and it lingers
  vx_status stopped; // what p9_ring_serve returns
  vx_worker pool[P9_RING_MAX_THREADS];
} p9_ring_server;

// Each serving thread's own: the request and reply it is serving, and
// whether it let the server go meanwhile (what it was looking at may have
// moved: the connection's held requests, the connections).
typedef struct p9_ring_worker {
  bool released;
  uint8_t req[P9_RING_MSIZE], resp[P9_RING_MSIZE];
} p9_ring_worker;

static thread_local p9_ring_server *p9_ring_current;
static thread_local p9_ring_worker *p9_ring_self;

static void p9_ring_loop(p9_ring_server *s);

static void p9_ring_worker_main(void *arg) {
  p9_ring_server *s = arg;
  vx_lock(&s->lock); // counted among the running by p9_release, which made it
  p9_ring_loop(s);
  vx_unlock(&s->lock);
}

// Lets the server go, for an operation of the file server's that is to wait
// (6d5a): another thread serves meanwhile, a parked one or a new one if none
// other is running. Nothing of the file server's own is kept safe by the
// server's lock until p9_acquire takes it back. False, and nothing done,
// outside a ring server's call, or while the call must keep the lock
// (server.c's p9_keep_lock): then p9_acquire is not called.
[[maybe_unused]] static bool p9_release(void) {
  p9_ring_server *s = p9_ring_current;
  if (!s || !p9_ring_self || p9_keep_lock) return false;
  p9_ring_self->released = true;
  s->running--;
  if (!s->running && !s->stopping) {
    if (s->parked) {
      s->parked--, s->tickets++, s->running++;
      atomic_fetch_add(&s->unpark, 1);
      vx_futex_wake(&s->unpark, 1);
    } else if (s->threads < s->max_threads && s->threads < P9_RING_MAX_THREADS &&
               vx_worker_start(&s->pool[s->threads], p9_ring_worker_main, s, 0) == VX_OK) {
      s->threads++, s->running++;
    }
  }
  vx_unlock(&s->lock);
  return true;
}

// Takes the server back after a p9_release that let it go.
[[maybe_unused]] static void p9_acquire(void) {
  p9_ring_server *s = p9_ring_current;
  if (!s || !p9_ring_self) return;
  vx_lock(&s->lock);
  s->running++;
}

// Waits, parked, until p9_release needs this thread, or the server stops.
static void p9_ring_park(p9_ring_server *s) {
  s->running--, s->parked++;
  while (!s->tickets && !s->stopping) {
    uint32_t seen = atomic_load(&s->unpark);
    vx_unlock(&s->lock);
    vx_futex_wait(&s->unpark, seen, VX_INFINITE);
    vx_lock(&s->lock);
  }
  if (s->tickets) {
    s->tickets--; // p9_release counted it running again
  } else {
    s->parked--, s->running++;
  }
}

static constexpr uint64_t P9_KEY_STOP = 3ull << 40;

// Ends the server: every thread goes, and p9_ring_serve returns st.
static void p9_ring_stop(p9_ring_server *s, vx_status st) {
  if (s->stopping) return;
  s->stopping = true, s->stopped = st;
  atomic_fetch_add(&s->unpark, 1);
  vx_futex_wake(&s->unpark, UINT32_MAX);
  for (uint32_t i = 0; i < s->threads; i++) vx_port_post(s->port, &(vx_packet){.key = P9_KEY_STOP});
}

// The handle a request came with, if any: the server's while it serves it.
static void p9_ring_drop_request_handle(void) {
  if (p9_request_handle) vx_handle_close(p9_request_handle);
  p9_request_handle = VX_HANDLE_NONE;
}

static void p9_ring_close(p9_ring_conn *c) {
  if (c->busy) { // a thread serves one of its requests: closed when it is done
    c->closing = true;
    return;
  }
  if (c->owner && c->owner->closed) c->owner->closed(c->owner->ctx, c->slot);
  for (uint32_t i = 0; i < c->nheld; i++)
    if (c->held[i].handle) vx_handle_close(c->held[i].handle);
  c->nheld = 0;
  for (uint32_t i = 0; i < P9_MAX_FIDS; i++)
    if (c->srv.fids[i].used) p9_fid_drop(&c->srv, &c->srv.fids[i]);
  vx_handle_close(c->end);
  p9_ring_unmap(&c->ring);
  c->used = c->closing = false;
}

// Answers one P9_CONNECT: a new ring, its client end and memory in the reply.
static void p9_ring_accept(p9_ring_server *s, const vx_msg_header *req) {
  vx_msg_header rep = {.txid = req->txid, .ordinal = P9_CONNECT};
  uint32_t i = 0;
  while (i < s->max_conns && s->conns[i].used) i++;
  vx_ring_handles h = {};
  vx_status st = i < s->max_conns ? vx_ring_create(&P9_RING_PARAMS, &h) : VX_ERR_NO_MEMORY;
  p9_ring_conn *c = i < s->max_conns ? &s->conns[i] : nullptr;
  if (st == VX_OK) st = p9_ring_map(h.memory, false, &c->ring);
  if (st == VX_OK) c->gen++;
  if (st == VX_OK)
    st = vx_port_bind(s->port, h.server, VX_TRIGGER_PEER_CLOSED, p9_conn_key(P9_KEY_CONN_CLOSED, i, c->gen),
                      0);
  if (st == VX_OK) {
    vx_handle give[2] = {h.client, h.memory};
    st = vx_channel_write(s->listen, &rep, sizeof rep, give, 2);
    h.client = h.memory = VX_HANDLE_NONE; // moved, whatever happened
  }
  if (st == VX_OK) {
    c->used = true;
    c->armed = c->closing = false;
    c->nheld = c->released = c->busy = 0;
    uint64_t arena_size;
    vx_ring_arena(&c->ring, &arena_size);
    c->out = (p9_arena){.size = arena_size};
    c->end = h.server;
    c->slot = i, c->owner = s;
    c->srv =
        (p9_server){.fs = s->fs, .max_msize = P9_RING_MSIZE, .supported = s->supported, .shared = &s->shared};
    return;
  }
  vx_handle_close(h.client);
  vx_handle_close(h.server);
  vx_handle_close(h.memory);
  rep.flags = 1; // refused: a reply without handles
  vx_channel_write(s->listen, &rep, sizeof rep, nullptr, 0);
}

// Requests served on one connection before the server turns to the others: a
// client that keeps its queue full gets its share, not the whole server.
static constexpr uint32_t P9_RING_BUDGET = 8;

typedef enum p9_drained : uint8_t { P9_DRAINED, P9_MORE, P9_BROKEN } p9_drained;

// Gives back the arena of every completion the client has consumed.
static void p9_ring_give_back(p9_ring_conn *c) {
  uint32_t consumed = vx_ring_peer_consumed(&c->ring);
  while (c->released != consumed && c->out.count) {
    p9_arena_free(&c->out, (int)c->out.first);
    c->released++;
  }
}

// Sends a reply of n bytes at resp for the submission e, with the reply's
// handle if the request made one. False if the client has broken the
// protocol: no room in the completion queue or the arena, which a client
// that keeps to the depth always leaves.
static bool p9_ring_reply(p9_ring_conn *c, const vx_sqe *e, const uint8_t *resp, size_t n) {
  p9_ring_give_back(c);
  uint64_t off;
  vx_cqe *out = n ? vx_ring_produce_slot(&c->ring) : nullptr;
  int region = out ? p9_arena_alloc(&c->out, n, &off) : -1;
  if (region < 0) {
    if (p9_reply_handle) vx_handle_close(p9_reply_handle); // no reply to carry it
    p9_reply_handle = VX_HANDLE_NONE;
    return false;
  }
  uint64_t arena_size;
  uint8_t *arena = vx_ring_arena(&c->ring, &arena_size);
  memcpy(arena + off, resp, n);
  *out = (vx_cqe){.user_data = e->user_data, .result = (int64_t)n, .aux2 = off};
  if (p9_reply_handle) { // Rmap's VMO, in a slot the completion names
    int64_t slot = vx_ring_put_handles(c->end, &p9_reply_handle, 1);
    if (slot >= 0)
      out->flags = P9_CQE_HANDLE, out->aux = (uint32_t)slot;
    else
      vx_handle_close(p9_reply_handle); // the client finds none, and its call fails
    p9_reply_handle = VX_HANDLE_NONE;
  }
  // With nothing more held, this server waits next: its client runs here as
  // it does, no other CPU woken for it (7a6b).
  if (vx_ring_produce(&c->ring)) c->nheld ? vx_ring_notify(c->end) : vx_ring_notify_handoff(c->end);
  return true;
}

static void p9_ring_unhold(p9_ring_conn *c, uint32_t i) {
  for (uint32_t j = i + 1; j < c->nheld; j++) c->held[j - 1] = c->held[j];
  c->nheld--;
}

// Where the held request with this id is now; nheld if it has gone.
static uint32_t p9_ring_find(const p9_ring_conn *c, uint32_t id) {
  uint32_t i = 0;
  while (i < c->nheld && c->held[i].id != id) i++;
  return i;
}

typedef enum p9_tried : uint8_t { P9_ANSWERED, P9_HELD, P9_TRY_BROKEN } p9_tried;

// Serves held[i] once, busy meanwhile: its bytes copied out of the client's
// arena again into this thread's buffer, its VMO lent to the server for the
// call. Answered, it is no longer held.
static p9_tried p9_ring_try(p9_ring_conn *c, uint32_t i) {
  p9_ring_worker *w = p9_ring_self;
  p9_held h = c->held[i];
  const uint8_t *p = vx_ring_peer_bytes(&c->ring, h.e.arena_off, h.e.len);
  if (!p || h.e.len > sizeof w->req) return P9_TRY_BROKEN;
  memcpy(w->req, p, h.e.len);
  c->held[i].busy = true, c->held[i].handle = VX_HANDLE_NONE;
  c->busy++;
  p9_request_handle = h.handle;
  const p9_ring_server *s = c->owner;
  size_t n = s && s->raw ? s->raw(s->ctx, c->slot, w->req, h.e.len, w->resp, sizeof w->resp)
                         : p9_serve(&c->srv, w->req, h.e.len, w->resp, sizeof w->resp);
  c->busy--;
  i = p9_ring_find(c, h.id); // others may have moved it, while the server was let go
  c->held[i].busy = false;
  if (n == P9_DEFER && !c->closing) {
    c->held[i].handle = p9_request_handle; // kept until it is served
    p9_request_handle = VX_HANDLE_NONE;
    return P9_HELD;
  }
  p9_ring_drop_request_handle();
  p9_ring_unhold(c, i);
  if (c->closing) { // its client went meanwhile: no one to answer
    if (p9_reply_handle) vx_handle_close(p9_reply_handle);
    p9_reply_handle = VX_HANDLE_NONE;
    return P9_TRY_BROKEN;
  }
  bool sent = p9_ring_reply(c, &h.e, w->resp, n);
  if (h.span) vx_span_end_hook(h.span, h.type, vx_prof_flow(c->ring.h.session, h.e.user_data));
  return sent ? P9_ANSWERED : P9_TRY_BROKEN;
}

// Whether an older held request than held[i] is on fid: if so, it waits behind that one.
static bool p9_ring_behind(const p9_ring_conn *c, uint32_t i, uint32_t fid) {
  if (fid == P9_NOFID) return false;
  for (uint32_t j = 0; j < i; j++)
    if (c->held[j].fid == fid || c->held[j].made == fid) return true; // on it, or making it
  return false;
}

// Whether held[i] waits for others first: anything behind the fid rule; a
// Tflush whose request is busy (its reply comes first); a Tversion while
// any is. A Tflush that may go drops the held request it names first.
static bool p9_ring_waits(p9_ring_conn *c, uint32_t i) {
  const p9_held *h = &c->held[i];
  if (h->busy || p9_ring_behind(c, i, h->fid)) return true;
  if (h->type == P9_Tversion) return c->busy > 0;
  if (h->type != P9_Tflush) return false;
  for (uint32_t j = 0; j < c->nheld; j++) {
    if (j == i || c->held[j].tag != h->oldtag) continue;
    if (c->held[j].busy) return true;
    if (c->held[j].handle) vx_handle_close(c->held[j].handle);
    p9_ring_unhold(c, j); // unanswered; then Rflush
    break;
  }
  return false;
}

// The fid a request is on, for the ordering rule; P9_NOFID if none.
static uint32_t p9_request_fid(const p9_msg *t) {
  switch (t->type) {
  case P9_Tversion:
  case P9_Tauth:
  case P9_Tflush: return P9_NOFID;
  default: return t->fid;
  }
}

// Serves the requests waiting on one connection, up to its budget: the held
// ones first, oldest first, then new ones. P9_MORE if requests are left, or
// if the server was let go during one (what was being looked at may have
// moved: look again); P9_BROKEN if the client broke the protocol, or sent
// something too broken to answer, and must be dropped.
static p9_drained p9_ring_drain(p9_ring_conn *c) {
  p9_ring_worker *w = p9_ring_self;
  if (c->closing) return P9_DRAINED;
  for (uint32_t i = 0; i < c->nheld;) {
    uint32_t before = c->nheld;
    bool waits = p9_ring_waits(c, i);
    if (c->nheld != before) { // a Tflush dropped one: start again
      i = 0;
      continue;
    }
    if (waits) {
      i++;
      continue;
    }
    w->released = false;
    p9_tried r = p9_ring_try(c, i);
    if (r == P9_TRY_BROKEN) return P9_BROKEN;
    if (w->released) return P9_MORE;
    if (r == P9_HELD) i++; // answered: no longer at i
  }
  for (uint32_t served = 0;; served++) {
    if (served == P9_RING_BUDGET) return P9_MORE;
    if (c->nheld == P9_RING_DEPTH) return P9_DRAINED; // a client past the depth waits for its answers
    p9_held h = {.fid = P9_NOFID, .made = P9_NOFID};
    vx_status st = vx_ring_consume(&c->ring, &h.e);
    if (st == VX_ERR_SHOULD_WAIT) return P9_DRAINED;
    if (st != VX_OK || h.e.opcode != P9_RING_MSG || h.e.len > sizeof w->req) return P9_BROKEN;
    const uint8_t *p = vx_ring_peer_bytes(&c->ring, h.e.arena_off, h.e.len);
    if (!p) return P9_BROKEN;
    if ((h.e.flags & VX_SQE_HANDLES) && vx_ring_take_handles(c->end, h.e.handle_slot, &h.handle, 1) != 1)
      h.handle = VX_HANDLE_NONE; // dref's VMO, for Treadref and Twriteref
    memcpy(w->req, p, h.e.len);
    p9_msg t;
    if (p9_decode(w->req, h.e.len, &t) != VX_OK) {
      if (h.handle) vx_handle_close(h.handle);
      return P9_BROKEN;
    }
    h.tag = t.tag, h.type = (uint8_t)t.type, h.oldtag = t.oldtag;
    h.fid = p9_request_fid(&t);
    if (t.type == P9_Twalk && t.newfid != t.fid) h.made = t.newfid; // a pipelined Topen on it waits
    h.id = c->next_id++;
    h.span = vx_span_begin_hook ? vx_span_begin_hook() : 0;
    c->held[c->nheld++] = h;
    uint32_t i = c->nheld - 1;
    if (p9_ring_waits(c, i)) continue;
    i = p9_ring_find(c, h.id); // a Tflush may have dropped one before it
    w->released = false;
    p9_tried r = p9_ring_try(c, i);
    if (r == P9_TRY_BROKEN) return P9_BROKEN;
    if (w->released) return P9_MORE;
  }
}

static int64_t p9_ring_now(void) { return vx_clock_read(); }

// The loop each of the server's threads runs, the server's lock held but
// while it sleeps or is parked, until the server stops.
static void p9_ring_loop(p9_ring_server *s) {
  p9_ring_worker self;
  p9_ring_current = s, p9_ring_self = &self;
  while (!s->stopping) {
    bool more = false; // a connection still has requests: no sleeping this time round
    for (uint32_t i = 0; i < s->max_conns && !s->stopping; i++) {
      p9_ring_conn *c = &s->conns[i];
      if (!c->used) continue;
      p9_drained d = p9_ring_drain(c);
      if (d == P9_BROKEN) p9_ring_close(c);
      more = more || d == P9_MORE;
    }
    for (; !s->deaf && !s->stopping;) {
      alignas(vx_msg_header) uint8_t msg[64];
      vx_handle handle = VX_HANDLE_NONE;
      vx_msg_size size;
      vx_status st = vx_channel_read(s->listen, msg, sizeof msg, &handle, 1, &size);
      if (st == VX_ERR_SHOULD_WAIT) break;
      if (st == VX_ERR_PEER_CLOSED && !s->linger) {
        p9_ring_stop(s, st);
        break;
      }
      if (st == VX_ERR_PEER_CLOSED) {
        s->deaf = true;
        break;
      }
      const vx_msg_header *req = (const vx_msg_header *)msg;
      if (st == VX_OK && size.bytes == sizeof *req && req->ordinal == P9_CONNECT && !size.handles) {
        p9_ring_accept(s, req);
      } else if (st == VX_OK && size.bytes >= sizeof *req && req->ordinal != P9_CONNECT && s->listen_msg) {
        s->listen_msg(s->ctx, msg, size.bytes, size.handles ? handle : VX_HANDLE_NONE);
      } else if (st == VX_OK && size.handles) {
        vx_handle_close(handle);
      }
      // Anything else, including a message too big for us (TOO_SMALL), is dropped.
      if (st == VX_ERR_TOO_SMALL) {
        static uint8_t junk[VX_CHANNEL_MAX_BYTES];
        static vx_handle junk_handles[VX_CHANNEL_MAX_HANDLES];
        if (vx_channel_read(s->listen, junk, sizeof junk, junk_handles, VX_CHANNEL_MAX_HANDLES, &size) ==
            VX_OK)
          for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(junk_handles[i]);
      }
    }

    if (s->deaf && !s->stopping) { // lingering: until the last connection goes
      bool any = false;
      for (uint32_t i = 0; i < s->max_conns && !any; i++) any = s->conns[i].used;
      if (!any) p9_ring_stop(s, VX_ERR_PEER_CLOSED);
    }
    if (s->stopping) break;

    // Arm what is idle, then sleep unless something arrived meanwhile. A
    // connection holding requests waits for an event or its doorbell: a new
    // request, or a Tflush of a held one. A thread with another running
    // parks instead: one sleeping on the port is enough.
    if (s->again ||
        s->shared.again) // a held request may go on now (an event, for a Tnotify): once more round
      more = true, s->again = false, s->shared.again = false;
    if (!more && s->running > 1) {
      p9_ring_park(s);
      continue;
    }
    // Only the thread that sleeps marks the rings and unmarks them after:
    // another's unmarking would leave the sleeper's doorbells silent.
    bool idle = !more;
    for (uint32_t i = 0; i < s->max_conns && idle; i++) {
      p9_ring_conn *c = &s->conns[i];
      if (!c->used || c->closing) continue;
      int64_t seen = vx_counter_read(c->end);
      if (!vx_ring_prepare_sleep(&c->ring)) {
        idle = false;
      } else if (!c->armed) {
        c->armed = vx_port_bind(s->port, c->end, VX_TRIGGER_COUNTER_GE,
                                p9_conn_key(P9_KEY_CONN_BELL, i, c->gen), (uint64_t)seen + 1) == VX_OK;
      }
    }
    if (idle && !s->deaf && !s->listen_armed)
      s->listen_armed = vx_port_bind(s->port, s->listen, VX_TRIGGER_READABLE, P9_KEY_LISTEN, 0) == VX_OK;
    vx_instant deadline = s->tick ? s->tick(s->ctx) : VX_INFINITE;
    if (idle) {
      vx_packet pk[16];
      vx_unlock(&s->lock); // while it sleeps, a thread let go may take the server back
      int64_t n = vx_port_wait(s->port, deadline, 0, pk, 16); // TIMED_OUT: the tick is due
      vx_lock(&s->lock);
      for (int64_t j = 0; j < n; j++) {
        uint64_t key = pk[j].key, kind = key >> 40;
        uint32_t slot = key & 0xff, gen = (uint32_t)(key >> 8);
        if (key >= P9_KEY_USER) {
          if (s->event) s->event(s->ctx, &pk[j]);
          continue;
        }
        if (key == P9_KEY_LISTEN) {
          s->listen_armed = false;
          continue;
        }
        if (key == P9_KEY_STOP) continue;
        p9_ring_conn *c = slot < s->max_conns ? &s->conns[slot] : nullptr;
        if (!c || !c->used || c->gen != gen) continue; // about a connection that has gone
        if (kind == P9_KEY_CONN_CLOSED)
          p9_ring_close(c);
        else if (kind == P9_KEY_CONN_BELL)
          c->armed = false;
      }
    }
    if (!more) // marked for a sleep, slept or not
      for (uint32_t i = 0; i < s->max_conns; i++)
        if (s->conns[i].used) vx_ring_end_sleep(&s->conns[i].ring);
  }
  p9_ring_current = nullptr, p9_ring_self = nullptr;
}

// Serves the file system on the listen channel until the channel goes away
// (or, lingering, its last connection too). The port is made here unless
// the file server made it already, to bind its own sources first.
[[maybe_unused]] static vx_status p9_ring_serve(p9_ring_server *s) {
  vx_status st = s->port ? VX_OK : vx_port_create(0, &s->port);
  if (st != VX_OK) return st;
  if (!s->conns || !s->max_conns || s->max_conns > 256)
    s->conns = s->default_conns, s->max_conns = P9_RING_MAX_CONNS;
  // Tokens for shared open files come from the entropy the spawn message
  // gives (a manifest's `entropy`); without it, Tshare is refused.
  s->shared.now = p9_ring_now;
  vx_ndb_record rec;
  vx_str seed = vx_spawn_record("entropy", &rec) ? vx_ndb_get(&rec, "entropy") : (vx_str){};
  if (seed.len >= 16 && !s->shared.random.seeded) vx_drbg_mix(&s->shared.random, seed.ptr, seed.len, true);
  if (!s->max_threads) s->max_threads = 1;
  vx_lock(&s->lock);
  s->threads = s->running = 1;
  p9_ring_loop(s);
  st = s->stopped;
  vx_unlock(&s->lock);
  return st;
}
