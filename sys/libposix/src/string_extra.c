/*
string_extra.c -- the string routines beyond the ones `sys/libc`'s `str.c`
already carries, plus `strerror` over the wire's error names.

`memcpy`, `memmove`, `memset`, `strlen`, `strcmp`, `strcpy` and `memcmp`
come from the shared `str.c`. This adds the handful a tool also uses.
*/
#include "posix_internal.h"
#include <string.h>
#include <errno.h>

int strncmp(const char *a, const char *b, size_t n)
{
	for (size_t i = 0; i < n; i++) {
		unsigned char x = (unsigned char)a[i], y = (unsigned char)b[i];
		if (x != y) {
			return (int)x - (int)y;
		}
		if (x == 0) {
			break;
		}
	}
	return 0;
}

char *strncpy(char *dst, const char *src, size_t n)
{
	size_t i = 0;
	for (; i < n && src[i]; i++) {
		dst[i] = src[i];
	}
	for (; i < n; i++) {
		dst[i] = 0;
	}
	return dst;
}

char *strcat(char *dst, const char *src)
{
	char *d = dst;
	while (*d) {
		d++;
	}
	while ((*d++ = *src++)) {
	}
	return dst;
}

char *strchr(const char *s, int c)
{
	for (; *s; s++) {
		if (*s == (char)c) {
			return (char *)s;
		}
	}
	return c == 0 ? (char *)s : NULL;
}

char *strrchr(const char *s, int c)
{
	const char *last = NULL;
	for (; *s; s++) {
		if (*s == (char)c) {
			last = s;
		}
	}
	return (char *)(c == 0 ? s : last);
}

char *strerror(int e)
{
	switch (e) {
	case EPERM: return "operation not permitted";
	case ENOENT: return "no such file or directory";
	case ESRCH: return "no such process";
	case EINTR: return "interrupted";
	case EIO: return "input/output error";
	case EBADF: return "bad file descriptor";
	case ENOMEM: return "out of memory";
	case EACCES: return "permission denied";
	case EEXIST: return "file exists";
	case ENOTDIR: return "not a directory";
	case EISDIR: return "is a directory";
	case EINVAL: return "invalid argument";
	case ENOSPC: return "no space left";
	case EPIPE: return "broken pipe";
	case ENOSYS: return "function not implemented";
	default: return "error";
	}
}
