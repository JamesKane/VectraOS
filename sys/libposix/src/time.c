/*
time.c -- the clock over `/dev/time`, `docs/DEVTOOLS.md` section 8.

`/dev/time` answers `seconds nanoseconds ticks hz`. `clock_gettime` and
`gettimeofday` read it and hand back the first two, and `nanosleep` is a
sleep in ticks, the timer at a thousand hertz. A read of a value file
answers the whole line at any offset, so one open and one read is enough.
*/
#include "posix_internal.h"
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

static int read_time(long *sec, long *nsec)
{
	int fd = (int)__vsyscall(SYS_OPEN, (long)"/dev/time", 9, 0, 0, 0, 0);
	if (fd < 0) {
		errno = (int)(-fd);
		return -1;
	}
	char buf[96];
	long n = __vsyscall(SYS_READ, fd, (long)buf, (long)sizeof(buf) - 1, 0, 0, 0);
	__vsyscall(SYS_CLOSE, fd, 0, 0, 0, 0, 0);
	if (n <= 0) {
		errno = EIO;
		return -1;
	}
	buf[n] = 0;
	long v[2] = {0, 0};
	int at = 0;
	for (int f = 0; f < 2; f++) {
		while (buf[at] == ' ') {
			at++;
		}
		while (buf[at] >= '0' && buf[at] <= '9') {
			v[f] = v[f] * 10 + (buf[at] - '0');
			at++;
		}
	}
	*sec = v[0];
	*nsec = v[1];
	return 0;
}

int clock_gettime(clockid_t clk, struct timespec *ts)
{
	(void)clk;
	long sec, nsec;
	if (read_time(&sec, &nsec) != 0) {
		return -1;
	}
	ts->tv_sec = sec;
	ts->tv_nsec = nsec;
	return 0;
}

int gettimeofday(struct timeval *tv, void *tz)
{
	(void)tz;
	long sec, nsec;
	if (read_time(&sec, &nsec) != 0) {
		return -1;
	}
	tv->tv_sec = sec;
	tv->tv_usec = nsec / 1000;
	return 0;
}

time_t time(time_t *t)
{
	long sec, nsec;
	if (read_time(&sec, &nsec) != 0) {
		return (time_t)-1;
	}
	if (t != NULL) {
		*t = sec;
	}
	return sec;
}

int nanosleep(const struct timespec *req, struct timespec *rem)
{
	(void)rem;
	long ms = req->tv_sec * 1000 + req->tv_nsec / 1000000;
	__vsyscall(SYS_SLEEP, ms > 0 ? ms : 1, 0, 0, 0, 0, 0);
	return 0;
}
