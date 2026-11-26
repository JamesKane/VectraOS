// SPDX-License-Identifier: BSD-3-Clause

// <stdlib.h>'s, <inttypes.h>'s, <string.h>'s and <time.h>'s C side (M6d),
// by principle 28's calling-convention exception: what returns a struct
// (div and its kin), a long double (strtold: Swift has no binary128) or a buffer of its
// own (strerror's, each thread's), or takes a C struct (strftime's struct tm,
// read into fields), over the Swift that does the work
// (system/libc/stdlib, string, time).

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

// In a locale, which can only be "C" (<locale.h>).
long double strtold_l(const char *__restrict s, char **__restrict end, locale_t locale) {
  (void)locale;
  return strtold(s, end);
}

// strftime (time/Strftime.swift): struct tm read into fields here.
#include <time.h>
size_t td_strftime(char *s, size_t max, const char *format, const int64_t fields[9], const char *zone);
size_t strftime(char *__restrict s, size_t max, const char *__restrict format, const struct tm *__restrict tm) {
  int64_t fields[9] = {tm->tm_sec,  tm->tm_min,  tm->tm_hour,  tm->tm_mday,  tm->tm_mon,
                       tm->tm_year, tm->tm_wday, tm->tm_yday, tm->tm_gmtoff};
  return td_strftime(s, max, format, fields, tm->tm_zone);
}
size_t strftime_l(char *__restrict s, size_t max, const char *__restrict format, const struct tm *__restrict tm,
                  locale_t locale) {
  (void)locale;
  return strftime(s, max, format, tm);
}
