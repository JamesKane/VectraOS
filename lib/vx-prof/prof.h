// vx-prof: profiling zones (docs/05 §9). A zone times a block of code in
// cycles, with no system call:
//
//   static vx_prof_zone work = {.name = "work"};
//   uint64_t t = vx_prof_begin(&work);
//   ...
//   vx_prof_end(&work, t);
//
// Each zone that ends writes a record (its start and end on the cycle
// counter, its zone, its thread) into the ring of the thread it ran on, in a
// VMO the process shares with procfs (M6 step 6d6b): a thread claims a ring
// of its own the first time it records, and writes it alone, so threads
// share no ring and no counter; past VX_PROF_THREADS of them, the rest share
// ring 0, which counts its records atomically. Zones are off until a reader
// writes "zones on" to /proc/N/prof/ctl; off, a zone costs one predictable
// branch. /proc/N/prof/zones reads them: a vx_prof_header, the zones' names,
// then every ring's records, merged oldest first by their end.
// /sys/clock/info's frequency (in the header too) turns cycles into time.
//
// vx_prof_init(connector) makes the ring and gives it to procfs, through its
// listen channel (a connector to /proc, vx_ns_connector), as PROC_PROF: the
// ring's address. procfs writes a challenge into the ring and reads it back
// through the task's memory at that address, so no process can give procfs a
// ring for another. Header-only; it
// uses vx-rt's base (the system calls and vx_cycles).

#pragma once

#include <stdatomic.h>

#include "../vx-rt/base.c"
#include "../vx-rt/thread.c"
#include "../vx-proc/proc.h"
#include "ring.h"

typedef struct vx_prof_zone {
  const char *name;
  uint32_t id; // from 1, once it has a name in the ring
} vx_prof_zone;
static vx_prof_header *vx_prof;

static thread_local vx_prof_ring *vx_prof_mine; // this thread's ring, once it has one
static thread_local uint32_t vx_prof_tid;

// Makes the ring and gives it to procfs (connector: to its listen channel).
[[maybe_unused]] static vx_status vx_prof_init(vx_handle connector) {
  if (vx_prof) return VX_OK;
  vx_handle vmo, dup;
  uint64_t at = 0;
  vx_status st = vx_vmo_create(VX_PROF_RING, 0, &vmo);
  if (st != VX_OK) return st;
  st = vx_as_map(vx_self, vmo, 0, VX_PROF_RING, VX_MAP_WRITE, &at);
  if (st == VX_OK) st = vx_handle_dup(vmo, VX_RIGHTS_SAME, &dup);
  vx_handle_close(vmo);
  if (st != VX_OK) return st;
  vx_prof_header *h = (vx_prof_header *)at;
  vx_clock_info clock = {};
  vx_clock_info_read(&clock);
  h->magic = VX_PROF_MAGIC;
  h->version = 3;
  h->counter_hz = clock.counter_hz;
  h->cap = VX_PROF_CAP, h->rings = VX_PROF_THREADS + 1;
  vx_task_summary me;
  vx_task_info(vx_self, &me);
  proc_msg req = {.h = {.ordinal = PROC_PROF}, .arg = {(int64_t)me.id, (int64_t)at}}, rep = {};
  vx_call c = {.wr_bytes = &req,
               .wr_len = sizeof req,
               .wr_handles = &dup,
               .wr_count = 1,
               .rd_bytes = &rep,
               .rd_cap = sizeof rep};
  st = vx_channel_call(connector, &c, vx_clock_read() + 2'000'000'000);
  if (st == VX_OK && rep.h.flags) st = (vx_status)(int32_t)rep.h.flags;
  if (st == VX_OK) vx_prof = h;
  return st;
}

// The zone's number, given it a name in the ring the first time.
static uint32_t vx_prof_id(vx_prof_zone *z) {
  if (z->id) return z->id;
  uint32_t n = atomic_fetch_add_explicit(&vx_prof->nzones, 1, memory_order_relaxed);
  if (n >= VX_PROF_ZONES) return 0; // no room: not recorded
  for (uint32_t i = 0; i + 1 < VX_PROF_NAME && z->name[i]; i++) vx_prof->names[n][i] = z->name[i];
  return z->id = n + 1;
}

// A zone starts: the cycle counter, or 0 if zones are off.
[[maybe_unused]] static inline uint64_t vx_prof_begin(vx_prof_zone *z) {
  (void)z;
  if (__builtin_expect(!vx_prof || !atomic_load_explicit(&vx_prof->enabled, memory_order_relaxed), 1))
    return 0;
  return vx_cycles();
}

// This thread's ring: claimed the first time, or ring 0 if none is left.
static vx_prof_ring *vx_prof_ring_of_thread(void) {
  if (vx_prof_mine) return vx_prof_mine;
  vx_prof_tid = vx_thread_self_id();
  uint64_t n = atomic_fetch_add_explicit(&vx_prof->head, 1, memory_order_relaxed);
  vx_prof_ring *r = vx_prof_ring_at(vx_prof, n < VX_PROF_THREADS ? (uint32_t)n + 1 : 0);
  if (n < VX_PROF_THREADS) atomic_store_explicit(&r->thread, vx_prof_tid, memory_order_release);
  return vx_prof_mine = r;
}

// A record into this thread's ring.
static void vx_prof_write(vx_prof_record rec) {
  vx_prof_ring *r = vx_prof_ring_of_thread();
  rec.thread = vx_prof_tid;
  if (r == vx_prof_ring_at(vx_prof, 0)) { // shared: a slot of its own, counted
    uint64_t slot = atomic_fetch_add_explicit(&r->head, 1, memory_order_acq_rel);
    vx_prof_ring_records(r)[slot % VX_PROF_CAP] = rec;
    return;
  }
  uint64_t head = atomic_load_explicit(&r->head, memory_order_relaxed); // its own: no one else writes it
  vx_prof_ring_records(r)[head % VX_PROF_CAP] = rec;
  atomic_store_explicit(&r->head, head + 1, memory_order_release);
}

// A zone ends: its record, if it started with zones on.
[[maybe_unused]] static inline void vx_prof_end(vx_prof_zone *z, uint64_t start) {
  if (__builtin_expect(!start, 1)) return;
  uint64_t end = vx_cycles();
  uint32_t id = vx_prof_id(z);
  if (id) vx_prof_write((vx_prof_record){.start = start, .end = end, .zone = id});
}

// --- Spans (20 §5, M7 step 7a2) ---
//
// A process spawned with procfs's registration has a ring its spawner made
// (vx_prof_give), at the address its spawn message's prof= record names; it
// is taken at the first span. Spans are off until /proc/trace starts with
// them.

static bool vx_prof_spawned_tried;

static vx_prof_header *vx_prof_spawned(void) {
  if (vx_prof || vx_prof_spawned_tried) return vx_prof;
  vx_prof_spawned_tried = true;
  vx_ndb_record rec;
  uint64_t at;
  if (vx_spawn_record("prof", &rec) && vx_ndb_get_u64(&rec, "prof", &at) && at) {
    vx_prof_header *h = (vx_prof_header *)at;
    if (h->magic == VX_PROF_MAGIC && h->version == 3) vx_prof = h;
  }
  return vx_prof;
}

// A span starts: the cycle counter, or 0 if spans are off.
[[maybe_unused]] static inline uint64_t vx_prof_span_begin(void) {
  vx_prof_header *h = vx_prof ? vx_prof : vx_prof_spawned();
  if (__builtin_expect(!h || !atomic_load_explicit(&h->spans, memory_order_relaxed), 1)) return 0;
  return vx_cycles();
}

// A span ends: what it was (a message type) and its flow.
[[maybe_unused]] static inline void vx_prof_span_end(uint64_t start, uint32_t what, uint64_t flow) {
  if (__builtin_expect(!start, 1)) return;
  vx_prof_write((vx_prof_record){.start = start, .end = vx_cycles(), .zone = what, .flow = flow | 1});
}
