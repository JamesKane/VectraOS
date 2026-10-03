// vx-pci: PCI configuration space (docs/01 §7.2), through ECAM, which maps
// each function's 4 KiB of configuration registers into memory. Builds for
// the target and the host (whose tests give it a fake function).

#pragma once

#include "../../abi/vx/abi.h"

typedef struct vx_pci_fn {
  volatile uint8_t *cfg; // its 4 KiB of configuration space
  uint8_t bus, dev, fn;
} vx_pci_fn;

[[maybe_unused]] static uint32_t vx_pci_read32(const vx_pci_fn *f, uint32_t off) {
  return *(volatile const uint32_t *)(f->cfg + (off & ~3u));
}
[[maybe_unused]] static uint16_t vx_pci_read16(const vx_pci_fn *f, uint32_t off) {
  return (uint16_t)(vx_pci_read32(f, off) >> (8 * (off & 2)));
}
[[maybe_unused]] static uint8_t vx_pci_read8(const vx_pci_fn *f, uint32_t off) {
  return (uint8_t)(vx_pci_read32(f, off) >> (8 * (off & 3)));
}
[[maybe_unused]] static void vx_pci_write32(const vx_pci_fn *f, uint32_t off, uint32_t v) {
  *(volatile uint32_t *)(f->cfg + (off & ~3u)) = v;
}
[[maybe_unused]] static void vx_pci_write16(const vx_pci_fn *f, uint32_t off, uint16_t v) {
  *(volatile uint16_t *)(f->cfg + (off & ~1u)) = v;
}

// The requester ID: how the function names itself on the bus (MSIs, the IOMMU).
[[maybe_unused]] static uint32_t vx_pci_rid(const vx_pci_fn *f) {
  return (uint32_t)f->bus << 8 | (uint32_t)f->dev << 3 | f->fn;
}

// Offset of the n-th capability with this ID (from 0) in the list, or 0. The
// list comes from the device, so it is walked a bounded number of steps.
[[maybe_unused]] static uint8_t vx_pci_cap(const vx_pci_fn *f, uint8_t id, uint32_t n) {
  if (!(vx_pci_read16(f, 0x06) & (1u << 4))) return 0; // status: no capability list
  uint8_t at = vx_pci_read8(f, 0x34) & 0xfc;
  for (int steps = 0; at >= 0x40 && steps < 48; steps++) {
    if (vx_pci_read8(f, at) == id && n-- == 0) return at;
    at = vx_pci_read8(f, at + 1) & 0xfc;
  }
  return 0;
}

typedef struct vx_pci_bar {
  uint64_t base, size; // size 0: the BAR is not implemented
  bool io, prefetchable;
} vx_pci_bar;

// Reads BAR i (a 64-bit BAR also takes i + 1) and sizes it, with memory and
// I/O decoding off while its address is all ones. A BAR the function does not
// implement reads back 0, and has size 0.
[[maybe_unused]] static vx_pci_bar vx_pci_bar_read(const vx_pci_fn *f, uint32_t i) {
  uint32_t off = 0x10 + 4 * i, low = vx_pci_read32(f, off), high = 0;
  bool io = low & 1, wide = !io && (low & 6) == 4 && i < 5;
  uint16_t command = vx_pci_read16(f, 0x04);
  vx_pci_write16(f, 0x04, command & (uint16_t)~3u);
  vx_pci_write32(f, off, ~0u);
  uint32_t low_mask = vx_pci_read32(f, off), high_mask = 0;
  vx_pci_write32(f, off, low);
  if (wide) {
    high = vx_pci_read32(f, off + 4);
    vx_pci_write32(f, off + 4, ~0u);
    high_mask = vx_pci_read32(f, off + 4);
    vx_pci_write32(f, off + 4, high);
  }
  vx_pci_write16(f, 0x04, command);
  vx_pci_bar b = {.io = io, .prefetchable = !io && (low & 8)};
  if (io) {
    uint32_t m = low_mask & ~3u;
    b.base = low & ~3u;
    b.size = m ? (uint16_t)(~(m | 0xffff'0000u) + 1) : 0; // I/O BARs decode 16 bits
  } else {
    uint64_t m = (uint64_t)(low_mask & ~0xfu) | (uint64_t)high_mask << 32;
    if (!wide && m) m |= 0xffff'ffff'0000'0000; // a 32-bit BAR's upper half is all address
    b.base = (low & ~0xfu) | (uint64_t)high << 32;
    b.size = m ? ~m + 1 : 0;
  }
  return b;
}

// --- MSI-X (PCI 3.0 §6.8.2) ---

// The MSI-X table, in whichever of the BARs (mapped by the caller: bar[i]
// and its size) the capability names; nullptr if there is none, or it does
// not fit. *count: its entries.
[[maybe_unused]] static volatile uint32_t *vx_pci_msix_table(const vx_pci_fn *f, volatile uint8_t *const *bar,
                                                             const uint64_t *bar_size, uint32_t *count) {
  uint8_t cap = vx_pci_cap(f, 0x11, 0);
  if (!cap) return nullptr;
  uint32_t table = vx_pci_read32(f, cap + 4), bir = table & 7;
  *count = (vx_pci_read16(f, cap + 2) & 0x7ff) + 1u;
  if (bir >= 6 || !bar[bir] || (table & ~7u) + 16ull * *count > bar_size[bir]) return nullptr;
  return (volatile uint32_t *)(bar[bir] + (table & ~7u));
}

// Points entry i at an MSI (from irq_create), unmasked, and turns MSI-X on,
// not function-masked.
[[maybe_unused]] static void vx_pci_msix_set(const vx_pci_fn *f, volatile uint32_t *table, uint32_t i,
                                             vx_msi msi) {
  volatile uint32_t *e = table + (size_t)4 * i;
  e[0] = (uint32_t)msi.address;
  e[1] = (uint32_t)(msi.address >> 32);
  e[2] = msi.data;
  e[3] = 0; // vector control: unmasked
  uint8_t cap = vx_pci_cap(f, 0x11, 0);
  uint16_t control = vx_pci_read16(f, cap + 2);
  vx_pci_write16(f, cap + 2, (uint16_t)((control | 1u << 15) & ~(1u << 14)));
}

// Memory decoding and bus mastering on, INTx off: what a driver of a device
// with MSI-X and DMA wants before it starts it.
[[maybe_unused]] static void vx_pci_enable(const vx_pci_fn *f) {
  uint16_t command = vx_pci_read16(f, 0x04);
  vx_pci_write16(f, 0x04, (uint16_t)(command | 1u << 2 | 1u << 1 | 1u << 10));
}
