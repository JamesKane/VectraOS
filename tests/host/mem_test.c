// mem_test.c: lib/vx-mem, renamed so the host C library keeps its own.

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
  return check_result();
}
