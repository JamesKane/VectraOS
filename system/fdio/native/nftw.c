// SPDX-License-Identifier: BSD-3-Clause

// nftw (POSIX XSI, <ftw.h>) over FDIO's fts, as the BSDs build it. C
// because its callback takes C's struct stat and struct FTW, which the
// fts walk already hands over as pointers.

#include <errno.h>
#include <fts.h>
#include <ftw.h>
#include <string.h>

int nftw(const char *path, int (*fn)(const char *, const struct stat *, int, struct FTW *), int nopenfd, int flags) {
  (void)nopenfd;
  char *const paths[] = {(char *)path, NULL};
  int options = FTS_NOCHDIR | ((flags & FTW_PHYS) ? FTS_PHYSICAL : FTS_LOGICAL);
  FTS *fts = fts_open(paths, options, NULL);
  if (fts == NULL) return -1;
  int result = 0;
  FTSENT *e;
  while (result == 0 && (e = fts_read(fts)) != NULL) {
    int type;
    switch (e->fts_info) {
    case FTS_D:
      if (flags & FTW_DEPTH) continue;
      type = FTW_D;
      break;
    case FTS_DP:
      if (!(flags & FTW_DEPTH)) continue;
      type = FTW_DP;
      break;
    case FTS_DNR: type = FTW_DNR; break;
    case FTS_NS: case FTS_NSOK: type = FTW_NS; break;
    case FTS_SL: type = FTW_SL; break;
    case FTS_SLNONE: type = FTW_SLN; break;
    case FTS_DC: type = FTW_D; break;
    case FTS_ERR:
      errno = e->fts_errno;
      result = -1;
      continue;
    default: type = FTW_F; break;
    }
    struct FTW ftw = {.base = (int)(e->fts_pathlen - e->fts_namelen), .level = e->fts_level};
    result = fn(e->fts_path, e->fts_statp, type, &ftw);
  }
  int saved = errno;
  fts_close(fts);
  errno = saved;
  return result;
}
