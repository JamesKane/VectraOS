// vx/thread.h: threads, locks, intents (09 §5.7, ADR-0004 libvx v0).
// libvx's public declarations: a native program's, and the system's own
// programs' through lib/vx-rt (VX_API, api.h).

#pragma once

#include "api.h"
// A lock between a task's threads (6d1): a futex word, 0 free, 1 held, 2
// held with waiters (Drepper's "Futexes are tricky", mutex 3). Not
// recursive.
typedef struct vx_lock_t {
  _Atomic uint32_t state;
} vx_lock_t;

// A thread of the program's own task (09 §5.7): it runs a function that
// returns its exit string, as a process's vx_main does ("" or nullptr for
// success).
typedef struct vx_thread vx_thread;
typedef struct vx_arena vx_arena;

// What is above userland's baseline (x86-64-v3, armv8.2-a; M6 step 6c3), to
// choose a code path at run time: a feature counts only when the CPU has it
// and the kernel saves what it needs (AVX-512's registers in XCR0; SVE, whose
// state the kernel does not save yet, never).
typedef enum vx_cpu_feature : uint32_t {
#ifdef __x86_64__
  VX_CPU_AVX512, // F, DQ, BW and VL
  VX_CPU_VAES,
  VX_CPU_VPCLMULQDQ,
  VX_CPU_GFNI,
  VX_CPU_SHA,
#else
  VX_CPU_AES,
  VX_CPU_PMULL,
  VX_CPU_SHA2,
  VX_CPU_SHA512,
  VX_CPU_SHA3,
  VX_CPU_CRC32,
  VX_CPU_DOTPROD,
  VX_CPU_SVE,
#endif
} vx_cpu_feature;

VX_API void vx_lock(vx_lock_t *m);
VX_API bool vx_lock_until(vx_lock_t *m, vx_instant deadline);
VX_API void vx_unlock(vx_lock_t *m);
// The calling thread's intent (enum vx_intent, ADR-0038): how it is
// scheduled, never a priority.
VX_API vx_status vx_intent_set(uint32_t intent);
VX_API uint32_t vx_cpu_count(void);
VX_API bool vx_cpu_has(vx_cpu_feature f);
// Plan 9's Rendez (09 §5.7), over a futex: vx_rendez_sleep lets go of l,
// sleeps until a wake, and takes l again before it returns. A wake may come
// for another reason, so the sleeper tests its condition in a loop:
//   vx_lock(&l); while (!ready) vx_rendez_sleep(&r, &l); ... vx_unlock(&l);
typedef struct vx_rendez {
  _Atomic uint32_t seq;
} vx_rendez;

VX_API void vx_rendez_sleep(vx_rendez *r, vx_lock_t *l);
VX_API void vx_rendez_wake(vx_rendez *r);     // one sleeper
VX_API void vx_rendez_wake_all(vx_rendez *r); // every sleeper

// Starts fn(arg) on a new thread with intent (0: interactive, as the first
// thread starts) and a stack of stack bytes (0: 256 KiB); nullptr, with
// vx_errstr, if it cannot.
VX_API vx_thread *vx_thread_spawn(const char *(*fn)(void *), void *arg, uint32_t intent, size_t stack);
// Waits for t to end and lets it go; its exit string, "" for success, into
// *exit, copied into a (exit may be nullptr: not wanted). A watched thread
// (vx_thread_watch) is joined after its VX_EV_EXIT, which reads its record.
VX_API vx_status vx_thread_join(vx_thread *t, vx_arena *a, vx_str *exit);
