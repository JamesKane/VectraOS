// SPDX-License-Identifier: BSD-3-Clause

// The libc's dispatch table (D128): memcpy, memmove and memset go through
// it. Each entry starts as the baseline's routine (Memory.swift, under
// td_*_baseline), so a call before the table is filled still works; the
// floor calls td_libc_dispatch_select before the program's first
// initializer, which sets each entry for the CPU's tier and then makes
// the table's page read only. A tier's routine joins only once it beats
// the baseline on the budgets it serves (ring.per_1000_slots for memcpy);
// none has yet, so every tier keeps the baseline's.
//
// C because the table needs a page of its own, which Swift can't align a
// global to, and a tier's routines will take that tier's target
// attributes, which Swift has no per-function form of.

#include <stddef.h>
#include <stdint.h>

#include "croi/syscall.h"
#include "td_dispatch.h"
#include "td_floor.h"
#include "td_native.h"  // td_runtime_vmar_root

void *td_memcpy_baseline(void *dest, const void *src, size_t n);
void *td_memmove_baseline(void *dest, const void *src, size_t n);
void *td_memset_baseline(void *s, int c, size_t n);


static union {
  td_libc_routines_t routines;
  uint8_t page[4096];
} table __attribute__((aligned(4096))) = {
    .routines = {td_memcpy_baseline, td_memmove_baseline, td_memset_baseline},
};

static int32_t protected_status = 1;  // not yet selected

const td_libc_routines_t *td_libc_dispatch(void) { return &table.routines; }

int32_t td_libc_dispatch_protected(void) { return protected_status; }

void td_libc_dispatch_select(void) {
  if (protected_status != 1) return;
  uint32_t tier = td_cpu_tier();
  (void)tier;  // no tier's routines yet
  protected_status = (int32_t)croi_vmar_protect(td_runtime_vmar_root, CROI_VM_PERM_READ,
                                                (uint64_t)(uintptr_t)&table, sizeof table);
}

void *memcpy(void *dest, const void *src, size_t n) { return table.routines.copy(dest, src, n); }
void *memmove(void *dest, const void *src, size_t n) { return table.routines.move(dest, src, n); }
void *memset(void *s, int c, size_t n) { return table.routines.set(s, c, n); }
