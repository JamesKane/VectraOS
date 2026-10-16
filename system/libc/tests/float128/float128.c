// SPDX-License-Identifier: BSD-3-Clause

#define __STDC_WANT_IEC_60559_TYPES_EXT__ 1
#include <stdlib.h>
#include <string.h>

#include "td_float128.h"

void td_strtof128(const char *s, char **end, unsigned char out[16]) {
  _Float128 v = strtof128(s, end);
  memcpy(out, &v, 16);
}

int td_strfromf128(char *buffer, size_t size, const char *format, const unsigned char bits[16]) {
  _Float128 v;
  memcpy(&v, bits, 16);
  return strfromf128(buffer, size, format, v);
}
