// SPDX-License-Identifier: BSD-3-Clause

// The libc's dispatch table (D128): memcpy, memmove and memset go through
// it. Each entry starts as the baseline's routine (Memory.swift, under
// td_*_baseline), so a call before the table is filled still works; the
// floor calls td_libc_dispatch_select before the program's first
// initializer, which sets each entry for the CPU's tier and then makes
// the table's page read only. A tier's routine joins only once it beats
// the baseline on the budgets it serves (ring.per_1000_slots for memcpy).
// On amd64 tiers 2 and 3 take x86-64-v3's (tiers.c): 4.5 µs against the
// baseline's 6.4 under KVM on a Zen 5, 2026-10-24, and AVX-512's 64-byte
// vectors did no better (4.6), so tier 3 has none of its own. arm64 and
// rv64 keep the baseline's until theirs are measured on hardware.
//
// C because the table needs a page of its own, which Swift can't align a
// global to, and a tier's routines will take that tier's target
// attributes, which Swift has no per-function form of.

#include <stddef.h>
#include <stdint.h>

#include "croi/syscall.h"
#include "td_dispatch.h"
#include "td_floor.h"
#include "td_tiers.h"
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
#if defined(__x86_64__)
  if (tier >= 2)
    table.routines = (td_libc_routines_t){td_memcpy_avx2, td_memmove_avx2, td_memset_avx2};
#else
  (void)tier;  // no tier's routines yet
#endif
  protected_status = (int32_t)croi_vmar_protect(td_runtime_vmar_root, CROI_VM_PERM_READ,
                                                (uint64_t)(uintptr_t)&table, sizeof table);
}

void *memcpy(void *dest, const void *src, size_t n) { return table.routines.copy(dest, src, n); }
void *memmove(void *dest, const void *src, size_t n) { return table.routines.move(dest, src, n); }
void *memset(void *s, int c, size_t n) { return table.routines.set(s, c, n); }
