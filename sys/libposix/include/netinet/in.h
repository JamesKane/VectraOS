/*
netinet/in.h -- the internet address a `connect` takes.

`sockaddr_in` is the family, a port in network order, and a four-byte
address in network order. `sys/libposix`'s `connect` reads them back into
the `host!port` string `/net` dials with.
*/
#ifndef NETINET_IN_H
#define NETINET_IN_H

#include <sys/socket.h>

typedef unsigned int in_addr_t;
typedef unsigned short in_port_t;

struct in_addr {
	in_addr_t s_addr;
};

struct sockaddr_in {
	sa_family_t sin_family;
	in_port_t sin_port;
	struct in_addr sin_addr;
	char sin_zero[8];
};

#define INADDR_ANY 0
#define INADDR_LOOPBACK 0x7f000001

#endif
