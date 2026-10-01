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

// Maps [offset, offset + size) of a VMO into a task. *addr == 0 lets the
// kernel choose; the address used is written back.
[[maybe_unused]] static vx_status vx_as_map(vx_handle task, vx_handle vmo, uint64_t offset, uint64_t size,
                                            uint32_t flags, uint64_t *addr) {
  return (vx_status)vx_syscall(VX_SYS_as_map, task, vmo, offset, size, flags, (uint64_t)addr);
}

[[maybe_unused]] static vx_status vx_vmo_rw(vx_handle vmo, enum vx_vmo_op op, uint64_t offset, void *buf,
                                            uint64_t size) {
  return (vx_status)vx_syscall(VX_SYS_vmo_rw, vmo, op, offset, (uint64_t)buf, size, 0);
}

[[maybe_unused]] static vx_status vx_handle_dup(vx_handle h, uint32_t rights, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_handle_dup, h, rights, (uint64_t)out, 0, 0, 0);
}

// --- Channels ---

[[maybe_unused]] static vx_status vx_channel_create(uint32_t options, vx_handle out[2]) {
  out[0] = out[1] = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_channel_create, options, (uint64_t)out, 0, 0, 0, 0);
}

// The message starts with a vx_msg_header. The handles leave the caller's
// table whether or not the write succeeds.
[[maybe_unused]] static vx_status vx_channel_write(vx_handle ch, const void *bytes, uint32_t len,
                                                   const vx_handle *handles, uint32_t count) {
  return (vx_status)vx_syscall(VX_SYS_channel_write, ch, (uint64_t)bytes, len, (uint64_t)handles, count, 0);
}

// SHOULD_WAIT when nothing is queued; TOO_SMALL, with the sizes in *actual, when
// the next message does not fit.
[[maybe_unused]] static vx_status vx_channel_read(vx_handle ch, void *bytes, uint32_t cap, vx_handle *handles,
                                                  uint32_t count_cap, vx_msg_size *actual) {
  *actual = (vx_msg_size){};
  return (vx_status)vx_syscall(VX_SYS_channel_read, ch, (uint64_t)bytes, cap, (uint64_t)handles, count_cap,
                               (uint64_t)actual);
}

[[maybe_unused]] static vx_status vx_channel_call(vx_handle ch, vx_call *args, vx_instant deadline) {
  args->actual = (vx_msg_size){};
  return (vx_status)vx_syscall(VX_SYS_channel_call, ch, (uint64_t)args, (uint64_t)deadline, 0, 0, 0);
}

// --- Rings ---

[[maybe_unused]] static vx_status vx_ring_create(const vx_ring_params *params, vx_ring_handles *out) {
  *out = (vx_ring_handles){};
  return (vx_status)vx_syscall(VX_SYS_ring_create, (uint64_t)params, (uint64_t)out, 0, 0, 0, 0);
}

// Rings the peer's doorbell: call it when vx_ring_produce says the peer sleeps.
[[maybe_unused]] static vx_status vx_ring_notify(vx_handle end) {
  return (vx_status)vx_syscall(VX_SYS_ring_notify, end, 0, 0, 0, 0, 0);
}

// Puts handles in a slot for the peer, returning the slot to name in an entry.
[[maybe_unused]] static int64_t vx_ring_put_handles(vx_handle end, const vx_handle *handles, uint32_t count) {
  return vx_syscall(VX_SYS_ring_xfer_handles, end, VX_RING_PUT, (uint64_t)handles, count, 0, 0);
}

// Takes the handles in the peer's slot, returning how many.
[[maybe_unused]] static int64_t vx_ring_take_handles(vx_handle end, uint32_t slot, vx_handle *handles,
                                                     uint32_t capacity) {
  return vx_syscall(VX_SYS_ring_xfer_handles, end, VX_RING_TAKE, (uint64_t)handles, capacity, slot, 0);
}

// --- Counters, bindings, futexes ---

[[maybe_unused]] static vx_status vx_counter_create(uint64_t initial, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_counter_create, initial, (uint64_t)out, 0, 0, 0, 0);
}

[[maybe_unused]] static vx_status vx_counter_signal(vx_handle c, uint64_t value) {
  return (vx_status)vx_syscall(VX_SYS_counter_signal, c, value, 0, 0, 0, 0);
}

[[maybe_unused]] static int64_t vx_counter_read(vx_handle c) {
  return vx_syscall(VX_SYS_counter_read, c, 0, 0, 0, 0, 0);
}

// A one-shot binding: the port gets one packet with `key` when the source's
// trigger holds (at once, if it already does).
[[maybe_unused]] static vx_status vx_port_bind(vx_handle port, vx_handle source, enum vx_trigger trigger,
                                               uint64_t key, uint64_t threshold) {
  return (vx_status)vx_syscall(VX_SYS_port_bind, port, source, trigger, key, threshold, 0);
}

[[maybe_unused]] static vx_status vx_futex_wait(const _Atomic uint32_t *word, uint32_t expected,
                                                vx_instant deadline) {
  return (vx_status)vx_syscall(VX_SYS_futex_wait, (uint64_t)word, expected, (uint64_t)deadline, 0, 0, 0);
}

[[maybe_unused]] static int64_t vx_futex_wake(const _Atomic uint32_t *word, uint32_t count) {
  return vx_syscall(VX_SYS_futex_wake, (uint64_t)word, count, 0, 0, 0, 0);
}

// --- Tasks and threads ---

[[maybe_unused]] static vx_status vx_task_create(vx_str name, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_task_create, (uint64_t)name.ptr, name.len, (uint64_t)out, 0, 0, 0);
}

[[maybe_unused]] static vx_status vx_thread_create(vx_handle task, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_thread_create, task, (uint64_t)out, 0, 0, 0, 0);
}

// Starts a thread at entry on stack sp. `handle`, unless 0, moves to the
// thread's task and arrives as the first argument; arg2 is the second.
[[maybe_unused]] static vx_status vx_thread_start(vx_handle thread, uint64_t entry, uint64_t sp,
                                                  vx_handle handle, uint64_t arg2) {
  return (vx_status)vx_syscall(VX_SYS_thread_start, thread, entry, sp, handle, arg2, 0);
}

[[maybe_unused]] [[noreturn]] static void vx_thread_exit(int64_t status) {
  vx_syscall(VX_SYS_thread_exit, (uint64_t)status, 0, 0, 0, 0, 0);
  __builtin_unreachable();
}

[[maybe_unused]] static vx_status vx_task_kill(vx_handle task, int64_t status) {
  return (vx_status)vx_syscall(VX_SYS_task_kill, task, (uint64_t)status, 0, 0, 0, 0);
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

// Called by _start with the handle the kernel passes. The thread ends with
// vx_main's return value as its exit status.
[[noreturn]] void vx_start(vx_handle self_task) { vx_thread_exit(vx_main(self_task)); }

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
