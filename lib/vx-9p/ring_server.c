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

// A request held for later: its submission (its bytes stay in the client's
// arena), the VMO it came with, and what the rules above look at.
typedef struct p9_held {
  vx_sqe e;
  vx_handle handle; // dref's VMO, the server's until it is answered
  uint16_t tag;
  uint32_t fid; // P9_NOFID: the message has none
} p9_held;

typedef struct p9_ring_server p9_ring_server;

typedef struct p9_ring_conn {
  bool used, armed;
  uint32_t gen, slot;
  p9_ring_server *owner;
  uint32_t nheld; // held[0..nheld), oldest first
  p9_held held[P9_RING_DEPTH];
  vx_ring ring;
  p9_arena out;      // the server's arena: the replies' bytes
  uint32_t released; // completions whose bytes have been given back
  vx_handle end;
  p9_server srv;
  uint8_t req[P9_RING_MSIZE], resp[P9_RING_MSIZE];
} p9_ring_conn;

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
  // Its connections: these, unless the file server gives more of its own
  // (procfs, which holds one per process) before serving. At most 256.
  p9_ring_conn *conns;
  uint32_t max_conns;
  p9_ring_conn default_conns[P9_RING_MAX_CONNS];
  p9_shared shared; // the open files and locks all its connections share (posix)
} p9_ring_server;

// The handle a request came with, if any: the server's while it serves it.
static void p9_ring_drop_request_handle(p9_ring_conn *c) {
  if (c->srv.request_handle) vx_handle_close(c->srv.request_handle);
  c->srv.request_handle = VX_HANDLE_NONE;
}

static void p9_ring_close(p9_ring_conn *c) {
  p9_ring_drop_request_handle(c);
  if (c->owner && c->owner->closed) c->owner->closed(c->owner->ctx, c->slot);
  for (uint32_t i = 0; i < c->nheld; i++)
    if (c->held[i].handle) vx_handle_close(c->held[i].handle);
  c->nheld = 0;
  for (uint32_t i = 0; i < P9_MAX_FIDS; i++)
    if (c->srv.fids[i].used) p9_fid_drop(&c->srv, &c->srv.fids[i]);
  vx_handle_close(c->end);
  p9_ring_unmap(&c->ring);
  c->used = false;
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
    c->armed = false;
    c->nheld = c->released = 0;
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
static void p9_ring_release(p9_ring_conn *c) {
  uint32_t consumed = vx_ring_peer_consumed(&c->ring);
  while (c->released != consumed && c->out.count) {
    p9_arena_free(&c->out, (int)c->out.first);
    c->released++;
  }
}

// Sends a reply of n bytes for the submission e, with the reply's handle if
// the request made one. False if the client has broken the protocol: no room
// in the completion queue or the arena, which a client that keeps to the
// depth always leaves.
static bool p9_ring_reply(p9_ring_conn *c, const vx_sqe *e, size_t n) {
  p9_ring_release(c);
  uint64_t off;
  vx_cqe *out = n ? vx_ring_produce_slot(&c->ring) : nullptr;
  int region = out ? p9_arena_alloc(&c->out, n, &off) : -1;
  if (region < 0) {
    if (c->srv.reply_handle) vx_handle_close(c->srv.reply_handle); // no reply to carry it
    c->srv.reply_handle = VX_HANDLE_NONE;
    return false;
  }
  uint64_t arena_size;
  uint8_t *arena = vx_ring_arena(&c->ring, &arena_size);
  memcpy(arena + off, c->resp, n);
  *out = (vx_cqe){.user_data = e->user_data, .result = (int64_t)n, .aux2 = off};
  if (c->srv.reply_handle) { // Rmap's VMO, in a slot the completion names
    int64_t slot = vx_ring_put_handles(c->end, &c->srv.reply_handle, 1);
    if (slot >= 0)
      out->flags = P9_CQE_HANDLE, out->aux = (uint32_t)slot;
    else
      vx_handle_close(c->srv.reply_handle); // the client finds none, and its call fails
    c->srv.reply_handle = VX_HANDLE_NONE;
  }
  if (vx_ring_produce(&c->ring)) vx_ring_notify(c->end);
  return true;
}

typedef enum p9_tried : uint8_t { P9_ANSWERED, P9_HELD, P9_TRY_BROKEN } p9_tried;

// Serves h once: its bytes copied out of the client's arena again, its VMO
// lent to the server for the call.
static p9_tried p9_ring_try(p9_ring_conn *c, p9_held *h) {
  const uint8_t *p = vx_ring_peer_bytes(&c->ring, h->e.arena_off, h->e.len);
  if (!p || h->e.len > sizeof c->req) return P9_TRY_BROKEN;
  memcpy(c->req, p, h->e.len);
  c->srv.request_handle = h->handle;
  h->handle = VX_HANDLE_NONE;
  const p9_ring_server *s = c->owner;
  size_t n = s && s->raw ? s->raw(s->ctx, c->slot, c->req, h->e.len, c->resp, sizeof c->resp)
                         : p9_serve(&c->srv, c->req, h->e.len, c->resp, sizeof c->resp);
  if (n == P9_DEFER) {
    h->handle = c->srv.request_handle; // kept until it is served
    c->srv.request_handle = VX_HANDLE_NONE;
    return P9_HELD;
  }
  p9_ring_drop_request_handle(c);
  return p9_ring_reply(c, &h->e, n) ? P9_ANSWERED : P9_TRY_BROKEN;
}

// Whether an older held request than held[i] (or than a new one, i ==
// nheld) is on fid: if so, it waits behind that one.
static bool p9_ring_behind(const p9_ring_conn *c, uint32_t i, uint32_t fid) {
  if (fid == P9_NOFID) return false;
  for (uint32_t j = 0; j < i; j++)
    if (c->held[j].fid == fid) return true;
  return false;
}

static void p9_ring_unhold(p9_ring_conn *c, uint32_t i) {
  for (uint32_t j = i + 1; j < c->nheld; j++) c->held[j - 1] = c->held[j];
  c->nheld--;
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
// ones first, oldest first, then new ones. P9_MORE if requests are left;
// P9_BROKEN if the client broke the protocol, or sent something too broken
// to answer, and must be dropped.
static p9_drained p9_ring_drain(p9_ring_conn *c) {
  for (uint32_t i = 0; i < c->nheld;) {
    if (p9_ring_behind(c, i, c->held[i].fid)) {
      i++;
      continue;
    }
    p9_tried r = p9_ring_try(c, &c->held[i]);
    if (r == P9_TRY_BROKEN) return P9_BROKEN;
    if (r == P9_ANSWERED)
      p9_ring_unhold(c, i);
    else
      i++;
  }
  for (uint32_t served = 0;; served++) {
    if (served == P9_RING_BUDGET) return P9_MORE;
    if (c->nheld == P9_RING_DEPTH) return P9_DRAINED; // a client past the depth waits for its answers
    p9_held h = {.fid = P9_NOFID};
    vx_status st = vx_ring_consume(&c->ring, &h.e);
    if (st == VX_ERR_SHOULD_WAIT) return P9_DRAINED;
    if (st != VX_OK || h.e.opcode != P9_RING_MSG || h.e.len > sizeof c->req) return P9_BROKEN;
    const uint8_t *p = vx_ring_peer_bytes(&c->ring, h.e.arena_off, h.e.len);
    if (!p) return P9_BROKEN;
    if ((h.e.flags & VX_SQE_HANDLES) && vx_ring_take_handles(c->end, h.e.handle_slot, &h.handle, 1) != 1)
      h.handle = VX_HANDLE_NONE; // dref's VMO, for Treadref and Twriteref
    memcpy(c->req, p, h.e.len);
    p9_msg t;
    if (p9_decode(c->req, h.e.len, &t) != VX_OK) {
      if (h.handle) vx_handle_close(h.handle);
      return P9_BROKEN;
    }
    h.tag = t.tag;
    h.fid = p9_request_fid(&t);
    if (t.type == P9_Tflush) // a held request it names goes unanswered; then Rflush
      for (uint32_t i = 0; i < c->nheld; i++)
        if (c->held[i].tag == t.oldtag) {
          if (c->held[i].handle) vx_handle_close(c->held[i].handle);
          p9_ring_unhold(c, i);
          break;
        }
    if (p9_ring_behind(c, c->nheld, h.fid)) {
      c->held[c->nheld++] = h;
      continue;
    }
    p9_tried r = p9_ring_try(c, &h);
    if (r == P9_TRY_BROKEN) return P9_BROKEN;
    if (r == P9_HELD) c->held[c->nheld++] = h;
  }
}

// Serves the file system on the listen channel until the channel goes away.
// The port is made here unless the file server made it already, to bind its
// own sources first.
static int64_t p9_ring_now(void) { return vx_clock_read(); }

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
  bool listening = true; // the listen channel's peer is there (linger)
  for (;;) {
    bool more = false; // a connection still has requests: no sleeping this time round
    for (uint32_t i = 0; i < s->max_conns; i++) {
      if (!s->conns[i].used) continue;
      p9_drained d = p9_ring_drain(&s->conns[i]);
      if (d == P9_BROKEN) p9_ring_close(&s->conns[i]);
      more = more || d == P9_MORE;
    }
    for (; listening;) {
      alignas(vx_msg_header) uint8_t msg[64];
      vx_handle handle = VX_HANDLE_NONE;
      vx_msg_size size;
      st = vx_channel_read(s->listen, msg, sizeof msg, &handle, 1, &size);
      if (st == VX_ERR_SHOULD_WAIT) break;
      if (st == VX_ERR_PEER_CLOSED && !s->linger) return st;
      if (st == VX_ERR_PEER_CLOSED) {
        listening = false;
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

    if (!listening) { // lingering: until the last connection goes
      bool any = false;
      for (uint32_t i = 0; i < s->max_conns && !any; i++) any = s->conns[i].used;
      if (!any) return VX_ERR_PEER_CLOSED;
    }

    // Arm what is idle, then sleep unless something arrived meanwhile. A
    // connection holding requests waits for an event or its doorbell: a new
    // request, or a Tflush of a held one.
    if (s->again) more = true, s->again = false; // a held request may go on now: once more round
    bool idle = !more;
    for (uint32_t i = 0; i < s->max_conns && idle; i++) {
      p9_ring_conn *c = &s->conns[i];
      if (!c->used) continue;
      int64_t seen = vx_counter_read(c->end);
      if (!vx_ring_prepare_sleep(&c->ring)) {
        idle = false;
      } else if (!c->armed) {
        c->armed = vx_port_bind(s->port, c->end, VX_TRIGGER_COUNTER_GE,
                                p9_conn_key(P9_KEY_CONN_BELL, i, c->gen), (uint64_t)seen + 1) == VX_OK;
      }
    }
    if (idle && listening && !s->listen_armed)
      s->listen_armed = vx_port_bind(s->port, s->listen, VX_TRIGGER_READABLE, P9_KEY_LISTEN, 0) == VX_OK;
    vx_instant deadline = s->tick ? s->tick(s->ctx) : VX_INFINITE;
    if (idle) {
      vx_packet pk[16];
      int64_t n = vx_port_wait(s->port, deadline, 0, pk, 16); // TIMED_OUT: the tick is due
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
        p9_ring_conn *c = slot < s->max_conns ? &s->conns[slot] : nullptr;
        if (!c || !c->used || c->gen != gen) continue; // about a connection that has gone
        if (kind == P9_KEY_CONN_CLOSED)
          p9_ring_close(c);
        else if (kind == P9_KEY_CONN_BELL)
          c->armed = false;
      }
    }
    for (uint32_t i = 0; i < s->max_conns; i++)
      if (s->conns[i].used) vx_ring_end_sleep(&s->conns[i].ring);
  }
}
