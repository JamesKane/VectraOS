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

// A thread of the program's own task, as vx_thread_spawn made it.
typedef struct vx_tcb vx_tcb;
typedef struct vx_thread {
  vx_handle handle;
  uint64_t base, size; // its mapping
  vx_tcb *tcb;
} vx_thread;

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
VX_API vx_status vx_intent_set(uint32_t intent);
VX_API uint32_t vx_cpu_count(void);
VX_API bool vx_cpu_has(vx_cpu_feature f);
VX_API vx_status vx_thread_spawn(vx_thread *t, void (*fn)(void *), void *arg, uint64_t stack_size);
VX_API void vx_thread_join(vx_thread *t);
