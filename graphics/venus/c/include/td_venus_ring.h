// SPDX-License-Identifier: BSD-3-Clause

// The Venus ring's shared words (docs/research/venus-protocol.md §12.3):
// head loaded with acquire, tail stored and status loaded sequentially
// consistent, so that either the renderer sees a new tail or we see it
// idle. Swift has no atomics on raw shared memory in tier 0; these are
// the compiler's.

#ifndef TD_VENUS_RING_H
#define TD_VENUS_RING_H

#include <stdint.h>

static inline uint32_t td_venus_load_acquire(const void *p) {
  return __atomic_load_n((const volatile uint32_t *)p, __ATOMIC_ACQUIRE);
}

static inline uint32_t td_venus_load_seq_cst(const void *p) {
  return __atomic_load_n((const volatile uint32_t *)p, __ATOMIC_SEQ_CST);
}

static inline void td_venus_store_seq_cst(void *p, uint32_t value) {
  __atomic_store_n((volatile uint32_t *)p, value, __ATOMIC_SEQ_CST);
}

#endif
