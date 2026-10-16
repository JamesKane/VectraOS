// SPDX-License-Identifier: BSD-3-Clause

// <stdio.h> for C programs on croi (M6c), from C23 §7.23: the standard
// streams (stdout and stderr to the process's debuglog, stdin empty), the
// printf family (system/libc/stdio, C23's conversions, correctly rounded)
// and character output. No file streams yet: fopen fails with ENOENT;
// remove and rename are fdio's in tier 1 (M6g, system/fdio), and fail with
// ENOENT without it.

#pragma once
#include <stdarg.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct td_file FILE;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

#define EOF (-1)
#define BUFSIZ 1024
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

int printf(const char *__restrict format, ...);
int fprintf(FILE *__restrict f, const char *__restrict format, ...);
int snprintf(char *__restrict s, size_t n, const char *__restrict format, ...);
int sprintf(char *__restrict s, const char *__restrict format, ...);
int vprintf(const char *__restrict format, va_list ap);
int vfprintf(FILE *__restrict f, const char *__restrict format, va_list ap);
int vsnprintf(char *__restrict s, size_t n, const char *__restrict format, va_list ap);
int vsprintf(char *__restrict s, const char *__restrict format, va_list ap);

int fputc(int c, FILE *f);
int putc(int c, FILE *f);
int putchar(int c);
int fputs(const char *__restrict s, FILE *__restrict f);
int puts(const char *s);
size_t fwrite(const void *__restrict p, size_t size, size_t n, FILE *__restrict f);
int fflush(FILE *f);

int fgetc(FILE *f);
int getc(FILE *f);
int getchar(void);
char *fgets(char *__restrict s, int n, FILE *__restrict f);
size_t fread(void *__restrict p, size_t size, size_t n, FILE *__restrict f);

int feof(FILE *f);
int ferror(FILE *f);
void clearerr(FILE *f);
FILE *fopen(const char *__restrict path, const char *__restrict mode);
int fileno(FILE *f);
int remove(const char *path);
int rename(const char *from, const char *to);
int fclose(FILE *f);
void flockfile(FILE *f);
void funlockfile(FILE *f);
int ftrylockfile(FILE *f);

#ifdef __cplusplus
}
#endif
