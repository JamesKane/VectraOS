/*
str.c -- the string and memory routines of the freestanding standard.

`memcpy`, `memset` and `memmove` are here because the compiler emits calls
to them for a struct copy or an array fill, so a freestanding program links
them whether or not it names them. The rest are the handful a small program
uses. None is POSIX; none allocates.
*/
#include "vlibc.h"

usize strlen(const char *s)
{
	const char *p = s;
	while (*p) {
		p++;
	}
	return (usize)(p - s);
}

int strcmp(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return (int)(uchar)*a - (int)(uchar)*b;
}

char *strcpy(char *dst, const char *src)
{
	char *d = dst;
	while ((*d++ = *src++)) {
	}
	return dst;
}

/* memcpy, memmove and memset are weak: the Odin runtime defines its own in
   a mixed image, and the linker takes those over these. A pure C program
   has only these. */
__attribute__((weak)) void *memcpy(void *dst, const void *src, usize n)
{
	uchar *d = dst;
	const uchar *s = src;
	while (n--) {
		*d++ = *s++;
	}
	return dst;
}

__attribute__((weak)) void *memmove(void *dst, const void *src, usize n)
{
	uchar *d = dst;
	const uchar *s = src;
	if (d == s || n == 0) {
		return dst;
	}
	if (d < s) {
		while (n--) {
			*d++ = *s++;
		}
	} else {
		d += n;
		s += n;
		while (n--) {
			*--d = *--s;
		}
	}
	return dst;
}

__attribute__((weak)) void *memset(void *dst, int c, usize n)
{
	uchar *d = dst;
	while (n--) {
		*d++ = (uchar)c;
	}
	return dst;
}

int memcmp(const void *a, const void *b, usize n)
{
	const uchar *p = a;
	const uchar *q = b;
	while (n--) {
		if (*p != *q) {
			return (int)*p - (int)*q;
		}
		p++;
		q++;
	}
	return 0;
}
