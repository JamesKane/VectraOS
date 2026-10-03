// vx-driver virtio: the virtio-pci modern transport (virtio 1.x, §4.1) and
// split virtqueues (§2.7), for user-space drivers.
//
// devmgr gives a virtio driver its function's configuration space, its memory
// BARs, a DMA domain and MSI-X interrupts (abi.h; 01 §7.1). The vendor
// capabilities in configuration space say where in the BARs the common, notify,
// ISR and device-specific registers are. Queue memory is a VMO mapped in the
// driver and, through the DMA domain, given to the device; each part of a
// queue (descriptors, the available and used rings) fits in its own page.
//
// Everything the device writes (the used ring, device config) is read as
// untrusted: indices are masked, lengths bounded.

#pragma once

#include "../vx-rt/base.c"
#include "../vx-pci/pci.c"

// The common configuration registers (§4.1.4.3).
typedef struct vx_virtio_common {
  uint32_t device_feature_select, device_feature;
  uint32_t driver_feature_select, driver_feature;
  uint16_t config_msix_vector, num_queues;
  uint8_t device_status, config_generation;
  uint16_t queue_select, queue_size, queue_msix_vector, queue_enable, queue_notify_off;
  uint64_t queue_desc, queue_driver, queue_device;
} vx_virtio_common;

enum : uint8_t {
  VIRTIO_ACKNOWLEDGE = 1,
  VIRTIO_DRIVER = 2,
  VIRTIO_DRIVER_OK = 4,
  VIRTIO_FEATURES_OK = 8,
  VIRTIO_FAILED = 128,
};

static constexpr uint64_t VIRTIO_F_VERSION_1 = 1ull << 32;
// The device's DMA goes through the platform's IOMMU (§6.1): accepted
// whenever offered, since the addresses a DMA domain gives are the IOMMU's.
static constexpr uint64_t VIRTIO_F_ACCESS_PLATFORM = 1ull << 33;
static constexpr uint64_t VIRTIO_RING_F_INDIRECT_DESC = 1ull << 28;
static constexpr uint16_t VIRTIO_NO_VECTOR = 0xffff;

typedef struct vx_virtio_desc {
  uint64_t addr;
  uint32_t len;
  uint16_t flags, next;
} vx_virtio_desc;

enum : uint16_t { VIRTQ_DESC_F_NEXT = 1, VIRTQ_DESC_F_WRITE = 2, VIRTQ_DESC_F_INDIRECT = 4 };

typedef struct vx_virtq {
  uint16_t index, size; // size: a power of two, at most 256
  volatile vx_virtio_desc *desc;
  volatile uint16_t *avail; // flags, idx, ring[size]
  volatile uint8_t *used;   // flags, idx, then {id, len} pairs
  uint16_t avail_idx, used_seen;
  volatile uint16_t *notify;
} vx_virtq;

typedef struct vx_virtio {
  vx_pci_fn fn;
  volatile uint8_t *bar[6]; // mapped by the driver; nullptr if not given
  uint64_t bar_size[6];
  volatile vx_virtio_common *common;
  volatile uint8_t *notify_base, *isr, *device;
  uint32_t notify_mult, notify_len;
  volatile uint32_t *msix; // the MSI-X table, 16 bytes an entry
  uint32_t msix_count;
  vx_handle dma; // the DMA domain
} vx_virtio;

// The register block one vendor capability describes, if it lies inside a
// BAR the driver has.
static volatile uint8_t *virtio_region(vx_virtio *v, uint8_t cap, uint32_t need, uint32_t *len) {
  uint8_t bar = vx_pci_read8(&v->fn, cap + 4);
  uint32_t offset = vx_pci_read32(&v->fn, cap + 8), length = vx_pci_read32(&v->fn, cap + 12);
  if (bar > 5 || !v->bar[bar] || length < need || offset > v->bar_size[bar] ||
      length > v->bar_size[bar] - offset)
    return nullptr;
  if (len) *len = length;
  return v->bar[bar] + offset;
}

// Finds the registers through the vendor capabilities (§4.1.4) and the MSI-X
// table. The caller has mapped the BARs into v->bar.
[[maybe_unused]] static vx_status vx_virtio_find(vx_virtio *v) {
  for (uint32_t n = 0; n < 16; n++) {
    uint8_t cap = vx_pci_cap(&v->fn, 0x09, n);
    if (!cap) break;
    uint8_t type = vx_pci_read8(&v->fn, cap + 3);
    if (type == 1 && !v->common)
      v->common = (volatile vx_virtio_common *)virtio_region(v, cap, sizeof(vx_virtio_common), nullptr);
    if (type == 2 && !v->notify_base) {
      v->notify_base = virtio_region(v, cap, 2, &v->notify_len);
      v->notify_mult = vx_pci_read32(&v->fn, cap + 16);
    }
    if (type == 3 && !v->isr) v->isr = virtio_region(v, cap, 1, nullptr);
    if (type == 4 && !v->device) v->device = virtio_region(v, cap, 8, nullptr);
  }
  v->msix = vx_pci_msix_table(&v->fn, v->bar, v->bar_size, &v->msix_count);
  return v->common && v->notify_base && v->isr && v->device && v->msix ? VX_OK : VX_ERR_UNSUPPORTED;
}

// Points MSI-X table entry i at an MSI (from irq_create), unmasked, and turns
// MSI-X on (§6.8.2 of PCI 3.0).
[[maybe_unused]] static void vx_virtio_msix(vx_virtio *v, uint32_t i, vx_msi msi) {
  vx_pci_msix_set(&v->fn, v->msix, i, msi);
  vx_pci_enable(&v->fn);
}

// Resets the device and negotiates features: VERSION_1 and whichever of
// `wanted` it offers. Returns them in *got.
[[maybe_unused]] static vx_status vx_virtio_start(vx_virtio *v, uint64_t wanted, uint64_t *got) {
  volatile vx_virtio_common *c = v->common;
  c->device_status = 0;
  for (int i = 0; i < 1'000'000 && c->device_status; i++) {} // the reset completes when it reads 0
  c->device_status = VIRTIO_ACKNOWLEDGE;
  c->device_status = VIRTIO_ACKNOWLEDGE | VIRTIO_DRIVER;
  c->device_feature_select = 0;
  uint64_t offered = c->device_feature;
  c->device_feature_select = 1;
  offered |= (uint64_t)c->device_feature << 32;
  uint64_t use = offered & (wanted | VIRTIO_F_VERSION_1 | VIRTIO_F_ACCESS_PLATFORM);
  if (!(use & VIRTIO_F_VERSION_1)) return VX_ERR_UNSUPPORTED; // a legacy-only device
  c->driver_feature_select = 0;
  c->driver_feature = (uint32_t)use;
  c->driver_feature_select = 1;
  c->driver_feature = (uint32_t)(use >> 32);
  c->device_status = VIRTIO_ACKNOWLEDGE | VIRTIO_DRIVER | VIRTIO_FEATURES_OK;
  if (!(c->device_status & VIRTIO_FEATURES_OK)) return VX_ERR_UNSUPPORTED;
  c->config_msix_vector = VIRTIO_NO_VECTOR;
  *got = use;
  return VX_OK;
}

[[maybe_unused]] static void vx_virtio_ready(vx_virtio *v) {
  v->common->device_status = VIRTIO_ACKNOWLEDGE | VIRTIO_DRIVER | VIRTIO_FEATURES_OK | VIRTIO_DRIVER_OK;
}

// Sets up queue `index` with `size` entries (at most what the device offers),
// its interrupts on MSI-X entry `vector`. Its memory: three pages of a new
// VMO, given to the device through the DMA domain.
[[maybe_unused]] static vx_status vx_virtq_init(vx_virtio *v, vx_virtq *q, uint16_t index, uint16_t size,
                                                uint16_t vector) {
  volatile vx_virtio_common *c = v->common;
  c->queue_select = index;
  uint16_t max = c->queue_size;
  if (size > max) size = max;
  if (!size || size & (size - 1) || size > 256) return VX_ERR_UNSUPPORTED;
  static constexpr uint64_t QUEUE_BYTES = 3ull * 4096; // descriptors, available ring, used ring
  vx_handle vmo;
  uint64_t at = 0, pa[3];
  vx_status st = vx_vmo_create(QUEUE_BYTES, 0, &vmo);
  if (st == VX_OK) st = vx_as_map(vx_self, vmo, 0, QUEUE_BYTES, VX_MAP_WRITE, &at);
  vx_handle mapping; // kept as long as the driver lives: the device reads the queue and writes its used ring
  if (st == VX_OK) st = vx_dma_map(v->dma, vmo, 0, QUEUE_BYTES, VX_DMA_READ | VX_DMA_WRITE, pa, &mapping);
  vx_handle_close(vmo); // the mappings keep it
  if (st != VX_OK) return st;
  *q = (vx_virtq){.index = index,
                  .size = size,
                  .desc = (volatile vx_virtio_desc *)at,
                  .avail = (volatile uint16_t *)(at + 4096),
                  .used = (volatile uint8_t *)(at + 8192)};
  c->queue_size = size;
  c->queue_desc = pa[0];
  c->queue_driver = pa[1];
  c->queue_device = pa[2];
  c->queue_msix_vector = vector;
  if (c->queue_msix_vector != vector) return VX_ERR_UNSUPPORTED; // the device could not take it
  uint64_t notify_at = (uint64_t)c->queue_notify_off * v->notify_mult;
  if (notify_at + 2 > v->notify_len) return VX_ERR_INVALID; // the device's offset, outside its own region
  q->notify = (volatile uint16_t *)(v->notify_base + notify_at);
  c->queue_enable = 1;
  return VX_OK;
}

// Makes descriptor `d` (one buffer) available to the device.
[[maybe_unused]] static void vx_virtq_offer(vx_virtq *q, uint16_t d, uint64_t addr, uint32_t len,
                                            bool device_writes) {
  q->desc[d] = (vx_virtio_desc){.addr = addr, .len = len, .flags = device_writes ? VIRTQ_DESC_F_WRITE : 0};
  q->avail[2 + q->avail_idx % q->size] = d;
  __atomic_thread_fence(__ATOMIC_RELEASE); // the descriptor and ring entry, before the index
  q->avail[1] = ++q->avail_idx;
}

// Makes descriptor `d` available as an indirect one (§2.7.5.3): a table of
// `n` descriptors at device address `table`, which the driver has filled and
// chained, and which the device reads once the descriptor is available. Needs
// VIRTIO_RING_F_INDIRECT_DESC.
[[maybe_unused]] static void vx_virtq_offer_indirect(vx_virtq *q, uint16_t d, uint64_t table, uint16_t n) {
  q->desc[d] = (vx_virtio_desc){
      .addr = table, .len = (uint32_t)n * sizeof(vx_virtio_desc), .flags = VIRTQ_DESC_F_INDIRECT};
  q->avail[2 + q->avail_idx % q->size] = d;
  __atomic_thread_fence(__ATOMIC_RELEASE); // the table, the descriptor and ring entry, before the index
  q->avail[1] = ++q->avail_idx;
}

// Tells the device the queue has new buffers.
[[maybe_unused]] static void vx_virtq_kick(vx_virtq *q) {
  __atomic_thread_fence(__ATOMIC_SEQ_CST);
  *q->notify = q->index;
}

// The next buffer the device has finished with: its descriptor, and how many
// bytes it wrote. False if there is none.
[[maybe_unused]] static bool vx_virtq_used(vx_virtq *q, uint16_t *d, uint32_t *len) {
  uint16_t idx = *(volatile uint16_t *)(q->used + 2);
  if (idx == q->used_seen) return false;
  __atomic_thread_fence(__ATOMIC_ACQUIRE); // the entry, after the index
  volatile const uint8_t *e = q->used + 4 + (size_t)8 * (q->used_seen % q->size);
  uint32_t id = *(volatile const uint32_t *)e;
  *len = *(volatile const uint32_t *)(e + 4);
  *d = (uint16_t)(id % q->size); // the device's word, kept in range
  q->used_seen++;
  return true;
}
