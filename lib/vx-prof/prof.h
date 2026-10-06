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

static constexpr uint32_t VX_PROF_MAGIC = 0x666f'7270; // "prof"
static constexpr uint32_t VX_PROF_ZONES = 64, VX_PROF_NAME = 32;
// The VMO: the header's page, then rings: ring 0, shared, then one each for
// the first VX_PROF_THREADS threads that record.
static constexpr uint32_t VX_PROF_THREADS = 32;
static constexpr uint64_t VX_PROF_RING_BYTES = 32ull * 1024, VX_PROF_HEADER_BYTES = 4096;
static constexpr uint64_t VX_PROF_RING = VX_PROF_HEADER_BYTES + (VX_PROF_THREADS + 1) * VX_PROF_RING_BYTES;

typedef struct vx_prof_record {
  uint64_t start, end; // on the cycle counter
  uint32_t zone;       // from 1: names[zone - 1]
  uint32_t thread;     // the kernel's id for it (/proc/N/threads)
} vx_prof_record;

// The start of the shared VMO, and of what /proc/N/prof/zones reads, where
// head and cap say how many records follow.
typedef struct vx_prof_header {
  uint32_t magic, version;
  uint64_t counter_hz;      // /sys/clock/info's
  uint64_t nonce;           // procfs's challenge, read back through the task's memory
  _Atomic uint32_t enabled; // set by procfs: ctl's "zones on"
  _Atomic uint32_t nzones;
  _Atomic uint64_t head; // in the VMO, rings claimed; in the file, the records that follow
  uint32_t cap, rings;   // records each ring holds; rings (in the file: records, and 0)
  char names[VX_PROF_ZONES][VX_PROF_NAME];
} vx_prof_header;
static_assert(sizeof(vx_prof_header) <= VX_PROF_HEADER_BYTES);

// A ring, then its records: written by its thread alone (head stored after
// each record; a reader takes what head says, less any it may have been
// overwriting meanwhile), or, ring 0, by any (head counted atomically).
typedef struct vx_prof_ring {
  _Atomic uint32_t thread; // its owner's id; 0 for ring 0
  uint32_t reserved;
  _Atomic uint64_t head; // records written, ever: it holds the last cap of them
} vx_prof_ring;

typedef struct vx_prof_zone {
  const char *name;
  uint32_t id; // from 1, once it has a name in the ring
} vx_prof_zone;

static vx_prof_header *vx_prof;

static vx_prof_ring *vx_prof_ring_at(vx_prof_header *h, uint32_t i) {
  return (vx_prof_ring *)((uint8_t *)h + VX_PROF_HEADER_BYTES + i * VX_PROF_RING_BYTES);
}
static vx_prof_record *vx_prof_ring_records(vx_prof_ring *r) { return (vx_prof_record *)(r + 1); }
static constexpr uint32_t VX_PROF_CAP = (VX_PROF_RING_BYTES - sizeof(vx_prof_ring)) / sizeof(vx_prof_record);

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
  h->version = 2;
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

// A zone ends: its record, if it started with zones on.
[[maybe_unused]] static inline void vx_prof_end(vx_prof_zone *z, uint64_t start) {
  if (__builtin_expect(!start, 1)) return;
  uint64_t end = vx_cycles();
  uint32_t id = vx_prof_id(z);
  if (!id) return;
  vx_prof_ring *r = vx_prof_ring_of_thread();
  vx_prof_record rec = {.start = start, .end = end, .zone = id, .thread = vx_prof_tid};
  if (r == vx_prof_ring_at(vx_prof, 0)) { // shared: a slot of its own, counted
    uint64_t slot = atomic_fetch_add_explicit(&r->head, 1, memory_order_acq_rel);
    vx_prof_ring_records(r)[slot % VX_PROF_CAP] = rec;
    return;
  }
  uint64_t head = atomic_load_explicit(&r->head, memory_order_relaxed); // its own: no one else writes it
  vx_prof_ring_records(r)[head % VX_PROF_CAP] = rec;
  atomic_store_explicit(&r->head, head + 1, memory_order_release);
}
