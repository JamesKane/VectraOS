// vx-rt base: syscall stubs, output and the spawn message; what the rest of
// vx-rt and the libraries under it (the 9P ring client) need. It defines no
// external symbol, so a C library can include it too (ports/musl/vx): the
// start-up, the stack protector and memcpy and the rest are rt.c's.
// Programs include rt.c, which includes this.

#pragma once

#include <stdatomic.h> // vx_lock_t, threads (freestanding: clang's own)

#include "../../abi/vx/abi.h"
// libvx's public declarations (ADR-0004). The system's own code compiles
// libvx in, so they are static there (VX_UNITY), and every definition here
// is checked against what a native program sees; libvx.so and libvx.a are
// built with VX_RT_LIBC, which exports them.
#ifndef VX_RT_LIBC
#ifndef VX_UNITY
#define VX_UNITY
#endif
#endif
#include "../../abi/vx.h"
#include "../vx-mem/mem.h"
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

VX_API vx_instant vx_clock_read(void) { return vx_syscall(VX_SYS_clock_read, 0, 0, 0, 0, 0, 0); }

// The cycle counter the clock is made from (/sys/clock/info).
VX_API vx_status vx_clock_info_read(vx_clock_info *info) {
  int64_t r = vx_syscall(VX_SYS_clock_read, (uint64_t)info, 0, 0, 0, 0, 0);
  return r < 0 ? (vx_status)r : VX_OK;
}

// UTC, in ns since 1970: the monotonic clock until there is a wall clock.
VX_API int64_t vx_wallclock(void) {
  vx_clock_info info = {};
  int64_t now = vx_syscall(VX_SYS_clock_read, (uint64_t)&info, 0, 0, 0, 0, 0);
  return now < 0 ? (int64_t)vx_clock_read() : now + info.utc_offset;
}

// The wall clock set to utc (ns since 1970), with the root Resource.
[[maybe_unused]] static vx_status vx_clock_set(vx_handle resource, int64_t utc) {
  return (vx_status)vx_syscall(VX_SYS_clock_set, resource, (uint64_t)utc, 0, 0, 0, 0);
}

// The cycle counter, read in user mode: no syscall (05 §9).
[[maybe_unused]] static inline uint64_t vx_cycles(void) {
#ifdef __x86_64__
  uint32_t lo, hi;
  __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
  return (uint64_t)hi << 32 | lo;
#else
  uint64_t v;
  __asm__ volatile("isb\n\tmrs %0, cntvct_el0" : "=r"(v));
  return v;
#endif
}

VX_API vx_status vx_task_info(vx_handle task, vx_task_summary *out) {
  *out = (vx_task_summary){};
  return (vx_status)vx_syscall(VX_SYS_task_info, task, (uint64_t)out, 0, 0, 0, 0);
}

// The task `id` in task's tree, or with VX_TASK_NEXT the next one after it (abi.h).
[[maybe_unused]] static vx_status vx_task_info_of(vx_handle task, uint64_t id, uint32_t flags,
                                                  vx_task_summary *out) {
  *out = (vx_task_summary){};
  return (vx_status)vx_syscall(VX_SYS_task_info, task, (uint64_t)out, id, flags, 0, 0);
}

VX_API vx_status vx_port_create(uint32_t options, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_port_create, options, (uint64_t)out, 0, 0, 0, 0);
}

// Returns how many packets it stored (at least 1), or a negative vx_status:
// VX_ERR_TIMED_OUT when the deadline passed with none.
VX_API int64_t vx_port_wait(vx_handle port, vx_instant deadline, vx_duration leeway, vx_packet *out,
                            size_t out_len) {
  return vx_syscall(VX_SYS_port_wait, port, (uint64_t)deadline, (uint64_t)leeway, (uint64_t)out, out_len, 0);
}

VX_API vx_status vx_port_post(vx_handle port, const vx_packet *packet) {
  return (vx_status)vx_syscall(VX_SYS_port_post, port, (uint64_t)packet, 0, 0, 0, 0);
}

VX_API vx_status vx_vmo_create(uint64_t size, uint32_t options, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_vmo_create, size, options, (uint64_t)out, 0, 0, 0);
}

// Maps [offset, offset + size) of a VMO into a task. *addr == 0 lets the
// kernel choose; the address used is written back.
VX_API vx_status vx_as_map(vx_handle task, vx_handle vmo, uint64_t offset, uint64_t size, uint32_t flags,
                           uint64_t *addr) {
  return (vx_status)vx_syscall(VX_SYS_as_map, task, vmo, offset, size, flags, (uint64_t)addr);
}

VX_API vx_status vx_vmo_clone(vx_handle vmo, uint64_t offset, uint64_t size, vx_handle *out) {
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

VX_API vx_status vx_thread_state(vx_handle task, uint64_t thread, uint32_t op, void *buf, uint64_t size) {
  return (vx_status)vx_syscall(VX_SYS_thread_state, task, thread, op, (uint64_t)buf, size, 0);
}

// What the kernel saves of FP/SIMD state and lets user code use (ADR-0035):
// asked once, then kept. Code choosing a path by the CPU (6c3) reads it.
[[maybe_unused]] static const vx_cpu_info *vx_cpu(void) {
  static vx_cpu_info info;
  static bool known;
  if (!known && vx_thread_state(VX_HANDLE_NONE, 0, VX_STATE_GET_CPU, &info, sizeof info) == VX_OK)
    known = true;
  return &info;
}

// The number of CPUs this process may run threads on (ADR-0045, os-requirements
// R12): every CPU no scheduling context reserves, and its own context's.
// Asked each time, as reservations come and go; 1 if the kernel does not say.
VX_API uint32_t vx_cpu_count(void) {
  vx_cpu_info info = {};
  if (vx_thread_state(VX_HANDLE_NONE, 0, VX_STATE_GET_CPU, &info, sizeof info) != VX_OK || !info.cpus_usable)
    return 1;
  return info.cpus_usable;
}

// --- Time (09 §5.6, os-requirements R13) ---

// The monotonic clock, in ns since boot. The system never suspends, so it is
// both the continuous and the suspending clock.
VX_API vx_instant vx_now(void) { return vx_clock_read(); }

// The clock's resolution in ns: one tick of the counter it is made from,
// rounded up; 1 for a counter at 1 GHz or faster.
VX_API vx_duration vx_clock_resolution(void) {
  vx_clock_info info = {};
  if (vx_clock_info_read(&info) != VX_OK || !info.counter_hz) return 1;
  uint64_t ns = (1'000'000'000 + info.counter_hz - 1) / info.counter_hz;
  return (vx_duration)(ns ? ns : 1);
}

// The calling thread's protection-key rights (ADR-0035), its own register,
// set with the unprivileged instruction (x86's WRPKRU): no syscall. A key
// with VX_KEY_READ may be read, with VX_KEY_WRITE written too (PKU has no
// write-only key: WRITE alone is read and write); with neither, not touched.
VX_API uint64_t vx_rights_get(void) {
#ifdef __x86_64__
  if (!vx_cpu()->keys) return 0;
  uint32_t pkru, edx;
  __asm__ volatile("rdpkru" : "=a"(pkru), "=d"(edx) : "c"(0));
  return pkru;
#else
  return 0;
#endif
}

VX_API void vx_rights_set(uint64_t rights) {
#ifdef __x86_64__
  if (vx_cpu()->keys) __asm__ volatile("wrpkru" : : "a"((uint32_t)rights), "c"(0), "d"(0) : "memory");
#else
  (void)rights;
#endif
}

VX_API vx_status vx_keys_set(uint32_t key, uint32_t rights) {
  if (!vx_cpu()->keys) return VX_ERR_UNSUPPORTED;
  if (key > vx_cpu()->keys || rights & ~(uint32_t)(VX_KEY_READ | VX_KEY_WRITE)) return VX_ERR_INVALID;
  uint64_t r = vx_rights_get() & ~(3ull << (2 * key));
  if (!(rights & VX_KEY_WRITE)) r |= 2ull << (2 * key); // WD: no writes
  if (!rights) r |= 1ull << (2 * key);                  // AD: no access at all
  vx_rights_set(r);
  return VX_OK;
}

// The calling thread's rights to key: VX_KEY_READ and VX_KEY_WRITE as it has them.
VX_API uint32_t vx_keys_get(uint32_t key) {
  if (!vx_cpu()->keys || key > vx_cpu()->keys) return VX_KEY_READ | VX_KEY_WRITE;
  uint64_t r = vx_rights_get() >> (2 * key) & 3;
  if (r & 1) return 0;
  return r & 2 ? VX_KEY_READ : VX_KEY_READ | VX_KEY_WRITE;
}

VX_API vx_status vx_as_protect(vx_handle task, uint64_t address, uint64_t size, uint32_t flags) {
  return (vx_status)vx_syscall(VX_SYS_as_protect, task, address, size, flags, 0, 0);
}

// as_reserve (ADR-0042): *address in and out.
VX_API vx_status vx_as_reserve(vx_handle task, uint64_t size, uint64_t align, uint32_t flags,
                               uint64_t *address) {
  return (vx_status)vx_syscall(VX_SYS_as_reserve, task, size, align, flags, (uint64_t)address, 0);
}

VX_API vx_status vx_as_key_alloc(vx_handle task, uint32_t *key) {
  return (vx_status)vx_syscall(VX_SYS_as_key_alloc, task, (uint64_t)key, 0, 0, 0, 0);
}

VX_API vx_status vx_as_key_free(vx_handle task, uint32_t key) {
  return (vx_status)vx_syscall(VX_SYS_as_key_free, task, key, 0, 0, 0, 0);
}

VX_API bool vx_cpu_has(vx_cpu_feature f) {
  const vx_cpu_info *c = vx_cpu();
#ifdef __x86_64__
  uint32_t a = 7, b, cx = 0, d;
  __asm__ volatile("cpuid" : "+a"(a), "=b"(b), "+c"(cx), "=d"(d));
  switch (f) {
  case VX_CPU_AVX512: {
    uint32_t need = 1u << 16 | 1u << 17 | 1u << 30 | 1u << 31;
    return (b & need) == need && (c->xfeatures & 0xe6) == 0xe6;
  }
  case VX_CPU_VAES: return cx >> 9 & 1;
  case VX_CPU_VPCLMULQDQ: return cx >> 10 & 1;
  case VX_CPU_GFNI: return cx >> 8 & 1;
  case VX_CPU_SHA: return b >> 29 & 1;
  }
#else
  uint64_t isar0 = c->isar0;
  switch (f) {
  case VX_CPU_AES: return (isar0 >> 4 & 0xf) >= 1;
  case VX_CPU_PMULL: return (isar0 >> 4 & 0xf) >= 2;
  case VX_CPU_SHA2: return (isar0 >> 12 & 0xf) >= 1;
  case VX_CPU_SHA512: return (isar0 >> 12 & 0xf) >= 2;
  case VX_CPU_SHA3: return (isar0 >> 32 & 0xf) >= 1;
  case VX_CPU_CRC32: return (isar0 >> 16 & 0xf) >= 1;
  case VX_CPU_DOTPROD: return (isar0 >> 44 & 0xf) >= 1;
  case VX_CPU_SVE: return (c->pfr0 >> 32 & 0xf) >= 1; // zeroed by the kernel until it saves SVE's state
  }
#endif
  return false;
}

VX_API vx_status vx_thread_suspend(vx_handle task, uint64_t thread) {
  return (vx_status)vx_syscall(VX_SYS_thread_suspend, task, thread, 0, 0, 0, 0);
}

VX_API vx_status vx_thread_resume(vx_handle task, uint64_t thread) {
  return (vx_status)vx_syscall(VX_SYS_thread_resume, task, thread, 0, 0, 0, 0);
}

// The first of the task's mappings that ends after address (INSPECT).
VX_API vx_status vx_as_query(vx_handle task, uint64_t address, vx_map_info *info) {
  return (vx_status)vx_syscall(VX_SYS_as_query, task, address, (uint64_t)info, 0, 0, 0);
}

[[maybe_unused]] static vx_status vx_task_mem_rw(vx_handle task, vx_mem_op *ops, uint32_t count) {
  return (vx_status)vx_syscall(VX_SYS_task_mem_rw, task, (uint64_t)ops, count, 0, 0, 0);
}

// Posts a note to a thread of the task, or with thread 0 to any (ADR-0010).
VX_API vx_status vx_thread_interrupt(vx_handle task, uint64_t thread, vx_str note) {
  return (vx_status)vx_syscall(VX_SYS_thread_interrupt, task, thread, (uint64_t)note.ptr, note.len, 0, 0);
}

VX_API vx_status vx_as_unmap(vx_handle task, uint64_t addr, uint64_t size) {
  return (vx_status)vx_syscall(VX_SYS_as_unmap, task, addr, size, 0, 0, 0);
}

VX_API vx_status vx_vmo_rw(vx_handle vmo, enum vx_vmo_op op, uint64_t offset, void *buf, uint64_t size) {
  return (vx_status)vx_syscall(VX_SYS_vmo_rw, vmo, op, offset, (uint64_t)buf, size, 0);
}

VX_API vx_status vx_handle_dup(vx_handle h, uint32_t rights, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_handle_dup, h, rights, (uint64_t)out, 0, 0, 0);
}

// --- Devices (abi.h, 01 §7.1) ---

[[maybe_unused]] static vx_status vx_vmo_create_physical(vx_handle resource, uint64_t pa, uint64_t size,
                                                         vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_vmo_create, size, VX_VMO_PHYSICAL, (uint64_t)out, resource, pa, 0);
}

// Pagers (abi.h, docs/11 §8): resource needs VX_RIGHT_PAGER, or is the root one.
[[maybe_unused]] static vx_status vx_pager_create(vx_handle resource, vx_handle port, uint64_t key,
                                                  vx_duration deadline, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_pager_create, resource, port, key, (uint64_t)deadline, (uint64_t)out,
                               0);
}

[[maybe_unused]] static vx_status vx_vmo_create_pager(vx_handle pager, uint32_t key, uint64_t size,
                                                      vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_vmo_create, size, VX_VMO_PAGER, (uint64_t)out, pager, key, 0);
}

[[maybe_unused]] static vx_status vx_pager_supply(vx_handle pager, vx_handle vmo, uint64_t offset,
                                                  uint64_t size, vx_handle source, uint64_t source_offset) {
  return (vx_status)vx_syscall(VX_SYS_pager_supply, pager, vmo, offset, size, source, source_offset);
}

// VX_PAGER_DIRTY: how many ranges, or a negative status; CLEAN and EVICT: a status.
[[maybe_unused]] static int64_t vx_pager_op(vx_handle pager, vx_handle vmo, uint32_t op, uint64_t offset,
                                            uint64_t size, vx_pager_range *ranges) {
  return vx_syscall(VX_SYS_pager_op, pager, vmo, op, offset, size, (uint64_t)ranges);
}

// vmo_seal, vmo_lease and vmo_revoke (ADR-0043).
VX_API vx_status vx_vmo_seal(vx_handle vmo) {
  return (vx_status)vx_syscall(VX_SYS_vmo_seal, vmo, 0, 0, 0, 0, 0);
}

VX_API vx_status vx_vmo_lease(vx_handle vmo, vx_handle *lease) {
  return (vx_status)vx_syscall(VX_SYS_vmo_lease, vmo, (uint64_t)lease, 0, 0, 0, 0);
}

VX_API vx_status vx_vmo_revoke(vx_handle lease) {
  return (vx_status)vx_syscall(VX_SYS_vmo_revoke, lease, 0, 0, 0, 0, 0);
}

VX_API vx_status vx_vmo_resize(vx_handle vmo, uint64_t size) {
  return (vx_status)vx_syscall(VX_SYS_vmo_op, vmo, VX_VMO_RESIZE, size, 0, 0, 0);
}

// A lazy VMO's pages in [offset, offset + size) freed (ADR-0046): a touch
// reads zeros again.
VX_API vx_status vx_vmo_decommit(vx_handle vmo, uint64_t offset, uint64_t size) {
  return (vx_status)vx_syscall(VX_SYS_vmo_op, vmo, VX_VMO_DECOMMIT, offset, size, 0, 0);
}

// A pager's own VMO's new size (pager_op RESIZE).
[[maybe_unused]] static vx_status vx_pager_resize(vx_handle pager, vx_handle vmo, uint64_t size) {
  return (vx_status)vx_syscall(VX_SYS_pager_op, pager, vmo, VX_PAGER_RESIZE, 0, size, 0);
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

// A DmaDomain for the PCI function whose requester ID is source (devmgr's).
[[maybe_unused]] static vx_status vx_dma_domain_create(vx_handle resource, uint32_t source, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_dma_domain_create, resource, source, 0, (uint64_t)out, 0, 0);
}

// The device address of each page of [offset, offset + size), into
// addresses[size / 4096], and the mapping, in *mapping: options say what
// the device may do (VX_DMA_READ, VX_DMA_WRITE). Let go by vx_dma_unmap.
[[maybe_unused]] static vx_status vx_dma_map(vx_handle domain, vx_handle vmo, uint64_t offset, uint64_t size,
                                             uint32_t options, uint64_t *addresses, vx_handle *mapping) {
  vx_dma_mapped m = {.addresses = addresses};
  vx_status st = (vx_status)vx_syscall(VX_SYS_dma_map, domain, vmo, offset, size, options, (uint64_t)&m);
  *mapping = st == VX_OK ? m.mapping : VX_HANDLE_NONE;
  return st;
}

// The device is done with the mapping: unmapped, and its handle closed.
[[maybe_unused]] static vx_status vx_dma_unmap(vx_handle mapping) {
  vx_status st = (vx_status)vx_syscall(VX_SYS_dma_unmap, mapping, 0, 0, 0, 0, 0);
  vx_syscall(VX_SYS_handle_close, mapping, 0, 0, 0, 0, 0);
  return st;
}

// The machine off (VX_POWER_OFF), with the root Resource: returns only if it did not happen.
[[maybe_unused]] static vx_status vx_system_power(vx_handle resource, uint32_t op) {
  return (vx_status)vx_syscall(VX_SYS_system_power, resource, op, 0, 0, 0, 0);
}

[[maybe_unused]] static int64_t vx_dma_domain_op(vx_handle domain, uint32_t op) {
  return vx_syscall(VX_SYS_dma_domain_op, domain, op, 0, 0, 0, 0);
}

[[maybe_unused]] static vx_status vx_iorange_create(vx_handle resource, uint16_t base, uint32_t count,
                                                    vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_iorange_create, resource, base, count, (uint64_t)out, 0, 0);
}

// --- Channels ---

VX_API vx_status vx_channel_create(uint32_t options, vx_handle out[2]) {
  out[0] = out[1] = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_channel_create, options, (uint64_t)out, 0, 0, 0, 0);
}

// The message starts with a vx_msg_header. The handles leave the caller's
// table whether or not the write succeeds.
VX_API vx_status vx_channel_write(vx_handle ch, const void *bytes, uint32_t len, const vx_handle *handles,
                                  uint32_t count) {
  return (vx_status)vx_syscall(VX_SYS_channel_write, ch, (uint64_t)bytes, len, (uint64_t)handles, count, 0);
}

// SHOULD_WAIT when nothing is queued; TOO_SMALL, with the sizes in *actual, when
// the next message does not fit.
VX_API vx_status vx_channel_read(vx_handle ch, void *bytes, uint32_t cap, vx_handle *handles,
                                 uint32_t count_cap, vx_msg_size *actual) {
  *actual = (vx_msg_size){};
  return (vx_status)vx_syscall(VX_SYS_channel_read, ch, (uint64_t)bytes, cap, (uint64_t)handles, count_cap,
                               (uint64_t)actual);
}

VX_API vx_status vx_channel_call(vx_handle ch, vx_call *args, vx_instant deadline) {
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

VX_API vx_status vx_counter_create(uint64_t initial, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_counter_create, initial, (uint64_t)out, 0, 0, 0, 0);
}

VX_API vx_status vx_counter_signal(vx_handle c, uint64_t value) {
  return (vx_status)vx_syscall(VX_SYS_counter_signal, c, value, 0, 0, 0, 0);
}

VX_API int64_t vx_counter_read(vx_handle c) { return vx_syscall(VX_SYS_counter_read, c, 0, 0, 0, 0, 0); }

// A one-shot binding: the port gets one packet with `key` when the source's
// trigger holds (at once, if it already does).
VX_API vx_status vx_port_bind(vx_handle port, vx_handle source, enum vx_trigger trigger, uint64_t key,
                              uint64_t threshold) {
  return (vx_status)vx_syscall(VX_SYS_port_bind, port, source, trigger, key, threshold, 0);
}

VX_API vx_status vx_futex_wait(const _Atomic uint32_t *word, uint32_t expected, vx_instant deadline) {
  return (vx_status)vx_syscall(VX_SYS_futex_wait, (uint64_t)word, expected, (uint64_t)deadline, 0, 0, 0);
}

// The calling thread's robust list (ADR-0037); head nullptr unregisters it.
VX_API vx_status vx_thread_set_robust(const void *head, uint64_t size, uint32_t owner) {
  return (vx_status)vx_syscall(VX_SYS_thread_set_robust, (uint64_t)head, size, owner, 0, 0, 0);
}

VX_API int64_t vx_futex_wake(const _Atomic uint32_t *word, uint32_t count) {
  return vx_syscall(VX_SYS_futex_wake, (uint64_t)word, count, 0, 0, 0, 0);
}

// Sleeps until the clock reaches at (or returns at once if it has). leeway, how
// late the wake may be, is not used yet: the kernel's deadlines are exact.
VX_API vx_status vx_sleep_until(vx_instant at, vx_duration leeway) {
  (void)leeway;
  static const _Atomic uint32_t never; // no one wakes it: only the deadline does
  vx_status st = VX_OK;
  while (vx_clock_read() < at) {
    st = vx_futex_wait(&never, 0, at);
    if (st != VX_OK && st != VX_ERR_TIMED_OUT) return st;
  }
  return VX_OK;
}

// --- Tasks and threads ---

// A thread's last steps, once fn has returned: the word cleared, the joiner
// woken, the thread ended, all in registers, as the joiner may unmap the
// stack as soon as the word is clear.
[[noreturn]] [[maybe_unused]] static void vx_thread_finish(_Atomic uint32_t *running) {
#ifdef __x86_64__
  __asm__ volatile("movl $0, (%0)\n\t"
                   "mov %0, %%rdi\n\t"
                   "mov $1, %%esi\n\t"
                   "mov %1, %%eax\n\t"
                   "syscall\n\t" // futex_wake(running, 1)
                   "mov %2, %%eax\n\t"
                   "syscall\n\t" // thread_exit()
                   "ud2"
                   :
                   : "r"(running), "i"(VX_SYS_futex_wake), "i"(VX_SYS_thread_exit)
                   : "rax", "rdi", "rsi", "rcx", "r11", "memory");
#else
  __asm__ volatile("stlr wzr, [%0]\n\t"
                   "mov x0, %0\n\t"
                   "mov x1, #1\n\t"
                   "mov x8, %1\n\t"
                   "svc #0\n\t" // futex_wake(running, 1)
                   "mov x8, %2\n\t"
                   "svc #0\n\t" // thread_exit()
                   "brk #0"
                   :
                   : "r"(running), "i"(VX_SYS_futex_wake), "i"(VX_SYS_thread_exit)
                   : "x0", "x1", "x8", "memory");
#endif
  __builtin_unreachable();
}

VX_API void vx_lock(vx_lock_t *m) {
  uint32_t c = 0;
  if (atomic_compare_exchange_strong(&m->state, &c, 1)) return;
  if (c != 2) c = atomic_exchange(&m->state, 2);
  while (c != 0) {
    vx_futex_wait(&m->state, 2, VX_INFINITE);
    c = atomic_exchange(&m->state, 2);
  }
}

// vx_lock, giving up at the deadline: false if it did not get the lock.
VX_API bool vx_lock_until(vx_lock_t *m, vx_instant deadline) {
  uint32_t c = 0;
  if (atomic_compare_exchange_strong(&m->state, &c, 1)) return true;
  if (c != 2) c = atomic_exchange(&m->state, 2);
  while (c != 0) {
    if (vx_futex_wait(&m->state, 2, deadline) == VX_ERR_TIMED_OUT) return false;
    c = atomic_exchange(&m->state, 2);
  }
  return true;
}

VX_API void vx_unlock(vx_lock_t *m) {
  if (atomic_fetch_sub(&m->state, 1) != 1) {
    atomic_store(&m->state, 0);
    vx_futex_wake(&m->state, 1);
  }
}

VX_API vx_status vx_task_create(vx_str name, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_task_create, (uint64_t)name.ptr, name.len, (uint64_t)out, 0, 0, 0);
}

// A copy of the caller, with no threads yet (VX_TASK_FORK).
VX_API vx_status vx_task_fork(vx_str name, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_task_create, (uint64_t)name.ptr, name.len, (uint64_t)out, VX_TASK_FORK,
                               0, 0);
}

VX_API vx_status vx_thread_create(vx_handle task, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_thread_create, task, (uint64_t)out, 0, 0, 0, 0);
}

// The same, and the thread's id in its task (exceptions and thread_interrupt name it so).
// --- Scheduling contexts (ADR-0038) ---

VX_API vx_status vx_sched_ctx_create(const vx_sched_params *p, vx_handle *out) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_sched_ctx_create, (uint64_t)p, (uint64_t)out, 0, 0, 0, 0);
}

// Binds thread (VX_HANDLE_NONE: the caller) to ctx (none: unbinds), on core
// (a CPU of its reservation) or -1.
VX_API vx_status vx_sched_ctx_bind(vx_handle ctx, vx_handle thread, int32_t core) {
  return (vx_status)vx_syscall(VX_SYS_sched_ctx_bind, ctx, thread, (uint64_t)(int64_t)core, 0, 0, 0);
}

VX_API vx_status vx_sched_ctx_configure(vx_handle ctx, const vx_sched_params *p) {
  return (vx_status)vx_syscall(VX_SYS_sched_ctx_configure, ctx, (uint64_t)p, 0, 0, 0, 0);
}

VX_API vx_status vx_sched_reserve(vx_handle ctx, uint32_t count, uint32_t cls, uint32_t domain,
                                  uint32_t flags, vx_core_set *out) {
  return (vx_status)vx_syscall(VX_SYS_sched_reserve, ctx, count, cls, domain, flags, (uint64_t)out);
}

// The calling thread's intent, anything but realtime, which needs a context
// (09 §5.7's vx_intent_set, here until libvx).
VX_API vx_status vx_intent_set(uint32_t intent) {
  vx_sched_params p = {.intent = intent};
  return vx_sched_ctx_configure(VX_HANDLE_NONE, &p);
}

VX_API vx_status vx_thread_create_id(vx_handle task, vx_handle *out, uint32_t *id) {
  *out = VX_HANDLE_NONE;
  return (vx_status)vx_syscall(VX_SYS_thread_create, task, (uint64_t)out, (uint64_t)id, 0, 0, 0);
}

// Starts a thread at entry on stack sp. `handle`, unless 0, moves to the
// thread's task and arrives as the first argument; arg2 is the second.
VX_API vx_status vx_thread_start(vx_handle thread, uint64_t entry, uint64_t sp, vx_handle handle,
                                 uint64_t arg2) {
  return (vx_status)vx_syscall(VX_SYS_thread_start, thread, entry, sp, handle, arg2, 0);
}

[[maybe_unused]] [[noreturn]] static void vx_thread_exit(void) {
  vx_syscall(VX_SYS_thread_exit, 0, 0, 0, 0, 0, 0);
  __builtin_unreachable();
}

// The caller takes scratch's address space and goes on as the program in it
// (ADR-0012), with bootstrap as its only handle. Returns only on a failure.
VX_API vx_status vx_task_exec(vx_handle scratch, vx_handle bootstrap, uint64_t entry, uint64_t sp) {
  return (vx_status)vx_syscall(VX_SYS_task_exec, scratch, bootstrap, entry, sp, 0, 0);
}

// Ends the task with msg as its exit string: empty for success (ADR-0010).
VX_API vx_status vx_task_kill(vx_handle task, vx_str msg) {
  return (vx_status)vx_syscall(VX_SYS_task_kill, task, (uint64_t)msg.ptr, msg.len, 0, 0, 0);
}

// The same for the task `id` in task's tree (abi.h).
VX_API vx_status vx_task_kill_id(vx_handle task, uint64_t id, vx_str msg) {
  return (vx_status)vx_syscall(VX_SYS_task_kill, task, (uint64_t)msg.ptr, msg.len, id, 0, 0);
}

VX_API vx_status vx_handle_close(vx_handle h) {
  return (vx_status)vx_syscall(VX_SYS_handle_close, h, 0, 0, 0, 0, 0);
}

// --- Console output ---
//
// To the console driver once vx_start has connected to it (the spawn
// message's "console"), and to the kernel log before that or without one.

static void (*vx_print_hook)(vx_str s);
static vx_lock_t vx_stdio_lock; // the output buffers, between a program's threads (6d1)

[[maybe_unused]] static void vx_print(vx_str s) {
  vx_lock(&vx_stdio_lock);
  if (vx_print_hook)
    vx_print_hook(s);
  else
    vx_debug_write(s);
  vx_unlock(&vx_stdio_lock);
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

// --- The spawn message (abi.h) ---

// arg= and env= records each: a spawn message (64 KiB) holds about that many
// short ones. A sender with more fails (E2BIG); a message with more is
// refused, not cut short.
static constexpr uint32_t VX_SPAWN_MAX_ARGS = 4096;

typedef struct vx_spawn_info {
  vx_str name;    // spawn=
  vx_str text;    // all the records, for vx-ns and the program to read again
  vx_str cmdline; // the root task's
  vx_str args[VX_SPAWN_MAX_ARGS];
  uint32_t argc;
  vx_str argv0;                   // argv0=: the POSIX argv[0], if not spawn=
  vx_str user;                    // user=: who the program runs as, which its attaches name (docs/11 §9)
  vx_str exe;                     // exe=: the program's path, as its spawner found it (6e1c3)
  vx_str envs[VX_SPAWN_MAX_ARGS]; // env=, each NAME=VALUE
  uint32_t envc;
  vx_str handle_names[VX_CHANNEL_MAX_HANDLES];
  vx_handle handles[VX_CHANNEL_MAX_HANDLES]; // VX_HANDLE_NONE once taken
  uint32_t handle_count;
} vx_spawn_info;

static vx_spawn_info vx_spawn;

// n random bytes from the process's generator: crt1.c's, or musl's back end's
// (start.c). spawn.c seeds each child from it.
static void vx_random_bytes(void *out, size_t n);
static vx_handle vx_self; // the task's handle to itself, or VX_HANDLE_NONE

// The same, for a program outside libvx (ADR-0004): what the wrappers that
// take a task are given for the program's own.
VX_API vx_handle vx_task_self(void) { return vx_self; }

// --- The current directory (M6 step 6d7a, ADR-0039) ---
//
// One for the process, an absolute and clean path (as vx-ns's vx_ns_clean
// makes them), at most 255 bytes: the spawn message's cwd=, else /. vx-ns
// resolves relative names against it, and its vx_chdir changes it; musl's
// back end keeps its working directory here too.

static constexpr size_t VX_WD_MAX = 256; // as vx-ns's VX_NS_MAX_PATH, its NUL included

static struct {
  vx_lock_t lock;
  size_t len;
  char path[VX_WD_MAX];
} vx_wd = {.len = 1, .path = "/"};

// The current directory into buf, NUL-ended: its length, or 0 if it needs more
// than cap bytes.
[[maybe_unused]] static size_t vx_getwd(char *buf, size_t cap) {
  vx_lock(&vx_wd.lock);
  size_t n = vx_wd.len;
  if (n < cap) memcpy(buf, vx_wd.path, n), buf[n] = 0;
  vx_unlock(&vx_wd.lock);
  return n < cap ? n : 0;
}

// Sets the current directory to path, absolute and clean, which the caller
// has found to be a directory (vx_chdir; musl's chdir). False if it is too long.
[[maybe_unused]] static bool vx_wd_set(vx_str path) {
  if (!path.len || path.ptr[0] != '/' || path.len >= VX_WD_MAX) return false;
  vx_lock(&vx_wd.lock);
  memcpy(vx_wd.path, path.ptr, path.len);
  vx_wd.path[path.len] = 0, vx_wd.len = path.len;
  vx_unlock(&vx_wd.lock);
  return true;
}

alignas(vx_msg_header) static uint8_t vx_spawn_msg[VX_CHANNEL_MAX_BYTES]; // read as a header first
static char vx_spawn_scratch[VX_CHANNEL_MAX_BYTES];                       // decoded values, which never grow

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

// The spawn message as it came, and its handles as they came, whatever the
// program takes from vx_spawn later: the dynamic loader hands them on
// (ADR-0047).
static struct {
  uint64_t bytes;
  uint32_t handle_count;
  vx_handle handles[VX_CHANNEL_MAX_HANDLES];
} vx_spawn_raw;

// Parses a spawn message in vx_spawn_msg, of size.bytes, with its handles
// got. A malformed one is reported and ignored: the program starts with
// nothing, and its handles are closed.
static void vx_spawn_parse(vx_msg_size size, vx_handle *got) {
  vx_spawn_raw.bytes = size.bytes, vx_spawn_raw.handle_count = size.handles;
  for (uint32_t i = 0; i < size.handles; i++) vx_spawn_raw.handles[i] = got[i];
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
      ok = vx_spawn.argc < VX_SPAWN_MAX_ARGS;
      if (ok) vx_spawn.args[vx_spawn.argc++] = vx_ndb_get(&rec, "arg");
    } else if (vx_ndb_has(&rec, "argv0")) {
      vx_spawn.argv0 = vx_ndb_get(&rec, "argv0");
    } else if (vx_ndb_has(&rec, "exe")) {
      vx_spawn.exe = vx_ndb_get(&rec, "exe");
    } else if (vx_ndb_has(&rec, "user")) {
      vx_spawn.user = vx_ndb_get(&rec, "user");
    } else if (vx_ndb_has(&rec, "cwd")) {
      vx_wd_set(vx_ndb_get(&rec, "cwd")); // the parent's directory; one not absolute leaves /
    } else if (vx_ndb_has(&rec, "env")) {
      ok = vx_spawn.envc < VX_SPAWN_MAX_ARGS;
      if (ok) vx_spawn.envs[vx_spawn.envc++] = vx_ndb_get(&rec, "env");
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

// Reads the spawn message from the bootstrap channel, and parses it.
static void vx_read_spawn(vx_handle bootstrap) {
  vx_handle got[VX_CHANNEL_MAX_HANDLES];
  vx_msg_size size;
  vx_status st =
      vx_channel_read(bootstrap, vx_spawn_msg, sizeof vx_spawn_msg, got, VX_CHANNEL_MAX_HANDLES, &size);
  vx_handle_close(bootstrap);
  if (st == VX_OK) vx_spawn_parse(size, got);
}

// Parses a spawn message the dynamic loader read (ADR-0047): its bytes and
// handles, copied, the handles still the process's.
[[maybe_unused]] static void vx_spawn_from(const uint8_t *msg, uint64_t bytes, const vx_handle *handles,
                                           uint32_t count) {
  vx_handle got[VX_CHANNEL_MAX_HANDLES];
  if (bytes > sizeof vx_spawn_msg || count > VX_CHANNEL_MAX_HANDLES) {
    vx_print(VX_STR("vx-rt: malformed spawn message\n"));
    return;
  }
  memcpy(vx_spawn_msg, msg, bytes);
  for (uint32_t i = 0; i < count; i++) got[i] = handles[i];
  vx_spawn_parse((vx_msg_size){.bytes = (uint32_t)bytes, .handles = count}, got);
}

// --- Identity (M6 step 6e1c3, os-requirements R16, R17), libvx's until libvx ---

// The process's id: its task's, which procfs names it by (ADR-0011).
// The vx-abi level the running system offers (09 §4.8): a dynamic program
// asks libvx.so, which the release ships, so it is the release's.
VX_API uint32_t vx_abi_level(void) { return VX_ABI_LEVEL; }

VX_API uint64_t vx_pid(void) {
  static uint64_t pid;
  vx_task_summary me;
  if (!pid && vx_task_info(vx_self, &me) == VX_OK) pid = me.id;
  return pid;
}

// The program's path, as its spawner found it (exe=); empty if it did not say.
VX_API vx_str vx_exe_path(void) { return vx_spawn.exe; }

// Who the process runs as (user=), none without it.
VX_API vx_str vx_user_name(void) { return vx_spawn.user.len ? vx_spawn.user : VX_STR("none"); }

// The value of name in the environment the process was given (env=), as a
// vx_str; {nullptr, 0} if it has none. The environment is vx_spawn.envs,
// vx_spawn.envc NAME=VALUE strings; /env is the shared store beside it
// (ADR-0044).
[[maybe_unused]] static vx_str vx_getenv(vx_str name) {
  for (uint32_t i = 0; i < vx_spawn.envc; i++) {
    vx_str e = vx_spawn.envs[i];
    if (e.len > name.len && e.ptr[name.len] == '=' && memcmp(e.ptr, name.ptr, name.len) == 0)
      return (vx_str){e.ptr + name.len + 1, e.len - name.len - 1};
  }
  return (vx_str){};
}
