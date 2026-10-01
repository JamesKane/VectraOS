// vx-rt base: syscall stubs, output, the stack protector and the spawn
// message; what the rest of vx-rt and the libraries under it (the 9P ring
// client) need. Programs include rt.c, which includes this.

#pragma once

#include "rt.h"
#include "../vx-mem/mem.c"
#include "../vx-ndb/ndb.c"

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

// The task `id` in task's tree, or with VX_TASK_NEXT the next one after it (abi.h).
[[maybe_unused]] static vx_status vx_task_info_of(vx_handle task, uint64_t id, uint32_t flags,
                                                  vx_task_summary *out) {
  *out = (vx_task_summary){};
  return (vx_status)vx_syscall(VX_SYS_task_info, task, (uint64_t)out, id, flags, 0, 0);
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

[[maybe_unused]] static vx_status vx_vmo_clone(vx_handle vmo, uint64_t offset, uint64_t size,
                                               vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_vmo_clone, vmo, offset, size, 0, (uint64_t)out, 0);
}

[[maybe_unused]] static vx_status vx_exception_bind(vx_handle task, vx_handle port, uint64_t key,
                                                    uint32_t options) {
  return (vx_status)vx_syscall(VX_SYS_exception_bind, task, port, key, options, 0, 0);
}

[[maybe_unused]] static vx_status vx_exception_resume(vx_handle task, uint64_t thread, uint32_t action,
                                                      const vx_regs *regs) {
  return (vx_status)vx_syscall(VX_SYS_exception_resume, task, thread, action, (uint64_t)regs, 0, 0);
}

[[maybe_unused]] static vx_status vx_thread_state(vx_handle task, uint64_t thread, uint32_t op, void *buf,
                                                  uint64_t size) {
  return (vx_status)vx_syscall(VX_SYS_thread_state, task, thread, op, (uint64_t)buf, size, 0);
}

[[maybe_unused]] static vx_status vx_thread_suspend(vx_handle task, uint64_t thread) {
  return (vx_status)vx_syscall(VX_SYS_thread_suspend, task, thread, 0, 0, 0, 0);
}

[[maybe_unused]] static vx_status vx_thread_resume(vx_handle task, uint64_t thread) {
  return (vx_status)vx_syscall(VX_SYS_thread_resume, task, thread, 0, 0, 0, 0);
}

[[maybe_unused]] static vx_status vx_task_mem_rw(vx_handle task, vx_mem_op *ops, uint32_t count) {
  return (vx_status)vx_syscall(VX_SYS_task_mem_rw, task, (uint64_t)ops, count, 0, 0, 0);
}

[[maybe_unused]] static vx_status vx_thread_interrupt(vx_handle task, uint64_t thread, uint64_t value) {
  return (vx_status)vx_syscall(VX_SYS_thread_interrupt, task, thread, value, 0, 0, 0);
}

[[maybe_unused]] static vx_status vx_as_unmap(vx_handle task, uint64_t addr, uint64_t size) {
  return (vx_status)vx_syscall(VX_SYS_as_unmap, task, addr, size, 0, 0, 0);
}

[[maybe_unused]] static vx_status vx_vmo_rw(vx_handle vmo, enum vx_vmo_op op, uint64_t offset, void *buf,
                                            uint64_t size) {
  return (vx_status)vx_syscall(VX_SYS_vmo_rw, vmo, op, offset, (uint64_t)buf, size, 0);
}

[[maybe_unused]] static vx_status vx_handle_dup(vx_handle h, uint32_t rights, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_handle_dup, h, rights, (uint64_t)out, 0, 0, 0);
}

// --- Devices (abi.h, 01 §7.1) ---

[[maybe_unused]] static vx_status vx_vmo_create_physical(vx_handle resource, uint64_t pa, uint64_t size,
                                                         vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_vmo_create, size, VX_VMO_PHYSICAL, (uint64_t)out, resource, pa, 0);
}

[[maybe_unused]] static vx_status vx_irq_create(vx_handle resource, uint32_t line, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_irq_create, resource, line, 0, (uint64_t)out, 0, 0);
}

[[maybe_unused]] static vx_status vx_irq_ack(vx_handle irq) {
  return (vx_status)vx_syscall(VX_SYS_irq_ack, irq, 0, 0, 0, 0, 0);
}

// An MSI for the PCI function `source` (its requester ID), and what the device
// must write where to raise it.
[[maybe_unused]] static vx_status vx_irq_create_msi(vx_handle resource, uint32_t source, vx_handle *out,
                                                    vx_msi *msi) {
  *out = VX_HANDLE_NONE;
  *msi = (vx_msi){};
  return (vx_status)vx_syscall(VX_SYS_irq_create, resource, source, VX_IRQ_MSI, (uint64_t)out, (uint64_t)msi,
                               0);
}

[[maybe_unused]] static vx_status vx_dma_domain_create(vx_handle resource, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_dma_domain_create, resource, 0, (uint64_t)out, 0, 0, 0);
}

// The device address of each page of [offset, offset + size), into addresses[size / 4096].
[[maybe_unused]] static vx_status vx_dma_map(vx_handle domain, vx_handle vmo, uint64_t offset, uint64_t size,
                                             uint64_t *addresses) {
  return (vx_status)vx_syscall(VX_SYS_dma_map, domain, vmo, offset, size, (uint64_t)addresses, 0);
}

[[maybe_unused]] static vx_status vx_dma_unmap(vx_handle domain, vx_handle vmo) {
  return (vx_status)vx_syscall(VX_SYS_dma_unmap, domain, vmo, 0, 0, 0, 0);
}

[[maybe_unused]] static vx_status vx_iorange_create(vx_handle resource, uint16_t base, uint32_t count,
                                                    vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_iorange_create, resource, base, count, (uint64_t)out, 0, 0);
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

// The same, and the thread's id in its task (exceptions and thread_interrupt name it so).
[[maybe_unused]] static vx_status vx_thread_create_id(vx_handle task, vx_handle *out, uint32_t *id) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_thread_create, task, (uint64_t)out, (uint64_t)id, 0, 0, 0);
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

// Kills the task `id` in task's tree (abi.h).
[[maybe_unused]] static vx_status vx_task_kill_id(vx_handle task, uint64_t id, int64_t status) {
  return (vx_status)vx_syscall(VX_SYS_task_kill, task, (uint64_t)status, id, 0, 0, 0);
}

[[maybe_unused]] static vx_status vx_handle_close(vx_handle h) {
  return (vx_status)vx_syscall(VX_SYS_handle_close, h, 0, 0, 0, 0, 0);
}

// --- Console output ---
//
// To the console driver once vx_start has connected to it (the spawn
// message's "console"), and to the kernel log before that or without one.

static void (*vx_print_hook)(vx_str s);

[[maybe_unused]] static void vx_print(vx_str s) {
  if (vx_print_hook)
    vx_print_hook(s);
  else
    vx_debug_write(s);
}

// A NUL-terminated string as a vx_str.
[[maybe_unused]] static vx_str vx_cstr(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  return (vx_str){s, n};
}

[[maybe_unused]] static void vx_print_u64(uint64_t v) {
  char buf[20];
  size_t i = sizeof buf;
  do {
    buf[--i] = (char)('0' + v % 10);
    v /= 10;
  } while (v);
  vx_print((vx_str){buf + i, sizeof buf - i});
}

// A duration in nanoseconds, as milliseconds with three decimals.
[[maybe_unused]] static void vx_print_millis(uint64_t ns) {
  uint64_t us = ns / 1000;
  char frac[4] = {'.', (char)('0' + us % 1000 / 100), (char)('0' + us % 100 / 10), (char)('0' + us % 10)};
  vx_print_u64(us / 1000);
  vx_print((vx_str){frac, 4});
}

// --- Start-up ---

uintptr_t __stack_chk_guard = 0x2e0f5b3c9d81a647; // to come from the kernel's entropy (M2)

// A smashed stack ends the task: the trap is reported by the kernel.
[[noreturn]] void __stack_chk_fail(void) { __builtin_trap(); }

// --- The spawn message (abi.h) ---

static constexpr uint32_t VX_SPAWN_MAX_ARGS = 64; // gsh's longest command line has fewer

typedef struct vx_spawn_info {
  vx_str name;    // spawn=
  vx_str text;    // all the records, for vx-ns and the program to read again
  vx_str cmdline; // the root task's
  vx_str args[VX_SPAWN_MAX_ARGS];
  uint32_t argc;
  vx_str handle_names[VX_CHANNEL_MAX_HANDLES];
  vx_handle handles[VX_CHANNEL_MAX_HANDLES]; // VX_HANDLE_NONE once taken
  uint32_t handle_count;
} vx_spawn_info;

static vx_spawn_info vx_spawn;
static vx_handle vx_self; // the task's handle to itself, or VX_HANDLE_NONE

static uint8_t vx_spawn_msg[VX_CHANNEL_MAX_BYTES];
static char vx_spawn_scratch[VX_CHANNEL_MAX_BYTES]; // decoded values, which never grow

// Takes the handle the spawn message calls `name`: it is the caller's from
// here on, and a second take finds nothing. VX_HANDLE_NONE if there is none.
[[maybe_unused]] static vx_handle vx_spawn_take(const char *name) {
  size_t len = 0;
  while (name[len]) len++;
  for (uint32_t i = 0; i < vx_spawn.handle_count; i++) {
    vx_str n = vx_spawn.handle_names[i];
    if (n.len != len || memcmp(n.ptr, name, len) != 0 || !vx_spawn.handles[i]) continue;
    vx_handle h = vx_spawn.handles[i];
    vx_spawn.handles[i] = VX_HANDLE_NONE;
    return h;
  }
  return VX_HANDLE_NONE;
}

// Finds the first record of the spawn message that has `key`. Its values stay
// valid until the next call.
[[maybe_unused]] static bool vx_spawn_record(const char *key, vx_ndb_record *out) {
  static char scratch[VX_CHANNEL_MAX_BYTES];
  vx_ndb_reader r = {.src = vx_spawn.text, .scratch = scratch, .scratch_cap = sizeof scratch};
  while (vx_ndb_next(&r, out) == VX_NDB_RECORD)
    if (vx_ndb_has(out, key)) return true;
  return false;
}

// Reads the spawn message. A malformed one is reported and ignored: the
// program starts with nothing, and its handles are closed.
static void vx_read_spawn(vx_handle bootstrap) {
  vx_handle got[VX_CHANNEL_MAX_HANDLES];
  vx_msg_size size;
  vx_status st =
      vx_channel_read(bootstrap, vx_spawn_msg, sizeof vx_spawn_msg, got, VX_CHANNEL_MAX_HANDLES, &size);
  vx_handle_close(bootstrap);
  if (st != VX_OK) return;
  const vx_msg_header *h = (const vx_msg_header *)vx_spawn_msg;
  vx_ndb_reader r = {.src = {(const char *)vx_spawn_msg + sizeof *h, size.bytes - sizeof *h},
                     .scratch = vx_spawn_scratch,
                     .scratch_cap = sizeof vx_spawn_scratch};
  bool ok = size.bytes >= sizeof *h && h->ordinal == VX_SPAWN;
  bool named[VX_CHANNEL_MAX_HANDLES] = {};
  vx_ndb_record rec;
  vx_ndb_result res;
  while (ok && (res = vx_ndb_next(&r, &rec)) == VX_NDB_RECORD) {
    uint64_t index;
    if (vx_ndb_has(&rec, "spawn")) {
      vx_spawn.name = vx_ndb_get(&rec, "spawn");
    } else if (vx_ndb_has(&rec, "cmdline")) {
      vx_spawn.cmdline = vx_ndb_get(&rec, "cmdline");
    } else if (vx_ndb_has(&rec, "arg")) {
      if (vx_spawn.argc < VX_SPAWN_MAX_ARGS) vx_spawn.args[vx_spawn.argc++] = vx_ndb_get(&rec, "arg");
    } else if (vx_ndb_has(&rec, "handle") && !vx_ndb_has(&rec, "mount")) {
      ok = vx_ndb_get_u64(&rec, "index", &index) && index < size.handles && !named[index];
      if (ok) named[index] = true, vx_spawn.handle_names[index] = vx_ndb_get(&rec, "handle");
    }
  }
  if (!ok || res == VX_NDB_ERROR) {
    vx_print(VX_STR("vx-rt: malformed spawn message\n"));
    for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(got[i]);
    vx_spawn = (vx_spawn_info){};
    return;
  }
  vx_spawn.text = r.src;
  vx_spawn.handle_count = size.handles;
  for (uint32_t i = 0; i < size.handles; i++) vx_spawn.handles[i] = got[i];
  vx_self = vx_spawn_take("self");
}
