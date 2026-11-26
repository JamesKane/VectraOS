// SPDX-License-Identifier: BSD-3-Clause

// What the libc's Swift reaches in C for stdio (M6c): C's va_list, which
// Swift can't read, through stdio.c's readers; the floor's stdout
// (system/sys/floor/Stdout.swift), reached by symbol (the floor imports the
// libc, so the libc can't import the floor); and FILE's layout, with the
// calls file streams make (native/Streams.swift).

#pragma once
#include <stddef.h>
#include <stdint.h>

// A FILE: stdio.c's three standard streams, and the file streams fopen
// and fdopen make (native/Streams.swift). The standard streams leave a
// file stream's fields zero.
struct td_file {
  int fd;
  int error, eof;
  int file;  // 1: a file stream, over `fd`
  int readable, writable, append;
  int buffering;  // _IOFBF, _IOLBF or _IONBF
  int pushed;     // a byte ungetc pushed back with no room in the buffer, or -1
  int own;        // whether `buffer` is the stream's own (malloc's)
  unsigned char *buffer;
  size_t size;           // the buffer's
  size_t at, count;      // reading: the buffer's next byte, and its end
  size_t pending;        // writing: bytes in the buffer, not yet written
  struct td_file *next;  // the open file streams, for fflush(NULL) and exit
};

// The calls file streams make, under names the libc's Swift imports
// without meeting its own functions' (stdio.c; open is variadic).
int td_file_sys_open(const char *path, int flags);
ptrdiff_t td_file_sys_read(int fd, void *buffer, size_t n);
ptrdiff_t td_file_sys_write(int fd, const void *buffer, size_t n);
int64_t td_file_sys_seek(int fd, int64_t offset, int whence);
int td_file_sys_close(int fd);
void *td_file_sys_alloc(size_t n);
void td_file_sys_free(void *p);
int td_file_sys_atexit(void (*f)(void));

/// The next variadic argument: an integer of `size` bytes (its bits), a
/// double, a long double, a pointer. `ap` is a va_list's address.
uint64_t td_va_integer(void *ap, int size);
double td_va_double(void *ap);
/// The next long double's bytes: x87's 10 (then padding) on amd64,
/// binary128's 16 elsewhere.
void td_va_long_double(void *ap, uint64_t out[2]);
uintptr_t td_va_pointer(void *ap);

void td_stdout_write(const void *bytes, size_t n);
void td_stdout_flush(void);
void td_stderr_write(const void *bytes, size_t n);
ptrdiff_t td_stdin_read(void *buffer, size_t n);
