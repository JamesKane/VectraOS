// SPDX-License-Identifier: BSD-3-Clause

// open (POSIX XSH) is variadic, which Swift can't define: its mode, if
// O_CREAT is in the flags, then fdio's td_fdio_open (Exports.swift).
//
// getenv is C too: the Swift runtime reads its own settings (SWIFT_*) with
// it from inside a swift_once, where Swift code waits on that once for
// good. Those come from the boot options (the floor's td_boot_getenv);
// the rest from /env, by Swift (td_fdio_getenv, D81).

#include <fcntl.h>
#include <stdarg.h>

int td_fdio_open(const char *path, int flags, mode_t mode);
char *td_fdio_getenv(const char *name);
char *td_boot_getenv(const char *name);

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

char *getenv(const char *name) {
  static const char swift[] = "SWIFT_";
  for (int i = 0; swift[i]; i++)
    if (name[i] != swift[i]) return td_fdio_getenv(name);
  return td_boot_getenv(name);
}
