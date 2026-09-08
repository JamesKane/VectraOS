/*
poll.c -- a first-cut `poll`, `docs/DEVTOOLS.md` section 8.

No kernel call waits on two descriptors at once, and the plan's answer is
one io proc per descriptor, in the library. `lld` and `clang` poll
nothing, so this reports every descriptor ready for the events it was
asked about and returns their count. A program that truly waits on
several at once grows the io-proc version; until then this keeps such a
program moving rather than blocking it. See section 8.
*/
#include "posix_internal.h"
#include <poll.h>

int poll(struct pollfd *fds, nfds_t n, int timeout)
{
	(void)timeout;
	int ready = 0;
	for (nfds_t i = 0; i < n; i++) {
		fds[i].revents = fds[i].events & (POLLIN | POLLOUT);
		if (fds[i].revents != 0) {
			ready++;
		}
	}
	return ready;
}
