// SPDX-License-Identifier: BSD-3-Clause

// <stdlib.h>'s, <inttypes.h>'s and <string.h>'s C side (M6d), by principle
// 28's calling-convention exception: what returns a struct (div and its
// kin), a long double (strtold: Swift has no binary128) or a buffer of its
// own (strerror's, each thread's), over the Swift that does the work
// (system/libc/stdlib, string).

#include <inttypes.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

div_t div(int numer, int denom) { return (div_t){numer / denom, numer % denom}; }
ldiv_t ldiv(long numer, long denom) { return (ldiv_t){numer / denom, numer % denom}; }
lldiv_t lldiv(long long numer, long long denom) { return (lldiv_t){numer / denom, numer % denom}; }
imaxdiv_t imaxdiv(intmax_t numer, intmax_t denom) { return (imaxdiv_t){numer / denom, numer % denom}; }

// strtold: the Swift conversion's bits, in the target's long double.
void td_strtold(const char *s, char **end, uint64_t out[2]);
long double strtold(const char *__restrict s, char **__restrict end) {
  union {
    uint64_t words[2];
    long double value;
  } u = {{0, 0}};
  td_strtold(s, end, u.words);
  return u.value;
}

char *strerror(int errnum) {
  static _Thread_local char buffer[40];
  strerror_r(errnum, buffer, sizeof buffer);
  return buffer;
}
