// SPDX-License-Identifier: BSD-3-Clause

// What Swift reaches in the native runtime's assembly (entry/<arch>.S)
// and C (runtime.c). System calls are croi/syscall.h's (D45), whose
// inline assembly Swift reaches through the CroiSyscall module.

#pragma once
#include <stdint.h>
#include "shared.h"  // croi_topology_page_t

// The calling thread's block (ThreadBlock in Thread.swift), through the
// thread pointer (FS, TPIDR_EL0, tp: on arm64 and rv64 the block is the
// 64 bytes below it); setting the thread pointer (not amd64's: croi sets
// FS's base for a system call).
void *td_thread_block(void);
void td_set_thread_pointer(void *tp);

// The CPUs a topology page (the vDSO's) counts.
static inline uint32_t td_topology_cpu_count(const void *page) {
  return ((const croi_topology_page_t *)page)->cpu_count;
}

// The program's ELF header (__ehdr_start): its program headers follow, in
// its first segment.
const void *td_image_header(void);

// amd64's I/O port instructions (in, out) of `width` bytes: 1, 2 or 4.
uint32_t td_port_in(uint16_t port, uint32_t width);
void td_port_out(uint16_t port, uint32_t width, uint32_t value);

// The runtime's per-process state (runtime.c): this process's handle, its
// root VMAR, its first thread's handle, the vDSO's base, and its clock and
// topology page (functions' addresses, or 0).
extern uint32_t td_runtime_process_self;
extern uint32_t td_runtime_vmar_root;
extern uint32_t td_runtime_thread_self;
extern uint64_t td_runtime_vdso_base;
extern uint64_t td_runtime_vdso_clock;
extern uint64_t td_runtime_vdso_topology;
// UTC now, in nanoseconds since the Unix epoch: the monotonic clock until
// the time service publishes UTC in a page (D48, V2's item 5).
int64_t td_utc_now(void);

// C's environment, the program's initializers, and the exit handlers
// (runtime.c).
extern char **environ;
void td_run_initializers(void);
void td_run_exit_handlers(void);

// The program's own entry: Swift's @main emits it.
int main(int argc, char **argv);
// The heap notes an allocation on this thread's count (runtime.c; M6m).
void td_heap_noted(void);
// Whether threads' TLS is up (the floor's start sets it): counted from then.
extern int td_heap_tls_ready;

