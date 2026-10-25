// SPDX-License-Identifier: BSD-3-Clause

// <sched.h> (POSIX XBD <sched.h>): sched_yield, natively the floor's
// (M6d): croi's nanosleep with a deadline already past; and Linux's CPU
// affinity, cpu_set_t and sched_setaffinity (the floor's too: a profile
// with a CPU mask, which needs the system resource).

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

int sched_yield(void);

// A set of CPUs, a bit each, as Linux's (1024 of them; croi has 64).
typedef struct {
  unsigned long __bits[1024 / (8 * sizeof(unsigned long))];
} cpu_set_t;

#define CPU_SETSIZE 1024
#define CPU_ZERO(set) __builtin_memset((set), 0, sizeof(cpu_set_t))
#define CPU_SET(cpu, set) ((set)->__bits[(cpu) / (8 * sizeof(unsigned long))] |= 1UL << ((cpu) % (8 * sizeof(unsigned long))))
#define CPU_CLR(cpu, set) ((set)->__bits[(cpu) / (8 * sizeof(unsigned long))] &= ~(1UL << ((cpu) % (8 * sizeof(unsigned long)))))
#define CPU_ISSET(cpu, set) (((set)->__bits[(cpu) / (8 * sizeof(unsigned long))] >> ((cpu) % (8 * sizeof(unsigned long)))) & 1)

// The calling thread (pid 0) kept to `set`'s CPUs.
int sched_setaffinity(int pid, unsigned long size, const cpu_set_t *set);

#ifdef __cplusplus
}
#endif
