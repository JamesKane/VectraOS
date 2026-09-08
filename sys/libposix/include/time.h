/*
time.h -- the clock, over `/dev/time` and the tick.

`clock_gettime` and `gettimeofday` read `/dev/time`, whose line is the
seconds and nanoseconds since 1970 and the tick and its rate.
`nanosleep` is a sleep in ticks, the timer running at a thousand hertz.
*/
#ifndef TIME_H
#define TIME_H

#include <sys/types.h>

#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1

typedef long clockid_t;

struct timespec {
	time_t tv_sec;
	long tv_nsec;
};

struct timeval {
	time_t tv_sec;
	long tv_usec;
};

int clock_gettime(clockid_t clk, struct timespec *ts);
int nanosleep(const struct timespec *req, struct timespec *rem);
int gettimeofday(struct timeval *tv, void *tz);
time_t time(time_t *t);

#endif
