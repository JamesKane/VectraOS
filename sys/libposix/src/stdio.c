/*
stdio.c -- printf and its kin, over `write`, unbuffered for now.

A `FILE` is a descriptor in a box, and `stdout` and `stderr` are the two
the kernel opened. The verbs are `%s %c %d %u %x %p %%`, the ones the
section 8 tests print with. A field gathers into one buffer and goes out
in one `write`, so a line is one call. A buffered `FILE` and the full
format are the library's to grow. See `docs/DEVTOOLS.md` section 8.
*/
#include "posix_internal.h"
#include <stdio.h>
#include <unistd.h>

struct FILE {
	int fd;
};

static FILE files[3] = {{0}, {1}, {2}};
FILE *stdin = &files[0];
FILE *stdout = &files[1];
FILE *stderr = &files[2];

#define BUF_MAX 1024

typedef struct {
	char *p;
	int n;
	int max;
} Buf;

static void put(Buf *b, char c)
{
	if (b->n < b->max) {
		b->p[b->n] = c;
	}
	b->n++;
}

static void puts_buf(Buf *b, const char *s)
{
	if (s == NULL) {
		s = "(null)";
	}
	while (*s) {
		put(b, *s++);
	}
}

static void putu(Buf *b, unsigned long v, int base, const char *digits)
{
	char tmp[24];
	int i = 0;
	if (v == 0) {
		put(b, '0');
		return;
	}
	while (v && i < (int)sizeof(tmp)) {
		tmp[i++] = digits[v % (unsigned long)base];
		v /= (unsigned long)base;
	}
	while (i > 0) {
		put(b, tmp[--i]);
	}
}

static void putd(Buf *b, long v)
{
	if (v < 0) {
		put(b, '-');
		putu(b, (unsigned long)(-v), 10, "0123456789");
	} else {
		putu(b, (unsigned long)v, 10, "0123456789");
	}
}

static int format(Buf *b, const char *fmt, __builtin_va_list ap)
{
	for (const char *f = fmt; *f; f++) {
		if (*f != '%') {
			put(b, *f);
			continue;
		}
		f++;
		/* A width and a length modifier are read and mostly ignored, so a
		   `%ld` or `%5d` prints its value even without the padding. */
		int lng = 0;
		while (*f == 'l') {
			lng = 1;
			f++;
		}
		switch (*f) {
		case 's':
			puts_buf(b, __builtin_va_arg(ap, const char *));
			break;
		case 'c':
			put(b, (char)__builtin_va_arg(ap, int));
			break;
		case 'd':
		case 'i':
			putd(b, lng ? __builtin_va_arg(ap, long) : (long)__builtin_va_arg(ap, int));
			break;
		case 'u':
			putu(b, lng ? __builtin_va_arg(ap, unsigned long) : (unsigned long)__builtin_va_arg(ap, unsigned int), 10, "0123456789");
			break;
		case 'x':
			putu(b, lng ? __builtin_va_arg(ap, unsigned long) : (unsigned long)__builtin_va_arg(ap, unsigned int), 16, "0123456789abcdef");
			break;
		case 'p':
			puts_buf(b, "0x");
			putu(b, (unsigned long)__builtin_va_arg(ap, void *), 16, "0123456789abcdef");
			break;
		case '%':
			put(b, '%');
			break;
		case 0:
			f--;
			break;
		default:
			put(b, '%');
			put(b, *f);
			break;
		}
	}
	return b->n;
}

int vfprintf(FILE *f, const char *fmt, __builtin_va_list ap)
{
	char storage[BUF_MAX];
	Buf b = {storage, 0, BUF_MAX};
	format(&b, fmt, ap);
	int n = b.n < b.max ? b.n : b.max;
	return (int)write(f->fd, storage, n);
}

int fprintf(FILE *f, const char *fmt, ...)
{
	__builtin_va_list ap;
	__builtin_va_start(ap, fmt);
	int n = vfprintf(f, fmt, ap);
	__builtin_va_end(ap);
	return n;
}

int printf(const char *fmt, ...)
{
	__builtin_va_list ap;
	__builtin_va_start(ap, fmt);
	int n = vfprintf(stdout, fmt, ap);
	__builtin_va_end(ap);
	return n;
}

int snprintf(char *buf, size_t n, const char *fmt, ...)
{
	Buf b = {buf, 0, n > 0 ? (int)n - 1 : 0};
	__builtin_va_list ap;
	__builtin_va_start(ap, fmt);
	format(&b, fmt, ap);
	__builtin_va_end(ap);
	if (n > 0) {
		buf[b.n < b.max ? b.n : b.max] = 0;
	}
	return b.n;
}

int fputs(const char *s, FILE *f)
{
	int n = 0;
	while (s[n]) {
		n++;
	}
	return (int)write(f->fd, s, n);
}

int puts(const char *s)
{
	fputs(s, stdout);
	return (int)write(stdout->fd, "\n", 1);
}

int fputc(int c, FILE *f)
{
	char b = (char)c;
	write(f->fd, &b, 1);
	return c;
}

int putchar(int c)
{
	return fputc(c, stdout);
}

int fflush(FILE *f)
{
	(void)f;
	return 0;
}
