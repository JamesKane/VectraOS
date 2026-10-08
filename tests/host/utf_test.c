// utf_test.c: lib/vx-utf at every boundary of the encoding (ADR-0013): the
// first and last rune of each length, overlong forms, surrogates, past
// U+10FFFF, truncated and stray bytes; cutting, stepping back, and names.

#include <string.h>

#include "check.h"
#include "../../abi/vx/utf.h"

static vx_rune decode(const char *s, size_t n, size_t *len) {
  vx_rune r;
  *len = vx_chartorune(&r, s, n);
  return r;
}

static bool decodes(const char *s, vx_rune want, size_t want_len) {
  size_t len;
  vx_rune r = decode(s, strlen(s), &len);
  return r == want && len == want_len;
}

static void test_decode(void) {
  CHECK(decodes("a", 'a', 1));
  size_t len;
  CHECK(decode("\0", 1, &len) == 0 && len == 1); // NUL is a rune too, given its length
  CHECK(decodes("\x7f", 0x7f, 1));
  CHECK(decodes("\xc2\x80", 0x80, 2));       // the first two-byte rune
  CHECK(decodes("\xdf\xbf", 0x7ff, 2));      // the last
  CHECK(decodes("\xe0\xa0\x80", 0x800, 3));  // the first three-byte rune
  CHECK(decodes("\xef\xbf\xbf", 0xffff, 3)); // the last
  CHECK(decodes("\xf0\x90\x80\x80", 0x10000, 4));
  CHECK(decodes("\xf4\x8f\xbf\xbf", 0x10ffff, 4)); // VX_RUNEMAX
  CHECK(decodes("\xef\xbf\xbd", VX_RUNEERROR, 3)); // U+FFFD itself, valid
  // Bad: each is VX_RUNEERROR, and one byte.
  CHECK(decodes("\xc0\x80", VX_RUNEERROR, 1));         // overlong NUL
  CHECK(decodes("\xc1\xbf", VX_RUNEERROR, 1));         // overlong
  CHECK(decodes("\xe0\x9f\xbf", VX_RUNEERROR, 1));     // overlong three-byte
  CHECK(decodes("\xf0\x8f\xbf\xbf", VX_RUNEERROR, 1)); // overlong four-byte
  CHECK(decodes("\xed\xa0\x80", VX_RUNEERROR, 1));     // U+D800, a surrogate
  CHECK(decodes("\xed\xbf\xbf", VX_RUNEERROR, 1));     // U+DFFF
  CHECK(decodes("\xed\x9f\xbf", 0xd7ff, 3));           // just below them
  CHECK(decodes("\xf4\x90\x80\x80", VX_RUNEERROR, 1)); // U+110000
  CHECK(decodes("\xf5\x80\x80\x80", VX_RUNEERROR, 1));
  CHECK(decodes("\xff", VX_RUNEERROR, 1));
  CHECK(decodes("\x80", VX_RUNEERROR, 1));                        // a stray continuation byte
  CHECK(decode("\xe2\x82", 2, &len) == VX_RUNEERROR && len == 1); // truncated
  CHECK(decodes("\xe2\x28\xa1", VX_RUNEERROR, 1));                // a bad continuation
  CHECK(decode("", 0, &len) == VX_RUNEERROR && len == 0);
}

static void test_encode(void) {
  static const vx_rune runes[] = {0,      'a',    0x7f,   0x80,    0x7ff,   0x800,
                                  0xd7ff, 0xe000, 0xffff, 0x10000, 0x10ffff};
  for (size_t i = 0; i < sizeof runes / sizeof runes[0]; i++) {
    char buf[VX_UTFMAX];
    size_t n = vx_runetochar(buf, runes[i]), len;
    CHECK(n == vx_runelen(runes[i]) && decode(buf, n, &len) == runes[i] && len == n);
    CHECK(vx_fullrune(buf, n) && (n == 1 || !vx_fullrune(buf, n - 1)));
  }
  char buf[VX_UTFMAX];
  size_t len;
  CHECK(vx_runetochar(buf, 0xd800) == 3 && decode(buf, 3, &len) == VX_RUNEERROR && len == 3); // as U+FFFD
  CHECK(vx_runetochar(buf, 0x110000) == 3 && vx_runelen(0x110000) == 3);
  CHECK(vx_fullrune("\xe2\x28", 2)); // bad already: no more bytes needed to know
}

static void test_strings(void) {
  static const char s[] = "a\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80z"; // a é € 😀 z: 1+2+3+4+1 bytes
  size_t n = sizeof s - 1;
  CHECK(vx_utflen(s, n) == 5 && vx_utf_valid(s, n));
  CHECK(vx_utfrune(s, n, 0x20ac) == s + 3 && vx_utfrune(s, n, 'q') == nullptr);
  static const char abab[] = "abab";
  CHECK(vx_utfrune(abab, 4, 'b') == abab + 1 && vx_utfrrune(abab, 4, 'b') == abab + 3);
  CHECK(!vx_utf_valid("a\xc3", 2) && !vx_utf_valid("\xed\xa0\x80", 3) && vx_utf_valid("", 0));
  CHECK(vx_utflen("\xff\xfe", 2) == 2); // a bad byte is one rune
  // Cuts end at rune boundaries: never inside é, €, 😀.
  CHECK(vx_utf_cut(s, n, 100) == n);
  CHECK(vx_utf_cut(s, n, 1) == 1 && vx_utf_cut(s, n, 2) == 1 && vx_utf_cut(s, n, 3) == 3);
  CHECK(vx_utf_cut(s, n, 5) == 3 && vx_utf_cut(s, n, 6) == 6 && vx_utf_cut(s, n, 9) == 6 &&
        vx_utf_cut(s, n, 10) == 10);
  CHECK(vx_utf_cut("\xff\xfe", 2, 1) == 1); // bad bytes cut anywhere
  // Back over one rune at a time.
  CHECK(vx_utf_back(s, n) == 10 && vx_utf_back(s, 10) == 6 && vx_utf_back(s, 6) == 3 &&
        vx_utf_back(s, 3) == 1);
  CHECK(vx_utf_back(s, 1) == 0 && vx_utf_back(s, 0) == 0);
  CHECK(vx_utf_back("a\x80", 2) == 1); // a stray continuation byte: one byte back
  CHECK(vx_utf_back("\xc3\xa9\x80", 3) == 2);
}

static void test_names(void) {
  CHECK(vx_utf_name("caf\xc3\xa9", 5) && vx_utf_name("a b", 3));
  CHECK(!vx_utf_name("a\nb", 3) && !vx_utf_name("a\tb", 3) && !vx_utf_name("\x7f", 1));
  CHECK(!vx_utf_name("a\0b", 3) && !vx_utf_name("\xc3", 1) && !vx_utf_name("\xc0\xaf", 2));
}

int main(void) {
  test_decode();
  test_encode();
  test_strings();
  test_names();
  return check_result();
}
