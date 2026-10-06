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
//
// Pipelining (M6 step 6d4a): a connection has several requests in flight,
// and the server answers them in any order. The client's region for a
// request stays its until the reply comes (or, for a flushed request, the
// Rflush), as the server may read it again while it holds the request: so
// its arena is chunks taken and given back in any order (p9_chunks), and a
// request held for long pins only its own. The server's region for a reply
// is freed once the client has consumed that completion, which is in order,
// so its arena is allotted in order (p9_arena). So each side knows, without
// asking, what of its arena is free.
// A reply that carries a handle (Rmap's VMO) has P9_CQE_HANDLE in flags and
// the ring's handle slot in aux (ring_xfer_handles), which the client takes.
// A request that carries one (dref's VMO) has VX_SQE_HANDLES and handle_slot.
// Each side copies the other's bytes out before it decodes them (01 §4.3),
// and a peer that names bytes outside its arena, or sends a reply that does
// not fit, is treated as gone.
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
static constexpr uint32_t P9_RING_DEPTH = 8; // requests in flight on a connection, at most
static const vx_ring_params P9_RING_PARAMS = {
    .sq_entries = P9_RING_DEPTH,
    .cq_entries = P9_RING_DEPTH,
    .sqe_size = sizeof(vx_sqe),
    .cqe_size = sizeof(vx_cqe),
    .client_arena = 2ull * P9_RING_MSIZE, // two whole messages, more smaller ones; a call waits for room
    .server_arena =
        3ull * P9_RING_MSIZE, // the client's calls reserve their replies' room, an msize short of it
};

// --- The client's arena: chunks ---
//
// 64 chunks, a bit each. A request of one chunk (most: a read, a walk, a
// clunk, the kind a server holds) is placed from the top down, and a longer
// one (a write's) first fit from the bottom up, so the small ones a server
// holds for long leave the long run a write needs.
typedef struct p9_chunks {
  uint64_t size; // the arena's; a chunk is size / 64
  uint64_t used; // bit i: chunk i taken
} p9_chunks;

// The offset of len bytes taken, or -1 if there is no run that long free.
static int64_t p9_chunks_take(p9_chunks *a, uint64_t len) {
  uint64_t chunk = a->size / 64, n = (len + chunk - 1) / chunk;
  if (!len || n > 64) return -1;
  if (n == 1) {
    for (int i = 63; i >= 0; i--)
      if (!(a->used & 1ull << i)) return a->used |= 1ull << i, (int64_t)((uint64_t)i * chunk);
    return -1;
  }
  uint64_t mask = n == 64 ? UINT64_MAX : (1ull << n) - 1;
  for (uint64_t i = 0; i + n <= 64; i++)
    if (!(a->used & mask << i)) return a->used |= mask << i, (int64_t)(i * chunk);
  return -1;
}

// Gives back the len bytes at off that p9_chunks_take gave.
static void p9_chunks_give(p9_chunks *a, uint64_t off, uint64_t len) {
  uint64_t chunk = a->size / 64, n = (len + chunk - 1) / chunk, first = off / chunk;
  uint64_t mask = n == 64 ? UINT64_MAX : (1ull << n) - 1;
  a->used &= ~(mask << first);
}

// --- The server's arena, allotted in order ---
//
// Regions are taken in order, each contiguous (one that would run past the
// end starts again at 0, the rest of the end going with it), and given back
// in any order; the space comes free as the oldest regions are given back.
// Positions count bytes for ever; a position's offset is it modulo the size.
typedef struct p9_arena {
  uint64_t size;
  uint64_t head, tail; // [head, tail): taken
  uint32_t first, count;
  struct {
    uint64_t end;
    bool done;
  } regions[2 * P9_RING_DEPTH];
} p9_arena;

// A region of len bytes: its index for p9_arena_free, and its offset in
// *off; -1 if there is no room now (or no region left).
[[maybe_unused]] static int p9_arena_alloc(p9_arena *a, uint64_t len, uint64_t *off) {
  constexpr uint32_t cap = 2 * P9_RING_DEPTH;
  if (!len || len > a->size || a->count == cap) return -1;
  uint64_t pos = a->tail, at = pos % a->size;
  if (at + len > a->size) pos += a->size - at, at = 0; // to the start, the end's rest with it
  if (pos + len - a->head > a->size) return -1;
  uint32_t i = (a->first + a->count++) % cap;
  a->regions[i].end = pos + len;
  a->regions[i].done = false;
  a->tail = pos + len;
  *off = at;
  return (int)i;
}

// Gives region i back.
[[maybe_unused]] static void p9_arena_free(p9_arena *a, int i) {
  constexpr uint32_t cap = 2 * P9_RING_DEPTH;
  a->regions[i].done = true;
  while (a->count && a->regions[a->first].done) {
    a->head = a->regions[a->first].end;
    a->first = (a->first + 1) % cap;
    a->count--;
  }
}

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
//
// Several threads share a connection (M6 step 6d4a), as 9front's mount
// driver shares a mount (devmnt.c's mountio and mountmux). A call takes a
// slot: its own buffer, a tag no call in flight has, and its share of both
// arenas. Whoever waits first leads: it reads every completion and hands
// each reply to its slot, waking that slot's thread; the others sleep on
// their slots, and when the leader's own call is done, a waiting one leads
// next. One slot is kept for Tflush, so a call can always be flushed.
//
// The server's arena is never overrun: each call reserves room for the
// largest reply its request can have (a read's count, an msize for a stat,
// 512 bytes for the rest, which an Rerror's text fits), and the reservation
// goes back as its reply is taken. The reservations stay an msize short of
// the arena: replies are placed in order, and the one that would run past
// its end starts again at 0, leaving the end's rest unused (less than an
// msize, once between the oldest reply and the newest), so the replies the
// server may be holding always fit. A call that finds no room waits for a
// reply to make some.
//
// A call interrupted (a note, if the connection's `interrupted` says the
// caller wants to hear of it) or past its timeout is flushed: Tflush with its
// tag, and then its reply if that came first (it is answered after all), or
// INTERRUPTED or TIMED_OUT. Its tag and its arena stay its own until then,
// so nothing the server still has is reused. No Rflush within the timeout
// ends the connection.

enum : uint64_t { P9_KEY_BELL = 1, P9_KEY_CLOSED = 2, P9_KEY_POKE = 3 };

// A program's own say in how calls wait, on every connection (the musl
// back end's, M6 step 6d4b; unset elsewhere):
//   - flush_wanted: an interrupted call is flushed if it says so (a
//     connection's own `interrupted` comes first);
//   - waiting: what the thread is about to sleep on (a port, or a futex
//     word), and (0, nullptr) after, so a note handler that runs just
//     before the sleep can end it (a P9_KEY_POKE packet, or the word moved).
static bool (*p9_ring_flush_wanted)(void);
static void (*p9_ring_waiting)(vx_handle port, _Atomic uint32_t *word);

typedef enum p9_slot_state : uint32_t {
  P9_SLOT_FREE,
  P9_SLOT_TAKEN,
  P9_SLOT_SENT,
  P9_SLOT_DONE
} p9_slot_state;

typedef struct p9_slot {
  p9_xfer x;              // first: the transport finds its slot from it
  uint8_t *buf;           // P9_RING_MSIZE bytes: the request, then the reply; mapped at its first call
  _Atomic uint32_t state; // a p9_slot_state
  uint32_t gen;           // with the slot's index, the request's user_data
  uint64_t at, len;       // the request's bytes in the client's arena; len 0: none
  uint64_t reserve;       // its share of the server's arena
  int64_t result;         // the reply's length, or a negative vx_status
  // p9_ring_send's call (6d4d1): its reply waits for p9_ring_receive, and its
  // caller's port gets notify_key when it comes.
  bool async;
  uint8_t sent; // its type, for its reply's
  vx_handle notify;
  uint64_t notify_key;
} p9_slot;

typedef struct p9_conn {
  p9_client c;
  vx_ring ring;
  vx_handle end, port;
  bool dead;
  int64_t timeout; // ns: a call not answered in that long is flushed (0: none)
  // When a wait is interrupted (a note): whether the caller wants the call
  // flushed, and INTERRUPTED. Without it the call goes on (01 §9).
  bool (*interrupted)(void *ctx);
  void *interrupted_ctx;
  vx_mutex lock; // the slots, tags and arenas, producing, and who leads
  bool leading;  // a thread reads completions for everyone
  uint16_t next_tag;
  uint64_t budget;          // the server's arena, reserved by calls in flight
  _Atomic uint32_t freed;   // a futex: changes when a slot comes free
  _Atomic uint32_t replies; // a futex: changes with each reply taken, and as a leader stops
  p9_chunks arena;          // the client's
  p9_slot slots[P9_RING_DEPTH];
} p9_conn;

// The most of the server's arena a reply to this request can take.
static uint64_t p9_reply_max(const uint8_t *req, size_t len, uint32_t msize) {
  constexpr uint64_t small = 512;
  if (len < 7) return small;
  switch (req[4]) {
  case P9_Tread: {
    uint64_t count = len >= 23 ? (uint64_t)req[19] | (uint64_t)req[20] << 8 | (uint64_t)req[21] << 16 |
                                     (uint64_t)req[22] << 24
                               : msize;
    return count + 11 > small ? count + 11 : small;
  }
  case P9_Tstat:
  case P9_Treadlink:
  case P9_Tgetlock: return msize;
  default: return small;
  }
}

// Ends the connection: every call in flight is answered PEER_CLOSED. Under
// the lock.
static void p9_ring_kill(p9_conn *k) {
  k->dead = true;
  for (uint32_t i = 0; i < P9_RING_DEPTH; i++) {
    p9_slot *s = &k->slots[i];
    if (atomic_load(&s->state) != P9_SLOT_SENT) continue;
    s->result = VX_ERR_PEER_CLOSED;
    atomic_store(&s->state, P9_SLOT_DONE);
  }
  atomic_fetch_add(&k->freed, 1);
  vx_futex_wake(&k->freed, UINT32_MAX);
  atomic_fetch_add(&k->replies, 1);
  vx_futex_wake(&k->replies, UINT32_MAX);
}

// A free slot, its tag chosen, its buffer mapped; waits for one. flush: the
// slot kept for Tflush may be taken. nullptr once the connection is gone.
static p9_slot *p9_ring_slot_take(p9_conn *k, bool version, bool flush) {
  for (;;) {
    vx_mutex_lock(&k->lock);
    if (k->dead) {
      vx_mutex_unlock(&k->lock);
      return nullptr;
    }
    uint32_t used = 0;
    p9_slot *s = nullptr;
    for (uint32_t i = 0; i < P9_RING_DEPTH; i++) {
      if (atomic_load(&k->slots[i].state) != P9_SLOT_FREE)
        used++;
      else if (!s)
        s = &k->slots[i];
    }
    if (s && used < (flush ? P9_RING_DEPTH : P9_RING_DEPTH - 1)) {
      uint16_t tag = P9_NOTAG;
      while (!version) { // the next not in flight, rotating, as a just-freed tag waits its turn
        tag = k->next_tag++ % P9_NOTAG;
        bool taken = false;
        for (uint32_t i = 0; i < P9_RING_DEPTH && !taken; i++)
          taken = atomic_load(&k->slots[i].state) != P9_SLOT_FREE && k->slots[i].x.tag == tag;
        if (!taken) break;
      }
      if (!s->buf) {
        vx_handle vmo;
        uint64_t at = 0;
        if (vx_vmo_create(P9_RING_MSIZE, 0, &vmo) == VX_OK) {
          if (vx_as_map(vx_self, vmo, 0, P9_RING_MSIZE, VX_MAP_WRITE, &at) != VX_OK) at = 0;
          vx_handle_close(vmo);
        }
        s->buf = (uint8_t *)at;
      }
      if (s->buf) {
        atomic_store(&s->state, P9_SLOT_TAKEN);
        s->gen++;
        s->len = 0;
        s->reserve = 0;
        s->x = (p9_xfer){.req = s->buf, .resp = s->buf, .cap = P9_RING_MSIZE, .tag = tag};
        s->async = false, s->notify = VX_HANDLE_NONE;
      }
      vx_mutex_unlock(&k->lock);
      return s->buf ? s : nullptr;
    }
    uint32_t seen = atomic_load(&k->freed);
    vx_mutex_unlock(&k->lock);
    vx_futex_wait(&k->freed, seen, VX_INFINITE);
  }
}

// Gives a slot back, and its handles. Its arena went back with its reply.
static void p9_ring_slot_give(p9_conn *k, p9_slot *s) {
  if (s->x.handle) vx_handle_close(s->x.handle); // one no call took
  if (s->x.send_handle) vx_handle_close(s->x.send_handle);
  s->x.handle = s->x.send_handle = VX_HANDLE_NONE;
  vx_mutex_lock(&k->lock);
  atomic_store(&s->state, P9_SLOT_FREE);
  atomic_fetch_add(&k->freed, 1);
  vx_mutex_unlock(&k->lock);
  vx_futex_wake(&k->freed, UINT32_MAX);
}

// A completion, handed to its slot. False if the server broke the protocol.
static bool p9_ring_deliver(p9_conn *k, const vx_cqe *c) {
  uint32_t i = (uint32_t)(c->user_data & 0xff), gen = (uint32_t)(c->user_data >> 8);
  vx_mutex_lock(&k->lock);
  p9_slot *s = i < P9_RING_DEPTH ? &k->slots[i] : nullptr;
  const uint8_t *p = s && atomic_load(&s->state) == P9_SLOT_SENT && s->gen == gen && c->result > 0 &&
                             (uint64_t)c->result <= P9_RING_MSIZE
                         ? vx_ring_peer_bytes(&k->ring, c->aux2, (uint64_t)c->result)
                         : nullptr;
  if (!p) {
    vx_mutex_unlock(&k->lock);
    return false;
  }
  memcpy(s->buf, p, (size_t)c->result);
  if ((c->flags & P9_CQE_HANDLE) && vx_ring_take_handles(k->end, c->aux, &s->x.handle, 1) != 1)
    s->x.handle = VX_HANDLE_NONE;
  p9_chunks_give(&k->arena, s->at, s->len);
  s->len = 0;
  k->budget -= s->reserve;
  s->reserve = 0;
  s->result = c->result;
  atomic_store(&s->state, P9_SLOT_DONE);
  atomic_fetch_add(&k->replies, 1);
  vx_handle notify = s->async ? s->notify : VX_HANDLE_NONE;
  uint64_t key = s->notify_key;
  vx_mutex_unlock(&k->lock);
  vx_futex_wake(&k->replies, UINT32_MAX);
  if (notify) vx_port_post(notify, &(vx_packet){.key = key}); // p9_ring_send's caller: its reply is here
  return true;
}

// Whether the wait is over: s done, or (s nullptr) a reply taken since `any`.
static bool p9_ring_waited(const p9_conn *k, p9_slot *s, uint32_t any) {
  return s ? atomic_load(&s->state) == P9_SLOT_DONE : atomic_load(&k->replies) != any;
}

// Whether the caller of an interrupted call wants it flushed.
static bool p9_ring_wants_flush(const p9_conn *k) {
  if (k->interrupted) return k->interrupted(k->interrupted_ctx);
  return p9_ring_flush_wanted && p9_ring_flush_wanted();
}

// Before a sleep: whether a signal already came that wants the call flushed
// (the program's hook, which looks at what is pending; a connection's own
// is asked only when a wait is interrupted).
static bool p9_ring_flush_due(void) { return p9_ring_flush_wanted && p9_ring_flush_wanted(); }

static void p9_ring_will_wait(vx_handle port, _Atomic uint32_t *word) {
  if (p9_ring_waiting) p9_ring_waiting(port, word);
}

// Leads: reads every completion, until the wait is over. INTERRUPTED (only
// with hear), TIMED_OUT, PEER_CLOSED.
static vx_status p9_ring_lead(p9_conn *k, p9_slot *s, uint32_t any, vx_instant deadline, bool hear) {
  for (;;) {
    for (;;) {
      vx_cqe c;
      vx_status st = vx_ring_consume(&k->ring, &c);
      if (st == VX_ERR_SHOULD_WAIT) break;
      if (st != VX_OK || !p9_ring_deliver(k, &c)) return VX_ERR_PEER_CLOSED;
    }
    if (p9_ring_waited(k, s, any)) return VX_OK;
    if (hear && p9_ring_flush_due()) return VX_ERR_INTERRUPTED; // one that came before the sleep
    int64_t seen = vx_counter_read(k->end);
    if (!vx_ring_prepare_sleep(&k->ring)) continue;
    vx_packet pk = {};
    vx_port_bind(k->port, k->end, VX_TRIGGER_COUNTER_GE, P9_KEY_BELL, (uint64_t)seen + 1);
    p9_ring_will_wait(k->port, nullptr);
    int64_t got = vx_port_wait(k->port, deadline, 0, &pk, 1);
    p9_ring_will_wait(VX_HANDLE_NONE, nullptr);
    vx_ring_end_sleep(&k->ring); // the binding made for this wait may fire later too
    if (got == VX_ERR_INTERRUPTED || (got == 1 && pk.key == P9_KEY_POKE)) {
      if (hear && p9_ring_wants_flush(k)) return VX_ERR_INTERRUPTED;
      continue;
    }
    if (got == VX_ERR_TIMED_OUT) return VX_ERR_TIMED_OUT;
    if (got != 1 || pk.key == P9_KEY_CLOSED) return VX_ERR_PEER_CLOSED;
  }
}

// Waits for slot s's reply (s nullptr: for any reply after `any`), leading
// if no one does. OK, PEER_CLOSED, TIMED_OUT, or INTERRUPTED (only with hear).
static vx_status p9_ring_wait(p9_conn *k, p9_slot *s, uint32_t any, vx_instant deadline, bool hear) {
  for (;;) {
    vx_mutex_lock(&k->lock);
    if (p9_ring_waited(k, s, any)) {
      vx_mutex_unlock(&k->lock);
      return VX_OK;
    }
    if (k->dead) {
      vx_mutex_unlock(&k->lock);
      return VX_ERR_PEER_CLOSED;
    }
    if (!k->leading) {
      k->leading = true;
      vx_mutex_unlock(&k->lock);
      vx_status st = p9_ring_lead(k, s, any, deadline, hear);
      vx_mutex_lock(&k->lock);
      k->leading = false;
      if (st == VX_ERR_PEER_CLOSED) p9_ring_kill(k);
      atomic_fetch_add(&k->replies, 1); // the next to wait leads: every waiter looks again
      vx_futex_wake(&k->replies, UINT32_MAX);
      for (uint32_t i = 0; i < P9_RING_DEPTH; i++) { // and p9_ring_send's callers, to arm their own ports
        const p9_slot *a = &k->slots[i];
        if (a->async && a->notify && atomic_load(&a->state) == P9_SLOT_SENT)
          vx_port_post(a->notify, &(vx_packet){.key = a->notify_key});
      }
      vx_mutex_unlock(&k->lock);
      if (st != VX_OK) return st;
      continue;
    }
    // Followers sleep on the count of replies, which also moves when the
    // leader stops: one taken between the look and the sleep ends the sleep.
    uint32_t value = atomic_load(&k->replies);
    vx_mutex_unlock(&k->lock);
    if (hear && p9_ring_flush_due()) return VX_ERR_INTERRUPTED; // one that came before the sleep
    p9_ring_will_wait(VX_HANDLE_NONE, &k->replies);
    vx_status w = vx_futex_wait(&k->replies, value, deadline);
    p9_ring_will_wait(VX_HANDLE_NONE, nullptr);
    if (w == VX_ERR_TIMED_OUT) return VX_ERR_TIMED_OUT;
    if (w == VX_ERR_INTERRUPTED && hear && p9_ring_wants_flush(k)) return VX_ERR_INTERRUPTED;
    if (w == VX_ERR_BAD_STATE && hear && p9_ring_flush_due()) return VX_ERR_INTERRUPTED; // a poke
  }
}

// Puts slot s's request (len bytes in its buffer) on the ring, once there is
// room for it and its reply. OK, or why not.
static vx_status p9_ring_put(p9_conn *k, p9_slot *s, size_t len, vx_instant deadline) {
  uint64_t arena_size;
  uint8_t *arena = vx_ring_arena(&k->ring, &arena_size);
  uint64_t server_size = k->ring.h.server_arena_size;
  uint64_t reserve = p9_reply_max(s->buf, len, k->c.msize ? k->c.msize : P9_RING_MSIZE);
  for (;;) {
    vx_mutex_lock(&k->lock);
    if (k->dead) {
      vx_mutex_unlock(&k->lock);
      return VX_ERR_PEER_CLOSED;
    }
    int64_t at = k->budget + reserve <= server_size - P9_RING_MSIZE ? p9_chunks_take(&k->arena, len) : -1;
    if (at >= 0) {
      uint64_t off = (uint64_t)at;
      vx_sqe *e = vx_ring_produce_slot(&k->ring);
      if (!e) { // the server took none of the depth's submissions: broken
        p9_chunks_give(&k->arena, off, len);
        p9_ring_kill(k);
        vx_mutex_unlock(&k->lock);
        return VX_ERR_PEER_CLOSED;
      }
      memcpy(arena + off, s->buf, len);
      *e = (vx_sqe){.opcode = P9_RING_MSG,
                    .len = (uint32_t)len,
                    .arena_off = off,
                    .user_data = (uint64_t)(s - k->slots) | (uint64_t)s->gen << 8};
      if (s->x.send_handle) { // dref's VMO, moved to a slot for the server
        int64_t slot = vx_ring_put_handles(k->end, &s->x.send_handle, 1);
        if (slot < 0) vx_handle_close(s->x.send_handle);
        s->x.send_handle = VX_HANDLE_NONE;
        if (slot >= 0) e->flags = VX_SQE_HANDLES, e->handle_slot = (uint32_t)slot;
      }
      s->at = off, s->len = len;
      s->reserve = reserve;
      k->budget += reserve;
      atomic_store(&s->state, P9_SLOT_SENT);
      if (vx_ring_produce(&k->ring)) vx_ring_notify(k->end);
      vx_mutex_unlock(&k->lock);
      return VX_OK;
    }
    uint32_t any = atomic_load(&k->replies);
    vx_mutex_unlock(&k->lock);
    vx_status st = p9_ring_wait(k, nullptr, any, deadline, false); // a reply makes room
    if (st != VX_OK) return st;
  }
}

// Flushes slot s's call, which `why` ended (INTERRUPTED, TIMED_OUT): its
// reply's length if it came after all, else -why.
static int64_t p9_ring_flush(p9_conn *k, p9_slot *s, vx_status why) {
  p9_slot *f = p9_ring_slot_take(k, false, true);
  if (!f) return VX_ERR_PEER_CLOSED;
  p9_msg t = {.type = P9_Tflush, .tag = f->x.tag, .oldtag = s->x.tag};
  size_t n = p9_encode(&t, f->buf, P9_RING_MSIZE);
  vx_instant deadline = vx_clock_read() + (k->timeout ? k->timeout : 5'000'000'000);
  vx_status st = p9_ring_put(k, f, n, deadline);
  if (st == VX_OK) st = p9_ring_wait(k, f, 0, deadline, false);
  if (st == VX_ERR_TIMED_OUT) { // no Rflush: a server that answers nothing more
    vx_mutex_lock(&k->lock);
    p9_ring_kill(k);
    vx_mutex_unlock(&k->lock);
  }
  p9_ring_slot_give(k, f);
  if (atomic_load(&s->state) == P9_SLOT_DONE) return s->result; // answered first, or the connection went
  if (st != VX_OK) return VX_ERR_PEER_CLOSED;
  vx_mutex_lock(&k->lock); // Rflush: no reply will come, and what it held is free
  p9_chunks_give(&k->arena, s->at, s->len);
  s->len = 0;
  k->budget -= s->reserve;
  s->reserve = 0;
  atomic_store(&s->state, P9_SLOT_TAKEN);
  vx_mutex_unlock(&k->lock);
  return why;
}

static p9_xfer *p9_ring_begin(void *ctx, bool version) {
  p9_slot *s = p9_ring_slot_take(ctx, version, false);
  return s ? &s->x : nullptr;
}

static int64_t p9_ring_call(void *ctx, p9_xfer *x, size_t len) {
  p9_conn *k = ctx;
  p9_slot *s = (p9_slot *)x;
  vx_instant deadline = k->timeout ? vx_clock_read() + k->timeout : VX_INFINITE;
  vx_status st = p9_ring_put(k, s, len, deadline);
  if (st != VX_OK) return st;
  st = p9_ring_wait(k, s, 0, deadline, true);
  if (st == VX_OK) return s->result;
  if (st == VX_ERR_PEER_CLOSED) return st;
  return p9_ring_flush(k, s, st);
}

static void p9_ring_end(void *ctx, p9_xfer *x) { p9_ring_slot_give(ctx, (p9_slot *)x); }

static const p9_pipe P9_RING_PIPE = {.begin = p9_ring_begin, .call = p9_ring_call, .end = p9_ring_end};

// Lets go of the slots' buffers. The connection is no one else's by now.
static void p9_ring_slots_unmap(p9_conn *k) {
  for (uint32_t i = 0; i < P9_RING_DEPTH; i++) {
    p9_slot *s = &k->slots[i];
    if (s->x.handle) vx_handle_close(s->x.handle);
    if (s->x.send_handle) vx_handle_close(s->x.send_handle);
    if (s->buf) vx_as_unmap(vx_self, (uint64_t)s->buf, P9_RING_MSIZE);
  }
}

// A connection cleared; dead says it may not be used. Not a compound literal,
// which a build without optimisation makes on the stack first.
static void p9_conn_clear(p9_conn *k, bool dead) {
  memset(k, 0, sizeof *k);
  k->dead = dead;
}

// Opens a connection through a connector (a listen channel's client end, which
// stays the caller's) and negotiates 9Px. The connection is ready to attach.
[[maybe_unused]] static vx_status p9_ring_connect(vx_handle connector, p9_conn *k) {
  p9_conn_clear(k, false);
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
    uint64_t arena_size;
    vx_ring_arena(&k->ring, &arena_size);
    k->arena = (p9_chunks){.size = arena_size};
    k->c = (p9_client){.pipe = &P9_RING_PIPE, .ctx = k, .bufsize = P9_RING_MSIZE};
    st = p9c_version(&k->c, P9_RING_MSIZE,
                     P9_EXT_POSIX | P9_EXT_XATTR | P9_EXT_MAP | P9_EXT_DREF |
                         P9_EXT_SRV); // what the server has
  }
  if (st != VX_OK) {
    p9_ring_slots_unmap(k);
    p9_ring_unmap(&k->ring);
    if (k->end) vx_handle_close(k->end);
    if (k->port) vx_handle_close(k->port);
    p9_conn_clear(k, true);
  }
  return st;
}

[[maybe_unused]] static void p9_ring_disconnect(p9_conn *k) {
  p9_ring_slots_unmap(k);
  p9_ring_unmap(&k->ring);
  if (k->end) vx_handle_close(k->end);
  if (k->port) vx_handle_close(k->port);
  p9_conn_clear(k, true);
}

// --- Calls whose replies are taken later ---
//
// For a reader that waits on many things at once (poll's read-ahead, in the
// musl back end): send a request, then look for its reply, arming a port of
// the caller's to hear when one may have come. A connection carries several
// such calls beside its ordinary ones (M6 step 6d4d1). Whoever leads at the
// time hands a reply to its slot and posts the caller's packet; with no
// leader, the caller's look reads the queue itself; a leader that stops
// posts every waiting caller's packet, so each looks again and arms its port
// on the doorbell.

// Sends t, its reply to be taken by p9_ring_receive with t->tag; port gets
// `key` when it may have come (VX_HANDLE_NONE: no packet).
[[maybe_unused]] static vx_status p9_ring_send(p9_conn *k, p9_msg *t, vx_handle port, uint64_t key) {
  p9_slot *s = p9_ring_slot_take(k, false, false);
  if (!s) return VX_ERR_PEER_CLOSED;
  t->tag = s->x.tag;
  size_t n = p9_encode(t, s->buf, P9_RING_MSIZE);
  s->async = true, s->notify = port, s->notify_key = key, s->sent = t->type;
  vx_status st = n ? p9_ring_put(k, s, n, VX_INFINITE) : VX_ERR_TOO_SMALL;
  if (st != VX_OK) {
    s->async = false;
    p9_ring_slot_give(k, s);
  }
  return st;
}

// The slot of the call sent with tag, if it is one p9_ring_send sent.
static p9_slot *p9_ring_async(p9_conn *k, uint16_t tag) {
  for (uint32_t i = 0; i < P9_RING_DEPTH; i++) {
    p9_slot *s = &k->slots[i];
    uint32_t state = atomic_load(&s->state);
    if (s->async && s->x.tag == tag && (state == P9_SLOT_SENT || state == P9_SLOT_DONE)) return s;
  }
  return nullptr;
}

// Reads what has come, if no one leads: the caller's look.
static void p9_ring_take_completions(p9_conn *k) {
  vx_mutex_lock(&k->lock);
  bool lead = !k->leading && !k->dead;
  if (lead) k->leading = true;
  vx_mutex_unlock(&k->lock);
  if (!lead) return;
  bool broken = false;
  for (vx_cqe c; !broken;) {
    vx_status st = vx_ring_consume(&k->ring, &c);
    if (st == VX_ERR_SHOULD_WAIT) break;
    broken = st != VX_OK || !p9_ring_deliver(k, &c);
  }
  vx_mutex_lock(&k->lock);
  k->leading = false;
  if (broken) p9_ring_kill(k);
  atomic_fetch_add(&k->replies, 1); // a thread waiting to lead may now
  vx_mutex_unlock(&k->lock);
  vx_futex_wake(&k->replies, UINT32_MAX);
}

// The reply to the call p9_ring_send sent with tag: OK, with *r decoded (its
// data in the slot's buffer, until the slot's next call); SHOULD_WAIT if it
// has not come; the error an Rerror names; or PEER_CLOSED.
[[maybe_unused]] static vx_status p9_ring_receive(p9_conn *k, uint16_t tag, p9_msg *r) {
  p9_slot *s = p9_ring_async(k, tag);
  if (!s) return VX_ERR_PEER_CLOSED;
  if (atomic_load(&s->state) != P9_SLOT_DONE) p9_ring_take_completions(k);
  if (atomic_load(&s->state) != P9_SLOT_DONE) return VX_ERR_SHOULD_WAIT;
  int64_t n = s->result;
  uint8_t sent = s->sent;
  s->async = false;
  p9_ring_slot_give(k, s); // its buffer keeps the reply until the slot's next call
  if (n < 0) return (vx_status)n;
  // Anything but its reply (or its error) means the server is confused, and
  // nothing more it says can be matched to a call.
  bool ok = p9_decode(s->buf, (size_t)n, r) == VX_OK && r->tag == tag;
  if (ok && r->type == P9_Rerror) return p9_error_status(r->ename);
  if (ok && r->type == P9_Rlerror) return p9_errno_status(r->ecode);
  if (!ok || r->type != sent + 1) {
    vx_mutex_lock(&k->lock);
    p9_ring_kill(k);
    vx_mutex_unlock(&k->lock);
    return VX_ERR_PEER_CLOSED;
  }
  return VX_OK;
}

// Lets go of the call p9_ring_send sent with tag, answered or not: Tflush if
// it has not been, and its slot back once the server has let it go.
[[maybe_unused]] static void p9_ring_cancel(p9_conn *k, uint16_t tag) {
  p9_slot *s = p9_ring_async(k, tag);
  if (!s) return;
  s->notify = VX_HANDLE_NONE; // no packet for a caller that has gone
  if (atomic_load(&s->state) != P9_SLOT_DONE) p9_ring_flush(k, s, VX_ERR_INTERRUPTED);
  s->async = false;
  p9_ring_slot_give(k, s);
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
  vx_handle dup;
  vx_status e = vx_handle_dup(vmo, VX_RIGHTS_SAME, &dup);
  if (e != VX_OK) return e;
  p9_msg t = {.type = type, .fid = fid, .offset = offset, .count = count, .roffset = roffset};
  p9_rcall rc = {};
  e = p9c_rpc(c, &t, &rc, dup);
  if (!rc.x) vx_handle_close(dup); // no call to carry it
  if (e == VX_OK) *done = rc.r.count;
  p9c_done(c, &rc);
  return e;
}

// --- srv (docs/proto/srv.md, 6d4d2a) ---

// Opens fid, the reply's handle (srvfs's connector) in *out.
[[maybe_unused]] static vx_status p9c_open_handle(p9_client *c, uint32_t fid, uint8_t mode, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  if (!(c->extensions & P9_EXT_SRV)) return VX_ERR_UNSUPPORTED;
  p9_msg t = {.type = P9_Topen, .fid = fid, .mode = mode};
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, VX_HANDLE_NONE);
  if (e == VX_OK && !rc.x->handle) e = VX_ERR_INVALID; // an Ropen without it
  if (e == VX_OK) *out = rc.x->handle, rc.x->handle = VX_HANDLE_NONE;
  p9c_done(c, &rc);
  return e;
}

// Writes to fid with h beside the message (a post), which goes to the server
// whatever the answer.
[[maybe_unused]] static vx_status p9c_write_handle(p9_client *c, uint32_t fid, vx_handle h) {
  if (!(c->extensions & P9_EXT_SRV)) {
    vx_handle_close(h);
    return VX_ERR_UNSUPPORTED;
  }
  p9_msg t = {.type = P9_Twrite, .fid = fid, .data = {(const uint8_t *)"post", 4}};
  p9_rcall rc = {};
  vx_status e = p9c_rpc(c, &t, &rc, h);
  if (!rc.x) vx_handle_close(h); // no call to carry it
  p9c_done(c, &rc);
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
