/*
print.c -- Plan 9's print and fprint, the subset a tool uses.

The verbs are `%s` a string, `%c` a rune as one byte, `%d` and `%ud` a
signed and unsigned decimal, `%x` a hexadecimal, `%p` a pointer, and `%%`
a percent. A field gathers into one buffer and goes out in one `vwrite`,
so a tool that prints a line makes one call. Anything the buffer cannot
hold is cut, because a freestanding print grows nothing.
*/
#include "vlibc.h"

#define PRINT_MAX 1024

typedef struct Buf Buf;
struct Buf {
	char *p;
	int n;
	int max;
};

static void put(Buf *b, char c)
{
	if (b->n < b->max) {
		b->p[b->n] = c;
	}
	b->n++;
}

static void puts_(Buf *b, const char *s)
{
	if (s == NULL) {
		s = "<nil>";
	}
	while (*s) {
		put(b, *s++);
	}
}

static void putu(Buf *b, uvlong v, int base, const char *digits)
{
	char tmp[32];
	int i = 0;
	if (v == 0) {
		put(b, '0');
		return;
	}
	while (v && i < (int)sizeof(tmp)) {
		tmp[i++] = digits[v % (uvlong)base];
		v /= (uvlong)base;
	}
	while (i > 0) {
		put(b, tmp[--i]);
	}
}

static void putd(Buf *b, vlong v)
{
	if (v < 0) {
		put(b, '-');
		putu(b, (uvlong)(-v), 10, "0123456789");
	} else {
		putu(b, (uvlong)v, 10, "0123456789");
	}
}

int vfprint(int fd, const char *fmt, __builtin_va_list ap)
{
	char storage[PRINT_MAX];
	Buf b = {storage, 0, PRINT_MAX};
	for (const char *f = fmt; *f; f++) {
		if (*f != '%') {
			put(&b, *f);
			continue;
		}
		f++;
		int uns = 0;
		if (*f == 'u') {
			uns = 1;
			f++;
		}
		switch (*f) {
		case 's':
			puts_(&b, __builtin_va_arg(ap, const char *));
			break;
		case 'c':
			put(&b, (char)__builtin_va_arg(ap, int));
			break;
		case 'd':
			if (uns) {
				putu(&b, __builtin_va_arg(ap, uvlong), 10, "0123456789");
			} else {
				putd(&b, __builtin_va_arg(ap, vlong));
			}
			break;
		case 'x':
			putu(&b, __builtin_va_arg(ap, uvlong), 16, "0123456789abcdef");
			break;
		case 'p':
			puts_(&b, "0x");
			putu(&b, (uvlong)(uintptr)__builtin_va_arg(ap, void *), 16, "0123456789abcdef");
			break;
		case '%':
			put(&b, '%');
			break;
		case 0:
			f--;
			break;
		default:
			put(&b, '%');
			put(&b, *f);
			break;
		}
	}
	int n = b.n < b.max ? b.n : b.max;
	return (int)vwrite(fd, storage, n);
}

int fprint(int fd, const char *fmt, ...)
{
	__builtin_va_list ap;
	__builtin_va_start(ap, fmt);
	int n = vfprint(fd, fmt, ap);
	__builtin_va_end(ap);
	return n;
}

int print(const char *fmt, ...)
{
	__builtin_va_list ap;
	__builtin_va_start(ap, fmt);
	int n = vfprint(1, fmt, ap);
	__builtin_va_end(ap);
	return n;
}
