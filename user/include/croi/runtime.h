// What a user program, C or Embedded Swift, reaches in C: the system
// calls (syscall.h, its own module CroiSyscall), processargs, and the
// floor's C interface (system/sys/floor/include: td_floor.h, td_native.h),
// the one user runtime (D49). `_start` reads the bootstrap message, keeps
// its handles (td_startup_take), and calls `main(argc, argv)`; returning
// from main exits the process. stdout (putchar, td_stdout_write) goes to
// the debuglog handed over as fd 1, if there is one.

#pragma once

#include <stddef.h>
#include <stdint.h>

#include "syscall.h"
#include "processargs.h"
#include "td_floor.h"
#include "td_native.h"

// Device registers, for drivers and the interrupts suite: volatile
// accesses, which Swift can't express. Port I/O is the floor's
// (td_port_in, td_port_out: amd64).
static inline uint8_t croi_mmio_read8(uint64_t address) { return *(volatile uint8_t *)address; }
static inline uint16_t croi_mmio_read16(uint64_t address) { return *(volatile uint16_t *)address; }
static inline uint32_t croi_mmio_read32(uint64_t address) { return *(volatile uint32_t *)address; }
static inline void croi_mmio_write16(uint64_t address, uint16_t value) { *(volatile uint16_t *)address = value; }
static inline void croi_mmio_write32(uint64_t address, uint32_t value) { *(volatile uint32_t *)address = value; }

// The C library floor the compilers and the Embedded Swift runtime call:
// lib/rt's, and the floor's heap.
int posix_memalign(void **pointer, size_t alignment, size_t size);
void *malloc(size_t size);
void free(void *pointer);
void *memset(void *destination, int value, size_t count);
void *memcpy(void *restrict destination, const void *restrict source, size_t count);
void *memmove(void *destination, const void *source, size_t count);
int memcmp(const void *a, const void *b, size_t count);
size_t strlen(const char *text);

// The floor's C library calls (Start.swift, Heap.swift, Posix.swift,
// libc's errno.c), until libc's headers come with it (V2's item 2).
char *getenv(const char *name);
void *calloc(size_t count, size_t size);
void *realloc(void *pointer, size_t size);
int *__errno_location(void);
int getpid(void);
// struct timespec's two words: seconds, nanoseconds.
int clock_gettime(int clock, int64_t *ts);
