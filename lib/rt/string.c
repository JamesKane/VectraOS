// Memory primitives that clang and swiftc emit calls to, and strlen. These are C because
// they must exist before any Swift runs and must never be lowered back into
// calls to themselves; LLVM's loop-idiom pass skips functions with these names.
//
// Eight bytes at a time where both ends can be aligned alike, bytes for the
// rest. Only aligned word accesses: arm64 with the MMU off (Device memory)
// and rv64 harts without misaligned access trap on anything else. Whole
// pages are zeroed by arch_zero_page instead.

#include <stddef.h>
#include <stdint.h>

typedef uint64_t __attribute__((may_alias)) word;

// [d, d+n) from [s, s+n), front to back: safe for overlap with d < s too,
// since each word is read before anything after it is written.
__attribute__((no_builtin)) static void forward(unsigned char *d, const unsigned char *s, size_t n) {
  if (n >= 16 && (((uintptr_t)d ^ (uintptr_t)s) & 7) == 0) {
    for (; (uintptr_t)d & 7; n--) *d++ = *s++;
    word *dw = (word *)d;
    const word *sw = (const word *)s;
    for (; n >= 32; n -= 32, dw += 4, sw += 4) {
      dw[0] = sw[0];
      dw[1] = sw[1];
      dw[2] = sw[2];
      dw[3] = sw[3];
    }
    for (; n >= 8; n -= 8) *dw++ = *sw++;
    d = (unsigned char *)dw;
    s = (const unsigned char *)sw;
  }
  while (n--) *d++ = *s++;
}

__attribute__((no_builtin)) [[gnu::visibility("default")]] void *memcpy(void *restrict dst, const void *restrict src, size_t n) {
  forward(dst, src, n);
  return dst;
}

__attribute__((no_builtin)) [[gnu::visibility("default")]] void *memmove(void *dst, const void *src, size_t n) {
  unsigned char *d = dst;
  const unsigned char *s = src;
  if (d < s || d >= s + n) {
    forward(d, s, n);
    return dst;
  }
  // Back to front, from the ends.
  d += n;
  s += n;
  if (n >= 16 && (((uintptr_t)d ^ (uintptr_t)s) & 7) == 0) {
    for (; (uintptr_t)d & 7; n--) *--d = *--s;
    word *dw = (word *)d;
    const word *sw = (const word *)s;
    for (; n >= 8; n -= 8) *--dw = *--sw;
    d = (unsigned char *)dw;
    s = (const unsigned char *)sw;
  }
  while (n--) *--d = *--s;
  return dst;
}

__attribute__((no_builtin)) [[gnu::visibility("default")]] void *memset(void *dst, int c, size_t n) {
  unsigned char *d = dst;
  if (n >= 16) {
    word v = 0x0101010101010101ull * (unsigned char)c;
    for (; (uintptr_t)d & 7; n--) *d++ = (unsigned char)c;
    word *dw = (word *)d;
    for (; n >= 32; n -= 32, dw += 4) {
      dw[0] = v;
      dw[1] = v;
      dw[2] = v;
      dw[3] = v;
    }
    for (; n >= 8; n -= 8) *dw++ = v;
    d = (unsigned char *)dw;
  }
  while (n--) *d++ = (unsigned char)c;
  return dst;
}

[[gnu::visibility("default")]] int memcmp(const void *a, const void *b, size_t n) {
  const unsigned char *x = a, *y = b;
  for (; n; n--, x++, y++) {
    if (*x != *y) return *x - *y;
  }
  return 0;
}

[[gnu::visibility("default")]] size_t strlen(const char *s) {
  size_t n = 0;
  while (s[n] != 0) n++;
  return n;
}
