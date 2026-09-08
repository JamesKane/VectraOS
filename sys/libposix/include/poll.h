/*
poll.h -- waiting on descriptors, `docs/DEVTOOLS.md` section 8.

The plan's answer is one io proc per descriptor, in the library, because
no kernel call waits on two at once. `lld` and `clang` poll nothing, so a
first cut reports every descriptor ready for what it was asked and lets a
program that truly waits grow the io-proc version. See section 8.
*/
#ifndef POLL_H
#define POLL_H

#define POLLIN 1
#define POLLPRI 2
#define POLLOUT 4
#define POLLERR 8
#define POLLHUP 16
#define POLLNVAL 32

struct pollfd {
	int fd;
	short events;
	short revents;
};

typedef unsigned long nfds_t;

int poll(struct pollfd *fds, nfds_t n, int timeout);

#endif
