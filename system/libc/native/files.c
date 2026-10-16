// SPDX-License-Identifier: BSD-3-Clause

// The file calls without files: weak definitions that fail as a system
// with no file system would, as stdio.c's remove and rename do. A tier 1
// program's fdio (system/fdio, M6g) gives the real ones, and a strong
// definition wins. Until fdio lands, a program that only mentions them
// (FoundationEssentials does) still links. In C because a weak definition
// is what Swift can't write, and open is variadic.
//
// A path names nothing (ENOENT), a descriptor is none of a file's
// (EBADF), and the working directory is "/", where fdio starts one.

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#define WEAK __attribute__((weak))

static int no_path(void) {
  errno = ENOENT;
  return -1;
}

static int no_descriptor(void) {
  errno = EBADF;
  return -1;
}

WEAK int open(const char *path, int flags, ...) {
  (void)path;
  (void)flags;
  return no_path();
}
WEAK int stat(const char *restrict path, struct stat *restrict st) {
  (void)path;
  (void)st;
  return no_path();
}
WEAK int lstat(const char *restrict path, struct stat *restrict st) {
  (void)path;
  (void)st;
  return no_path();
}
WEAK int access(const char *path, int mode) {
  (void)path;
  (void)mode;
  return no_path();
}
WEAK int mkdir(const char *path, mode_t mode) {
  (void)path;
  (void)mode;
  return no_path();
}
WEAK int chmod(const char *path, mode_t mode) {
  (void)path;
  (void)mode;
  return no_path();
}
WEAK int unlink(const char *path) {
  (void)path;
  return no_path();
}
WEAK int rmdir(const char *path) {
  (void)path;
  return no_path();
}
WEAK int chdir(const char *path) {
  (void)path;
  return no_path();
}
WEAK ssize_t readlink(const char *restrict path, char *restrict buffer, size_t size) {
  (void)path;
  (void)buffer;
  (void)size;
  return no_path();
}
WEAK int symlink(const char *target, const char *path) {
  (void)target;
  (void)path;
  return no_path();
}
WEAK int link(const char *from, const char *to) {
  (void)from;
  (void)to;
  return no_path();
}
WEAK char *realpath(const char *restrict path, char *restrict resolved) {
  (void)path;
  (void)resolved;
  no_path();
  return 0;
}
// POSIX's failure: the template made an empty string.
WEAK char *mktemp(char *template_) {
  template_[0] = 0;
  no_path();
  return template_;
}

WEAK char *getcwd(char *buffer, size_t size) {
  if (size < 2) {
    errno = size == 0 ? EINVAL : ERANGE;
    return 0;
  }
  buffer[0] = '/';
  buffer[1] = 0;
  return buffer;
}

WEAK ssize_t read(int fd, void *buffer, size_t count) {
  (void)fd;
  (void)buffer;
  (void)count;
  return no_descriptor();
}
WEAK ssize_t pread(int fd, void *buffer, size_t count, off_t offset) {
  (void)fd;
  (void)buffer;
  (void)count;
  (void)offset;
  return no_descriptor();
}
WEAK ssize_t pwrite(int fd, const void *buffer, size_t count, off_t offset) {
  (void)fd;
  (void)buffer;
  (void)count;
  (void)offset;
  return no_descriptor();
}
WEAK off_t lseek(int fd, off_t offset, int whence) {
  (void)fd;
  (void)offset;
  (void)whence;
  return no_descriptor();
}
WEAK int close(int fd) {
  (void)fd;
  return no_descriptor();
}
WEAK int fsync(int fd) {
  (void)fd;
  return no_descriptor();
}
WEAK int ftruncate(int fd, off_t size) {
  (void)fd;
  (void)size;
  return no_descriptor();
}
WEAK int fstat(int fd, struct stat *st) {
  (void)fd;
  (void)st;
  return no_descriptor();
}
WEAK int fchmod(int fd, mode_t mode) {
  (void)fd;
  (void)mode;
  return no_descriptor();
}

// No directory opens, so none is ever handed back.
WEAK DIR *opendir(const char *path) {
  (void)path;
  no_path();
  return 0;
}
WEAK struct dirent *readdir(DIR *dir) {
  (void)dir;
  no_descriptor();
  return 0;
}
WEAK void rewinddir(DIR *dir) { (void)dir; }
WEAK int closedir(DIR *dir) {
  (void)dir;
  return no_descriptor();
}
WEAK FTS *fts_open(char *const *paths, int options, int (*compar)(const FTSENT **, const FTSENT **)) {
  (void)paths;
  (void)options;
  (void)compar;
  no_path();
  return 0;
}
WEAK FTSENT *fts_read(FTS *fts) {
  (void)fts;
  no_descriptor();
  return 0;
}
WEAK int fts_set(FTS *fts, FTSENT *entry, int instruction) {
  (void)fts;
  (void)entry;
  (void)instruction;
  return no_descriptor();
}
WEAK int fts_close(FTS *fts) {
  (void)fts;
  return no_descriptor();
}
