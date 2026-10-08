// vtd.c: Intel VT-d, the x86_64 IOMMU (Intel VT-d specification 4.x; docs/01
// §7.1, §10). The kernel finds the remapping units in the firmware's DMAR
// table at boot and turns translation on before any driver runs, with every
// device's context empty: no device can DMA until devmgr gives it a domain
// (dma_domain_create, obj/device.c), which closes the window Thunderbolt and
// USB4 DMA attacks use. The firmware's reserved regions (RMRRs) are
// identity-mapped for the devices they name, in every domain those devices
// get.
//
// Translation is legacy mode: a root table (a context table for each bus),
// each device's context entry naming its domain's second-level page tables,
// 4-level (48-bit) or 3-level (39-bit) as the unit supports, 4 KiB pages.
// Invalidation goes through the queued-invalidation interface where the unit
// has one, else the registers. Every change to the tables is invalidated
// before the call returns, so caching mode (CAP.CM, which QEMU's intel-iommu
// may set) needs nothing more; a unit that wants its write buffer flushed
// (CAP.RWBF) gets that first, and one whose page walks do not snoop (no
// ECAP.C) has each table line it writes flushed from the CPU's caches.
//
// Faults are recorded by the unit and raised as an interrupt (VECTOR_IOMMU),
// which reads the records and counts each against the domain whose requester
// ID it names (dma_fault). Interrupt remapping is not used yet: MSIs go
// through untranslated, as compatibility-format interrupts.
//
// Fuchsia's VT-d driver was the comparison: it supported neither bridge nor
// multi-hop scopes; here a scope's path is walked through PCI configuration
// space (MCFG) to the bus it names.

static constexpr uint32_t VTD_MAX_UNITS = 8, VTD_MAX_RMRR = 16, VTD_MAX_DOMAINS = 128;
static constexpr uint8_t VECTOR_IOMMU = 0xf0;

// Registers (§11.4).
enum : uint32_t {
  VTD_VER = 0x00,
  VTD_CAP = 0x08,
  VTD_ECAP = 0x10,
  VTD_GCMD = 0x18,
  VTD_GSTS = 0x1c,
  VTD_RTADDR = 0x20,
  VTD_CCMD = 0x28,
  VTD_FSTS = 0x34,
  VTD_FECTL = 0x38,
  VTD_FEDATA = 0x3c,
  VTD_FEADDR = 0x40,
  VTD_FEUADDR = 0x44,
  VTD_IQH = 0x80,
  VTD_IQT = 0x88,
  VTD_IQA = 0x90,
};
enum : uint32_t { GCMD_TE = 1u << 31, GCMD_SRTP = 1u << 30, GCMD_WBF = 1u << 27, GCMD_QIE = 1u << 26 };

typedef struct vtd_unit {
  volatile uint8_t *regs;
  uint64_t cap, ecap;
  uint16_t segment;
  bool all;           // INCLUDE_PCI_ALL: every device of its segment no other unit names
  uint8_t levels;     // 3 or 4
  uint8_t aw;         // the context entry's address width field: 1 (39 bits) or 2 (48)
  uint64_t root;      // the root table (physical)
  uint64_t *ctx[256]; // each bus's context table (direct map), made when a device on it is attached
  uint64_t iq;        // the invalidation queue (physical), or 0 if invalidations go through registers
  uint32_t iq_tail;   // in descriptors
  _Atomic uint32_t *iq_status; // what a wait descriptor writes, in a page of its own
  uint64_t iq_status_pa;
  spinlock lock;
  uint32_t scopes[32]; // the requester IDs it names (endpoints), or bus ranges (bridges): see vtd_covers
  uint8_t nscopes;
  uint8_t bridge[32]; // whether scopes[i] is a bus range (start << 8 | end)
} vtd_unit;

typedef struct vtd_rmrr {
  uint64_t base, limit; // [base, limit], inclusive, as DMAR has it
  uint32_t rid;
} vtd_rmrr;

static vtd_unit vtd_units[VTD_MAX_UNITS];
static uint32_t vtd_nunits;
static vtd_rmrr vtd_rmrrs[VTD_MAX_RMRR];
static uint32_t vtd_nrmrr;
static struct dma_domain *vtd_domains[VTD_MAX_DOMAINS]; // attached, for faults to find by requester ID
static spinlock vtd_domains_lock;
static uint64_t vtd_did_used[VTD_MAX_UNITS][1024 / 64]; // domain ids in use, at most 1024 a unit here
static uint64_t vtd_ecam_base;                          // MCFG's segment 0 window, for scope paths
static uint8_t vtd_ecam_start, vtd_ecam_end;

static uint32_t vtd_r32(const vtd_unit *u, uint32_t at) { return *(volatile uint32_t *)(u->regs + at); }
static uint64_t vtd_r64(const vtd_unit *u, uint32_t at) { return *(volatile uint64_t *)(u->regs + at); }
static void vtd_w32(const vtd_unit *u, uint32_t at, uint32_t v) { *(volatile uint32_t *)(u->regs + at) = v; }
static void vtd_w64(const vtd_unit *u, uint32_t at, uint64_t v) { *(volatile uint64_t *)(u->regs + at) = v; }

// A table line the unit's walks read, out of the CPU's caches if they do not snoop.
static void vtd_flush(const vtd_unit *u, const void *p) {
  if (u->ecap & 1) return; // ECAP.C: coherent
  __asm__ volatile("clflush (%0)" ::"r"(p) : "memory");
}
static void vtd_fence(void) { __asm__ volatile("mfence" ::: "memory"); }

// A global command (§11.4.4): the enabled bits kept, one set or cleared, and waited for.
static bool vtd_command(const vtd_unit *u, uint32_t bit, bool on) {
  uint32_t keep = vtd_r32(u, VTD_GSTS) & (GCMD_TE | GCMD_QIE); // the persistent ones
  vtd_w32(u, VTD_GCMD, on ? keep | bit : keep & ~bit);
  for (uint32_t spins = 0; spins < 10'000'000; spins++)
    if (((vtd_r32(u, VTD_GSTS) & bit) != 0) == on) return true;
  return false;
}

static bool vtd_one_shot(const vtd_unit *u, uint32_t bit) { // SRTP, WBF: set, then done when the status says
  uint32_t keep = vtd_r32(u, VTD_GSTS) & (GCMD_TE | GCMD_QIE);
  vtd_w32(u, VTD_GCMD, keep | bit);
  for (uint32_t spins = 0; spins < 10'000'000; spins++) {
    uint32_t st = vtd_r32(u, VTD_GSTS);
    if (bit == GCMD_SRTP ? (st & (1u << 30)) != 0 : !(st & (1u << 27))) return true;
  }
  return false;
}

// --- Invalidation (§6.5) ---

static void vtd_qi_submit(vtd_unit *u, uint64_t lo, uint64_t hi) {
  uint64_t *q = phys_to_virt(u->iq);
  q[(size_t)2 * u->iq_tail] = lo, q[(size_t)2 * u->iq_tail + 1] = hi;
  u->iq_tail = (u->iq_tail + 1) % 256;
}

// Context caches and the IOTLB, for one domain (did) or all (did 0): every
// change made before this is seen by the unit when it returns.
static void vtd_invalidate(vtd_unit *u, uint16_t did, bool context) {
  if (u->cap & (1u << 4)) vtd_one_shot(u, GCMD_WBF); // CAP.RWBF
  if (u->iq) {
    spin_lock(&u->lock);
    uint32_t gran = did ? 2 : 1; // domain-selective, or global
    if (context) vtd_qi_submit(u, 0x1 | gran << 4 | (uint64_t)did << 16, 0);
    vtd_qi_submit(u, 0x2 | (uint64_t)gran << 4 | 1u << 6 | 1u << 7 | (uint64_t)did << 16,
                  0); // drain reads, writes
    atomic_store(u->iq_status, 0);
    vtd_qi_submit(u, 0x5 | 1u << 5 | 1ull << 32, u->iq_status_pa); // wait, status 1 written when done
    vtd_fence();
    vtd_w64(u, VTD_IQT, (uint64_t)u->iq_tail << 4);
    for (uint32_t spins = 0; atomic_load(u->iq_status) != 1 && spins < 100'000'000; spins++)
      if (vtd_r32(u, VTD_FSTS) & (1u << 4)) break; // an invalidation queue error
    spin_unlock(&u->lock);
    return;
  }
  spin_lock(&u->lock);
  if (context) { // CCMD: ICC, global or domain-selective
    uint64_t cmd = 1ull << 63 | (did ? 2ull : 1ull) << 61 | did;
    vtd_w64(u, VTD_CCMD, cmd);
    for (uint32_t spins = 0; spins < 10'000'000 && vtd_r64(u, VTD_CCMD) >> 63; spins++) {}
  }
  uint32_t iro = (uint32_t)((u->ecap >> 8) & 0x3ff) * 16;
  uint64_t cmd = 1ull << 63 | (did ? 2ull : 1ull) << 60 | 1ull << 49 | 1ull << 48 | (uint64_t)did << 32;
  vtd_w64(u, iro + 8, cmd);
  for (uint32_t spins = 0; spins < 10'000'000 && vtd_r64(u, iro + 8) >> 63; spins++) {}
  spin_unlock(&u->lock);
}

// --- PCI configuration space, for the scopes' paths ---

static uint8_t vtd_config8(uint8_t bus, uint8_t dev, uint8_t fn, uint32_t off) {
  if (!vtd_ecam_base || bus < vtd_ecam_start || bus > vtd_ecam_end) return 0xff;
  uint64_t pa = vtd_ecam_base + ((uint64_t)bus << 20 | (uint64_t)dev << 15 | (uint64_t)fn << 12);
  int level;
  if (!leaf_entry(kernel_root, boot.hhdm + pa, &level) &&
      !map_range(kernel_root, boot.hhdm + pa, pa, 4096, MAP_WRITE | MAP_DEVICE))
    return 0xff;
  return *(volatile uint8_t *)(boot.hhdm + pa + off);
}

// A device scope (§8.3.1): an endpoint's requester ID, or a bridge's buses,
// found by following its path from its start bus through the bridges on it.
static void vtd_scope(vtd_unit *u, const uint8_t *sc, uint32_t len, bool rmrr, uint64_t base,
                      uint64_t limit) {
  uint8_t type = sc[0], bus = sc[5];
  if (len < 8 || (type != 1 && type != 2))
    return; // endpoints and bridges; IOAPICs, HPETs and the rest are not DMA
  uint8_t dev = 0, fn = 0;
  for (uint32_t at = 6; at + 2 <= len; at += 2) {
    dev = sc[at] & 31, fn = sc[at + 1] & 7;
    if (at + 2 < len) bus = vtd_config8(bus, dev, fn, 0x19); // through this bridge: its secondary bus
  }
  uint32_t rid = (uint32_t)bus << 8 | (uint32_t)dev << 3 | fn;
  if (rmrr) {
    if (vtd_nrmrr < VTD_MAX_RMRR) vtd_rmrrs[vtd_nrmrr++] = (vtd_rmrr){base, limit, rid};
    return;
  }
  if (u->nscopes == 32) return;
  bool bridge = type == 2;
  if (bridge) { // the buses behind it: secondary to subordinate
    uint8_t sec = vtd_config8(bus, dev, fn, 0x19), sub = vtd_config8(bus, dev, fn, 0x1a);
    rid = (uint32_t)sec << 8 | sub;
  }
  u->bridge[u->nscopes] = bridge;
  u->scopes[u->nscopes++] = rid;
}

static bool vtd_names(const vtd_unit *u, uint32_t rid) {
  for (uint32_t i = 0; i < u->nscopes; i++) {
    if (!u->bridge[i] && u->scopes[i] == rid) return true;
    if (u->bridge[i] && (rid >> 8) >= (u->scopes[i] >> 8) && (rid >> 8) <= (u->scopes[i] & 0xff)) return true;
  }
  return false;
}

// The unit for a requester ID (segment 0): the one that names it, else the
// one that takes all the rest; VTD_MAX_UNITS if none.
static uint32_t vtd_unit_for(uint32_t rid) {
  for (uint32_t i = 0; i < vtd_nunits; i++)
    if (!vtd_units[i].segment && vtd_names(&vtd_units[i], rid)) return i;
  for (uint32_t i = 0; i < vtd_nunits; i++)
    if (!vtd_units[i].segment && vtd_units[i].all) return i;
  return VTD_MAX_UNITS;
}

// --- Second-level page tables (§9.8) ---

static constexpr uint64_t VTD_R = 1, VTD_W = 2, VTD_ADDR = 0x000f'ffff'ffff'f000;

// The leaf entry for iova, the tables to it made if `make`; nullptr if not there.
static uint64_t *vtd_leaf(const vtd_unit *u, uint64_t root, uint64_t iova, bool make) {
  uint64_t table = root;
  for (int level = u->levels; level > 1; level--) {
    uint64_t *e = (uint64_t *)phys_to_virt(table) + ((iova >> (12 + 9 * (level - 1))) & 511);
    if (!(*e & (VTD_R | VTD_W))) {
      if (!make) return nullptr;
      uint64_t next = phys_alloc_zeroed(0);
      if (!next) return nullptr;
      if (!(u->ecap & 1))
        for (uint32_t l = 0; l < 4096; l += 64) vtd_flush(u, (uint8_t *)phys_to_virt(next) + l);
      *e = next | VTD_R | VTD_W;
      vtd_flush(u, e);
    }
    table = *e & VTD_ADDR;
  }
  return (uint64_t *)phys_to_virt(table) + ((iova >> 12) & 511);
}

// NOLINTNEXTLINE(misc-no-recursion): as deep as the tables, four levels at most
static void vtd_free_tables(uint64_t table, int level) {
  if (level > 1) {
    const uint64_t *e = phys_to_virt(table);
    for (uint32_t i = 0; i < 512; i++)
      if (e[i] & (VTD_R | VTD_W)) vtd_free_tables(e[i] & VTD_ADDR, level - 1);
  }
  phys_free(table, 0);
}

static bool iommu_map(dma_domain *d, uint64_t iova, const uint64_t *pa, uint64_t pages, uint32_t options) {
  vtd_unit *u = &vtd_units[d->io.unit];
  uint64_t perm = (options & VX_DMA_READ ? VTD_R : 0) | (options & VX_DMA_WRITE ? VTD_W : 0);
  bool ok = true;
  spin_lock(&d->lock); // the tables are the domain's
  for (uint64_t i = 0; i < pages && ok; i++) {
    uint64_t *e = vtd_leaf(u, d->io.root, iova + i * 4096, true);
    if (e) {
      *e = (pa[i] & VTD_ADDR) | perm;
      vtd_flush(u, e);
    }
    ok = e != nullptr;
  }
  spin_unlock(&d->lock);
  vtd_fence();
  vtd_invalidate(u, d->io.did, false); // caching mode caches what was not present, too
  return ok;
}

static void iommu_unmap(dma_domain *d, uint64_t iova, uint64_t pages) {
  vtd_unit *u = &vtd_units[d->io.unit];
  spin_lock(&d->lock);
  for (uint64_t i = 0; i < pages; i++) {
    uint64_t *e = vtd_leaf(u, d->io.root, iova + i * 4096, false);
    if (e) *e = 0, vtd_flush(u, e);
  }
  spin_unlock(&d->lock);
  vtd_fence();
  vtd_invalidate(u, d->io.did, false); // the device cannot reach them when this returns
}

// --- Domains: a device's context entry (§9.3) ---

static vx_status iommu_attach(dma_domain *d) {
  uint32_t ui = vtd_unit_for(d->source);
  if (ui == VTD_MAX_UNITS) return VX_OK; // no IOMMU in front of it: pass-through
  vtd_unit *u = &vtd_units[ui];
  uint8_t bus = (uint8_t)(d->source >> 8), devfn = (uint8_t)d->source;
  uint32_t nd = 1u << (4 + 2 * (u->cap & 7));
  if (nd > 1024) nd = 1024;
  spin_lock(&vtd_domains_lock);
  uint32_t slot = 0;
  while (slot < VTD_MAX_DOMAINS && vtd_domains[slot]) slot++;
  uint16_t did = 0;
  for (uint32_t i = 1; i < nd && !did; i++) // 0 is reserved under caching mode: never used
    if (!(vtd_did_used[ui][i / 64] >> (i % 64) & 1)) did = (uint16_t)i;
  bool taken = false;
  for (uint32_t i = 0; i < VTD_MAX_DOMAINS; i++) // one domain to a device
    taken = taken || (vtd_domains[i] && vtd_domains[i]->source == d->source && vtd_domains[i]->io.on);
  if (slot == VTD_MAX_DOMAINS || !did || taken) {
    spin_unlock(&vtd_domains_lock);
    return taken ? VX_ERR_EXISTS : VX_ERR_NO_MEMORY;
  }
  vtd_did_used[ui][did / 64] |= 1ull << (did % 64);
  vtd_domains[slot] = d;
  spin_unlock(&vtd_domains_lock);
  d->io = (iommu_dom){.on = true, .unit = (uint8_t)ui, .did = did, .root = phys_alloc_zeroed(0)};
  spin_lock(&u->lock);
  if (!u->ctx[bus]) { // this bus's context table, and the root entry naming it
    uint64_t t = phys_alloc_zeroed(0);
    if (t) {
      u->ctx[bus] = phys_to_virt(t);
      for (uint32_t l = 0; l < 4096; l += 64) vtd_flush(u, (uint8_t *)u->ctx[bus] + l);
      uint64_t *r = (uint64_t *)phys_to_virt(u->root) + (size_t)2 * bus;
      r[0] = t | 1;
      vtd_flush(u, r);
    }
  }
  bool ok = d->io.root && u->ctx[bus];
  spin_unlock(&u->lock);
  // The firmware's reserved regions for this device: identity-mapped in it.
  for (uint32_t i = 0; ok && i < vtd_nrmrr; i++) {
    if (vtd_rmrrs[i].rid != d->source) continue;
    for (uint64_t pa = vtd_rmrrs[i].base & ~4095ull; ok && pa <= vtd_rmrrs[i].limit; pa += 4096)
      ok = iommu_map(d, pa, &pa, 1, VX_DMA_READ | VX_DMA_WRITE);
  }
  if (!ok) {
    iommu_detach(d);
    return VX_ERR_NO_MEMORY;
  }
  spin_lock(&u->lock);
  uint64_t *ce = u->ctx[bus] + (size_t)2 * devfn;
  ce[1] = u->aw | (uint64_t)did << 8;
  vtd_flush(u, &ce[1]);
  vtd_fence();
  ce[0] = (d->io.root & VTD_ADDR) | 1; // present, translation type 0: through the tables; faults recorded
  vtd_flush(u, ce);
  spin_unlock(&u->lock);
  vtd_fence();
  vtd_invalidate(u, did, true);
  return VX_OK;
}

static void iommu_detach(dma_domain *d) {
  if (!d->io.on) return;
  vtd_unit *u = &vtd_units[d->io.unit];
  uint8_t bus = (uint8_t)(d->source >> 8), devfn = (uint8_t)d->source;
  spin_lock(&u->lock);
  if (u->ctx[bus]) { // the device's context gone: its DMA faults from here
    uint64_t *ce = u->ctx[bus] + (size_t)2 * devfn;
    if ((ce[1] >> 8 & 0xffff) == d->io.did) {
      ce[0] = 0, ce[1] = 0;
      vtd_flush(u, ce);
    }
  }
  spin_unlock(&u->lock);
  vtd_fence();
  vtd_invalidate(u, d->io.did, true);
  if (d->io.root) vtd_free_tables(d->io.root, u->levels);
  spin_lock(&vtd_domains_lock);
  for (uint32_t i = 0; i < VTD_MAX_DOMAINS; i++)
    if (vtd_domains[i] == d) vtd_domains[i] = nullptr;
  vtd_did_used[d->io.unit][d->io.did / 64] &= ~(1ull << (d->io.did % 64));
  spin_unlock(&vtd_domains_lock);
  d->io = (iommu_dom){};
}

// --- Faults (§7.2) ---

// The fault interrupt: each recorded fault counted against its device's domain.
static void vtd_fault_interrupt(void) {
  for (uint32_t ui = 0; ui < vtd_nunits; ui++) {
    vtd_unit *u = &vtd_units[ui];
    uint32_t fsts = vtd_r32(u, VTD_FSTS);
    if (!(fsts & 3)) continue; // neither a pending fault nor an overflow
    uint32_t fro = (uint32_t)((u->cap >> 24) & 0x3ff) * 16, nfr = (uint32_t)((u->cap >> 40) & 0xff) + 1;
    for (uint32_t n = 0, i = (fsts >> 8) & 0xff; n < nfr; n++, i = (i + 1) % nfr) {
      uint64_t hi = vtd_r64(u, fro + 16 * i + 8);
      if (!(hi >> 63)) break; // no fault recorded here
      uint32_t rid = (uint32_t)(hi & 0xffff), reason = (uint32_t)(hi >> 32 & 0xff);
      uint64_t addr = vtd_r64(u, fro + 16 * i) & ~4095ull;
      vtd_w32(u, fro + 16 * i + 12, 1u << 31); // the record's F, cleared
      kput(VX_STR("vx: iommu: a fault from "));
      kput_hex(rid);
      kput(VX_STR(" at "));
      kput_hex(addr);
      kput(VX_STR(", reason "));
      kput_u64(reason);
      kput(VX_STR("\n"));
      spin_lock(&vtd_domains_lock);
      dma_domain *d = nullptr;
      for (uint32_t k = 0; k < VTD_MAX_DOMAINS && !d; k++)
        if (vtd_domains[k] && vtd_domains[k]->source == rid && vtd_domains[k]->io.unit == ui)
          d = vtd_domains[k];
      if (d) object_ref(&d->obj);
      spin_unlock(&vtd_domains_lock);
      if (d) {
        dma_fault(d);
        object_drop(&d->obj);
      }
    }
    vtd_w32(u, VTD_FSTS, fsts & 3); // PFO and PPF, write 1 to clear
  }
}

// --- Bringing the units up ---

static void vtd_unit_init(vtd_unit *u) {
  u->cap = vtd_r64(u, VTD_CAP), u->ecap = vtd_r64(u, VTD_ECAP);
  uint32_t sagaw = (uint32_t)(u->cap >> 8) & 0x1f;
  if (sagaw & 4)
    u->levels = 4, u->aw = 2;
  else if (sagaw & 2)
    u->levels = 3, u->aw = 1;
  else
    panic(VX_STR("vtd: no 3- or 4-level tables"));
  // Off first (the firmware's), then the empty root table: deny-all.
  if (vtd_r32(u, VTD_GSTS) & GCMD_TE) vtd_command(u, GCMD_TE, false);
  u->root = phys_alloc_zeroed(0);
  if (!u->root) panic(VX_STR("vtd: no memory"));
  for (uint32_t l = 0; l < 4096; l += 64) vtd_flush(u, (uint8_t *)phys_to_virt(u->root) + l);
  if (u->ecap & 2) { // ECAP.QI: the invalidation queue, one page (256 descriptors)
    u->iq = phys_alloc_zeroed(0);
    u->iq_status_pa = phys_alloc_zeroed(0);
    u->iq_status = u->iq_status_pa ? phys_to_virt(u->iq_status_pa) : nullptr;
    if (u->iq && !u->iq_status) u->iq = 0;
    if (u->iq) {
      vtd_w64(u, VTD_IQT, 0);
      vtd_w64(u, VTD_IQA, u->iq); // QS 0: one page; 128-bit descriptors
      if (!vtd_command(u, GCMD_QIE, true)) u->iq = 0;
    }
  }
  vtd_w64(u, VTD_RTADDR, u->root); // legacy mode (TTM 0)
  if (!vtd_one_shot(u, GCMD_SRTP)) panic(VX_STR("vtd: the root table was not taken"));
  vtd_invalidate(u, 0, true);
  // Faults, to the boot CPU (compatibility format: no interrupt remapping).
  vtd_w32(u, VTD_FEDATA, VECTOR_IOMMU);
  vtd_w32(u, VTD_FEADDR, 0xfee0'0000 | (uint32_t)(cpus[0].arch_id << 12));
  vtd_w32(u, VTD_FEUADDR, 0);
  vtd_w32(u, VTD_FECTL, 0); // unmasked
  if (!vtd_command(u, GCMD_TE, true)) panic(VX_STR("vtd: translation would not turn on"));
}

// The DMAR table's units and reserved regions, and translation on: called
// at boot, before the root task starts, so no driver ever runs without it.
static void iommu_init(void) {
  const uint8_t *mcfg = acpi_table("MCFG");
  if (mcfg && read32(mcfg + 4) >= 44 + 16) { // the first window, for scope paths
    memcpy(&vtd_ecam_base, mcfg + 44, 8);
    vtd_ecam_start = mcfg[44 + 10], vtd_ecam_end = mcfg[44 + 11];
  }
  const uint8_t *dmar = acpi_table("DMAR");
  if (!dmar) return; // no VT-d: pass-through, as before (docs/milestones/known-gaps.md)
  uint32_t len = read32(dmar + 4);
  for (uint32_t off = 48; off + 4 <= len;) {
    uint16_t type, slen;
    memcpy(&type, dmar + off, 2), memcpy(&slen, dmar + off + 2, 2);
    if (slen < 4 || off + slen > len) break;
    const uint8_t *s = dmar + off;
    if (type == 0 && slen >= 16 && vtd_nunits < VTD_MAX_UNITS) { // DRHD
      vtd_unit *u = &vtd_units[vtd_nunits];
      uint64_t base;
      memcpy(&base, s + 8, 8);
      memcpy(&u->segment, s + 6, 2);
      u->all = s[4] & 1;
      uint64_t size = 4096ull << (s[5] & 0xf);
      if (size > 16ull * 4096) size = 16ull * 4096;
      if (!map_range(kernel_root, boot.hhdm + base, base, size, MAP_WRITE | MAP_DEVICE))
        panic(VX_STR("vtd: cannot map a unit's registers"));
      u->regs = (volatile uint8_t *)(boot.hhdm + base);
      for (uint32_t at = 16; at + 6 <= slen && s[at + 1] >= 6 && at + s[at + 1] <= slen; at += s[at + 1])
        vtd_scope(u, s + at, s[at + 1], false, 0, 0);
      vtd_nunits++;
    } else if (type == 1 && slen >= 24) { // RMRR
      uint64_t base, limit;
      memcpy(&base, s + 8, 8), memcpy(&limit, s + 16, 8);
      for (uint32_t at = 24; at + 6 <= slen && s[at + 1] >= 6 && at + s[at + 1] <= slen; at += s[at + 1])
        vtd_scope(nullptr, s + at, s[at + 1], true, base, limit);
    }
    off += slen;
  }
  for (uint32_t i = 0; i < vtd_nunits; i++) vtd_unit_init(&vtd_units[i]);
  kput(VX_STR("vx: VT-d: "));
  kput_u64(vtd_nunits);
  kput(vtd_nunits == 1 ? VX_STR(" unit") : VX_STR(" units"));
  if (vtd_nunits && vtd_units[0].iq) kput(VX_STR(", queued invalidation"));
  if (vtd_nunits && vtd_units[0].cap >> 7 & 1) kput(VX_STR(", caching mode"));
  kput(VX_STR(", deny-all\n"));
}
