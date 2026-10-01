// vx-rt: the user runtime for first-party programs in M1 (docs/04 §2): the
// entry point, syscall stubs, console output and the stack protector. A
// program includes this file, as its unity build, and defines vx_main.
//
// M1 programs are built with -mgeneral-regs-only: the kernel does not save
// FP/SIMD state across context switches yet. That comes with M2's threads.

#include "rt.h"
#include "../vx-mem/mem.c"

#ifdef __clang_analyzer__
// The static analyzer cannot see a syscall instruction write through the
// pointers it is passed. For the analyzer only, the stub calls a function it
// knows nothing about, with the arguments as pointers, so it assumes the
// memory behind them may change, as it may.
int64_t vx_syscall_seen_by_analyzer(enum vx_syscall nr, void *a0, void *a1, void *a2, void *a3, void *a4,
                                    void *a5);
#endif

static inline int64_t vx_syscall(enum vx_syscall nr, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                                 uint64_t a4, uint64_t a5) {
  int64_t ret;
#ifdef __clang_analyzer__
  ret =
      vx_syscall_seen_by_analyzer(nr, (void *)a0, (void *)a1, (void *)a2, (void *)a3, (void *)a4, (void *)a5);
#elifdef __x86_64__
  register uint64_t r10 __asm__("r10") = a3;
  register uint64_t r8 __asm__("r8") = a4;
  register uint64_t r9 __asm__("r9") = a5;
  __asm__ volatile("syscall"
                   : "=a"(ret)
                   : "a"((uint64_t)nr), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8), "r"(r9)
                   : "rcx", "r11", "memory");
#else
  register uint64_t x8 __asm__("x8") = nr;
  register uint64_t x0 __asm__("x0") = a0;
  register uint64_t x1 __asm__("x1") = a1;
  register uint64_t x2 __asm__("x2") = a2;
  register uint64_t x3 __asm__("x3") = a3;
  register uint64_t x4 __asm__("x4") = a4;
  register uint64_t x5 __asm__("x5") = a5;
  __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory");
  ret = (int64_t)x0;
#endif
  return ret;
}

// --- Syscalls (the M1 subset; the argument conventions are a draft until ADR-0004) ---
//
// Wrappers that create something zero their output first, so a failed call
// leaves VX_HANDLE_NONE behind rather than whatever was there.

[[maybe_unused]] static vx_status vx_debug_write(vx_str s) {
  return (vx_status)vx_syscall(VX_SYS_debug_write, (uint64_t)s.ptr, s.len, 0, 0, 0, 0);
}

[[maybe_unused]] static vx_instant vx_clock_read(void) {
  return vx_syscall(VX_SYS_clock_read, 0, 0, 0, 0, 0, 0);
}

[[maybe_unused]] static vx_status vx_task_info(vx_handle task, vx_task_summary *out) {
  *out = (vx_task_summary){};
  return (vx_status)vx_syscall(VX_SYS_task_info, task, (uint64_t)out, 0, 0, 0, 0);
}

[[maybe_unused]] static vx_status vx_port_create(uint32_t options, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_port_create, options, (uint64_t)out, 0, 0, 0, 0);
}

// Returns how many packets it stored (at least 1), or a negative vx_status:
// VX_ERR_TIMED_OUT when the deadline passed with none.
[[maybe_unused]] static int64_t vx_port_wait(vx_handle port, vx_instant deadline, vx_duration leeway,
                                             vx_packet *out, size_t out_len) {
  return vx_syscall(VX_SYS_port_wait, port, (uint64_t)deadline, (uint64_t)leeway, (uint64_t)out, out_len, 0);
}

[[maybe_unused]] static vx_status vx_port_post(vx_handle port, const vx_packet *packet) {
  return (vx_status)vx_syscall(VX_SYS_port_post, port, (uint64_t)packet, 0, 0, 0, 0);
}

[[maybe_unused]] static vx_status vx_vmo_create(uint64_t size, uint32_t options, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_vmo_create, size, options, (uint64_t)out, 0, 0, 0);
}

// Maps a whole VMO into a task. *addr == 0 lets the kernel choose; the address
// used is written back.
[[maybe_unused]] static vx_status vx_as_map(vx_handle task, vx_handle vmo, uint32_t flags, uint64_t *addr) {
  return (vx_status)vx_syscall(VX_SYS_as_map, task, vmo, flags, (uint64_t)addr, 0, 0);
}

[[maybe_unused]] static vx_status vx_handle_close(vx_handle h) {
  return (vx_status)vx_syscall(VX_SYS_handle_close, h, 0, 0, 0, 0, 0);
}

// --- Console output, through debug_write ---

[[maybe_unused]] static void vx_print(vx_str s) { vx_debug_write(s); }

[[maybe_unused]] static void vx_print_u64(uint64_t v) {
  char buf[20];
  size_t i = sizeof buf;
  do {
    buf[--i] = (char)('0' + v % 10);
    v /= 10;
  } while (v);
  vx_debug_write((vx_str){buf + i, sizeof buf - i});
}

// A duration in nanoseconds, as milliseconds with three decimals.
[[maybe_unused]] static void vx_print_millis(uint64_t ns) {
  uint64_t us = ns / 1000;
  char frac[4] = {'.', (char)('0' + us % 1000 / 100), (char)('0' + us % 100 / 10), (char)('0' + us % 10)};
  vx_print_u64(us / 1000);
  vx_debug_write((vx_str){frac, 4});
}

// --- Start-up ---

uintptr_t __stack_chk_guard = 0x2e0f5b3c9d81a647; // to come from the kernel's entropy (M2)

// A smashed stack ends the task: the trap is reported by the kernel.
[[noreturn]] void __stack_chk_fail(void) { __builtin_trap(); }

// Called by _start with the handle the kernel passes. There is no thread_exit
// before M2, so a vx_main that returns ends in a trap the kernel reports.
[[noreturn]] void vx_start(vx_handle self_task) {
  vx_main(self_task);
  __builtin_trap();
}

#ifdef __x86_64__
[[gnu::naked, noreturn]] void _start(void) {
  __asm__("endbr64\n\t"
          "xorl %ebp, %ebp\n\t"
          "andq $-16, %rsp\n\t"
          "call vx_start\n\t" // the argument is already in rdi
          "ud2");
}
#else
[[gnu::naked, noreturn]] void _start(void) {
  __asm__("hint #34\n\t" // bti c
          "mov x29, xzr\n\t"
          "mov x30, xzr\n\t"
          "bl vx_start\n\t" // the argument is already in x0
          "brk #0");
}
#endif
