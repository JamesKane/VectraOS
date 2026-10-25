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
#include <croi/syscall.h>
#include <pthread.h>
#include <sched.h>
#include <sys/mman.h>
#include <td_native.h>
#include <unistd.h>

/// snprintf with a mix of conversions: what it wrote, or its error.
// Anonymous mappings: zeroed, written and read across pages, 2 MiB too,
// unmapped; MAP_FIXED, file mappings and PROT_EXEC refused. 1 if all hold.
int libc_suite_mappings(void) {
  char *p = mmap(NULL, 3 * 4096 + 1, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (p == MAP_FAILED || ((uintptr_t)p & 4095) != 0) return 0;
  for (int i = 0; i < 4 * 4096; i += 4096) {
    if (p[i] != 0) return 0;
    p[i] = (char)(i / 4096 + 1);
  }
  if (p[3 * 4096] != 4 || munmap(p, 3 * 4096 + 1) != 0) return 0;
  char *big = mmap(NULL, 2u << 20, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
  if (big == MAP_FAILED) return 0;
  big[(2u << 20) - 1] = 7;
  if (mprotect(big, 2u << 20, PROT_READ) != 0 || big[(2u << 20) - 1] != 7 || munmap(big, 2u << 20) != 0) return 0;
  return mmap(NULL, 4096, PROT_READ, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0) == MAP_FAILED && errno == EINVAL
      && mmap(NULL, 4096, PROT_READ, MAP_PRIVATE, 3, 0) == MAP_FAILED && errno == ENODEV
      && mmap(NULL, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0) == MAP_FAILED && errno == EACCES
      && munmap((char *)4097, 4096) == -1 && errno == EINVAL;
}

// The calling thread's CPU mask, as the kernel has it (THREAD info).
static uint64_t affinity(void) {
  croi_info_thread_t info;
  if (croi_syscall6(CROI_SYS_OBJECT_GET_INFO, td_runtime_thread_self, CROI_INFO_THREAD, (uint64_t)(uintptr_t)&info,
                    sizeof info, 0, 0) != 0)
    return 0;
  return info.cpu_affinity_mask[0];
}

// CPU affinity: the calling thread kept to the last CPU, by
// sched_setaffinity and by pthread_setaffinity_np, then to every CPU
// again; a set with no CPU refused. 1 if all hold.
int libc_suite_affinity(void) {
  long count = sysconf(_SC_NPROCESSORS_ONLN);
  if (count < 1 || count > 64) return 0;
  uint64_t all = count == 64 ? ~0ull : (1ull << count) - 1;
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(count - 1, &set);
  if (sched_setaffinity(0, sizeof set, &set) != 0 || affinity() != 1ull << (count - 1)) return 0;
  CPU_ZERO(&set);
  CPU_SET(0, &set);
  if (pthread_setaffinity_np(pthread_self(), sizeof set, &set) != 0 || affinity() != 1) return 0;
  CPU_ZERO(&set);
  if (sched_setaffinity(0, sizeof set, &set) != -1 || errno != EINVAL) return 0;
  if (pthread_setaffinity_np(pthread_self(), sizeof set, &set) != EINVAL) return 0;
  for (long i = 0; i < count; i++) CPU_SET(i, &set);
  return sched_setaffinity(0, sizeof set, &set) == 0 && affinity() == all;
}

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
