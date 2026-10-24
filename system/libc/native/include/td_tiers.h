// SPDX-License-Identifier: BSD-3-Clause

// The tiers' memory routines (D128, native/tiers.c), which the dispatch
// table chooses from.

#pragma once
#include <stddef.h>

#if defined(__x86_64__)
void *td_memcpy_avx2(void *dest, const void *src, size_t n);
void *td_memmove_avx2(void *dest, const void *src, size_t n);
void *td_memset_avx2(void *dest, int c, size_t n);
#endif
