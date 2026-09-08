/*
errno.h -- the error a POSIX call left, in the thread's own storage.

The wire's numbers are Linux's, chosen in `docs/VECTRA9.md` for exactly
this: a 9P reply's `-errno` becomes `errno` with no table. `errno` is a
thread-local, so two threads do not overwrite each other's, which the
thread pointer from `docs/DEVTOOLS.md` section 3 made possible.
*/
#ifndef ERRNO_H
#define ERRNO_H

extern _Thread_local int errno;

#define EPERM 1
#define ENOENT 2
#define ESRCH 3
#define EINTR 4
#define EIO 5
#define ENXIO 6
#define E2BIG 7
#define ENOEXEC 8
#define EBADF 9
#define ECHILD 10
#define EAGAIN 11
#define ENOMEM 12
#define EACCES 13
#define EFAULT 14
#define EBUSY 16
#define EEXIST 17
#define EXDEV 18
#define ENODEV 19
#define ENOTDIR 20
#define EISDIR 21
#define EINVAL 22
#define ENFILE 23
#define EMFILE 24
#define ENOSPC 28
#define ESPIPE 29
#define EROFS 30
#define EMLINK 31
#define EPIPE 32
#define EDEADLK 35
#define ENAMETOOLONG 36
#define ENOSYS 38
#define ENOTEMPTY 39
#define ELOOP 40
#define EPROTO 71
#define EOPNOTSUPP 95
#define ETIMEDOUT 110
#define ECONNREFUSED 111

#endif
