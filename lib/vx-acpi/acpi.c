// vx-acpi: reading the firmware's ACPI tables in user space (docs/01 §7.2).
// Builds for the target and the host.
//
// The kernel gives the root task every table end to end in one VMO (kernel/
// acpi.c). The tables come from firmware, so each is checked before use: its
// length must fit, and its bytes must sum to zero. The AML in the DSDT is not
// read here; bus-acpi's interpreter comes later.

#pragma once

#include "../../abi/vx/abi.h"

typedef struct vx_acpi_table {
  const uint8_t *ptr;
  uint32_t len; // the whole table, header included
} vx_acpi_table;

static uint32_t acpi_u32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t acpi_u64(const uint8_t *p) { return acpi_u32(p) | (uint64_t)acpi_u32(p + 4) << 32; }

// The n-th table with this signature (n from 0) in the blob. NOT_FOUND if
// there is none; INVALID if the tables before it are malformed.
[[maybe_unused]] static vx_status vx_acpi_find(const uint8_t *blob, size_t size, const char sig[4],
                                               uint32_t n, vx_acpi_table *out) {
  for (size_t at = 0; at < size;) {
    if (size - at < 36) return VX_ERR_INVALID;
    uint32_t len = acpi_u32(blob + at + 4);
    if (len < 36 || len > size - at) return VX_ERR_INVALID;
    uint8_t sum = 0;
    for (uint32_t i = 0; i < len; i++) sum = (uint8_t)(sum + blob[at + i]);
    bool match = true;
    for (int i = 0; i < 4; i++) match = match && blob[at + i] == (uint8_t)sig[i];
    if (match && sum == 0 && n-- == 0) {
      *out = (vx_acpi_table){blob + at, len};
      return VX_OK;
    }
    at += len;
  }
  return VX_ERR_NOT_FOUND;
}

// --- MCFG: where PCI configuration space is (ECAM) ---

typedef struct vx_ecam {
  uint64_t base; // the address of bus 0's space, even if start_bus is not 0
  uint16_t segment;
  uint8_t start_bus, end_bus;
} vx_ecam;

// The MCFG's n-th region. NOT_FOUND past the last.
[[maybe_unused]] static vx_status vx_acpi_mcfg(vx_acpi_table mcfg, uint32_t n, vx_ecam *out) {
  uint64_t at = 44 + (uint64_t)n * 16;
  if (at + 16 > mcfg.len) return VX_ERR_NOT_FOUND;
  const uint8_t *e = mcfg.ptr + at;
  *out = (vx_ecam){
      .base = acpi_u64(e), .segment = (uint16_t)(e[8] | e[9] << 8), .start_bus = e[10], .end_bus = e[11]};
  return out->end_bus >= out->start_bus ? VX_OK : VX_ERR_INVALID;
}
