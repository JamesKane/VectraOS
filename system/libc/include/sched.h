// SPDX-License-Identifier: BSD-3-Clause

// <sched.h> (POSIX XBD <sched.h>): sched_yield, natively the floor's
// (M6d): croi's nanosleep with a deadline already past.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

int sched_yield(void);

#ifdef __cplusplus
}
#endif
