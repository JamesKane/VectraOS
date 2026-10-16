// SPDX-License-Identifier: BSD-3-Clause

// <stdio.h>'s C side (M6c): what Swift can't be, by principle 28's
// calling-convention exception. The variadic functions (printf and its
// family) and the va_list readers the Swift formatter
// (system/libc/stdio/Format.swift) takes its arguments through, and the
// three standard streams, over the floor's (system/sys/floor/Stdout.swift):
// stdout as lines and stderr at once, to the debuglog; stdin through a
// buffer, empty until byte streams come (V2's item 6, D46). fopen has no
// files to open yet (tier 1's files are the fs service's, from Swift).

#include <errno.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#include "td_stdio_shim.h"

struct td_file {
  int fd;
  int error, eof;
};
typedef struct td_file FILE;

static FILE streams[3] = {{0, 0, 0}, {1, 0, 0}, {2, 0, 0}};
FILE *stdin = &streams[0];
FILE *stdout = &streams[1];
FILE *stderr = &streams[2];

// The Swift formatter's entries (Exports.swift).
int td_format_buffer(char *buffer, size_t size, const char *format, va_list *ap);
int td_format_stream(int fd, const char *format, va_list *ap);

uint64_t td_va_integer(void *ap, int size) {
  va_list *v = ap;
  return size == 8 ? va_arg(*v, unsigned long long) : (uint64_t)va_arg(*v, unsigned int);
}
double td_va_double(void *ap) { return va_arg(*(va_list *)ap, double); }
void td_va_long_double(void *ap, uint64_t out[2]) {
  long double v = va_arg(*(va_list *)ap, long double);
  __builtin_memcpy(out, &v, sizeof v);  // x87's 10 bytes then padding, or binary128's 16
}
uintptr_t td_va_pointer(void *ap) { return (uintptr_t)va_arg(*(va_list *)ap, void *); }

int vsnprintf(char *buffer, size_t size, const char *format, va_list ap) {
  va_list copy;
  va_copy(copy, ap);
  int n = td_format_buffer(buffer, size, format, &copy);
  va_end(copy);
  return n;
}

int snprintf(char *buffer, size_t size, const char *format, ...) {
  va_list ap;
  va_start(ap, format);
  int n = vsnprintf(buffer, size, format, ap);
  va_end(ap);
  return n;
}

int vsprintf(char *buffer, const char *format, va_list ap) { return vsnprintf(buffer, SIZE_MAX, format, ap); }

int sprintf(char *buffer, const char *format, ...) {
  va_list ap;
  va_start(ap, format);
  int n = vsprintf(buffer, format, ap);
  va_end(ap);
  return n;
}

int vfprintf(FILE *f, const char *format, va_list ap) {
  if (f->fd == 0) {
    f->error = 1;
    errno = EBADF;
    return -1;
  }
  va_list copy;
  va_copy(copy, ap);
  int n = td_format_stream(f->fd, format, &copy);
  va_end(copy);
  return n;
}

int fprintf(FILE *f, const char *format, ...) {
  va_list ap;
  va_start(ap, format);
  int n = vfprintf(f, format, ap);
  va_end(ap);
  return n;
}

int vprintf(const char *format, va_list ap) { return vfprintf(stdout, format, ap); }

int printf(const char *format, ...) {
  va_list ap;
  va_start(ap, format);
  int n = vfprintf(stdout, format, ap);
  va_end(ap);
  return n;
}

size_t fwrite(const void *p, size_t size, size_t n, FILE *f) {
  if (f->fd == 0) {
    f->error = 1;
    errno = EBADF;
    return 0;
  }
  if (size == 0 || n == 0) return 0;
  if (f->fd == 2) {
    td_stderr_write(p, size * n);
  } else {
    td_stdout_write(p, size * n);
  }
  return n;
}

int fputc(int c, FILE *f) {
  unsigned char b = (unsigned char)c;
  return fwrite(&b, 1, 1, f) == 1 ? b : -1;
}
int putc(int c, FILE *f) { return fputc(c, f); }

int fputs(const char *s, FILE *f) {
  size_t n = 0;
  while (s[n]) n++;
  return n == 0 || fwrite(s, 1, n, f) == n ? 0 : -1;
}

int puts(const char *s) { return fputs(s, stdout) < 0 || fputc('\n', stdout) < 0 ? -1 : 0; }

int fflush(FILE *f) {
  (void)f;
  td_stdout_flush();
  return 0;
}

// Reading: stdin's socket through a buffer (stdout flushed before each
// read, by the floor); the other streams can't be read.
static unsigned char in_buffer[4096];
static size_t in_at, in_count;

static int fill(FILE *f) {
  if (f->fd != 0) {
    f->error = 1;
    errno = EBADF;
    return 0;
  }
  if (in_at < in_count) return 1;
  ptrdiff_t n = td_stdin_read(in_buffer, sizeof in_buffer);
  if (n <= 0) {
    f->eof = 1;
    return 0;
  }
  in_at = 0;
  in_count = (size_t)n;
  return 1;
}

int fgetc(FILE *f) { return fill(f) ? in_buffer[in_at++] : -1; }
int getc(FILE *f) { return fgetc(f); }
int getchar(void) { return fgetc(stdin); }
char *fgets(char *s, int n, FILE *f) {
  if (n <= 0) return 0;
  int i = 0;
  while (i < n - 1) {
    int c = fgetc(f);
    if (c < 0) break;
    s[i++] = (char)c;
    if (c == '\n') break;
  }
  if (i == 0) return 0;
  s[i] = 0;
  return s;
}
size_t fread(void *p, size_t size, size_t n, FILE *f) {
  if (size == 0 || n == 0) return 0;
  unsigned char *out = p;
  size_t want = size * n, got = 0;
  while (got < want && fill(f)) {
    size_t k = in_count - in_at < want - got ? in_count - in_at : want - got;
    __builtin_memcpy(out + got, in_buffer + in_at, k);
    in_at += k;
    got += k;
  }
  return got / size;
}

int feof(FILE *f) { return f->eof; }
int ferror(FILE *f) { return f->error; }
void clearerr(FILE *f) { f->eof = f->error = 0; }

// No file streams yet. remove and rename are weak: a tier 1 program's
// fdio (system/fdio, M6g) gives the real ones; without it they fail.
FILE *fopen(const char *path, const char *mode) {
  (void)path;
  (void)mode;
  errno = ENOENT;
  return 0;
}
__attribute__((weak)) int remove(const char *path) {
  (void)path;
  errno = ENOENT;
  return -1;
}
__attribute__((weak)) int rename(const char *from, const char *to) {
  (void)from;
  (void)to;
  errno = ENOENT;
  return -1;
}
int fileno(FILE *f) { return f->fd; }
int fclose(FILE *f) {
  (void)f;
  return 0;
}

// The standard streams are written whole, under stdout's lock.
void flockfile(FILE *f) { (void)f; }
void funlockfile(FILE *f) { (void)f; }
int ftrylockfile(FILE *f) {
  (void)f;
  return 0;
}

// <assert.h>'s failure: the expression, where, and abort.
_Noreturn void abort(void);
_Noreturn void __td_assert_fail(const char *expression, const char *file, int line, const char *function) {
  fprintf(stderr, "%s:%d: %s: assertion failed: %s\n", file, line, function, expression);
  abort();
}
