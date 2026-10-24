// SPDX-License-Identifier: BSD-3-Clause

// The tiers' memcpy, memmove and memset (D128), which the dispatch table
// (dispatch.c) chooses from. One shape, stamped with a tier's target
// attributes (TD_ROUTINES): a copy up to 128 bytes is two loads that may
// overlap and two stores, the loads first, so it is a move too; a longer
// one stores a vector at each end and aligned vectors between. Where a
// tier's vector is narrower than the shape's, the compiler splits it.
// Only amd64's x86-64-v3 is stamped so far (dispatch.c says why).
//
// C because each variant needs its tier's target attributes, which Swift
// has no per-function form of.

#include <stddef.h>
#include <stdint.h>

#include "td_tiers.h"

typedef uint8_t v16 __attribute__((vector_size(16), aligned(1), may_alias));
typedef uint8_t v32 __attribute__((vector_size(32), aligned(1), may_alias));
typedef uint8_t v64 __attribute__((vector_size(64), aligned(1), may_alias));
typedef uint16_t u16 __attribute__((aligned(1), may_alias));
typedef uint32_t u32 __attribute__((aligned(1), may_alias));
typedef uint64_t u64 __attribute__((aligned(1), may_alias));

// Up to 16 bytes: two loads of the widest word that fits, overlapping.
#define TD_SMALL(d, s, n)                                                       \
  do {                                                                          \
    if (n >= 8) {                                                               \
      u64 a = *(const u64 *)(s), b = *(const u64 *)((s) + n - 8);               \
      *(u64 *)(d) = a, *(u64 *)((d) + n - 8) = b;                               \
    } else if (n >= 4) {                                                        \
      u32 a = *(const u32 *)(s), b = *(const u32 *)((s) + n - 4);               \
      *(u32 *)(d) = a, *(u32 *)((d) + n - 4) = b;                               \
    } else if (n >= 2) {                                                        \
      u16 a = *(const u16 *)(s), b = *(const u16 *)((s) + n - 2);               \
      *(u16 *)(d) = a, *(u16 *)((d) + n - 2) = b;                               \
    } else if (n == 1) {                                                        \
      *(d) = *(s);                                                              \
    }                                                                           \
  } while (0)

// Two vectors of type V, overlapping: n is between one and two of them.
#define TD_PAIR(V, d, s, n)                                                     \
  do {                                                                          \
    V a = *(const V *)(s), b = *(const V *)((s) + n - sizeof(V));               \
    *(V *)(d) = a, *(V *)((d) + n - sizeof(V)) = b;                             \
  } while (0)

// n up to 128 bytes, loads before stores.
#define TD_SHORT(d, s, n)                                                       \
  do {                                                                          \
    if (n <= 16) TD_SMALL(d, s, n);                                             \
    else if (n <= 32) TD_PAIR(v16, d, s, n);                                    \
    else if (n <= 64) TD_PAIR(v32, d, s, n);                                    \
    else TD_PAIR(v64, d, s, n);                                                 \
  } while (0)

// The ends are loaded first and stored last, so a forward copy with dest
// below src, and a backward one with dest above, read nothing they wrote.
#define TD_ROUTINES(tier, attributes)                                           \
  attributes static void tier##_forward(uint8_t *d, const uint8_t *s, size_t n) { \
    v64 head = *(const v64 *)s, tail = *(const v64 *)(s + n - 64);              \
    size_t i = 64 - ((uintptr_t)d & 63);                                        \
    for (; n - i > 64; i += 64) *(v64 *)(d + i) = *(const v64 *)(s + i);        \
    *(v64 *)d = head, *(v64 *)(d + n - 64) = tail;                              \
  }                                                                             \
  attributes static void tier##_backward(uint8_t *d, const uint8_t *s, size_t n) { \
    v64 head = *(const v64 *)s, tail = *(const v64 *)(s + n - 64);              \
    size_t i = n - ((uintptr_t)(d + n) & 63);                                   \
    if (i == n) i -= 64;                                                        \
    for (; i > 64; i -= 64) *(v64 *)(d + i - 64) = *(const v64 *)(s + i - 64);  \
    *(v64 *)(d + n - 64) = tail, *(v64 *)d = head;                              \
  }                                                                             \
  attributes void *td_memcpy_##tier(void *dest, const void *src, size_t n) {   \
    uint8_t *d = dest;                                                          \
    const uint8_t *s = src;                                                     \
    if (n <= 128) TD_SHORT(d, s, n);                                            \
    else tier##_forward(d, s, n);                                               \
    return dest;                                                                \
  }                                                                             \
  attributes void *td_memmove_##tier(void *dest, const void *src, size_t n) {  \
    uint8_t *d = dest;                                                          \
    const uint8_t *s = src;                                                     \
    if (n <= 128) TD_SHORT(d, s, n);                                            \
    else if ((uintptr_t)d - (uintptr_t)s >= n) tier##_forward(d, s, n);         \
    else tier##_backward(d, s, n);                                              \
    return dest;                                                                \
  }                                                                             \
  attributes void *td_memset_##tier(void *dest, int c, size_t n) {             \
    uint8_t *d = dest;                                                          \
    v64 v = (v64){0} + (uint8_t)c;                                              \
    if (n <= 16) {                                                              \
      uint64_t w = (uint8_t)c * 0x0101010101010101ull;                          \
      if (n >= 8) *(u64 *)d = w, *(u64 *)(d + n - 8) = w;                       \
      else if (n >= 4) *(u32 *)d = (uint32_t)w, *(u32 *)(d + n - 4) = (uint32_t)w; \
      else if (n >= 2) *(u16 *)d = (uint16_t)w, *(u16 *)(d + n - 2) = (uint16_t)w; \
      else if (n == 1) *d = (uint8_t)c;                                         \
    } else if (n <= 32) {                                                       \
      v16 h = __builtin_shufflevector(v, v, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15); \
      *(v16 *)d = h, *(v16 *)(d + n - 16) = h;                                  \
    } else if (n <= 64) {                                                       \
      v32 h = __builtin_shufflevector(v, v, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, \
                                      16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31); \
      *(v32 *)d = h, *(v32 *)(d + n - 32) = h;                                  \
    } else {                                                                    \
      *(v64 *)d = v, *(v64 *)(d + n - 64) = v;                                  \
      for (size_t i = 64 - ((uintptr_t)d & 63); i + 64 < n; i += 64) *(v64 *)(d + i) = v; \
    }                                                                           \
    return dest;                                                                \
  }

#if defined(__x86_64__)
TD_ROUTINES(avx2, __attribute__((target("arch=x86-64-v3,tune=x86-64-v3"))))
#endif
