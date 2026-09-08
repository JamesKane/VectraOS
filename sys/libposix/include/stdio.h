/*
stdio.h -- output over `write`, and the format the tests print with.

A first cut: unbuffered `printf`, `fprintf` and the character and string
writers, straight to a descriptor. `FILE` is a descriptor in a box, and
`stdout` and `stderr` are the two the kernel opened. The verbs are
`%s %c %d %u %x %p %%`, which is what the section 8 tests use. A buffered
`FILE` and the full format are the library's to grow when a program needs
them.
*/
#ifndef STDIO_H
#define STDIO_H

#include <sys/types.h>

typedef struct FILE FILE;
extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

int printf(const char *fmt, ...);
int fprintf(FILE *f, const char *fmt, ...);
int vfprintf(FILE *f, const char *fmt, __builtin_va_list ap);
int snprintf(char *buf, size_t n, const char *fmt, ...);
int puts(const char *s);
int fputs(const char *s, FILE *f);
int putchar(int c);
int fputc(int c, FILE *f);
int fflush(FILE *f);

#endif
