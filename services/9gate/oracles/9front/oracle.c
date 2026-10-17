// SPDX-License-Identifier: BSD-3-Clause

// fcall_oracle.h's calls, over 9front's conversion files (in C because
// they are; host only, D4). convM2S rewrites its input in place (each
// string moved down over its count to end in NUL), so it reads a copy.
// A message's strings end at a NUL it carries, as Plan 9's do, so a
// string holding one comes back shorter, and differs.

#include <stdlib.h>
#include <u.h>
#include <libc.h>
#include <fcall.h>
#include "include/fcall_oracle.h"

uint32_t fcall_oracle_reencode(const uint8_t *in, uint32_t n, uint8_t *out, uint32_t cap) {
  uchar *copy = malloc(n ? n : 1);
  Fcall f;
  uint got, put;

  memcpy(copy, in, n);
  memset(&f, 0, sizeof f);
  got = convM2S(copy, n, &f);
  put = got == n ? convS2M(&f, out, cap) : 0;
  free(copy);
  return put;
}

uint32_t fcall_oracle_reencode_stat(const uint8_t *in, uint32_t n, uint8_t *out, uint32_t cap) {
  uchar *copy = malloc(n ? n : 1);
  char *strs = malloc(n + 4);
  Dir d;
  uint put = 0;

  memcpy(copy, in, n);
  if(statcheck(copy, n) == 0 && convM2D(copy, n, &d, strs) == n)
    put = convD2M(&d, out, cap);
  free(strs);
  free(copy);
  return put == 2 ? 0 : put;
}
