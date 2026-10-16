// SPDX-License-Identifier: BSD-3-Clause
//
// What the trace writer needs that Swift can't express (principle 28):
// - the CPU's cycle counter, one instruction (rdtsc; cntvct_el0; rdtime);
// - a thread-local pointer to the thread's ring, read in one TLS access
//   (pthread_getspecific would cost more than the zone budget allows);
// - C11 atomics on shared, mapped memory, where Swift's Atomic can't live.

#ifndef TD_TRACE_CPU_H
#define TD_TRACE_CPU_H

#include <stdatomic.h>
#include <stdint.h>

static inline uint64_t td_trace_ticks(void) {
#if defined(__x86_64__)
  return __builtin_ia32_rdtsc();
#elif defined(__aarch64__)
  uint64_t v;
  __asm__ volatile("mrs %0, cntvct_el0" : "=r"(v));
  return v;
#elif defined(__riscv) && __riscv_xlen == 64
  uint64_t v;
  __asm__ volatile("rdtime %0" : "=r"(v));
  return v;
#else
#error "td_trace_ticks: no cycle counter for this architecture"
#endif
}

// The calling thread's ring: NULL until it claims one, (void *)1 if none
// was left to claim.
void *td_trace_thread_ring(void);
void td_trace_set_thread_ring(void *ring);

static inline uint64_t td_trace_fetch_add_u64(void *p, uint64_t v) {
  return atomic_fetch_add_explicit((_Atomic uint64_t *)p, v, memory_order_relaxed);
}
static inline uint32_t td_trace_fetch_add_u32(void *p, uint32_t v) {
  return atomic_fetch_add_explicit((_Atomic uint32_t *)p, v, memory_order_relaxed);
}
static inline void td_trace_store_release_u64(void *p, uint64_t v) {
  atomic_store_explicit((_Atomic uint64_t *)p, v, memory_order_release);
}
static inline uint64_t td_trace_load_acquire_u64(const void *p) {
  return atomic_load_explicit((const _Atomic uint64_t *)p, memory_order_acquire);
}

#endif
