// SPDX-License-Identifier: BSD-3-Clause

// <unistd.h> (POSIX XBD <unistd.h>), what tier 1 needs so far (M6d):
// sysconf's processor counts and page size, natively the floor's (the
// count from croi's topology page, in the vDSO), and isatty (no terminals
// yet: 0, ENOTTY), getentropy (croi's CPRNG), and the file calls: write
// to stdout and stderr (the floor's, M6f: both the process's debuglog,
// through stdout's lines), and in tier 1 every descriptor's, fdio's (M6g,
// system/fdio). _POSIX_TIMERS: clock_gettime is there (<time.h>).

#pragma once
#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define _POSIX_TIMERS 200809L


#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

#define _SC_PAGESIZE 30
#define _SC_PAGE_SIZE _SC_PAGESIZE
#define _SC_NPROCESSORS_CONF 83
#define _SC_NPROCESSORS_ONLN 84

long sysconf(int name);
int getpagesize(void);  // BSD's and Linux's: 4096
int gethostname(char *name, size_t size);  // "localhost" for now
pid_t getpid(void);  // the process's koid
// No links (fdio's): readlink says EINVAL of what's there, symlink and
// link EPERM.
ssize_t readlink(const char *__restrict path, char *__restrict buffer, size_t size);
int symlink(const char *target, const char *path);
int link(const char *from, const char *to);
#define HOST_NAME_MAX 64
int getentropy(void *buffer, size_t length);
int isatty(int fd);
ssize_t write(int fd, const void *buffer, size_t count);

#define F_OK 0
#define X_OK 1
#define W_OK 2
#define R_OK 4
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

ssize_t read(int fd, void *buffer, size_t count);
ssize_t pread(int fd, void *buffer, size_t count, off_t offset);
ssize_t pwrite(int fd, const void *buffer, size_t count, off_t offset);
off_t lseek(int fd, off_t offset, int whence);
int close(int fd);
int fsync(int fd);
int ftruncate(int fd, off_t size);
int unlink(const char *path);
int rmdir(const char *path);
int access(const char *path, int mode);
char *getcwd(char *buffer, size_t size);
int chdir(const char *path);

#ifdef __cplusplus
}
#endif
