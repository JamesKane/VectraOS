// fmt_test.c: lib/vx-fmt's slices and formatting (M6 step 6e4c2). Every
// format is checked against the host C library's snprintf, byte for byte,
// floating point among them: random doubles through each conversion.

#include <float.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#include "check.h"
#include "../../lib/vx-fmt/fmt.c"

static int compared;

// fmt with one argument, both ways.
#define SAME(fmt, ...)                                                                                       \
  do {                                                                                                       \
    char want[4096], got[4096];                                                                              \
    int wn = snprintf(want, sizeof want, fmt, __VA_ARGS__);                                                  \
    size_t gn = vx_bfmt((vx_bytes){(uint8_t *)got, sizeof got}, fmt, __VA_ARGS__);                           \
    compared++;                                                                                              \
    if (wn < 0 || (size_t)wn != gn || memcmp(want, got, gn) != 0) {                                          \
      fprintf(stderr, "format %s: want \"%s\", got \"%.*s\"\n", fmt, want, (int)gn, got);                    \
      CHECK(false);                                                                                          \
    }                                                                                                        \
  } while (0)

static uint64_t rng = 0x9e3779b97f4a7c15;

static uint64_t next(void) {
  rng ^= rng << 13, rng ^= rng >> 7, rng ^= rng << 17;
  return rng;
}

static void floats(double x) {
  SAME("%f", x);
  SAME("%.0f", x);
  SAME("%.3f", x);
  SAME("%.17f", x);
  SAME("%e", x);
  SAME("%.0e", x);
  SAME("%.16e", x);
  SAME("%.25E", x);
  SAME("%g", x);
  SAME("%.1g", x);
  SAME("%.17g", x);
  SAME("%#g", x);
  SAME("%#.0f", x);
  SAME("%#.0e", x);
  SAME("%a", x);
  SAME("%.3a", x);
  SAME("%.0a", x);
  SAME("%#.0a", x);
  SAME("%.15A", x);
  SAME("%+14.4e|", x);
  SAME("%-14.3f|", x);
  SAME("%014.3f", x);
  SAME("% G", x);
  SAME("%020a", x);
  SAME("%-20a|", x);
}

static void floats_wide(double x) { // exact digits: a double's whole expansion
  SAME("%.40f", x);
  SAME("%.60e", x);
  SAME("%.800f", x);
  SAME("%.770e", x);
}

static void integers(void) {
  static const long long vals[] = {
      0,         1,        -1, 7, 42, -42, 255, 65535, 0x7fffffff, -0x7fffffff - 1, 1LL << 40, -(1LL << 40),
      INT64_MAX, INT64_MIN};
  for (size_t i = 0; i < sizeof vals / sizeof vals[0]; i++) {
    long long v = vals[i];
    SAME("%d|%i", (int)v, (int)v);
    SAME("%lld", v);
    SAME("%+lld", v);
    SAME("% lld", v);
    SAME("%20lld|", v);
    SAME("%-20lld|", v);
    SAME("%020lld", v);
    SAME("%.25lld", v);
    SAME("%.0lld", v);
    SAME("%+.0d", (int)v);
    SAME("%llu", (unsigned long long)v);
    SAME("%llx %llX", (unsigned long long)v, (unsigned long long)v);
    SAME("%#llx %#llX", (unsigned long long)v, (unsigned long long)v);
    SAME("%#llo %llo", (unsigned long long)v, (unsigned long long)v);
    SAME("%#.0o|%.0o", (unsigned)v, (unsigned)v);
    SAME("%#020llx", (unsigned long long)v);
    SAME("%#20.8llx|", (unsigned long long)v);
    SAME("%hhd %hhu %hd %hu", (int)v, (int)v, (int)v, (int)v);
    SAME("%ld %lu %jd %zu %td", (long)v, (unsigned long)v, (intmax_t)v, (size_t)v, (ptrdiff_t)v);
    SAME("%*d|%-*d|%.*d", 9, (int)v, 9, (int)v, 5, (int)v);
    SAME("%*d|", -9, (int)v);
    SAME("%.*d", -1, (int)v);
    SAME("%#b %B %010b", (unsigned)v, (unsigned)v, (unsigned)(v & 0xff));
  }
  int x = 5;
  SAME("%p", (void *)&x);
  SAME("%20p|%-20p|", (void *)&x, (void *)&x);
}

static void strings(void) {
  SAME("%s|%5s|%-5s|%.2s|%.0s|", "abc", "abc", "abc", "abc", "abc");
  SAME("%c%c%5c|%-3c|", 'a', 'b', 'c', 'd');
  SAME("100%% %s", "done");
  vx_str s = VX_STR("slice, not NUL-terminated");
  char got[64];
  size_t n = vx_bfmt((vx_bytes){(uint8_t *)got, sizeof got}, "[%.*s]", VX_FMT(vx_str_cut(s, 0, 5)));
  CHECK(n == 7 && memcmp(got, "[slice]", 7) == 0);
  vx_str none = {};
  n = vx_bfmt((vx_bytes){(uint8_t *)got, sizeof got}, "[%.*s]", VX_FMT(none));
  CHECK(n == 2 && memcmp(got, "[]", 2) == 0);
  // Runes as UTF-8: é is 2 bytes, € 3, 😀 4.
  n = vx_bfmt((vx_bytes){(uint8_t *)got, sizeof got}, "%lc|%ls|%.5ls|%6ls|", (wint_t)0xe9, L"é€", L"é€é",
              L"€");
  CHECK(n == 2 + 1 + 5 + 1 + 5 + 1 + 6 + 1 && memcmp(got, "é|é€|é€|   €|", n) == 0);
}

static void cutting(void) {
  // A buffer is filled to a rune's boundary, never past it.
  char buf[8];
  memset(buf, '#', sizeof buf);
  CHECK(vx_bfmt((vx_bytes){(uint8_t *)buf, 5}, "ab%s", "€€") == 5); // ab + € (3)
  CHECK(memcmp(buf, "ab€", 5) == 0 && buf[5] == '#');
  CHECK(vx_bfmt((vx_bytes){(uint8_t *)buf, 4}, "ab%s", "€€") == 2); // € would not fit
  CHECK(vx_bfmt((vx_bytes){(uint8_t *)buf, 6}, "%s", "\xf0\x9f\x98\x80\xf0\x9f\x98\x80") == 4);
  CHECK(vx_bfmt((vx_bytes){(uint8_t *)buf, 3}, "%d", 12345) == 3 && memcmp(buf, "123", 3) == 0);
  CHECK(vx_bfmt((vx_bytes){}, "%d", 12345) == 0);
  CHECK(vx_bfmt((vx_bytes){(uint8_t *)buf, 2}, "a\xff\xff") == 2); // bad bytes are runes of their own
}

static void slices(void) {
  vx_str s = VX_STR("key=value=more");
  CHECK(vx_str_eq(s, VX_STR("key=value=more")) && !vx_str_eq(s, VX_STR("key")));
  CHECK(vx_str_eq((vx_str){}, VX_STR("")));
  CHECK(vx_str_prefix(s, VX_STR("key=")) && !vx_str_prefix(VX_STR("k"), VX_STR("key")));
  CHECK(vx_str_suffix(s, VX_STR("more")) && !vx_str_suffix(s, VX_STR("mor")));
  CHECK(vx_str_find(s, VX_STR("=")) == 3 && vx_str_find(s, VX_STR("=more")) == 9);
  CHECK(vx_str_find(s, VX_STR("x")) == -1 && vx_str_find(s, VX_STR("")) == 0);
  CHECK(vx_str_find(VX_STR("ab"), VX_STR("abc")) == -1);
  CHECK(vx_str_eq(vx_str_cut(s, 4, 9), VX_STR("value")) && vx_str_cut(s, 20, 30).len == 0);
  CHECK(vx_str_eq(vx_str_cut(s, 10, 2), VX_STR("")));
  CHECK(vx_str_eq(vx_cstr("hello"), VX_STR("hello")));

  vx_str rest = VX_STR("a,b,,c,"), f;
  const char *want[] = {"a", "b", "", "c", ""};
  int count = 0;
  while (vx_str_split(&rest, VX_STR(","), &f)) {
    CHECK(count < 5 && vx_str_eq(f, vx_cstr(want[count])));
    count++;
  }
  CHECK(count == 5);
  rest = VX_STR("");
  count = 0;
  while (vx_str_split(&rest, VX_STR(","), &f)) count++;
  CHECK(count == 1);
  rest = (vx_str){};
  CHECK(!vx_str_split(&rest, VX_STR(","), &f));
  rest = VX_STR("a::b");
  CHECK(vx_str_split(&rest, VX_STR("::"), &f) && vx_str_eq(f, VX_STR("a")) && vx_str_eq(rest, VX_STR("b")));

  uint64_t u = 7;
  int64_t i = 7;
  CHECK(vx_str_u64(VX_STR("0"), &u) && u == 0);
  CHECK(vx_str_u64(VX_STR("18446744073709551615"), &u) && u == UINT64_MAX);
  CHECK(!vx_str_u64(VX_STR("18446744073709551616"), &u) && u == UINT64_MAX);
  CHECK(vx_str_u64(VX_STR("0xffFF"), &u) && u == 0xffff);
  CHECK(vx_str_u64(VX_STR("007"), &u) && u == 7);
  CHECK(!vx_str_u64(VX_STR(""), &u) && !vx_str_u64(VX_STR("0x"), &u) && !vx_str_u64(VX_STR("12a"), &u));
  CHECK(!vx_str_u64(VX_STR("-1"), &u) && !vx_str_u64(VX_STR(" 1"), &u));
  CHECK(vx_str_i64(VX_STR("-9223372036854775808"), &i) && i == INT64_MIN);
  CHECK(vx_str_i64(VX_STR("+9223372036854775807"), &i) && i == INT64_MAX);
  CHECK(!vx_str_i64(VX_STR("9223372036854775808"), &i) && !vx_str_i64(VX_STR("-"), &i));
  CHECK(vx_str_i64(VX_STR("-0x10"), &i) && i == -16);
}

int main(void) {
  integers();
  strings();
  cutting();
  slices();
  static const double special[] = {0.0,
                                   -0.0,
                                   1.0,
                                   -1.0,
                                   0.5,
                                   1.5,
                                   2.5,
                                   0.125,
                                   0.1,
                                   0.3,
                                   2.0 / 3,
                                   1e22,
                                   1e23,
                                   123456789.0,
                                   9.5,
                                   99.5,
                                   999.5,
                                   0.0005,
                                   0.00015,
                                   1e-5,
                                   9.9999e-5,
                                   1e15,
                                   1e16,
                                   1e17,
                                   1e300,
                                   1e-300,
                                   DBL_MAX,
                                   DBL_MIN,
                                   DBL_TRUE_MIN,
                                   5e-324 * 3,
                                   0x1.fffffffffffffp-1,
                                   0x1.08p0,
                                   0x1.18p0,
                                   INFINITY,
                                   -INFINITY,
                                   NAN,
                                   2.5e-310};
  for (size_t k = 0; k < sizeof special / sizeof special[0]; k++) {
    floats(special[k]);
    if (isfinite(special[k])) floats_wide(special[k]);
  }
  for (int k = 0; k < 20000; k++) {
    uint64_t bits = next();
    double x;
    memcpy(&x, &bits, sizeof x);
    if (!isfinite(x)) continue;
    floats(x);
    if (k % 50 == 0) floats_wide(x);
  }
  for (int k = 0; k < 20000; k++) { // ordinary sizes, where %f and %g show most digits
    double x = (double)(int64_t)next() / (double)(1ull << (next() % 64));
    floats(x);
  }
  printf("fmt_test: %d formats compared\n", compared);
  return check_result();
}
