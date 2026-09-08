/*
stdlib_extra.c -- number conversion, `calloc` and `realloc`.

`malloc` and `free` are the bump heap in the shared `malloc.c`. `calloc`
zeroes, and `realloc` allocates and copies, because the bump never frees.
The environment lives in `env.c`, over files under `/env`.
*/
#include "posix_internal.h"
#include <stdlib.h>
#include <string.h>

int atoi(const char *s)
{
	return (int)atol(s);
}

long atol(const char *s)
{
	long v = 0;
	int neg = 0;
	while (*s == ' ' || *s == '\t') {
		s++;
	}
	if (*s == '-') {
		neg = 1;
		s++;
	} else if (*s == '+') {
		s++;
	}
	while (*s >= '0' && *s <= '9') {
		v = v * 10 + (*s - '0');
		s++;
	}
	return neg ? -v : v;
}

long strtol(const char *s, char **end, int base)
{
	long v = 0;
	int neg = 0;
	while (*s == ' ' || *s == '\t') {
		s++;
	}
	if (*s == '-') {
		neg = 1;
		s++;
	} else if (*s == '+') {
		s++;
	}
	if ((base == 0 || base == 16) && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
		base = 16;
		s += 2;
	} else if (base == 0) {
		base = 10;
	}
	for (;;) {
		int d;
		if (*s >= '0' && *s <= '9') {
			d = *s - '0';
		} else if (*s >= 'a' && *s <= 'f') {
			d = *s - 'a' + 10;
		} else if (*s >= 'A' && *s <= 'F') {
			d = *s - 'A' + 10;
		} else {
			break;
		}
		if (d >= base) {
			break;
		}
		v = v * base + d;
		s++;
	}
	if (end != NULL) {
		*end = (char *)s;
	}
	return neg ? -v : v;
}

void *calloc(size_t n, size_t size)
{
	size_t total = n * size;
	void *p = malloc(total);
	if (p != NULL) {
		memset(p, 0, total);
	}
	return p;
}

void *realloc(void *p, size_t n)
{
	/* The bump heap never frees, so a grow is a fresh block and a copy. The
	   old size is unknown, so the copy is bounded by the new size, which is
	   safe for a grow and lossless for the common one. */
	void *q = malloc(n);
	if (q != NULL && p != NULL) {
		memcpy(q, p, n);
	}
	return q;
}

