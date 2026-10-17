// SPDX-License-Identifier: BSD-3-Clause

// Plan 9's u.h and libc.h, as much as fcall(2)'s conversion files need,
// on Linux. In C because they are: 9front's own code, compiled unchanged
// beside this header, for 9gate's codec tests only (never the device,
// D4), as libsec is crypto's oracle (D89). The fixed-width types are
// exact; Qid and Dir are libc.h's.

#pragma once
#include <stdint.h>
#include <string.h>

typedef unsigned char uchar;
typedef unsigned short ushort;
typedef unsigned int uint;
typedef unsigned long ulong;
typedef long long vlong;
typedef unsigned long long uvlong;
typedef uint8_t u8int;
typedef uint16_t u16int;
typedef uint32_t u32int;
typedef uint64_t u64int;

#define nil ((void *)0)

typedef struct Fmt Fmt;

typedef struct Qid {
  uvlong path;
  ulong vers;
  uchar type;
} Qid;

typedef struct Dir {
  ushort type;
  uint dev;
  Qid qid;
  ulong mode;
  ulong atime;
  ulong mtime;
  vlong length;
  char *name;
  char *uid;
  char *gid;
  char *muid;
} Dir;
