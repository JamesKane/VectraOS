// mem.h: the four functions the compiler may call even in freestanding code.
// A hosted program (the musl back end) has them from its C library.
#pragma once

#include <stddef.h>

#if __STDC_HOSTED__
#include <string.h>
#else
void *memset(void *dst, int c, size_t n);
void *memcpy(void *restrict dst, const void *restrict src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
int memcmp(const void *a, const void *b, size_t n);
#endif
