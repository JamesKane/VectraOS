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
// A reply that carries a handle (Rmap's VMO) has P9_CQE_HANDLE in flags and
// the ring's handle slot in aux (ring_xfer_handles), which the client takes.
// A request that carries one (dref's VMO) has VX_SQE_HANDLES and handle_slot.
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
enum : uint32_t { P9_CQE_HANDLE = 1 };        // a completion's flags: a handle in slot aux
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
  uint8_t sent;    // the type of the call p9_ring_send sent, for its reply's
  int64_t timeout; // ns: a call not answered in that long ends the connection (0: none)
  uint8_t tbuf[P9_RING_MSIZE], rbuf[P9_RING_MSIZE];
} p9_conn;

// Puts one request on the ring (the connection has at most one outstanding).
static bool p9_ring_put(p9_conn *k, const uint8_t *req, size_t len) {
  uint64_t arena_size;
  uint8_t *arena = vx_ring_arena(&k->ring, &arena_size);
  vx_sqe *e = k->dead || len > arena_size ? nullptr : vx_ring_produce_slot(&k->ring);
  if (!e) {
    k->dead = true;
    return false;
  }
  memcpy(arena, req, len);
  *e = (vx_sqe){.opcode = P9_RING_MSG, .len = (uint32_t)len};
  if (k->c.send_handle) { // dref's VMO, moved to a slot for the server
    int64_t slot = vx_ring_put_handles(k->end, &k->c.send_handle, 1);
    if (slot < 0) vx_handle_close(k->c.send_handle);
    k->c.send_handle = VX_HANDLE_NONE;
    if (slot < 0) return false; // the slots are full: a server not taking them
    e->flags = VX_SQE_HANDLES, e->handle_slot = (uint32_t)slot;
  }
  if (vx_ring_produce(&k->ring)) vx_ring_notify(k->end);
  return true;
}

// Takes the reply if it has come: its length, 0 if not yet, or -1 if the
// connection is broken.
static int64_t p9_ring_take(p9_conn *k, uint8_t *resp, size_t cap) {
  vx_cqe c;
  vx_status st = vx_ring_consume(&k->ring, &c);
  if (st == VX_ERR_SHOULD_WAIT) return 0;
  const uint8_t *p = st == VX_OK && c.result > 0 && (uint64_t)c.result <= cap
                         ? vx_ring_peer_bytes(&k->ring, c.aux2, (uint64_t)c.result)
                         : nullptr;
  if (!p) return -1;
  memcpy(resp, p, (size_t)c.result);
  if (k->c.handle) vx_handle_close(k->c.handle); // one no call took
  k->c.handle = VX_HANDLE_NONE;
  if ((c.flags & P9_CQE_HANDLE) && vx_ring_take_handles(k->end, c.aux, &k->c.handle, 1) != 1)
    k->c.handle = VX_HANDLE_NONE;
  return c.result;
}

static size_t p9_ring_rpc(void *ctx, const uint8_t *req, size_t len, uint8_t *resp, size_t cap) {
  p9_conn *k = ctx;
  if (!p9_ring_put(k, req, len)) return 0;
  vx_instant deadline = k->timeout ? vx_clock_read() + (vx_instant)k->timeout : VX_INFINITE;
  for (;;) {
    int64_t n = p9_ring_take(k, resp, cap);
    if (n > 0) return (size_t)n;
    if (n < 0) break;
    int64_t seen = vx_counter_read(k->end);
    if (vx_ring_prepare_sleep(&k->ring)) {
      vx_packet pk = {};
      vx_port_bind(k->port, k->end, VX_TRIGGER_COUNTER_GE, P9_KEY_BELL, (uint64_t)seen + 1);
      int64_t got = vx_port_wait(k->port, deadline, 0, &pk, 1);
      // An interrupt (a POSIX signal) does not end a call the server is
      // answering: the wait goes on, and its handler runs once the call is
      // done (01 §9). The binding made for this wait may fire later, too.
      if (got == VX_ERR_INTERRUPTED) {
        vx_ring_end_sleep(&k->ring);
        continue;
      }
      if (got != 1 || pk.key == P9_KEY_CLOSED) break;
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
    st = p9c_version(&k->c, P9_RING_MSIZE,
                     P9_EXT_POSIX | P9_EXT_XATTR | P9_EXT_MAP | P9_EXT_DREF); // what the server has of them
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
  if (k->c.handle) vx_handle_close(k->c.handle);
  if (k->end) vx_handle_close(k->end);
  if (k->port) vx_handle_close(k->port);
  *k = (p9_conn){.dead = true};
}

// --- One call at a time, its reply taken later ---
//
// For a reader that waits on many things at once (poll's read-ahead, in the
// musl back end): send a request, then look for its reply, arming a port of
// the caller's to hear when one may have come. Nothing else may use the
// connection while a call is outstanding.

[[maybe_unused]] static vx_status p9_ring_send(p9_conn *k, p9_msg *t) {
  t->tag = k->c.next_tag++ % P9_NOTAG;
  size_t n = p9_encode(t, k->c.tbuf, k->c.bufsize);
  if (!n) return VX_ERR_TOO_SMALL;
  k->sent = t->type;
  return p9_ring_put(k, k->c.tbuf, n) ? VX_OK : VX_ERR_PEER_CLOSED;
}

// The reply to the call sent with tag: OK, with *r decoded (its data in the
// connection's buffer, until the next call); SHOULD_WAIT if it has not come;
// the error an Rerror names; or PEER_CLOSED.
[[maybe_unused]] static vx_status p9_ring_receive(p9_conn *k, uint16_t tag, p9_msg *r) {
  int64_t n = p9_ring_take(k, k->c.rbuf, k->c.bufsize);
  if (n == 0) return VX_ERR_SHOULD_WAIT;
  if (n < 0) {
    k->dead = true;
    return VX_ERR_PEER_CLOSED;
  }
  // One call at a time: anything but its reply (or its error) means the
  // server is confused, and nothing more it says can be matched to a call.
  bool ok = p9_decode(k->c.rbuf, (size_t)n, r) == VX_OK && r->tag == tag;
  if (ok && r->type == P9_Rerror) return p9_error_status(r->ename);
  if (!ok || r->type != k->sent + 1) {
    k->dead = true;
    return VX_ERR_PEER_CLOSED;
  }
  return VX_OK;
}

// Arms port to get `key` once a reply may have come. False when one may
// already have: look again rather than wait. vx_ring_end_sleep after.
[[maybe_unused]] static bool p9_ring_arm(p9_conn *k, vx_handle port, uint64_t key) {
  int64_t seen = vx_counter_read(k->end);
  if (!vx_ring_prepare_sleep(&k->ring)) return false;
  return vx_port_bind(port, k->end, VX_TRIGGER_COUNTER_GE, key, (uint64_t)seen + 1) == VX_OK;
}

// --- dref ---
//
// Treadref and Twriteref (docs/proto/dref.md), here rather than in
// client.c, which is built for the host too: count bytes of the file at
// offset copied into (or from) vmo at roffset by the server, in one message
// whatever the msize; *done how many. The VMO stays the caller's: the
// request carries a duplicate (so it needs DUPLICATE and TRANSFER).
static vx_status p9c_ref(p9_client *c, p9_type type, uint32_t fid, uint64_t offset, vx_handle vmo,
                         uint64_t roffset, uint32_t count, uint32_t *done) {
  if (!(c->extensions & P9_EXT_DREF)) return VX_ERR_UNSUPPORTED;
  vx_status e = vx_handle_dup(vmo, VX_RIGHTS_SAME, &c->send_handle);
  if (e != VX_OK) return e;
  p9_msg t = {.type = type, .fid = fid, .offset = offset, .count = count, .roffset = roffset};
  e = p9c_call(c, &t);
  if (c->send_handle) vx_handle_close(c->send_handle); // never sent
  c->send_handle = VX_HANDLE_NONE;
  if (e == VX_OK) *done = c->reply.count;
  return e;
}

[[maybe_unused]] static vx_status p9c_readref(p9_client *c, uint32_t fid, uint64_t offset, vx_handle vmo,
                                              uint64_t roffset, uint32_t count, uint32_t *done) {
  return p9c_ref(c, P9_Treadref, fid, offset, vmo, roffset, count, done);
}

[[maybe_unused]] static vx_status p9c_writeref(p9_client *c, uint32_t fid, uint64_t offset, vx_handle vmo,
                                               uint64_t roffset, uint32_t count, uint32_t *done) {
  return p9c_ref(c, P9_Twriteref, fid, offset, vmo, roffset, count, done);
}
