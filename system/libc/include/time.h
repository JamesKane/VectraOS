// SPDX-License-Identifier: BSD-3-Clause

// <time.h> (ISO C §7.29, POSIX's clocks): struct timespec, POSIX's clock
// ids with Linux's values, clock_gettime, clock_getres, nanosleep and
// clock_nanosleep (natively the floor's, over croi's monotonic clock:
// M6d), and time. The
// realtime clock is UTC (M6g); no calendar functions yet.

#ifndef TD_TIME_H
#define TD_TIME_H

#include <bits/locale_t.h>
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
// flags: TIMER_ABSTIME, `request` a time on `clock` rather than a
// duration. It returns the error number (0 when it slept), not -1.
#define TIMER_ABSTIME 1
int clock_nanosleep(clockid_t clock, int flags, const struct timespec *request, struct timespec *remaining);

// A broken-down time (C23 §7.29.1, with glibc's two fields after).
struct tm {
  int tm_sec;
  int tm_min;
  int tm_hour;
  int tm_mday;
  int tm_mon;
  int tm_year;
  int tm_wday;
  int tm_yday;
  int tm_isdst;
  long tm_gmtoff;
  const char *tm_zone;
};

// strftime in the C locale (C23 §7.29.3.5): every conversion, E and O
// modifiers accepted and ignored; a time zone is the one tm_zone and
// tm_gmtoff name (UTC when tm_zone is null). strftime_l's locale can
// only be "C".
size_t strftime(char *__restrict s, size_t max, const char *__restrict format, const struct tm *__restrict tm);
size_t strftime_l(char *__restrict s, size_t max, const char *__restrict format, const struct tm *__restrict tm,
                  locale_t locale);

#ifdef __cplusplus
}
#endif

#endif
