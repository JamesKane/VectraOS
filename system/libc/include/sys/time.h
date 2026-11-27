// SPDX-License-Identifier: BSD-3-Clause

// <sys/time.h> (POSIX): struct timeval, gettimeofday (the realtime clock,
// as clock_gettime's CLOCK_REALTIME; no time zone), and utimes, which
// fails with ENOSYS: fdio sets no file's times yet.

#pragma once
#include <sys/types.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef long suseconds_t;

struct timeval {
  time_t tv_sec;
  suseconds_t tv_usec;
};

int gettimeofday(struct timeval *__restrict tv, void *__restrict zone);
int utimes(const char *path, const struct timeval times[2]);

#ifdef __cplusplus
}
#endif
