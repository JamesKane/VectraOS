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
// This file is the client, which every program has for its console (vx-rt);
// ring_server.c is the server.

#pragma once

#include "../vx-rt/base.c"
#include "../vx-ring/ring.c"
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
  if (st == VX_OK && (st = vx_ring_attach(r, (void *)base, layout.size, client, &P9_RING_PARAMS)) != VX_OK)
    vx_as_unmap(vx_self, base, layout.size); // a ring it would not attach to
  return st;
}

// Lets a ring's memory go from this task's address space.
static void p9_ring_unmap(vx_ring *r) {
  if (r->base) vx_as_unmap(vx_self, (uint64_t)r->base, r->h.size);
  r->base = nullptr;
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
  p9_ring_unmap(&k->ring);
  if (k->end) vx_handle_close(k->end);
  if (k->port) vx_handle_close(k->port);
  *k = (p9_conn){.dead = true};
}
