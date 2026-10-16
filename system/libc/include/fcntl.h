// SPDX-License-Identifier: BSD-3-Clause

// <fcntl.h> (POSIX XBD): open's flags, with Linux's values (M6g). Files
// are fdio's (system/fdio): descriptors over the Node and fs protocols, in
// tier 1's programs.

#pragma once
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define O_ACCMODE 0003
#define O_RDONLY 00
#define O_WRONLY 01
#define O_RDWR 02
#define O_CREAT 0100
#define O_EXCL 0200
#define O_NOCTTY 0400
#define O_TRUNC 01000
#define O_APPEND 02000
#define O_NONBLOCK 04000
#define O_DIRECTORY 0200000
#define O_NOFOLLOW 0400000
#define O_CLOEXEC 02000000

int open(const char *path, int flags, ...);
int creat(const char *path, mode_t mode);

// open, not variadic: Swift can't call a variadic function, so the
// platform module's open (VectraOSLibc) calls this.
static inline int __td_open(const char *path, int flags, mode_t mode) { return open(path, flags, mode); }

#ifdef __cplusplus
}
#endif
