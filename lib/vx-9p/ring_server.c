// vx-9p over a ring, the server side (ring.c describes the transport).
//
// The server waits on one port for everything: READABLE on the listen channel;
// for each connection, its doorbell (COUNTER_GE) and its client going away
// (PEER_CLOSED); and whatever the file server binds there itself, such as a
// driver's Irq, with keys from P9_KEY_USER up, which go to its event hook.
//
// A request the file server cannot do yet (p9_serve's P9_DEFER) is held, and
// the connection takes nothing more until it completes: it is served again
// after every event, after every tick, and when the file server says
// something it did may let it go on (`again`): a request on another
// connection, say, that queued what the held one waits for. (Holding one request per connection is what a
// synchronous client needs; Tflush of a held request comes with pipelining.)

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

typedef struct p9_ring_conn {
  bool used, armed;
  bool holding; // req holds a deferred request (held_len bytes), answered with held_user_data
  uint32_t gen, held_len;
  uint64_t held_user_data;
  vx_ring ring;
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
  // Its connections: these, unless the file server gives more of its own
  // (procfs, which holds one per process) before serving. At most 256.
  p9_ring_conn *conns;
  uint32_t max_conns;
  p9_ring_conn default_conns[P9_RING_MAX_CONNS];
  p9_shared shared; // the open files and locks all its connections share (posix)
} p9_ring_server;

static void p9_ring_close(p9_ring_conn *c) {
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
    c->armed = c->holding = false;
    c->end = h.server;
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

// Serves the requests waiting on one connection, up to its budget: first one
// it holds, if it can be served now. P9_MORE if requests are left; P9_BROKEN
// if the client broke the protocol, or sent something too broken to answer,
// and must be dropped.
static p9_drained p9_ring_drain(p9_ring_conn *c) {
  for (uint32_t served = 0;; served++) {
    if (served == P9_RING_BUDGET) return P9_MORE;
    vx_sqe e = {.user_data = c->held_user_data, .len = c->held_len};
    if (!c->holding) {
      vx_status st = vx_ring_consume(&c->ring, &e);
      if (st == VX_ERR_SHOULD_WAIT) return P9_DRAINED;
      if (st != VX_OK || e.opcode != P9_RING_MSG || e.len > sizeof c->req) return P9_BROKEN;
      const uint8_t *p = vx_ring_peer_bytes(&c->ring, e.arena_off, e.len);
      if (!p) return P9_BROKEN;
      memcpy(c->req, p, e.len);
    }
    size_t n = p9_serve(&c->srv, c->req, e.len, c->resp, sizeof c->resp);
    c->holding = n == P9_DEFER;
    if (c->holding) {
      c->held_len = e.len;
      c->held_user_data = e.user_data;
      return P9_DRAINED;
    }
    uint64_t arena_size;
    uint8_t *arena = vx_ring_arena(&c->ring, &arena_size);
    vx_cqe *out = n && n <= arena_size ? vx_ring_produce_slot(&c->ring) : nullptr;
    if (!out) return P9_BROKEN; // unanswerable, or a client that does not drain its completions
    memcpy(arena, c->resp, n);
    *out = (vx_cqe){.user_data = e.user_data, .result = (int64_t)n};
    if (vx_ring_produce(&c->ring)) vx_ring_notify(c->end);
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
  for (;;) {
    bool more = false; // a connection still has requests: no sleeping this time round
    for (uint32_t i = 0; i < s->max_conns; i++) {
      if (!s->conns[i].used) continue;
      p9_drained d = p9_ring_drain(&s->conns[i]);
      if (d == P9_BROKEN) p9_ring_close(&s->conns[i]);
      more = more || d == P9_MORE;
    }
    for (;;) {
      alignas(vx_msg_header) uint8_t msg[64];
      vx_handle handle = VX_HANDLE_NONE;
      vx_msg_size size;
      st = vx_channel_read(s->listen, msg, sizeof msg, &handle, 1, &size);
      if (st == VX_ERR_SHOULD_WAIT) break;
      if (st == VX_ERR_PEER_CLOSED) return st;
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

    // Arm what is idle, then sleep unless something arrived meanwhile. A
    // connection holding a request waits for an event, not its doorbell.
    if (s->again) more = true, s->again = false; // a held request may go on now: once more round
    bool idle = !more;
    for (uint32_t i = 0; i < s->max_conns && idle; i++) {
      p9_ring_conn *c = &s->conns[i];
      if (!c->used || c->holding) continue;
      int64_t seen = vx_counter_read(c->end);
      if (!vx_ring_prepare_sleep(&c->ring)) {
        idle = false;
      } else if (!c->armed) {
        c->armed = vx_port_bind(s->port, c->end, VX_TRIGGER_COUNTER_GE,
                                p9_conn_key(P9_KEY_CONN_BELL, i, c->gen), (uint64_t)seen + 1) == VX_OK;
      }
    }
    if (idle && !s->listen_armed)
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
