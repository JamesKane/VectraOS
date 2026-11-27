// Device registers: volatile loads and stores, each made once, in order
// and at its width, which Swift can't express (D74). Drivers, the PCI
// library's ECAM and the interrupts suite reach registers only through
// these (module CroiMMIO, which the host's tests import too: it needs
// nothing but <stdint.h>). Port I/O is the floor's (td_port_in,
// td_port_out: amd64).

#pragma once

#include <stdint.h>

static inline uint8_t croi_mmio_read8(uint64_t address) { return *(volatile uint8_t *)address; }
static inline uint16_t croi_mmio_read16(uint64_t address) { return *(volatile uint16_t *)address; }
static inline uint32_t croi_mmio_read32(uint64_t address) { return *(volatile uint32_t *)address; }
static inline uint64_t croi_mmio_read64(uint64_t address) { return *(volatile uint64_t *)address; }
static inline void croi_mmio_write8(uint64_t address, uint8_t value) { *(volatile uint8_t *)address = value; }
static inline void croi_mmio_write16(uint64_t address, uint16_t value) { *(volatile uint16_t *)address = value; }
static inline void croi_mmio_write32(uint64_t address, uint32_t value) { *(volatile uint32_t *)address = value; }
static inline void croi_mmio_write64(uint64_t address, uint64_t value) { *(volatile uint64_t *)address = value; }

// The frequency of the CPU's architected counter, CNTFRQ_EL0, which the kernel lets user code read (CNTKCTL_EL0's
// EL0VCTEN), in Hz: what a GPU's timestamp counter runs at (valhall 16 section 16.8.5). Inline assembly, which Swift
// can't express. Zero where the architecture has no such register here, and where firmware never set it.
static inline uint64_t croi_counter_frequency(void) {
#if defined(__aarch64__)
  uint64_t value;
  __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(value));
  return value;
#else
  return 0;
#endif
}

// The CPU's architected counter, CNTVCT_EL0, which the kernel lets user code read: what a GPU's timestamps count in, so
// a benchmark can place them on the CPU's clock. Inline assembly, which Swift can't express; zero where there is none.
static inline uint64_t croi_counter_value(void) {
#if defined(__aarch64__)
  uint64_t value;
  __asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(value));
  return value;
#else
  return 0;
#endif
}

// A barrier between memory a device reads or writes by DMA and the
// accesses around it: every load and store before it, to memory or to
// registers, is seen by the device before any after it (Linux's mb() for
// devices). virtio's rings need one between filling a slot and publishing
// its index, before notifying the device, and between reading the
// device's index and the slots it covers. Inline assembly, which Swift
// can't express. Outer shareable on arm64, so the device's observer
// counts; rv64 orders device I/O with memory too; amd64's stores are
// already ordered, and mfence orders loads with them.
static inline void croi_dma_barrier(void) {
#if defined(__x86_64__)
  __asm__ volatile("mfence" ::: "memory");
#elif defined(__aarch64__)
  __asm__ volatile("dmb osh" ::: "memory");
#elif defined(__riscv)
  __asm__ volatile("fence iorw, iorw" ::: "memory");
#else
#error "croi_dma_barrier: an unknown architecture"
#endif
}

// Like croi_dma_barrier, but complete: every store before it, including those to write-combining
// and uncached memory, has reached the point the device reads from when it returns (dsb on arm64,
// whose dmb only orders them). A device that doesn't snoop the CPU's buffers is told to look after
// one: a GPU's doorbell, and a client's submit of streams it wrote.
static inline void croi_dma_complete(void) {
#if defined(__x86_64__)
  __asm__ volatile("mfence" ::: "memory");
#elif defined(__aarch64__)
  __asm__ volatile("dsb sy" ::: "memory");
#elif defined(__riscv)
  __asm__ volatile("fence iorw, iorw" ::: "memory");
#else
#error "croi_dma_complete: an unknown architecture"
#endif
}
