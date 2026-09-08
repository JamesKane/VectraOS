/*
sys/socket.h -- a Berkeley face on Plan 9's dial, `docs/DEVTOOLS.md` section 8.

`socket` reserves a descriptor, `connect` dials `/net` to the address and
turns the descriptor into the conversation's stream, and `read` and
`write` then carry bytes. This is the client half, which is what a program
fetching over the network needs; `bind`, `listen` and `accept` are the
announce side, and come with a server that wants them.
*/
#ifndef SYS_SOCKET_H
#define SYS_SOCKET_H

#include <sys/types.h>

#define AF_INET 2
#define AF_INET6 10
#define SOCK_STREAM 1
#define SOCK_DGRAM 2

typedef unsigned int socklen_t;
typedef unsigned short sa_family_t;

struct sockaddr {
	sa_family_t sa_family;
	char sa_data[14];
};

int socket(int domain, int type, int protocol);
int connect(int fd, const struct sockaddr *addr, socklen_t len);
long send(int fd, const void *buf, size_t n, int flags);
long recv(int fd, void *buf, size_t n, int flags);
int shutdown(int fd, int how);

#endif
