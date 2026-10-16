// SPDX-License-Identifier: BSD-3-Clause

// The UTC page (D48): one page the time service writes and every other
// process maps read only, under a seqlock. UTC is the monotonic clock plus
// `offset`; `error` bounds how far that may be from true UTC (UINT64_MAX:
// unknown, as the launcher's backstop is). In C because its reader is the
// floor's td_utc_now, which runs beneath any Swift runtime (as runtime.c
// does), and the seqlock is fences on memory another process shares;
// Sys's writer calls the same functions.

#pragma once
#include <stdint.h>

typedef struct {
  uint64_t seq;      // odd while the writer is mid-update
  int64_t offset;    // UTC minus monotonic, in ns
  uint64_t error;    // in ns
  int64_t updated;   // monotonic time of the last update, in ns
} td_utc_page_t;

// The writer's update. One writer only (the time service).
static inline void td_utc_publish(td_utc_page_t *page, int64_t offset, uint64_t error, int64_t now) {
  uint64_t seq = __atomic_load_n(&page->seq, __ATOMIC_RELAXED);
  __atomic_store_n(&page->seq, seq + 1, __ATOMIC_RELAXED);
  __atomic_thread_fence(__ATOMIC_RELEASE);
  __atomic_store_n(&page->offset, offset, __ATOMIC_RELAXED);
  __atomic_store_n(&page->error, error, __ATOMIC_RELAXED);
  __atomic_store_n(&page->updated, now, __ATOMIC_RELAXED);
  __atomic_store_n(&page->seq, seq + 2, __ATOMIC_RELEASE);
}

// A reader's view: the offset and error as of one update, never torn.
static inline void td_utc_read(const td_utc_page_t *page, int64_t *offset, uint64_t *error) {
  for (;;) {
    uint64_t seq = __atomic_load_n(&page->seq, __ATOMIC_ACQUIRE);
    if (seq & 1) continue;
    int64_t o = __atomic_load_n(&page->offset, __ATOMIC_RELAXED);
    uint64_t e = __atomic_load_n(&page->error, __ATOMIC_RELAXED);
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    if (__atomic_load_n(&page->seq, __ATOMIC_RELAXED) == seq) {
      *offset = o;
      *error = e;
      return;
    }
  }
}
