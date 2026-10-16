// SPDX-License-Identifier: BSD-3-Clause

// <dirent.h> (POSIX XBD): a directory's entries, fdio's (M6g): "." and
// ".." first, then the directory's listing (a union's merged, and mount
// points below it), taken when opened.

#pragma once
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DT_UNKNOWN 0
#define DT_DIR 4
#define DT_REG 8

struct dirent {
  ino_t d_ino;
  off_t d_off;
  unsigned short d_reclen;
  unsigned char d_type;
  char d_name[256];
};

typedef struct td_dir DIR;

DIR *opendir(const char *path);
struct dirent *readdir(DIR *dir);
void rewinddir(DIR *dir);
int closedir(DIR *dir);

#ifdef __cplusplus
}
#endif
