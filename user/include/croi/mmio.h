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
