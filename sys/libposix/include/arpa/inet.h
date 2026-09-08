/*
arpa/inet.h -- byte order and address text.

The wire is big-endian, so the `hton`/`ntoh` pair swap on a little-endian
machine. `inet_addr` reads dotted decimal into a network-order address.
*/
#ifndef ARPA_INET_H
#define ARPA_INET_H

#include <netinet/in.h>

unsigned short htons(unsigned short v);
unsigned short ntohs(unsigned short v);
unsigned int htonl(unsigned int v);
unsigned int ntohl(unsigned int v);
in_addr_t inet_addr(const char *dotted);

#endif
