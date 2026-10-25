// SPDX-License-Identifier: BSD-3-Clause

// <ftw.h> (POSIX XSI): nftw, a walk of a file tree calling a function at
// each entry (natively FDIO's, over its fts: system/fdio/native/nftw.c),
// with glibc's flag and type values.

#pragma once

#include <sys/stat.h>

#ifdef __cplusplus
extern "C" {
#endif

// The entry's kind, as the function is told it.
#define FTW_F 0    // a file
#define FTW_D 1    // a directory, before its contents
#define FTW_DNR 2  // a directory that can't be read
#define FTW_NS 3   // stat failed
#define FTW_SL 4   // a symbolic link (FTW_PHYS)
#define FTW_DP 5   // a directory, after its contents (FTW_DEPTH)
#define FTW_SLN 6  // a symbolic link to nothing

// nftw's flags.
#define FTW_PHYS 1   // links are reported, not followed
#define FTW_MOUNT 2  // stays on one file system (every walk here does)
#define FTW_CHDIR 4  // ignored: the walk never changes directory
#define FTW_DEPTH 8  // a directory is reported after its contents

struct FTW {
  int base;   // where the entry's name starts in its path
  int level;  // its depth below the root, the root 0
};

// Calls `fn` for each entry under `path`, the path itself first (last
// with FTW_DEPTH); a nonzero result from `fn` ends the walk and is
// returned. `nopenfd` is ignored. -1 with errno if the walk fails.
int nftw(const char *path, int (*fn)(const char *, const struct stat *, int, struct FTW *), int nopenfd, int flags);

#ifdef __cplusplus
}
#endif
