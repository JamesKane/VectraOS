// vx-prof: profiling zones (docs/05 §9). A zone times a block of code in
// cycles, with no system call:
//
//   static vx_prof_zone work = {.name = "work"};
//   uint64_t t = vx_prof_begin(&work);
//   ...
//   vx_prof_end(&work, t);
//
// Each zone that ends writes a record (its start and end on the cycle
// counter, its zone, its thread) into a ring in a VMO the process shares with
// procfs. Zones are off until a reader writes "zones on" to /proc/N/prof/ctl;
// off, a zone costs one predictable branch. /proc/N/prof/zones reads the ring:
// a vx_prof_header, the zones' names, then the records, oldest first.
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
#include "../vx-proc/proc.h"

static constexpr uint32_t VX_PROF_MAGIC = 0x666f'7270; // "prof"
static constexpr uint32_t VX_PROF_ZONES = 64, VX_PROF_NAME = 32;
static constexpr uint64_t VX_PROF_RING = 64ull * 1024;

typedef struct vx_prof_record {
  uint64_t start, end; // on the cycle counter
  uint32_t zone;       // from 1: names[zone - 1]
  uint32_t thread;
} vx_prof_record;

// The start of the shared ring, and of what /proc/N/prof/zones reads.
typedef struct vx_prof_header {
  uint32_t magic, version;
  uint64_t counter_hz;      // /sys/clock/info's
  uint64_t nonce;           // procfs's challenge, read back through the task's memory
  _Atomic uint32_t enabled; // set by procfs: ctl's "zones on"
  _Atomic uint32_t nzones;
  _Atomic uint64_t head; // records written, ever: the ring holds the last `cap` of them
  uint32_t cap, reserved;
  char names[VX_PROF_ZONES][VX_PROF_NAME];
} vx_prof_header;

typedef struct vx_prof_zone {
  const char *name;
  uint32_t id; // from 1, once it has a name in the ring
} vx_prof_zone;

static vx_prof_header *vx_prof;

static vx_prof_record *vx_prof_records(vx_prof_header *h) { return (vx_prof_record *)(h + 1); }

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
  h->version = 1;
  h->counter_hz = clock.counter_hz;
  h->cap = (uint32_t)((VX_PROF_RING - sizeof *h) / sizeof(vx_prof_record));
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

// A zone ends: its record, if it started with zones on.
[[maybe_unused]] static inline void vx_prof_end(vx_prof_zone *z, uint64_t start) {
  if (__builtin_expect(!start, 1)) return;
  uint64_t end = vx_cycles();
  uint32_t id = vx_prof_id(z);
  if (!id) return;
  uint64_t slot = atomic_fetch_add_explicit(&vx_prof->head, 1, memory_order_release);
  vx_prof_records(vx_prof)[slot % vx_prof->cap] =
      (vx_prof_record){.start = start, .end = end, .zone = id, .thread = 1};
}
