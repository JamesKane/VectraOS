// SPDX-License-Identifier: BSD-3-Clause

// The libc suite's C side (LibcSuite.swift has its checks): only what
// Swift can't do. Embedded Swift can't make a variadic call (it has no
// withVaList), so printf's family is called from here; and `_Thread_local`
// is C's, so ELF TLS is exercised here (after todhchai's tls-test.c):
// initialized, zeroed, over-aligned and external variables, each thread's
// own from its first instruction (variant II on amd64, I on arm64 and
// rv64), and errno each thread's.

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/// snprintf with a mix of conversions: what it wrote, or its error.
int libc_suite_format(char *buffer, size_t size) {
  return snprintf(buffer, size, "%d|%5s|%-4x|%.3f|%e|%c|%lld|%%", -42, "ab", 255, 3.14159, 1e-300, 'z',
                  -9007199254740993LL);
}

/// snprintf of a truncated buffer: the length it would have written.
int libc_suite_truncated(char *buffer, size_t size) { return snprintf(buffer, size, "%s-%d", "truncated", 12345); }

/// strtold of 0.1, printed to 25 digits: x87's format on amd64,
/// binary128's elsewhere.
int libc_suite_long_double(char *buffer, size_t size) {
  return snprintf(buffer, size, "%.25Lg", strtold("0.1", 0));
}

static _Thread_local int initialized = 42;
static _Thread_local long zeroed[16];
static _Thread_local _Alignas(64) char aligned[3] = {'a', 'b', 'c'};
_Thread_local int libc_suite_shared = 7;  // external linkage: another model

/// An address the compiler can't reason about (it would fold the check
/// from the declared alignment).
static uintptr_t address(const void *p) {
  volatile uintptr_t a = (uintptr_t)p;
  return a;
}

/// The calling thread's TLS image is the program's.
int libc_suite_tls_image(void) {
  return initialized == 42 && aligned[1] == 'b' && (address(aligned) & 63) == 0;
}

/// Marks the main thread's TLS, then checks it is unchanged once the
/// others have written theirs.
void libc_suite_tls_mark(void) {
  initialized = 1;
  errno = 5;
}
int libc_suite_tls_marked(void) { return initialized == 1 && errno == 5 && aligned[1] == 'b'; }

/// A thread's body: its TLS starts as the image, and what it writes is its
/// own. Returns nonzero if all held.
void *libc_suite_tls_thread(void *arg) {
  long id = (long)arg;
  int ok = initialized == 42 && aligned[0] == 'a' && aligned[2] == 'c' && libc_suite_shared == 7
           && (address(aligned) & 63) == 0;
  aligned[1] = (char)id;
  for (int i = 0; i < 16; i++) ok = ok && zeroed[i] == 0;
  initialized = (int)id;
  libc_suite_shared = (int)id * 2;
  errno = (int)id + 100;
  for (int i = 0; i < 16; i++) zeroed[i] = id;
  // Let the others write theirs, then see only ours.
  for (volatile int spin = 0; spin < 200000; spin++) {}
  ok = ok && initialized == id && libc_suite_shared == id * 2 && errno == id + 100 && aligned[1] == (char)id;
  for (int i = 0; i < 16; i++) ok = ok && zeroed[i] == id;
  return (void *)(intptr_t)ok;
}
