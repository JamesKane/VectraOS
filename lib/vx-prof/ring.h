// vx-prof's ring format (docs/05 §9, 20 §5), and what a spawner needs to
// give a child one: apart from prof.h's writers, so what includes spawn.c
// (the musl back end among them) does not take vx-rt's threads with it.

#pragma once

#include "../vx-proc/proc.h"
#include "../vx-rt/base.c"

static constexpr uint32_t VX_PROF_MAGIC = 0x666f'7270; // "prof"
static constexpr uint32_t VX_PROF_ZONES = 64, VX_PROF_NAME = 32;
// The VMO: the header's page, then rings: ring 0, shared, then one each for
// the first VX_PROF_THREADS threads that record.
static constexpr uint32_t VX_PROF_THREADS = 32;
static constexpr uint64_t VX_PROF_RING_BYTES = 32ull * 1024, VX_PROF_HEADER_BYTES = 4096;
static constexpr uint64_t VX_PROF_RING = VX_PROF_HEADER_BYTES + (VX_PROF_THREADS + 1) * VX_PROF_RING_BYTES;

// Version 3 (M7 step 7a2): a span is a record with a flow (20 §5), which
// the 9Px and ring frameworks write for every request; its zone is then the
// message's type, not a name. A zone's flow is 0.
typedef struct vx_prof_record {
  uint64_t start, end; // on the cycle counter
  uint32_t zone;       // from 1: names[zone - 1]; a span's message type
  uint32_t thread;     // the kernel's id for it (/proc/N/threads)
  uint64_t flow;       // a span's flow, which each end of its request computes alike; 0 for a zone
} vx_prof_record;
static_assert(sizeof(vx_prof_record) == 32);

// The start of the shared VMO, and of what /proc/N/prof/zones reads, where
// head and cap say how many records follow.
typedef struct vx_prof_header {
  uint32_t magic, version;
  uint64_t counter_hz;      // /sys/clock/info's
  uint64_t nonce;           // procfs's challenge, read back through the task's memory
  _Atomic uint32_t enabled; // set by procfs: ctl's "zones on"
  _Atomic uint32_t nzones;
  _Atomic uint32_t spans; // set by procfs while /proc/trace takes spans (its ctl's "start ... span")
  uint32_t reserved;
  _Atomic uint64_t head; // in the VMO, rings claimed; in the file, the records that follow
  uint32_t cap, rings;   // records each ring holds; rings (in the file: records, and 0)
  char names[VX_PROF_ZONES][VX_PROF_NAME];
  // Where its process heap's pointer is (vx_heap_the, lib/vx-rt/heap.c), in
  // its memory, for /proc/N/heap (7a4b); 0: none said.
  uint64_t heap;
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

[[maybe_unused]] static vx_prof_ring *vx_prof_ring_at(vx_prof_header *h, uint32_t i) {
  return (vx_prof_ring *)((uint8_t *)h + VX_PROF_HEADER_BYTES + i * VX_PROF_RING_BYTES);
}
[[maybe_unused]] static vx_prof_record *vx_prof_ring_records(vx_prof_ring *r) {
  return (vx_prof_record *)(r + 1);
}
static constexpr uint32_t VX_PROF_CAP = (VX_PROF_RING_BYTES - sizeof(vx_prof_ring)) / sizeof(vx_prof_record);

// A ring request's flow (20 §5): from what client and server share, the
// ring's session (the kernel's id for it) and the submission's user_data,
// which names the request uniquely while it is outstanding.
[[maybe_unused]] static uint64_t vx_prof_flow(uint64_t session, uint64_t user_data) {
  uint64_t x = session * 0x9e37'79b9'7f4a'7c15ull ^ user_data;
  x ^= x >> 31, x *= 0xbf58'476d'1ce4'e5b9ull, x ^= x >> 27;
  return x | 1;
}

// For a spawner (vx_spawn_elf): a ring for the child, task, made and
// mapped into it before it runs, at *at; the header written as
// vx_prof_init writes it. vx_prof_give hands it to procfs once the child is
// registered.
[[maybe_unused]] static vx_status vx_prof_make_for(vx_handle task, vx_handle *vmo, uint64_t *at) {
  *vmo = VX_HANDLE_NONE, *at = 0;
  vx_status st = vx_vmo_create(VX_PROF_RING, VX_VMO_LAZY, vmo);
  if (st == VX_OK) st = vx_as_map(task, *vmo, 0, VX_PROF_RING, VX_MAP_WRITE, at);
  vx_clock_info clock = {};
  vx_clock_info_read(&clock);
  vx_prof_header h = {.magic = VX_PROF_MAGIC,
                      .version = 3,
                      .counter_hz = clock.counter_hz,
                      .cap = VX_PROF_CAP,
                      .rings = VX_PROF_THREADS + 1};
  if (st == VX_OK) st = vx_vmo_rw(*vmo, VX_VMO_WRITE, 0, &h, offsetof(vx_prof_header, names));
  if (st != VX_OK && *vmo) vx_handle_close(*vmo), *vmo = VX_HANDLE_NONE;
  return st;
}

// The child's ring to procfs, as vx_prof_init gives a process's own.
[[maybe_unused]] static vx_status vx_prof_give(vx_handle connector, uint64_t pid, vx_handle vmo,
                                               uint64_t at) {
  proc_msg req = {.h = {.ordinal = PROC_PROF}, .arg = {(int64_t)pid, (int64_t)at}}, rep = {};
  vx_call c = {.wr_bytes = &req,
               .wr_len = sizeof req,
               .wr_handles = &vmo,
               .wr_count = 1,
               .rd_bytes = &rep,
               .rd_cap = sizeof rep};
  vx_status st = vx_channel_call(connector, &c, vx_clock_read() + 2'000'000'000);
  if (st == VX_OK && rep.h.flags) st = (vx_status)(int32_t)rep.h.flags;
  return st;
}
