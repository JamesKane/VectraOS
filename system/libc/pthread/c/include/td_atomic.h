// SPDX-License-Identifier: BSD-3-Clause

// Atomics on words in memory a C caller owns (M5k: pthreads' mutexes,
// conditions, onces): Swift's Atomic owns its storage, these act on any
// 32-bit word, sequentially consistent. The compiler's builtins.

#ifndef TD_ATOMIC_H
#define TD_ATOMIC_H

#include <stdint.h>

static inline uint32_t td_atomic_load(const void *p) { return __atomic_load_n((const volatile uint32_t *)p, __ATOMIC_SEQ_CST); }

static inline void td_atomic_store(void *p, uint32_t v) { __atomic_store_n((volatile uint32_t *)p, v, __ATOMIC_SEQ_CST); }

static inline uint32_t td_atomic_exchange(void *p, uint32_t v) {
  return __atomic_exchange_n((volatile uint32_t *)p, v, __ATOMIC_SEQ_CST);
}

/// 1 if `*p` was `expected` and is now `desired`.
static inline int td_atomic_cas(void *p, uint32_t expected, uint32_t desired) {
  return __atomic_compare_exchange_n((volatile uint32_t *)p, &expected, desired, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}

/// The value before adding.
static inline uint32_t td_atomic_add(void *p, uint32_t v) { return __atomic_fetch_add((volatile uint32_t *)p, v, __ATOMIC_SEQ_CST); }

#endif
