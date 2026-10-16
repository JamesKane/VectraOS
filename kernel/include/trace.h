// Kernel trace ABI (roadmap "Trace", the core of requirement 18; NeoVectra
// ADR-0049 is the model). The ring and record layouts are read by user
// space through a capability (K5), so they are C. The category mask is
// here too, defined in trace.c: a C object is initialized statically,
// while a Swift global atomic is initialized lazily and would add a guard
// to every probe. A disabled probe is one relaxed load and a branch.

#pragma once

#include <stdint.h>

// Categories (bits of the mask).
enum : uint32_t {
  CROI_TRACE_SCHED = 1u << 0,
  CROI_TRACE_IRQ = 1u << 1,
  CROI_TRACE_VM = 1u << 2,       // K4
  CROI_TRACE_IPC = 1u << 3,      // K7
  CROI_TRACE_FUTEX = 1u << 4,    // K7
  CROI_TRACE_SYSCALL = 1u << 5,  // K6
  CROI_TRACE_SAMPLE = 1u << 6,   // K6
  CROI_TRACE_MARK = 1u << 7,     // marks (user space from K6; kernel tests now)
};

// Record kinds. 0x0000-0x3fff are croi's (kernel categories); 0x4000-
// 0x7fff belong to user space (Todhchai's Trace module defines them, e.g.
// zones, flows, counters, names) so kernel and user rings merge into one
// timeline; 0x8000-0xffff are reserved.
//
// Threads are named `task << 12 | thread` (a process's id, and the
// thread's index in it): kernel threads are task 0, idle threads 0.
enum : uint16_t {
  CROI_TK_USER_FIRST = 0x4000,
  CROI_TK_USER_LAST = 0x7fff,

  CROI_TK_SWITCH = 1,   // thread: previous; a: next; b: previous state
  CROI_TK_WAKE = 2,     // thread: waker; a: woken; b: CPU it was queued on
  CROI_TK_BLOCK = 3,    // thread: blocker; a: timeout (ns, or ~0)
  CROI_TK_PREEMPT = 4,  // thread: preempted; a: reason (CROI_TRACE_PREEMPT_*)
  CROI_TK_MIGRATE = 5,  // a: thread; b: from << 32 | to
  CROI_TK_OVERRUN = 6,  // thread: overrunning; a: overruns so far
  CROI_TK_IRQ_ENTER = 16,  // a: vector / INTID / scause
  CROI_TK_IRQ_EXIT = 17,   // a: as for enter
  CROI_TK_SYSCALL_ENTER = 48,  // a: number; b: first argument
  CROI_TK_SYSCALL_EXIT = 49,   // a: number; b: result
  CROI_TK_FAULT = 32,      // a: faulting user address; b: CROI_VM_FAULT_* bits
  CROI_TK_COMMIT = 33,     // a: VMO trace id; b: page index committed
  CROI_TK_SAMPLE = 64,     // thread: sampled; a: PC; b: frames << 8 | source
  CROI_TK_FRAMES = 65,     // a, b: the next two return addresses (0: none)
  CROI_TK_CHANNEL_WRITE = 80,  // a: flow id (ipc.h); b: bytes | handles << 32
  CROI_TK_CHANNEL_READ = 81,   // a: flow id; b: bytes | handles << 32
  CROI_TK_DONATE = 82,         // thread: the server; a: flow id; b: the caller's trace id
  CROI_TK_FUTEX_WAIT = 96,     // a: user address; b: the owner's trace id (0: none)
  CROI_TK_FUTEX_WAKE = 97,     // a: user address; b: threads woken
  CROI_TK_MARK = 112,      // a, b: 16 bytes of the marker's choosing
};

enum : uint64_t {
  CROI_TRACE_PREEMPT_BUDGET = 1,    // a deadline thread's budget ran out
  CROI_TRACE_PREEMPT_DEADLINE = 2,  // an earlier deadline became runnable
  CROI_TRACE_PREEMPT_SLICE = 3,     // a fair slice ended with others waiting
  CROI_TRACE_PREEMPT_RESERVED = 4,  // its CPU was reserved away from it
};

// Samples (CROI_TRACE_SAMPLE): a SAMPLE record, then frames/2 rounded up
// FRAMES records, innermost first, consecutive in the ring. Addresses in
// the kernel image are offsets from its base with CROI_SAMPLE_KERNEL set
// (records never hold kernel addresses); user addresses are as they are.
// A thread sampled in a syscall gets its kernel frames, then its user PC
// and frames. Source 0 is the tick; PMU overflow sources are 1 + counter.
enum : uint64_t {
  CROI_SAMPLE_KERNEL = 1ull << 63,
  CROI_SAMPLE_MAX_FRAMES = 16,
  CROI_SAMPLE_DEFAULT_HZ = 1000,
};

enum : uint64_t {
  CROI_VM_FAULT_WRITE = 1,
  CROI_VM_FAULT_EXECUTE = 2,
  CROI_VM_FAULT_RESOLVED = 4,  // else the access was refused
};

// One record: 32 bytes. `time` is the raw counter (see the ring's
// frequency).
typedef struct {
  uint64_t time;
  uint16_t kind;
  uint16_t cpu;
  uint32_t thread;
  uint64_t a;
  uint64_t b;
} croi_trace_record_t;

enum : uint32_t {
  CROI_TRACE_ONESHOT = 0,   // stop recording when full; count drops
  CROI_TRACE_CIRCULAR = 1,  // overwrite the oldest
};

// A trace ring (D50): this header, then at +CROI_TRACE_RING_HEADER a one
// ring (ring.h), OVERWRITE, of croi_trace_slot_t slots, format
// CROI_TRACE_RING_FORMAT. Its producer is a CPU (the kernel's rings: one
// a CPU, written with interrupts masked) or a thread (a user region's,
// docs/trace-format.md). The ring's cursor counts records ever written;
// ONESHOT stops once it reaches the slot count, and counts drops here.
typedef struct {
  uint64_t frequency;   // counter Hz
  uint64_t session;     // bumped by every start (a region's: its start)
  uint64_t drops;
  uint64_t first_drop;  // counter values of the first and last drop
  uint64_t last_drop;
  uint32_t mode;
  uint32_t cpu;         // a thread's ring: 0xffffffff
  uint32_t magic;       // CROI_TRACE_RING_MAGIC
  uint32_t thread;      // a thread's ring: its id; a CPU's: 0
  uint64_t reserved[9];
} croi_trace_ring_t;

static_assert(sizeof(croi_trace_ring_t) == 128);

// A slot: the ring's sequence, then the record.
typedef struct {
  uint64_t sequence;
  croi_trace_record_t record;
} croi_trace_slot_t;

static_assert(sizeof(croi_trace_slot_t) == 40);

enum : uint32_t {
  CROI_TRACE_RING_HEADER = 128,       // the one ring's offset in a trace ring
  CROI_TRACE_RING_MAGIC = 0x676e6972,  // "ring"
  CROI_TRACE_RING_FORMAT = 0x32435254,  // "TRC2": trace records, version 2
  // trace_configure's pages: CROI_TRACE_RECORDS_PER_PAGE records a page.
  CROI_TRACE_RECORDS_PER_PAGE = 128,
};

extern uint32_t croi_trace_mask;

static inline uint32_t croi_trace_categories(void) {
  return __atomic_load_n(&croi_trace_mask, __ATOMIC_RELAXED);
}

static inline uint32_t croi_trace_categories_ordered(void) {
  return __atomic_load_n(&croi_trace_mask, __ATOMIC_SEQ_CST);
}

static inline void croi_trace_set_categories(uint32_t mask) {
  __atomic_store_n(&croi_trace_mask, mask, __ATOMIC_SEQ_CST);
}
