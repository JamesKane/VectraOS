// SPDX-License-Identifier: BSD-3-Clause

// <sys/statvfs.h> (POSIX): struct statvfs, and statvfs and fstatvfs,
// which fail with ENOSYS: fdio reports no file system's capacity yet
// (system/libc/native/files.c).

#pragma once
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint64_t fsblkcnt_t;
typedef uint64_t fsfilcnt_t;

struct statvfs {
  unsigned long f_bsize;
  unsigned long f_frsize;
  fsblkcnt_t f_blocks;
  fsblkcnt_t f_bfree;
  fsblkcnt_t f_bavail;
  fsfilcnt_t f_files;
  fsfilcnt_t f_ffree;
  fsfilcnt_t f_favail;
  unsigned long f_fsid;
  unsigned long f_flag;
  unsigned long f_namemax;
};

#define ST_RDONLY 1
#define ST_NOSUID 2

int statvfs(const char *__restrict path, struct statvfs *__restrict buf);
int fstatvfs(int fd, struct statvfs *buf);

#ifdef __cplusplus
}
#endif
