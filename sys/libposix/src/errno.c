/*
errno.c -- the thread's error number, and the door's answer turned into it.

The kernel answers a call with a count or a descriptor at zero or more,
and `-errno` below. `__posix` is the one place that reading is turned into
POSIX's: a negative answer sets `errno` and returns -1, and anything else
passes through. The wire's numbers are Linux's, so no table stands between
the reply and `errno`. See `docs/DEVTOOLS.md` section 8.
*/
#include "posix_internal.h"

_Thread_local int errno = 0;

long __posix(long r)
{
	if (r < 0) {
		errno = (int)(-r);
		return -1;
	}
	return r;
}
