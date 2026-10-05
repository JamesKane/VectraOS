// vx-mem: the four functions the compiler may call even in freestanding code.
// The kernel and vx-rt both include this file. no_builtin keeps clang from
// turning the loops back into calls to themselves.
//
// Words, not bytes (M6 step 6c2): on x86_64 memcpy and memset are the string
// instructions, which ERMS and FSRM make as fast as vector code for the
// kernel's sizes; elsewhere, and for memmove and memcmp, eight bytes at a time
// where source and destination share their alignment (two at once, a load or
// store pair on aarch64), bytes at the edges and where they do not. Only
// aligned words are touched, so device memory, which faults an unaligned
// access, is safe to copy where a byte copy was.

#include "mem.h"

#include <stdint.h>

typedef uint64_t __attribute__((may_alias)) vx_mem_word;

static bool vx_mem_coaligned(const void *a, const void *b) {
  return (((uintptr_t)a ^ (uintptr_t)b) & 7) == 0;
}

[[clang::no_builtin]] static void vx_mem_fwd(unsigned char *d, const unsigned char *s, size_t n) {
  if (n >= 16 && vx_mem_coaligned(d, s)) {
    for (; (uintptr_t)d & 7; n--) *d++ = *s++;
    vx_mem_word *dw = (vx_mem_word *)d;
    const vx_mem_word *sw = (const vx_mem_word *)s;
    for (; n >= 16; n -= 16, dw += 2, sw += 2) {
      vx_mem_word a = sw[0], b = sw[1];
      dw[0] = a, dw[1] = b;
    }
    d = (unsigned char *)dw, s = (const unsigned char *)sw;
  }
  while (n--) *d++ = *s++;
}

[[clang::no_builtin]] static void vx_mem_back(unsigned char *d, const unsigned char *s, size_t n) {
  d += n, s += n;
  if (n >= 16 && vx_mem_coaligned(d, s)) {
    for (; (uintptr_t)d & 7; n--) *--d = *--s;
    vx_mem_word *dw = (vx_mem_word *)d;
    const vx_mem_word *sw = (const vx_mem_word *)s;
    for (; n >= 16; n -= 16) {
      vx_mem_word b = *--sw, a = *--sw;
      *--dw = b, *--dw = a;
    }
    d = (unsigned char *)dw, s = (const unsigned char *)sw;
  }
  while (n--) *--d = *--s;
}

[[clang::no_builtin]] void *memset(void *dst, int c, size_t n) {
#if defined(__x86_64__) && !defined(VX_MEM_WORDS) // VX_MEM_WORDS: the word paths, for the host test
  void *d = dst;
  __asm__ volatile("rep stosb" : "+D"(d), "+c"(n) : "a"(c) : "memory");
#else
  unsigned char *d = dst, b = (unsigned char)c;
  if (n >= 16) {
    for (; (uintptr_t)d & 7; n--) *d++ = b;
    uint64_t v = b * 0x0101'0101'0101'0101ull;
    vx_mem_word *dw = (vx_mem_word *)d;
    for (; n >= 16; n -= 16, dw += 2) dw[0] = v, dw[1] = v;
    d = (unsigned char *)dw;
  }
  while (n--) *d++ = b;
#endif
  return dst;
}

[[clang::no_builtin]] void *memcpy(void *restrict dst, const void *restrict src, size_t n) {
#if defined(__x86_64__) && !defined(VX_MEM_WORDS) // VX_MEM_WORDS: the word paths, for the host test
  void *d = dst;
  const void *s = src;
  __asm__ volatile("rep movsb" : "+D"(d), "+S"(s), "+c"(n) : : "memory");
#else
  vx_mem_fwd(dst, src, n);
#endif
  return dst;
}

[[clang::no_builtin]] void *memmove(void *dst, const void *src, size_t n) {
  unsigned char *d = dst;
  const unsigned char *s = src;
  if (d <= s || d >= s + n)
    vx_mem_fwd(d, s, n); // forwards is safe unless the destination starts inside the source
  else
    vx_mem_back(d, s, n);
  return dst;
}

[[clang::no_builtin]] int memcmp(const void *a, const void *b, size_t n) {
  const unsigned char *x = a, *y = b;
  if (n >= 16 && vx_mem_coaligned(x, y)) {
    for (; (uintptr_t)x & 7; n--, x++, y++)
      if (*x != *y) return *x - *y;
    const vx_mem_word *xw = (const vx_mem_word *)x, *yw = (const vx_mem_word *)y;
    for (; n >= 8 && *xw == *yw; n -= 8) xw++, yw++; // the first differing word is compared by bytes
    x = (const unsigned char *)xw, y = (const unsigned char *)yw;
  }
  for (size_t i = 0; i < n; i++)
    if (x[i] != y[i]) return x[i] - y[i];
  return 0;
}
