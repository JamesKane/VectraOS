// mem_test.c: lib/vx-mem, renamed so the host C library keeps its own: each
// function against a byte-at-a-time reference, every length to 72 at every
// pair of alignments (the word paths' heads and tails), and overlaps both
// ways (6c2's word-sized copies).

#include <string.h>

#include "check.h"

#define memset  vx_memset
#define memcpy  vx_memcpy
#define memmove vx_memmove
#define memcmp  vx_memcmp
#include "../../lib/vx-mem/mem.c"
#undef memset
#undef memcpy
#undef memmove
#undef memcmp

int main(void) {
  char a[32] = "0123456789abcdefghijklmnopqrstu";
  vx_memmove(a + 4, a, 10); // forwards overlap
  CHECK(strcmp(a, "01230123456789efghijklmnopqrstu") == 0);
  vx_memmove(a, a + 4, 10); // backwards overlap
  CHECK(strncmp(a, "0123456789", 10) == 0);

  char b[8];
  vx_memset(b, 'x', sizeof b);
  CHECK(b[0] == 'x' && b[7] == 'x');
  vx_memcpy(b, "hello", 5);
  CHECK(vx_memcmp(b, "helloxxx", 8) == 0);
  CHECK(vx_memcmp("a", "b", 1) < 0 && vx_memcmp("b", "a", 1) > 0);
  CHECK(vx_memcmp("\x80", "\x01", 1) > 0); // bytes compare unsigned
  CHECK(vx_memcmp(b, b, 0) == 0);

  static unsigned char src[160], dst[160], want[160];
  for (size_t i = 0; i < sizeof src; i++) src[i] = (unsigned char)(i * 37 + 11);
  bool same = true;
  for (size_t sa = 0; sa < 8; sa++)
    for (size_t da = 0; da < 8; da++)
      for (size_t n = 0; n <= 72; n++) {
        memset(dst, 0xee, sizeof dst), memset(want, 0xee, sizeof want);
        for (size_t i = 0; i < n; i++) want[da + i] = src[sa + i];
        vx_memcpy(dst + da, src + sa, n);
        same = same && memcmp(dst, want, sizeof dst) == 0;
        memset(dst, 0xee, sizeof dst);
        vx_memmove(dst + da, src + sa, n);
        same = same && memcmp(dst, want, sizeof dst) == 0;
        memset(dst, 0xee, sizeof dst), memset(want, 0xee, sizeof want);
        memset(want + da, 0x5a, n);
        vx_memset(dst + da, 0x5a, n);
        same = same && memcmp(dst, want, sizeof dst) == 0;
        memcpy(dst, src, sizeof src);
        if (n) dst[da + n - 1] ^= 1; // the last byte differs: the word path hands it to the bytes
        int got = vx_memcmp(dst + da, src + da, n), ref = memcmp(dst + da, src + da, n);
        same = same && (got < 0) == (ref < 0) && (got > 0) == (ref > 0);
        // overlaps, each way, within one buffer
        unsigned char buf[160], ref2[160];
        for (size_t i = 0; i < sizeof buf; i++) buf[i] = ref2[i] = (unsigned char)i;
        memmove(ref2 + da, ref2 + sa, n);
        vx_memmove(buf + da, buf + sa, n);
        same = same && memcmp(buf, ref2, sizeof buf) == 0;
      }
  CHECK(same);
  return check_result();
}
