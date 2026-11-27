// SPDX-License-Identifier: BSD-3-Clause

// <stdio.h> for C programs on croi (M6c), from C23 §7.23: the standard
// streams (stdout and stderr to the process's debuglog or its stdout
// ring, stdin from its stdin ring), the printf family (system/libc/stdio,
// C23's conversions, correctly rounded), the scanf family from a string,
// and file streams over descriptors (fopen and POSIX's fdopen, fseeko
// and ftello: system/libc/native/Streams.swift), whose files are tier 1's
// fdio's (M6g, system/fdio): without it fopen fails as open does (ENOENT),
// as remove and rename do. A file stream has no lock (flockfile does
// nothing): two threads may not use one at once. No scanf from a stream,
// no tmpfile, popen or wide characters.

#pragma once
#include <stdarg.h>
#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct td_file FILE;
typedef struct {
  off_t __offset;
} fpos_t;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

#define EOF (-1)
#define BUFSIZ 1024
#define FILENAME_MAX 4096
#define FOPEN_MAX 16
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
// setvbuf's modes (glibc's values).
#define _IOFBF 0
#define _IOLBF 1
#define _IONBF 2

int printf(const char *__restrict format, ...);
int fprintf(FILE *__restrict f, const char *__restrict format, ...);
int snprintf(char *__restrict s, size_t n, const char *__restrict format, ...);
int sprintf(char *__restrict s, const char *__restrict format, ...);
int vprintf(const char *__restrict format, va_list ap);
int vfprintf(FILE *__restrict f, const char *__restrict format, va_list ap);
int vsnprintf(char *__restrict s, size_t n, const char *__restrict format, va_list ap);
int vsprintf(char *__restrict s, const char *__restrict format, va_list ap);
// POSIX's: the formatted text in a buffer of malloc's, which the caller
// frees; -1 (and *s undefined) if there is no memory.
int asprintf(char **__restrict s, const char *__restrict format, ...);
int vasprintf(char **__restrict s, const char *__restrict format, va_list ap);

// The scanf family from a string (C23 §7.23.6.4).
int sscanf(const char *__restrict s, const char *__restrict format, ...);
int vsscanf(const char *__restrict s, const char *__restrict format, va_list ap);

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
int ungetc(int c, FILE *f);
char *fgets(char *__restrict s, int n, FILE *__restrict f);
size_t fread(void *__restrict p, size_t size, size_t n, FILE *__restrict f);

int feof(FILE *f);
int ferror(FILE *f);
void clearerr(FILE *f);
FILE *fopen(const char *__restrict path, const char *__restrict mode);
FILE *fdopen(int fd, const char *mode);
int fclose(FILE *f);
int fileno(FILE *f);
int setvbuf(FILE *__restrict f, char *__restrict buffer, int mode, size_t size);
void setbuf(FILE *__restrict f, char *__restrict buffer);
// The standard streams don't seek (ESPIPE).
int fseek(FILE *f, long offset, int whence);
int fseeko(FILE *f, off_t offset, int whence);
long ftell(FILE *f);
off_t ftello(FILE *f);
void rewind(FILE *f);
int fgetpos(FILE *__restrict f, fpos_t *__restrict position);
int fsetpos(FILE *f, const fpos_t *position);
int remove(const char *path);
int rename(const char *from, const char *to);
void flockfile(FILE *f);
void funlockfile(FILE *f);
int ftrylockfile(FILE *f);

#ifdef __cplusplus
}
#endif
