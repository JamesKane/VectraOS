// SPDX-License-Identifier: BSD-3-Clause

// The libc suite's C side for what C++'s iostreams and ported C programs
// take from the libc (LibcSuite.swift has the checks): the C locale,
// sscanf, asprintf, strftime, setjmp, getopt_long, getrusage and rand,
// and file streams with no fdio. Variadic calls, setjmp and C's structs
// are C's, so they are exercised here; each returns 1 if all held.

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <locale.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#ifdef __CHAR_UNSIGNED__
#define NO_VALUE 255
#else
#define NO_VALUE 127
#endif

// setlocale's names, localeconv's conventions, locale objects and the
// thread's locale, the *_l forms and collation.
int libc_suite_locale(void) {
  if (strcmp(setlocale(LC_ALL, NULL), "C") != 0 || strcmp(setlocale(LC_NUMERIC, ""), "C") != 0) return 0;
  if (setlocale(LC_ALL, "POSIX") == NULL || setlocale(LC_ALL, "en_US.UTF-8") != NULL) return 0;
  struct lconv *c = localeconv();
  if (strcmp(c->decimal_point, ".") != 0 || c->thousands_sep[0] != 0 || c->frac_digits != (char)NO_VALUE) return 0;
  locale_t l = newlocale(LC_ALL_MASK, "C", (locale_t)0);
  if (l == NULL || newlocale(LC_ALL_MASK, "fr_FR", (locale_t)0) != NULL || errno != ENOENT) return 0;
  if (uselocale((locale_t)0) != LC_GLOBAL_LOCALE || uselocale(l) != LC_GLOBAL_LOCALE || uselocale((locale_t)0) != l)
    return 0;
  uselocale(LC_GLOBAL_LOCALE);
  locale_t d = duplocale(l);
  int ok = d != NULL && isdigit_l('7', d) && !isalpha_l('7', d) && toupper_l('q', d) == 'Q' && isxdigit_l('F', d);
  char *end;
  ok = ok && strtod_l("2.5x", &end, d) == 2.5 && *end == 'x' && strtoll_l("-0x10", NULL, 0, d) == -16
       && strtoull_l("777", NULL, 8, d) == 511 && strtof_l("0.5", NULL, d) == 0.5f;
  (void)strtold_l("4x", &end, d);  // its value is printf's to check (tier 0 has no binary128 compare)
  ok = ok && *end == 'x';
  char x[8];
  ok = ok && strcoll("abc", "abd") < 0 && strcoll_l("b", "a", d) > 0 && strxfrm(x, "croi", sizeof x) == 4
       && strcmp(x, "croi") == 0 && strxfrm(NULL, "longer", 0) == 6;
  freelocale(d);
  freelocale(l);
  return ok;
}

// Integers in each base and size, floats, strings, a scanset, characters,
// %n, suppression, widths, a pointer, matching and input failures, EOF.
int libc_suite_scan(void) {
  int a = 0, b = 0, n = 0;
  unsigned u = 0;
  unsigned long long ull = 0;
  short h = 0;
  unsigned char hh = 0;
  double d = 0;
  float f = 0;
  char s[16] = {0}, set[16] = {0}, cs[4] = {0};
  void *p = NULL;
  if (sscanf("  42 -0x1f 0777 18446744073709551615", "%d %i %o %llu", &a, &b, &u, &ull) != 4 || a != 42 || b != -31
      || u != 511 || ull != 18446744073709551615ull)
    return 0;
  if (sscanf("-12 300 1.5e3 -0x1p-2", "%hd %hhu %lf %f", &h, &hh, &d, &f) != 4 || h != -12 || hh != 44 || d != 1500
      || f != -0.25f)
    return 0;
  if (sscanf("inf", "%lf", &d) != 1 || d != __builtin_inf()) return 0;
  if (sscanf("word next", "%s%n", s, &n) != 1 || strcmp(s, "word") != 0 || n != 4) return 0;
  if (sscanf("abc123xyz", "%[a-c]%*d%3c", set, cs) != 2 || strcmp(set, "abc") != 0 || memcmp(cs, "xyz", 3) != 0)
    return 0;
  if (sscanf("12345", "%2d%d", &a, &b) != 2 || a != 12 || b != 345) return 0;
  if (sscanf("0x1234", "%p", &p) != 1 || p != (void *)0x1234) return 0;
  if (sscanf("[x]", "[%[^]]]", set) != 1 || strcmp(set, "x") != 0) return 0;
  if (sscanf("7 apples", "%d pears", &a) != 1) return 0;  // a matching failure after one item
  if (sscanf("abc", "%d", &a) != 0) return 0;              // a matching failure first
  if (sscanf("", "%d", &a) != EOF || sscanf("   ", " %d", &a) != EOF) return 0;
  return sscanf("100%", "%d%%", &a) == 1 && a == 100;
}

// The text in malloc's buffer, and its length.
int libc_suite_asprintf(void) {
  char *s = NULL;
  int n = asprintf(&s, "%s=%d", "answer", 42);
  int ok = n == 9 && s != NULL && strcmp(s, "answer=42") == 0;
  free(s);
  return ok;
}

// Every conversion of the C locale, ISO weeks at a year's edges, a time
// zone, a buffer too small.
int libc_suite_strftime(void) {
  struct tm t = {.tm_sec = 7, .tm_min = 5, .tm_hour = 21, .tm_mday = 3, .tm_mon = 0, .tm_year = 121, .tm_wday = 0,
                 .tm_yday = 2, .tm_gmtoff = -5 * 3600 - 1800, .tm_zone = "NST"};
  char b[200];
  size_t n = strftime(b, sizeof b,
                      "%a %A %b %B %C %d %D %e %F %g %G %H %I %j %m %M %p %R %S %T %u %U %V %w %W %y %Y %z %Z %%", &t);
  const char *want = "Sun Sunday Jan January 20 03 01/03/21  3 2021-01-03 20 2020 21 09 003 01 05 PM 21:05 07 21:05:07 "
                     "7 01 53 0 00 21 2021 -0530 NST %";
  if (n != strlen(want) || strcmp(b, want) != 0) return 0;
  if (strftime(b, sizeof b, "%c|%x|%X|%r|%Ey|%Od", &t) == 0
      || strcmp(b, "Sun Jan  3 21:05:07 2021|01/03/21|21:05:07|09:05:07 PM|21|03") != 0)
    return 0;
  // 2026-12-31, a Thursday: ISO week 53 of 2026.
  struct tm e = {.tm_mday = 31, .tm_mon = 11, .tm_year = 126, .tm_wday = 4, .tm_yday = 364};
  if (strftime(b, sizeof b, "%G-W%V-%u", &e) == 0 || strcmp(b, "2026-W53-4") != 0) return 0;
  return strftime(b, 4, "%Y", &t) == 0 && strftime(b, 5, "%Y", &t) == 4;
}

// A return through frames with callee-saved state kept, and
// longjmp(env, 0) seen as 1.
static jmp_buf jump;
[[gnu::noinline]] static void leap(int value, int depth) {
  if (depth == 0) longjmp(jump, value);
  leap(value, depth - 1);
}
int libc_suite_setjmp(void) {
  volatile int round = 0;
  volatile double kept = 1.5;
  int r = setjmp(jump);
  if (round == 0) {
    round = 1;
    leap(7, 5);
  }
  if (round == 1) {
    if (r != 7 || kept != 1.5) return 0;
    round = 2;
    r = setjmp(jump);
    if (round == 2) {
      round = 3;
      leap(0, 2);
    }
    return round == 3 && r == 1;
  }
  return 0;
}

// Short options grouped and with arguments, long ones by prefix, with =
// and as the next argument, a flag, an unknown option, "--", and a
// missing argument.
int libc_suite_getopt(void) {
  int flag = 0;
  const struct option longs[] = {{"benchmark", required_argument, NULL, 'b'},
                                 {"off-screen", no_argument, &flag, 1},
                                 {"size", required_argument, NULL, 's'},
                                 {NULL, 0, NULL, 0}};
  char *argv[] = {"t", "-vx", "-b", "build", "--bench=shading", "--off", "--size", "800x600", "-q", "--", "-v", NULL};
  opterr = 0;
  optind = 0;
  int verbose = 0, x = 0, unknown = 0, sizes = 0, nb = 0, c, index = -1;
  char benchmarks[2][16] = {{0}};
  while ((c = getopt_long(11, argv, "vxb:s:", longs, &index)) != -1) {
    switch (c) {
    case 'v': verbose++; break;
    case 'x': x++; break;
    case 'b':
      if (nb < 2) strcpy(benchmarks[nb++], optarg);
      break;
    case 's': sizes += strcmp(optarg, "800x600") == 0; break;
    case '?': unknown += optopt == 'q'; break;
    }
  }
  if (verbose != 1 || x != 1 || nb != 2 || strcmp(benchmarks[0], "build") != 0 || strcmp(benchmarks[1], "shading") != 0
      || flag != 1 || sizes != 1 || unknown != 1 || optind != 10)
    return 0;
  char *missing[] = {"t", "-b", NULL};
  optind = 0;
  return getopt(2, missing, ":b:") == ':' && optopt == 'b';
}

// The process's CPU time grows as it runs, the realtime clock is read,
// rand repeats for a seed.
int libc_suite_usage(void) {
  struct rusage before, after;
  if (getrusage(RUSAGE_SELF, &before) != 0) return 0;
  for (volatile int spin = 0; spin < 2000000; spin++) {}
  if (getrusage(RUSAGE_THREAD, &after) != 0 || getrusage(5, &after) != -1 || getrusage(RUSAGE_SELF, &after) != 0)
    return 0;
  long long t0 = before.ru_utime.tv_sec * 1000000ll + before.ru_utime.tv_usec;
  long long t1 = after.ru_utime.tv_sec * 1000000ll + after.ru_utime.tv_usec;
  struct timeval tv;
  if (t1 <= t0 || gettimeofday(&tv, NULL) != 0 || tv.tv_usec < 0 || tv.tv_usec >= 1000000) return 0;
  srand(9);
  int r1 = rand(), r2 = rand();
  srand(9);
  return r1 == rand() && r2 == rand() && r1 != r2 && r1 >= 0 && r1 <= RAND_MAX;
}

// With no fdio (tier 0): fopen fails as open does, a standard stream
// doesn't seek, a call relative to a directory's descriptor is ENOSYS,
// pathconf has the file limits.
int libc_suite_no_files(void) {
  if (fopen("/nope", "r") != NULL || errno != ENOENT || fopen("/nope", "q") != NULL || errno != EINVAL) return 0;
  if (fseek(stdout, 0, SEEK_SET) != -1 || errno != ESPIPE || ftell(stdin) != -1) return 0;
  if (openat(3, "x", O_RDONLY) != -1 || errno != ENOSYS || unlinkat(AT_FDCWD, "/nope", 0) != -1 || errno != ENOENT)
    return 0;
  if (fdopendir(3) != NULL || errno != ENOSYS || ungetc('a', stdout) != EOF) return 0;
  return pathconf("/", _PC_NAME_MAX) == 255 && pathconf("/", _PC_PATH_MAX) == 4096
         && setvbuf(stdout, NULL, _IOLBF, 0) == 0;
}
