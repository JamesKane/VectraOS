// vx-9p over a ring: 9px+shm, the local transport (docs/02 §3.2).
//
// Connecting. A server reads a listen channel, which svcd posts as /srv/NAME
// and hands out to clients. A client sends P9_CONNECT there with channel_call;
// the server creates a ring, keeps the server end, and answers with the client
// end and the ring's memory. Each connection is its own ring, so each queue has
// one producer and one consumer, as vx-ring requires.
//
// Messages. One 9P message is one submission: opcode P9_RING_MSG, its bytes at
// arena_off in the client's arena, len bytes long. The reply is one
// completion: result is its length, aux2 its offset in the server's arena.
// Each side copies the other's bytes out once before it decodes them (01
// §4.3), and a peer that names bytes outside its arena, or sends a reply that
// does not fit, is treated as gone. This client has one request in flight;
// pipelining (02 §3.3) changes no wire format, only how the arenas are split.
//
// The server waits on one port for everything: READABLE on the listen channel,
// and for each connection, its doorbell (COUNTER_GE) and its client going
// away (PEER_CLOSED).

#pragma once

#include "../vx-rt/rt.c"
#include "../vx-ring/ring.c"
#include "server.c"
#include "client.c"

enum : uint32_t { P9_CONNECT = 0x3970'6e63 }; // the listen channel's one ordinal: "cnp9"
enum : uint16_t { P9_RING_MSG = 1 };          // the one submission opcode
static constexpr uint32_t P9_RING_MSIZE = 16 * 1024;
static const vx_ring_params P9_RING_PARAMS = {
    .sq_entries = 8,
    .cq_entries = 8,
    .sqe_size = sizeof(vx_sqe),
    .cqe_size = sizeof(vx_cqe),
    .client_arena = P9_RING_MSIZE,
    .server_arena = P9_RING_MSIZE,
};

// Maps a ring's memory into this task and attaches to it as one side.
static vx_status p9_ring_map(vx_handle memory, bool client, vx_ring *r) {
  vx_ring_header layout;
  vx_status st = vx_ring_layout(&P9_RING_PARAMS, &layout);
  uint64_t base = 0;
  if (st == VX_OK) st = vx_as_map(vx_self, memory, 0, layout.size, VX_MAP_WRITE, &base);
  // The mapping stays for the life of the task until as_unmap lands (01 §5).
  if (st == VX_OK) st = vx_ring_attach(r, (void *)base, layout.size, client);
  return st;
}

// --- Client ---

enum : uint64_t { P9_KEY_BELL = 1, P9_KEY_CLOSED = 2 };

typedef struct p9_conn {
  p9_client c;
  vx_ring ring;
  vx_handle end, port;
  bool dead;
  uint8_t tbuf[P9_RING_MSIZE], rbuf[P9_RING_MSIZE];
} p9_conn;

static size_t p9_ring_rpc(void *ctx, const uint8_t *req, size_t len, uint8_t *resp, size_t cap) {
  p9_conn *k = ctx;
  uint64_t arena_size;
  uint8_t *arena = vx_ring_arena(&k->ring, &arena_size);
  vx_sqe *e = k->dead || len > arena_size ? nullptr : vx_ring_produce_slot(&k->ring);
  if (!e) {
    k->dead = true;
    return 0;
  }
  memcpy(arena, req, len);
  *e = (vx_sqe){.opcode = P9_RING_MSG, .len = (uint32_t)len};
  if (vx_ring_produce(&k->ring)) vx_ring_notify(k->end);
  for (;;) {
    vx_cqe c;
    vx_status st = vx_ring_consume(&k->ring, &c);
    if (st == VX_OK) {
      const uint8_t *p = c.result > 0 && (uint64_t)c.result <= cap
                             ? vx_ring_peer_bytes(&k->ring, c.aux2, (uint64_t)c.result)
                             : nullptr;
      if (!p) break;
      memcpy(resp, p, (size_t)c.result);
      return (size_t)c.result;
    }
    if (st != VX_ERR_SHOULD_WAIT) break;
    int64_t seen = vx_counter_read(k->end);
    if (vx_ring_prepare_sleep(&k->ring)) {
      vx_packet pk = {};
      vx_port_bind(k->port, k->end, VX_TRIGGER_COUNTER_GE, P9_KEY_BELL, (uint64_t)seen + 1);
      if (vx_port_wait(k->port, VX_INFINITE, 0, &pk, 1) != 1 || pk.key == P9_KEY_CLOSED) break;
    }
    vx_ring_end_sleep(&k->ring);
  }
  k->dead = true;
  return 0;
}

// Opens a connection through a connector (a listen channel's client end, which
// stays the caller's) and negotiates 9Px. The connection is ready to attach.
[[maybe_unused]] static vx_status p9_ring_connect(vx_handle connector, p9_conn *k) {
  *k = (p9_conn){};
  vx_msg_header req = {.ordinal = P9_CONNECT}, rep;
  vx_handle got[2] = {};
  vx_call call = {.wr_bytes = &req,
                  .wr_len = sizeof req,
                  .rd_bytes = &rep,
                  .rd_cap = sizeof rep,
                  .rd_handles = got,
                  .rd_count_cap = 2};
  vx_status st = vx_channel_call(connector, &call, vx_clock_read() + 5'000'000'000);
  if (st == VX_OK && call.actual.handles != 2) st = VX_ERR_INVALID;
  if (st == VX_OK) st = p9_ring_map(got[1], true, &k->ring);
  if (got[1]) vx_handle_close(got[1]); // the mapping keeps the memory
  k->end = got[0];
  if (st == VX_OK) st = vx_port_create(0, &k->port);
  if (st == VX_OK) st = vx_port_bind(k->port, k->end, VX_TRIGGER_PEER_CLOSED, P9_KEY_CLOSED, 0);
  if (st == VX_OK) {
    k->c =
        (p9_client){.rpc = p9_ring_rpc, .ctx = k, .tbuf = k->tbuf, .rbuf = k->rbuf, .bufsize = P9_RING_MSIZE};
    st = p9c_version(&k->c, P9_RING_MSIZE, 0);
  }
  if (st != VX_OK) {
    if (k->end) vx_handle_close(k->end);
    if (k->port) vx_handle_close(k->port);
    *k = (p9_conn){.dead = true};
  }
  return st;
}

[[maybe_unused]] static void p9_ring_disconnect(p9_conn *k) {
  if (k->end) vx_handle_close(k->end);
  if (k->port) vx_handle_close(k->port);
  *k = (p9_conn){.dead = true};
}

// --- Server ---

static constexpr uint32_t P9_RING_MAX_CONNS = 8;

// A connection's port keys carry its slot and the slot's generation, so a
// packet from a binding on a connection that has gone is never taken for one
// about its slot's next connection.
enum : uint64_t { P9_KEY_LISTEN = 0, P9_KEY_CONN_BELL = 1, P9_KEY_CONN_CLOSED = 2 };

static uint64_t p9_conn_key(uint64_t kind, uint32_t slot, uint32_t gen) {
  return kind << 40 | (uint64_t)gen << 8 | slot;
}

typedef struct p9_ring_conn {
  bool used, armed;
  uint32_t gen;
  vx_ring ring;
  vx_handle end;
  p9_server srv;
  uint8_t req[P9_RING_MSIZE], resp[P9_RING_MSIZE];
} p9_ring_conn;

typedef struct p9_ring_server {
  p9_fs fs;
  uint32_t supported; // 9Px extensions
  vx_str name;        // for messages
  vx_handle listen, port;
  bool listen_armed;
  p9_ring_conn conns[P9_RING_MAX_CONNS];
} p9_ring_server;

static void p9_ring_close(p9_ring_conn *c) {
  for (uint32_t i = 0; i < P9_MAX_FIDS; i++)
    if (c->srv.fids[i].used) p9_fid_drop(&c->srv, &c->srv.fids[i]);
  vx_handle_close(c->end);
  c->used = false;
}

// Answers one P9_CONNECT: a new ring, its client end and memory in the reply.
static void p9_ring_accept(p9_ring_server *s, const vx_msg_header *req) {
  vx_msg_header rep = {.txid = req->txid, .ordinal = P9_CONNECT};
  uint32_t i = 0;
  while (i < P9_RING_MAX_CONNS && s->conns[i].used) i++;
  vx_ring_handles h = {};
  vx_status st = i < P9_RING_MAX_CONNS ? vx_ring_create(&P9_RING_PARAMS, &h) : VX_ERR_NO_MEMORY;
  p9_ring_conn *c = i < P9_RING_MAX_CONNS ? &s->conns[i] : nullptr;
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
    c->end = h.server;
    c->srv = (p9_server){.fs = s->fs, .max_msize = P9_RING_MSIZE, .supported = s->supported};
    return;
  }
  vx_handle_close(h.client);
  vx_handle_close(h.server);
  vx_handle_close(h.memory);
  rep.flags = 1; // refused: a reply without handles
  vx_channel_write(s->listen, &rep, sizeof rep, nullptr, 0);
}

// Serves every request waiting on one connection. False if the client broke
// the protocol, or sent something too broken to answer, and must be dropped.
static bool p9_ring_drain(p9_ring_conn *c) {
  for (;;) {
    vx_sqe e;
    vx_status st = vx_ring_consume(&c->ring, &e);
    if (st == VX_ERR_SHOULD_WAIT) return true;
    if (st != VX_OK || e.opcode != P9_RING_MSG || e.len > sizeof c->req) return false;
    const uint8_t *p = vx_ring_peer_bytes(&c->ring, e.arena_off, e.len);
    if (!p) return false;
    memcpy(c->req, p, e.len);
    size_t n = p9_serve(&c->srv, c->req, e.len, c->resp, sizeof c->resp);
    uint64_t arena_size;
    uint8_t *arena = vx_ring_arena(&c->ring, &arena_size);
    vx_cqe *out = n && n <= arena_size ? vx_ring_produce_slot(&c->ring) : nullptr;
    if (!out) return false; // unanswerable, or a client that does not drain its completions
    memcpy(arena, c->resp, n);
    *out = (vx_cqe){.user_data = e.user_data, .result = (int64_t)n};
    if (vx_ring_produce(&c->ring)) vx_ring_notify(c->end);
  }
}

// Serves the file system on the listen channel until the channel goes away.
[[maybe_unused]] static vx_status p9_ring_serve(p9_ring_server *s) {
  vx_status st = vx_port_create(0, &s->port);
  if (st != VX_OK) return st;
  for (;;) {
    for (uint32_t i = 0; i < P9_RING_MAX_CONNS; i++)
      if (s->conns[i].used && !p9_ring_drain(&s->conns[i])) p9_ring_close(&s->conns[i]);
    for (;;) {
      vx_msg_header req;
      vx_msg_size size;
      st = vx_channel_read(s->listen, &req, sizeof req, nullptr, 0, &size);
      if (st == VX_ERR_SHOULD_WAIT) break;
      if (st == VX_ERR_PEER_CLOSED) return st;
      if (st == VX_OK && size.bytes == sizeof req && req.ordinal == P9_CONNECT) p9_ring_accept(s, &req);
      // Anything else, including a message too big for us (TOO_SMALL), is dropped.
      if (st == VX_ERR_TOO_SMALL) {
        static uint8_t junk[VX_CHANNEL_MAX_BYTES];
        static vx_handle junk_handles[VX_CHANNEL_MAX_HANDLES];
        if (vx_channel_read(s->listen, junk, sizeof junk, junk_handles, VX_CHANNEL_MAX_HANDLES, &size) ==
            VX_OK)
          for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(junk_handles[i]);
      }
    }

    // Arm what is idle, then sleep unless something arrived meanwhile.
    bool idle = true;
    for (uint32_t i = 0; i < P9_RING_MAX_CONNS && idle; i++) {
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
    if (idle && !s->listen_armed)
      s->listen_armed = vx_port_bind(s->port, s->listen, VX_TRIGGER_READABLE, P9_KEY_LISTEN, 0) == VX_OK;
    if (idle) {
      vx_packet pk[16];
      int64_t n = vx_port_wait(s->port, VX_INFINITE, 0, pk, 16);
      for (int64_t j = 0; j < n; j++) {
        uint64_t key = pk[j].key, kind = key >> 40;
        uint32_t slot = key & 0xff, gen = (uint32_t)(key >> 8);
        if (key == P9_KEY_LISTEN) {
          s->listen_armed = false;
          continue;
        }
        p9_ring_conn *c = slot < P9_RING_MAX_CONNS ? &s->conns[slot] : nullptr;
        if (!c || !c->used || c->gen != gen) continue; // about a connection that has gone
        if (kind == P9_KEY_CONN_CLOSED)
          p9_ring_close(c);
        else if (kind == P9_KEY_CONN_BELL)
          c->armed = false;
      }
    }
    for (uint32_t i = 0; i < P9_RING_MAX_CONNS; i++)
      if (s->conns[i].used) vx_ring_end_sleep(&s->conns[i].ring);
  }
}
