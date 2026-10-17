// SPDX-License-Identifier: BSD-3-Clause

// Plan 9's u.h and libc.h, as much as libsec's oracle files need, on
// Linux (D89). In C because libsec is: 9front's own code, compiled
// unchanged beside this header, for the crypto tests only (never the
// device, D4). Plan 9's ulong is 32 bits on every arch and Linux's is
// 64; libsec uses ulong only for lengths, counts and buffer sizes, so
// the wider one is harmless. The fixed-width types are exact.

#pragma once
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
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
typedef uintptr_t uintptr;
typedef int Rune;

#define nil ((void *)0)
#define nelem(x) (sizeof(x) / sizeof((x)[0]))
#define USED(x) ((void)(x))

void sysfatal(char *, ...);

static inline void *mallocz(ulong n, int clear) { return clear ? calloc(1, n) : malloc(n); }
