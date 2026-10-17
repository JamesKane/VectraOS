// SPDX-License-Identifier: BSD-3-Clause

// The runtime's per-process state (Runtime in Start.swift), as C globals
// (M5k). Swift globals don't do here: Embedded Swift copies the code that
// uses another module's global into each client, and with it a weak,
// protected copy of the global's storage, so a shared object loaded with
// dlopen would read its own copy, never set. A C global is one symbol,
// which a library imports from the program.

#include "td_native.h"
#include "td_utc.h"

uint32_t td_runtime_process_self;
uint32_t td_runtime_vmar_root;
uint32_t td_runtime_thread_self;
uint64_t td_runtime_vdso_base;
uint64_t td_runtime_vdso_clock;
uint64_t td_runtime_vdso_topology;
uint64_t td_runtime_utc_page;

int64_t td_monotonic(void);

// UTC now: the monotonic clock plus the UTC page's offset (D48), read
// under its seqlock; the monotonic clock alone in a process given no page.
int64_t td_utc_now(void) {
  int64_t now = td_monotonic();
  if (!td_runtime_utc_page) return now;
  int64_t offset;
  uint64_t error;
  td_utc_read((const td_utc_page_t *)(uintptr_t)td_runtime_utc_page, &offset, &error);
  return now + offset;
}

// C's environment (POSIX's environ): the floor's start points it at the
// processargs message's strings (Start.swift), the kernel's boot options
// for the programs userboot starts and empty for the rest (D81).
char **environ;

// The program's initializers, which C, C++ and a full Swift runtime (its
// swiftrt.o registers the program's metadata) leave in .preinit_array and
// .init_array: run before main, in order. ld.lld defines the bounds.
extern void (*__preinit_array_start[])(void) __attribute__((weak));
extern void (*__preinit_array_end[])(void) __attribute__((weak));
extern void (*__init_array_start[])(void) __attribute__((weak));
extern void (*__init_array_end[])(void) __attribute__((weak));

void td_run_initializers(void) {
  for (void (**f)(void) = __preinit_array_start; f < __preinit_array_end; f++) (*f)();
  for (void (**f)(void) = __init_array_start; f < __init_array_end; f++) (*f)();
}

// atexit (C23 §7.24.4.2) and the C++ ABI's __cxa_atexit, which a full Swift
// runtime and C++ static objects register with: run last first by exit. A
// fixed table (C23 asks for room for 32); one registered past it is refused.
enum { exit_handlers_max = 64 };
static struct {
  void (*f)(void *);
  void *arg;
} exit_handlers[exit_handlers_max];
static int exit_handler_count;

int __cxa_atexit(void (*f)(void *), void *arg, void *dso) {
  (void)dso;
  if (exit_handler_count == exit_handlers_max) return -1;
  exit_handlers[exit_handler_count].f = f;
  exit_handlers[exit_handler_count].arg = arg;
  exit_handler_count++;
  return 0;
}

static void call_plain(void *f) { ((void (*)(void))f)(); }
int atexit(void (*f)(void)) { return __cxa_atexit(call_plain, (void *)f, 0); }

void td_run_exit_handlers(void) {
  while (exit_handler_count > 0) {
    exit_handler_count--;
    exit_handlers[exit_handler_count].f(exit_handlers[exit_handler_count].arg);
  }
}

// The C++ ABI's handle for this object (crtbegin.o's elsewhere).
void *__dso_handle = &__dso_handle;

// abort (C23 §7.24.4.1): said on stdout, then a trap, so that croi reports
// the process as having crashed (as Zircon's abort does).
void td_stdout_write(const void *bytes, unsigned long n);
void td_stdout_flush(void);

// write (POSIX XSH) to stdout (1) and stderr (2), which are both the
// process's debuglog: stdout's lines, a stderr write flushed at once. Weak:
// a tier 1 program's fdio (system/fdio, M6g) gives the write for every
// descriptor, these two included.
extern int *__errno_location(void);
__attribute__((weak)) long write(int fd, const void *buffer, unsigned long count) {
  if (fd != 1 && fd != 2) {
    *__errno_location() = 9;  // EBADF
    return -1;
  }
  if (count == 0 || !buffer) return 0;
  td_stdout_write(buffer, count);
  if (fd == 2) td_stdout_flush();
  return (long)count;
}
_Noreturn void abort(void) {
  td_stdout_write("abort()\n", 8);
  td_stdout_flush();
  __builtin_trap();
}

// The compiler's 128-bit shifts by a variable amount (compiler-rt's names
// and ABI): code optimized for size calls them rather than expanding the
// shift (LibC's UInt128 significands, M6d), and tier 0 links no
// compiler-rt. In 64-bit halves, so that they can't become calls to
// themselves.
typedef unsigned long long td_u64;
typedef union {
  unsigned __int128 all;
  struct {
    td_u64 low, high;  // little-endian, as all three machines are
  } s;
} td_u128;

unsigned __int128 __ashlti3(unsigned __int128 a, int b) {
  td_u128 x = {.all = a}, r;
  if (b == 0) return a;
  if (b >= 64) {
    r.s.low = 0;
    r.s.high = x.s.low << (b - 64);
  } else {
    r.s.low = x.s.low << b;
    r.s.high = x.s.high << b | x.s.low >> (64 - b);
  }
  return r.all;
}

unsigned __int128 __lshrti3(unsigned __int128 a, int b) {
  td_u128 x = {.all = a}, r;
  if (b == 0) return a;
  if (b >= 64) {
    r.s.high = 0;
    r.s.low = x.s.high >> (b - 64);
  } else {
    r.s.high = x.s.high >> b;
    r.s.low = x.s.low >> b | x.s.high << (64 - b);
  }
  return r.all;
}

// Each thread's allocations (M6m: a frame's are counted on its own
// thread; other threads allocate meanwhile).
static _Thread_local uint64_t td_thread_allocations;
// Set once the main thread's TLS is in place (the heap allocates before).
int td_heap_tls_ready;
void td_heap_noted(void) {
  if (td_heap_tls_ready) td_thread_allocations++;
}
uint64_t td_heap_thread_allocations(void) { return td_thread_allocations; }

void td_cpuid(uint32_t leaf, uint32_t sub, uint32_t *out) {
#if defined(__x86_64__)
  __asm__ volatile("cpuid" : "=a"(out[0]), "=b"(out[1]), "=c"(out[2]), "=d"(out[3]) : "a"(leaf), "c"(sub));
#else
  out[0] = out[1] = out[2] = out[3] = 0;
  (void)leaf;
  (void)sub;
#endif
}

// getenv (C23 §7.24.4.6) over environ: the kernel's boot options, for the
// programs userboot starts (Start.swift's td_boot_getenv). Weak: a tier 1
// program's fdio gives the getenv that reads its /env (D81).
char *td_boot_getenv(const char *name);
__attribute__((weak)) char *getenv(const char *name) { return td_boot_getenv(name); }
