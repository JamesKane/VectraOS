// SPDX-License-Identifier: BSD-3-Clause

// open (POSIX XSH) is variadic, which Swift can't define: its mode, if
// O_CREAT is in the flags, then fdio's td_fdio_open (Exports.swift).

#include <fcntl.h>
#include <stdarg.h>

int td_fdio_open(const char *path, int flags, mode_t mode);

int open(const char *path, int flags, ...) {
  mode_t mode = 0;
  if (flags & O_CREAT) {
    va_list ap;
    va_start(ap, flags);
    mode = va_arg(ap, unsigned);
    va_end(ap);
  }
  return td_fdio_open(path, flags, mode);
}
