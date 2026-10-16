// SPDX-License-Identifier: BSD-3-Clause

// The floor's interface for what can't import its Swift module (M6e): Sys
// and LibSys built as tier 1's full Swift, which can't import an Embedded
// module, and C. The floor (system/sys/floor) defines them; tier 0's
// Embedded Swift uses the same ones, so Sys has one source for both tiers.
// Its other state (this process's handle, its root VMAR, environ) is
// td_native.h's.

#pragma once
#include <stddef.h>
#include <stdint.h>
#include <croi/syscall.h>  // the ABI's values and layouts (D45)

#ifdef __cplusplus
extern "C" {
#endif

// Nanoseconds on croi's monotonic clock (the vDSO's).
int64_t td_monotonic(void);

// Ends the process with `code`: the exit handlers, then stdout written out.
__attribute__((__noreturn__)) void td_exit(int64_t code);

// The handle the process was started with whose processargs info is
// `info`, the caller's from then on; 0 if there was none or it was taken.
uint32_t td_startup_take(uint32_t info);
// How many handles the process was started with, and the info of the
// `i`th if it hasn't been taken (else 0).
size_t td_startup_count(void);
uint32_t td_startup_info(size_t i);

// stdout's bytes, written as lines to the process's debuglog, and what's
// buffered written out (the floor's Stdout; stderr's writes flush).
void td_stdout_write(const void *bytes, size_t n);
void td_stdout_flush(void);
// stderr's bytes (stdout's, flushed), and stdin's: none yet, so 0, its
// end. Byte streams come on the ring (D46, V2's item 6).
void td_stderr_write(const void *bytes, size_t n);
ptrdiff_t td_stdin_read(void *buffer, size_t n);

// The program's arguments, kept for the process's life.
char **td_argv(int *argc);

// A thread's block and TLS: the bytes their area takes (from any start),
// laying them out in an area (the block returned), and making a block the
// calling thread's (`thread` its own handle).
size_t td_thread_area_size(void);
void *td_thread_prepare(void *area);
void td_thread_install(void *block, uint32_t thread);
// Starts `thread` (thread_create's; the caller's handle, kept) running
// entry(arg) on a stack of its own with its block and TLS, which it unmaps
// as it exits: 0, or NO_MEMORY or thread_start's status. And ends the
// calling thread (closing its port; a thread so started unmapping its
// stack).
int32_t td_thread_start(uint32_t thread, void (*entry)(uintptr_t), uintptr_t arg);
__attribute__((__noreturn__)) void td_thread_exit(void);

// croi's futexes and ports, for the runtimes below Sys (M6f: tier 1's
// global executor and Synchronization.Mutex). Each returns croi's status:
// 0, or negative (BAD_STATE -20, TIMED_OUT -21). Deadlines are on the
// monotonic clock; INT64_MAX never passes.
int32_t td_futex_wait(uint32_t *word, uint32_t current, int64_t deadline);
int32_t td_futex_wake(uint32_t *word, uint32_t count);

// A port's packet: the ABI's (port.h's types; a SIGNALS binding's
// payload[0] is the trigger | observed << 32).
typedef croi_port_packet_t td_port_packet_t;

int32_t td_port_create(uint32_t *port);
int32_t td_port_queue(uint32_t port, const td_port_packet_t *packet);
int32_t td_port_wait(uint32_t port, int64_t deadline, td_port_packet_t *packet);

// port_cancel: every binding to `port` with `key`, from any source, and
// its packets still queued; NOT_FOUND (-25) if there were none.
int32_t td_port_cancel_key(uint32_t port, uint64_t key);

// The calling thread's port (V1 cut the thread waits, D23): made on first
// use, kept in its block, closed as a floor thread ends. Like everything
// per thread here, only on the main thread or one the floor started: a raw
// thread_create's thread has no block. Its waits bind
// ONCE there; nothing else binds to it.
uint32_t td_thread_port(void);
// Waits for one event until `deadline`: a ONCE binding of `item` (its key
// the thread's own) to the thread's port, cancelled if the deadline passes
// first. 0 (the packet, if `packet` isn't null), TIMED_OUT (-21), or the
// binding's or the call's status.
int32_t td_wait_bind(const croi_bind_item_t *item, int64_t deadline, td_port_packet_t *packet);
// Waits until `handle` asserts any of `signals` or `deadline` passes: 0,
// TIMED_OUT (-21), or the call's status; the signals seen in *observed (if
// not null). A ONCE binding to the thread's port, cancelled if the deadline
// passes first.
int32_t td_wait_one(uint32_t handle, uint32_t signals, int64_t deadline, uint32_t *observed);
// Sleeps until `deadline` (V1 cut nanosleep, D25): a wait on the thread's
// port to its deadline.
void td_sleep(int64_t deadline);

// The CPUs croi runs.
size_t td_cpu_count(void);

// CPUID's leaf `leaf`, subleaf `sub` (amd64; zeros elsewhere): eax, ebx,
// ecx, edx into out[0..3] (M6l: About this system's CPU model and clock).
void td_cpuid(uint32_t leaf, uint32_t sub, uint32_t *out);

// The heap's allocations since the program started (M6m: the editor's
// criterion, none in a frame's layout and paint).
uint64_t td_heap_allocations(void);
// This thread's allocations since it started.
uint64_t td_heap_thread_allocations(void);

// The process's executor port (M6f): tier 1's global executor's threads
// sleep on it, and a packet on it whose key is a td_port_waiter's address
// is that waiter's: a pool thread calls its `fire` with the packet, once.
// So an async wait (an object_bind ONCE to this port, the waiter's address
// as its key) resumes a task with no thread blocked on it (Sys's
// `Handle.wait(for:) async`). Made on first use; 0 if croi refused.
typedef struct td_port_waiter {
  void (*fire)(struct td_port_waiter *waiter, const td_port_packet_t *packet);
  void *context;
} td_port_waiter_t;

uint32_t td_executor_port(void);

#ifdef __cplusplus
}
#endif
