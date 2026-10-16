// SPDX-License-Identifier: BSD-3-Clause

// <inttypes.h> (C23 §7.8) for LP64 (all three of croi's machines): the
// printf and scanf macros, imaxabs, imaxdiv, strtoimax and strtoumax
// (system/libc/stdlib, M6d). No wide-character conversions.

#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PRId8 "d"
#define PRId16 "d"
#define PRId32 "d"
#define PRId64 "ld"
#define PRIdMAX "ld"
#define PRIdPTR "ld"
#define PRIi8 "i"
#define PRIi16 "i"
#define PRIi32 "i"
#define PRIi64 "li"
#define PRIiMAX "li"
#define PRIiPTR "li"
#define PRIu8 "u"
#define PRIu16 "u"
#define PRIu32 "u"
#define PRIu64 "lu"
#define PRIuMAX "lu"
#define PRIuPTR "lu"
#define PRIo8 "o"
#define PRIo16 "o"
#define PRIo32 "o"
#define PRIo64 "lo"
#define PRIoMAX "lo"
#define PRIoPTR "lo"
#define PRIx8 "x"
#define PRIx16 "x"
#define PRIx32 "x"
#define PRIx64 "lx"
#define PRIxMAX "lx"
#define PRIxPTR "lx"
#define PRIX8 "X"
#define PRIX16 "X"
#define PRIX32 "X"
#define PRIX64 "lX"
#define PRIXMAX "lX"
#define PRIXPTR "lX"

typedef struct { intmax_t quot, rem; } imaxdiv_t;

intmax_t imaxabs(intmax_t j);
imaxdiv_t imaxdiv(intmax_t numer, intmax_t denom);
intmax_t strtoimax(const char *__restrict nptr, char **__restrict endptr, int base);
uintmax_t strtoumax(const char *__restrict nptr, char **__restrict endptr, int base);

#ifdef __cplusplus
}
#endif
