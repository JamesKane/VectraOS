// SPDX-License-Identifier: BSD-3-Clause

// <stdio.h>'s C side (M6c): what Swift can't be, by principle 28's
// calling-convention exception. The variadic functions (printf's and
// scanf's families) and the va_list readers the Swift formatter
// (system/libc/stdio/Format.swift) and scanner (Scan.swift) take their
// arguments through; the three standard streams, which are data C names,
// over the floor's (system/sys/floor/Stdout.swift): stdout as lines and
// stderr at once, to the stdout ring or the debuglog; stdin through a
// buffer, from the stdin ring (D46); and the calls file streams make,
// open among them, which is variadic. A file stream (fopen's and
// fdopen's) is native/Streams.swift's: each function here that takes a
// FILE sends one there.

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "td_stdio_shim.h"

typedef struct td_file FILE;

static FILE streams[3] = {{.fd = 0}, {.fd = 1}, {.fd = 2}};
FILE *stdin = &streams[0];
FILE *stdout = &streams[1];
FILE *stderr = &streams[2];

// The Swift formatter's and scanner's entries (Exports.swift).
int td_format_buffer(char *buffer, size_t size, const char *format, va_list *ap);
int td_format_stream(int fd, const char *format, va_list *ap);
int td_scan_string(const char *s, const char *format, va_list *ap);
// File streams' (Streams.swift).
int td_format_file(FILE *f, const char *format, va_list *ap);
size_t td_file_write(FILE *f, const void *p, size_t n);
size_t td_file_read(FILE *f, void *p, size_t n);
int td_file_getc(FILE *f);
int td_file_ungetc(int c, FILE *f);
int td_file_flush(FILE *f);
int td_file_flush_all(void);
int td_file_close(FILE *f);

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

int td_file_sys_open(const char *path, int flags) { return open(path, flags, 0666); }
ptrdiff_t td_file_sys_read(int fd, void *buffer, size_t n) { return read(fd, buffer, n); }
ptrdiff_t td_file_sys_write(int fd, const void *buffer, size_t n) { return write(fd, buffer, n); }
int64_t td_file_sys_seek(int fd, int64_t offset, int whence) { return lseek(fd, offset, whence); }
int td_file_sys_close(int fd) { return close(fd); }
void *td_file_sys_alloc(size_t n) { return malloc(n); }
void td_file_sys_free(void *p) { free(p); }
int td_file_sys_atexit(void (*f)(void)) { return atexit(f); }

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

int vasprintf(char **s, const char *format, va_list ap) {
  va_list copy;
  va_copy(copy, ap);
  int n = vsnprintf(NULL, 0, format, copy);
  va_end(copy);
  if (n < 0) return -1;
  char *buffer = malloc((size_t)n + 1);
  if (buffer == NULL) return -1;
  va_copy(copy, ap);
  vsnprintf(buffer, (size_t)n + 1, format, copy);
  va_end(copy);
  *s = buffer;
  return n;
}

int asprintf(char **s, const char *format, ...) {
  va_list ap;
  va_start(ap, format);
  int n = vasprintf(s, format, ap);
  va_end(ap);
  return n;
}

int vsscanf(const char *s, const char *format, va_list ap) {
  va_list copy;
  va_copy(copy, ap);
  int n = td_scan_string(s, format, &copy);
  va_end(copy);
  return n;
}

int sscanf(const char *s, const char *format, ...) {
  va_list ap;
  va_start(ap, format);
  int n = vsscanf(s, format, ap);
  va_end(ap);
  return n;
}

int vfprintf(FILE *f, const char *format, va_list ap) {
  va_list copy;
  va_copy(copy, ap);
  int n;
  if (f->file) {
    n = td_format_file(f, format, &copy);
  } else if (f->fd == 0) {
    f->error = 1;
    errno = EBADF;
    n = -1;
  } else {
    n = td_format_stream(f->fd, format, &copy);
  }
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
  if (size == 0 || n == 0) return 0;
  if (f->file) return td_file_write(f, p, size * n) / size;
  if (f->fd == 0) {
    f->error = 1;
    errno = EBADF;
    return 0;
  }
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

// fflush(NULL) writes out every stream.
int fflush(FILE *f) {
  if (f != NULL && f->file) return td_file_flush(f);
  td_stdout_flush();
  return f == NULL ? td_file_flush_all() : 0;
}

// Reading stdin: its ring through a buffer (stdout flushed before each
// read, by the floor); stdout and stderr can't be read.
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

int fgetc(FILE *f) {
  if (f->file) return td_file_getc(f);
  return fill(f) ? in_buffer[in_at++] : -1;
}
int getc(FILE *f) { return fgetc(f); }
int getchar(void) { return fgetc(stdin); }

// A byte back into stdin's buffer: before what's left of it, which moves
// up a byte when nothing has been taken from it.
int ungetc(int c, FILE *f) {
  if (f->file) return td_file_ungetc(c, f);
  if (c == EOF || f->fd != 0) return EOF;
  if (in_at == 0) {
    if (in_count == sizeof in_buffer) return EOF;
    __builtin_memmove(in_buffer + 1, in_buffer, in_count);
    in_count++;
    in_at = 1;
  }
  in_buffer[--in_at] = (unsigned char)c;
  f->eof = 0;
  return (unsigned char)c;
}

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
  if (f->file) return td_file_read(f, p, size * n) / size;
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

// remove and rename are weak: a tier 1 program's fdio (system/fdio, M6g)
// gives the real ones; without it they fail.
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
  if (f->file) return td_file_close(f);
  fflush(f);
  return 0;
}

int fgetpos(FILE *__restrict f, fpos_t *__restrict position) {
  off_t at = ftello(f);
  if (at < 0) return -1;
  position->__offset = at;
  return 0;
}
int fsetpos(FILE *f, const fpos_t *position) { return fseeko(f, position->__offset, SEEK_SET); }

// The standard streams are written whole, under stdout's lock; a file
// stream has no lock (Streams.swift).
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
