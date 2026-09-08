/*
posix_internal.h -- the library's own declarations, not a program's.

The door, the answer-to-errno helper, and the kernel's own numbers from
the generated `abi.h`. A program includes the standard headers; the
library's sources include this.
*/
#ifndef POSIX_INTERNAL_H
#define POSIX_INTERNAL_H

#include "abi.h"

#ifndef NULL
#define NULL ((void *)0)
#endif

typedef unsigned long usize;

/* The door, shared with `sys/libc`: the call number and six arguments,
   the kernel's signed answer. */
long __vsyscall(long nr, long a0, long a1, long a2, long a3, long a4, long a5);

/* __posix turns the door's answer into POSIX's: -1 with `errno` set on a
   negative reply, the value itself otherwise. */
long __posix(long r);

/* An Odin string, the shape `exec` and the argument block use: a pointer
   and a length, not a NUL-terminated run. */
typedef struct {
	const char *data;
	long len;
} VString;

#endif
