// vx-ring: the ring protocol (docs/01 §4.3). Pure memory operations, no
// syscalls, so it builds for the target and the host alike; the caller rings
// doorbells (ring_notify) and sleeps (port_wait) when this says to.
//
// Each side produces into one queue and consumes from the other: the client
// produces submissions (SQ) and consumes completions (CQ); the server does the
// opposite. Each queue has one producer and one consumer, so both are
// wait-free. A side writes only its own lines and its own arena.
//
// The wake protocol, model-checked by vx-check (tests/host/ring_model_test.c):
//
//   producer: write entry; tail.store(release); fence(seq_cst);
//             if the consumer's flags hold NEED_WAKEUP, ring its doorbell
//   consumer: before sleeping: flags.store(NEED_WAKEUP); fence(seq_cst);
//             recheck the tail; sleep only if still empty
//
// One of the two fences always sees the other side's store, so a wake-up is
// never lost (the store-buffer litmus test). With both sides busy, nothing
// enters the kernel.
//
// Shared memory is hostile (01 §4.3): the header is validated once and used
// only from a private copy, each entry is copied out exactly once, and an index
// that runs ahead of the other marks the ring broken.

#pragma once

#include "../../abi/vx/abi.h"
#if __STDC_HOSTED__
#include <string.h> // host tests
#else
#include "../vx-mem/mem.h"
#endif

typedef struct vx_ring {
  uint8_t *base;
  vx_ring_header h; // the validated copy; the one in shared memory is never read again
  bool client;
  bool broken; // the peer broke the protocol; every call fails from here on

  // The queue this side produces into.
  uint32_t *out_tail;        // ours
  const uint32_t *out_head;  // the peer's
  const uint32_t *out_flags; // the peer's NEED_WAKEUP
  uint8_t *out_entries;
  uint32_t out_mask, out_size;
  uint32_t out_tail_local;

  // The queue this side consumes.
  const uint32_t *in_tail; // the peer's
  uint32_t *in_head;       // ours
  uint32_t *in_flags;      // ours
  const uint8_t *in_entries;
  uint32_t in_mask, in_size;
  uint32_t in_head_local;
} vx_ring;

static bool ring_pow2(uint32_t n) { return n && !(n & (n - 1)); }
static uint64_t ring_page_up(uint64_t v) { return (v + 4095) & ~4095ull; }

// The layout for these parameters: the header the kernel writes into a new
// ring. INVALID for queue lengths that are not powers of two from 1 to 4096,
// or entry sizes that are not multiples of 16 up to 256.
[[maybe_unused]] static vx_status vx_ring_layout(const vx_ring_params *p, vx_ring_header *out) {
  if (!ring_pow2(p->sq_entries) || !ring_pow2(p->cq_entries) || p->sq_entries > 4096 || p->cq_entries > 4096)
    return VX_ERR_INVALID;
  if (!p->sqe_size || !p->cqe_size || p->sqe_size % 16 || p->cqe_size % 16 || p->sqe_size > 256 ||
      p->cqe_size > 256)
    return VX_ERR_INVALID;
  if (p->client_arena > (1ull << 30) || p->server_arena > (1ull << 30)) return VX_ERR_RANGE;
  vx_ring_header h = {
      .magic = VX_RING_MAGIC,
      .version = VX_RING_VERSION,
      .sq_entries = p->sq_entries,
      .cq_entries = p->cq_entries,
      .sqe_size = p->sqe_size,
      .cqe_size = p->cqe_size,
      .sq_offset = VX_RING_INDEX_OFFSET + 4096,
  };
  h.cq_offset = (h.sq_offset + (uint64_t)h.sq_entries * h.sqe_size + 63) & ~63ull;
  h.client_arena_offset = ring_page_up(h.cq_offset + (uint64_t)h.cq_entries * h.cqe_size);
  h.client_arena_size = ring_page_up(p->client_arena);
  h.server_arena_offset = h.client_arena_offset + h.client_arena_size;
  h.server_arena_size = ring_page_up(p->server_arena);
  h.size = h.server_arena_offset + h.server_arena_size;
  *out = h;
  return VX_OK;
}

// Attaches to a ring mapped at `base` (mapped_size bytes) as the client or the
// server. The header must be exactly what vx_ring_layout makes of `expect`,
// the parameters this side's protocol uses: whoever made the ring may be
// hostile, and entry sizes and queue lengths decide how much each consume
// copies into the caller's buffer. Takes the indices as they stand: a side
// attaches before it uses the ring.
[[maybe_unused]] static vx_status vx_ring_attach(vx_ring *r, void *base, uint64_t mapped_size, bool client,
                                                 const vx_ring_params *expect) {
  *r = (vx_ring){.broken = true}; // after a failed attach, every operation fails
  vx_ring_header h, want;
  memcpy(&h, base, sizeof h);
  if (vx_ring_layout(expect, &want) != VX_OK) return VX_ERR_INVALID;
  want.session = h.session; // the kernel's, whatever it is
  if (memcmp(&h, &want, sizeof h) != 0 || h.size > mapped_size) return VX_ERR_INVALID;

  uint8_t *b = base;
  vx_ring_index *lines = (vx_ring_index *)(b + VX_RING_INDEX_OFFSET);
  *r = (vx_ring){.base = b, .h = h, .client = client};
  enum vx_ring_line out_tail = client ? VX_RING_SQ_TAIL : VX_RING_CQ_TAIL;
  enum vx_ring_line out_head = client ? VX_RING_SQ_HEAD : VX_RING_CQ_HEAD;
  enum vx_ring_line in_tail = client ? VX_RING_CQ_TAIL : VX_RING_SQ_TAIL;
  enum vx_ring_line in_head = client ? VX_RING_CQ_HEAD : VX_RING_SQ_HEAD;
  r->out_tail = &lines[out_tail].index;
  r->out_head = &lines[out_head].index;
  r->out_flags = &lines[out_head].flags;
  r->out_entries = b + (client ? h.sq_offset : h.cq_offset);
  r->out_mask = (client ? h.sq_entries : h.cq_entries) - 1;
  r->out_size = client ? h.sqe_size : h.cqe_size;
  r->out_tail_local = __atomic_load_n(r->out_tail, __ATOMIC_RELAXED);
  r->in_tail = &lines[in_tail].index;
  r->in_head = &lines[in_head].index;
  r->in_flags = &lines[in_head].flags;
  r->in_entries = b + (client ? h.cq_offset : h.sq_offset);
  r->in_mask = (client ? h.cq_entries : h.sq_entries) - 1;
  r->in_size = client ? h.cqe_size : h.sqe_size;
  r->in_head_local = __atomic_load_n(r->in_head, __ATOMIC_RELAXED);
  return VX_OK;
}

// --- Producing ---

// The next free entry to fill, or nullptr if the queue is full or the ring is
// broken. Nothing is visible to the peer until vx_ring_produce.
[[maybe_unused]] static void *vx_ring_produce_slot(vx_ring *r) {
  if (r->broken) return nullptr;
  uint32_t head = __atomic_load_n(r->out_head, __ATOMIC_ACQUIRE);
  uint32_t used = r->out_tail_local - head;
  if (used > r->out_mask + 1) { // the peer's head ran past our tail
    r->broken = true;
    return nullptr;
  }
  if (used == r->out_mask + 1) return nullptr;
  return r->out_entries + (size_t)(r->out_tail_local & r->out_mask) * r->out_size;
}

// Publishes the entry vx_ring_produce_slot gave. Returns true if the peer is
// asleep, and its doorbell must be rung (ring_notify).
[[maybe_unused]] static bool vx_ring_produce(vx_ring *r) {
  r->out_tail_local++;
  __atomic_store_n(r->out_tail, r->out_tail_local, __ATOMIC_RELEASE);
  __atomic_thread_fence(__ATOMIC_SEQ_CST);
  return __atomic_load_n(r->out_flags, __ATOMIC_RELAXED) & VX_RING_NEED_WAKEUP;
}

// How many entries the peer has consumed of what this side produced: the
// head of the queue this side produces into, as a running count.
[[maybe_unused]] static uint32_t vx_ring_peer_consumed(const vx_ring *r) {
  return __atomic_load_n(r->out_head, __ATOMIC_ACQUIRE);
}

// How many entries this side has produced, as a running count.
[[maybe_unused]] static uint32_t vx_ring_produced(const vx_ring *r) { return r->out_tail_local; }

// --- Consuming ---

// Copies the next entry into out (the entry size bytes) and frees its slot.
// SHOULD_WAIT if the queue is empty; BAD_STATE once the peer has broken the
// protocol, which the caller treats as the peer going away.
[[maybe_unused]] static vx_status vx_ring_consume(vx_ring *r, void *out) {
  if (r->broken) return VX_ERR_BAD_STATE;
  uint32_t tail = __atomic_load_n(r->in_tail, __ATOMIC_ACQUIRE);
  uint32_t ready = tail - r->in_head_local;
  if (ready == 0) return VX_ERR_SHOULD_WAIT;
  if (ready > r->in_mask + 1) { // the peer's tail ran ahead of what fits
    r->broken = true;
    return VX_ERR_BAD_STATE;
  }
  memcpy(out, r->in_entries + (size_t)(r->in_head_local & r->in_mask) * r->in_size, r->in_size);
  r->in_head_local++;
  __atomic_store_n(r->in_head, r->in_head_local, __ATOMIC_RELEASE);
  return VX_OK;
}

// About to sleep: announces it, then looks once more. Returns true if the
// queue is still empty, and the caller may sleep until its doorbell rings;
// false if an entry arrived meanwhile (and the announcement is withdrawn).
[[maybe_unused]] static bool vx_ring_prepare_sleep(vx_ring *r) {
  __atomic_store_n(r->in_flags, VX_RING_NEED_WAKEUP, __ATOMIC_RELAXED);
  __atomic_thread_fence(__ATOMIC_SEQ_CST);
  if (__atomic_load_n(r->in_tail, __ATOMIC_ACQUIRE) != r->in_head_local) {
    __atomic_store_n(r->in_flags, 0, __ATOMIC_RELAXED);
    return false;
  }
  return true;
}

// Awake again: the peer need not ring until the next vx_ring_prepare_sleep.
[[maybe_unused]] static void vx_ring_end_sleep(vx_ring *r) {
  __atomic_store_n(r->in_flags, 0, __ATOMIC_RELAXED);
}

// --- Arenas ---

// This side's arena, where it puts payloads for the peer to read.
[[maybe_unused]] static uint8_t *vx_ring_arena(vx_ring *r, uint64_t *size) {
  *size = r->client ? r->h.client_arena_size : r->h.server_arena_size;
  return r->base + (r->client ? r->h.client_arena_offset : r->h.server_arena_offset);
}

// [offset, offset + len) of the peer's arena, or nullptr if an entry named a
// range outside it.
[[maybe_unused]] static const uint8_t *vx_ring_peer_bytes(const vx_ring *r, uint64_t offset, uint64_t len) {
  uint64_t size = r->client ? r->h.server_arena_size : r->h.client_arena_size;
  if (offset > size || len > size - offset) return nullptr;
  return r->base + (r->client ? r->h.server_arena_offset : r->h.client_arena_offset) + offset;
}
