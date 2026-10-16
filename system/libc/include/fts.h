// SPDX-License-Identifier: BSD-3-Clause

// <fts.h>: BSD's file hierarchy walk (fts(3), as glibc has it), fdio's in
// tier 1 (M6g, system/fdio: Walk.swift, native/Fts.swift). glibc's
// constants and FTSENT's fields by name; the layout is ours. No links to
// follow, so FTS_LOGICAL, FTS_COMFOLLOW and FTS_FOLLOW change nothing, and
// FTS_SL, FTS_SLNONE and FTS_DC never come. An entry stays valid until
// fts_close. fts_children isn't there yet.

#pragma once
#include <sys/types.h>
#include <sys/stat.h>

#ifdef __cplusplus
extern "C" {
#endif

// fts_open's options.
#define FTS_COMFOLLOW 0x0001
#define FTS_LOGICAL 0x0002
#define FTS_NOCHDIR 0x0004
#define FTS_NOSTAT 0x0008
#define FTS_PHYSICAL 0x0010
#define FTS_SEEDOT 0x0020
#define FTS_XDEV 0x0040

// fts_info.
#define FTS_D 1
#define FTS_DC 2
#define FTS_DEFAULT 3
#define FTS_DNR 4
#define FTS_DOT 5
#define FTS_DP 6
#define FTS_ERR 7
#define FTS_F 8
#define FTS_INIT 9
#define FTS_NS 10
#define FTS_NSOK 11
#define FTS_SL 12
#define FTS_SLNONE 13

// fts_set's instructions.
#define FTS_AGAIN 1
#define FTS_FOLLOW 2
#define FTS_NOINSTR 3
#define FTS_SKIP 4

typedef struct _ftsent {
  struct _ftsent *fts_cycle;
  struct _ftsent *fts_parent;
  struct _ftsent *fts_link;
  long fts_number;
  void *fts_pointer;
  char *fts_accpath;
  char *fts_path;
  int fts_errno;
  int fts_symfd;
  unsigned short fts_pathlen;
  unsigned short fts_namelen;
  ino_t fts_ino;
  dev_t fts_dev;
  nlink_t fts_nlink;
  short fts_level;
  unsigned short fts_info;
  unsigned short fts_flags;
  unsigned short fts_instr;
  struct stat *fts_statp;
  char fts_name[1];
} FTSENT;

// The walk: its current entry and options, and fdio's state.
typedef struct {
  FTSENT *fts_cur;
  int fts_options;
  void *__td_walk;
} FTS;

FTS *fts_open(char *const *paths, int options, int (*compar)(const FTSENT **, const FTSENT **));
FTSENT *fts_read(FTS *fts);
int fts_set(FTS *fts, FTSENT *entry, int instruction);
int fts_close(FTS *fts);

#ifdef __cplusplus
}
#endif
