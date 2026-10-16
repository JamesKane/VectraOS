// SPDX-License-Identifier: BSD-3-Clause

// <time.h> (ISO C §7.29, POSIX's clocks): struct timespec, POSIX's clock
// ids with Linux's values, clock_gettime, clock_getres and nanosleep
// (natively the floor's, over croi's monotonic clock: M6d), and time. The
// realtime clock is UTC (M6g); no calendar functions yet.

#ifndef TD_TIME_H
#define TD_TIME_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int64_t time_t;
typedef int32_t clockid_t;

struct timespec {
  time_t tv_sec;
  long tv_nsec;
};

#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1
// Linux's, all croi's monotonic clock.
#define CLOCK_MONOTONIC_RAW 4
#define CLOCK_MONOTONIC_COARSE 6
#define CLOCK_BOOTTIME 7

// CLOCK_REALTIME is the UTC clock the launcher gives a process (M6g), set
// from the RTC by the time service; the monotonic clock without one.
time_t time(time_t *out);
int clock_gettime(clockid_t clock, struct timespec *ts);
int clock_getres(clockid_t clock, struct timespec *res);
int nanosleep(const struct timespec *duration, struct timespec *remaining);

#ifdef __cplusplus
}
#endif

#endif
