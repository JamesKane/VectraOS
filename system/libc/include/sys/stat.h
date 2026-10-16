// SPDX-License-Identifier: BSD-3-Clause

// <sys/stat.h> (POSIX XBD): struct stat with Linux's field names (our
// layout), its mode bits, and the calls fdio has (M6g). There are no
// permissions or owners: a file reads 0644, a directory 0755, both owned
// by 0; the three times are the node's modification time.

#pragma once
#include <sys/types.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

struct stat {
  dev_t st_dev;
  ino_t st_ino;
  nlink_t st_nlink;
  mode_t st_mode;
  uid_t st_uid;
  gid_t st_gid;
  dev_t st_rdev;
  off_t st_size;
  blksize_t st_blksize;
  blkcnt_t st_blocks;
  struct timespec st_atim;
  struct timespec st_mtim;
  struct timespec st_ctim;
};

#define st_atime st_atim.tv_sec
#define st_mtime st_mtim.tv_sec
#define st_ctime st_ctim.tv_sec

// POSIX's file types; fdio's nodes are only directories and regular files.
#define S_IFMT 0170000
#define S_IFIFO 0010000
#define S_IFCHR 0020000
#define S_IFDIR 0040000
#define S_IFBLK 0060000
#define S_IFREG 0100000
#define S_IFLNK 0120000
#define S_IFSOCK 0140000
#define S_ISUID 04000
#define S_ISGID 02000
#define S_ISVTX 01000
#define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
#define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)
#define S_ISLNK(m) (((m) & S_IFMT) == S_IFLNK)

#define S_IRWXU 0700
#define S_IRUSR 0400
#define S_IWUSR 0200
#define S_IXUSR 0100
#define S_IRWXG 070
#define S_IRGRP 040
#define S_IWGRP 020
#define S_IXGRP 010
#define S_IRWXO 07
#define S_IROTH 04
#define S_IWOTH 02
#define S_IXOTH 01

int stat(const char *__restrict path, struct stat *__restrict st);
int lstat(const char *__restrict path, struct stat *__restrict st);
int fstat(int fd, struct stat *st);
int mkdir(const char *path, mode_t mode);
// No permissions to change: chmod and fchmod succeed on what's there
// (fdio's, M6g).
int chmod(const char *path, mode_t mode);
int fchmod(int fd, mode_t mode);

#ifdef __cplusplus
}
#endif
