/*
sys/types.h -- the handful of POSIX type names the library uses.

A first cut: the widths a program on this machine sees, not the full set.
*/
#ifndef SYS_TYPES_H
#define SYS_TYPES_H

typedef unsigned long size_t;
typedef long ssize_t;
typedef long off_t;
typedef int pid_t;
typedef unsigned int mode_t;
typedef long time_t;

#ifndef NULL
#define NULL ((void *)0)
#endif

#endif
