// SPDX-License-Identifier: BSD-3-Clause

// The libc's dispatch table (D128, native/dispatch.c): the routines
// memcpy, memmove and memset call, set once for the CPU's tier.

#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct {
  void *(*copy)(void *dest, const void *src, size_t n);
  void *(*move)(void *dest, const void *src, size_t n);
  void *(*set)(void *s, int c, size_t n);
} td_libc_routines_t;

// The table, read only once selected.
const td_libc_routines_t *td_libc_dispatch(void);
// Sets the table for the CPU's tier and makes its page read only: the
// floor calls it once, before the program's first initializer.
void td_libc_dispatch_select(void);
// The protection's status: 0 once read only, 1 before the selection, or
// vmar_protect's error.
int32_t td_libc_dispatch_protected(void);
