// smmuv3.c: the Arm SMMUv3, the aarch64 IOMMU (SMMUv3 architecture,
// IHI 0070; docs/01 §7.1, §10). The kernel finds it in the firmware's IORT
// table at boot, with each PCI root complex's map from requester IDs to
// stream IDs, and turns it on before any driver runs with every stream
// aborting: no device can DMA until devmgr gives it a domain
// (dma_domain_create, obj/device.c).
//
// A domain is stage 1: a context descriptor with an ASID of its own, and
// LPAE tables with a 4 KiB granule over 39 bits (three levels). A stream
// with a domain has an STE naming its descriptor; every other stream's
// STE aborts. Stage 1 cannot give a device write without read, so a
// mapping the device may write is read-write too. Since a device's MSIs are
// writes to the GIC ITS's doorbell, every domain maps that page at its own
// address, or a translated device could not interrupt.
//
// The stream table is two-level where the SMMU has that (each bus's 256
// STEs a table of their own, made when a device on it gets a domain), else
// one level of 256 STEs. Commands go through the command queue, each batch
// closed by CMD_SYNC and waited for; every change to the tables is
// invalidated before the call returns. Faults come through the event
// queue, on its wired interrupt, and are counted against the domain whose
// stream they name (dma_fault). A SMMU that does not snoop (no IDR0.COHACC)
// has each table line it reads cleaned from the CPU's caches.
//
// Fuchsia has no SMMUv3; its SMMUv2 design notes were the comparison: lock
// everything down at start, and choose abort, never read-as-zero, for a
// block device's faults.

static constexpr uint32_t SMMU_MAX_DOMAINS = 128, SMMU_MAX_MAPS = 16;

// Registers (§6.3), page 0 unless said.
enum : uint32_t {
  SMMU_IDR0 = 0x00,
  SMMU_IDR1 = 0x04,
  SMMU_IDR5 = 0x14,
  SMMU_CR0 = 0x20,
  SMMU_CR0ACK = 0x24,
  SMMU_CR1 = 0x28,
  SMMU_CR2 = 0x2c,
  SMMU_GBPA = 0x44,
  SMMU_IRQ_CTRL = 0x50,
  SMMU_IRQ_CTRLACK = 0x54,
  SMMU_GERROR = 0x60,
  SMMU_STRTAB_BASE = 0x80,
  SMMU_STRTAB_BASE_CFG = 0x88,
  SMMU_CMDQ_BASE = 0x90,
  SMMU_CMDQ_PROD = 0x98,
  SMMU_CMDQ_CONS = 0x9c,
  SMMU_EVENTQ_BASE = 0xa0,
  SMMU_EVENTQ_PROD = 0x100a8, // page 1
  SMMU_EVENTQ_CONS = 0x100ac,
};
enum : uint32_t { CR0_SMMUEN = 1, CR0_EVTQEN = 4, CR0_CMDQEN = 8 };
static constexpr uint32_t CMDQ_LOG2 = 8, EVTQ_LOG2 = 7;

typedef struct smmu_map { // a root complex's requester IDs [rid, rid + count) to streams from sid
  uint32_t rid, count, sid;
} smmu_map;

typedef struct smmu {
  volatile uint8_t *regs;
  uint32_t idr0, sid_bits, oas;
  bool two_level, coherent, asid16;
  uint64_t strtab;     // the stream table: level 1 (two-level) or the STEs (linear), physical
  uint64_t *l2[256];   // two-level: each bus's 256 STEs (direct map), once made
  uint64_t cmdq, evtq; // physical
  uint32_t cmdq_prod, evtq_cons;
  uint32_t event_intid; // the event queue's wired interrupt, or 0
  smmu_map maps[SMMU_MAX_MAPS];
  uint32_t nmaps;
  spinlock lock;
} smmu;

static smmu smmu0; // one SMMU here; QEMU's virt has one
static bool smmu_on;
static struct dma_domain *smmu_domains[SMMU_MAX_DOMAINS];
static spinlock smmu_domains_lock;
static uint64_t smmu_asids[65536 / 64];

static void arch_kernel_spi(uint32_t line, bool edge); // arch.c: the kernel's own interrupt line
static uint64_t arch_msi_doorbell(void);               // arch.c: the page a device's MSIs write

static uint32_t smmu_r32(uint32_t at) { return *(volatile uint32_t *)(smmu0.regs + at); }
static void smmu_w32(uint32_t at, uint32_t v) { *(volatile uint32_t *)(smmu0.regs + at) = v; }
static void smmu_w64(uint32_t at, uint64_t v) { *(volatile uint64_t *)(smmu0.regs + at) = v; }

// A line the SMMU reads, out of the CPU's caches if it does not snoop; then
// the stores ordered before the SMMU is told.
static void smmu_clean(const void *p) {
  if (!smmu0.coherent) __asm__ volatile("dc cvac, %0" ::"r"(p) : "memory");
}
static void smmu_barrier(void) { __asm__ volatile("dsb sy" ::: "memory"); }

static bool smmu_cr0(uint32_t value) {
  smmu_w32(SMMU_CR0, value);
  for (uint32_t spins = 0; spins < 10'000'000; spins++)
    if (smmu_r32(SMMU_CR0ACK) == value) return true;
  return false;
}

// --- The command queue (§4) ---

static void smmu_cmd(uint64_t lo, uint64_t hi) { // under the lock; the caller syncs
  uint32_t mask = (1u << CMDQ_LOG2) - 1, wrap = 1u << CMDQ_LOG2;
  for (uint32_t spins = 0; spins < 100'000'000; spins++) { // room: prod not a whole queue ahead of cons
    uint32_t cons = smmu_r32(SMMU_CMDQ_CONS);
    if ((smmu0.cmdq_prod & mask) != (cons & mask) || (smmu0.cmdq_prod & wrap) == (cons & wrap)) break;
  }
  uint64_t *q = phys_to_virt(smmu0.cmdq);
  q[2 * (size_t)(smmu0.cmdq_prod & mask)] = lo, q[2 * (size_t)(smmu0.cmdq_prod & mask) + 1] = hi;
  smmu_clean(&q[2 * (size_t)(smmu0.cmdq_prod & mask)]);
  smmu0.cmdq_prod = (smmu0.cmdq_prod + 1) & (2 * wrap - 1);
}

static void smmu_sync(void) { // under the lock: everything queued so far done when it returns
  smmu_cmd(0x46, 0);          // CMD_SYNC, no completion signal: CONS is watched
  smmu_barrier();
  smmu_w32(SMMU_CMDQ_PROD, smmu0.cmdq_prod);
  for (uint32_t spins = 0; spins < 100'000'000; spins++) {
    uint32_t cons = smmu_r32(SMMU_CMDQ_CONS);
    if ((cons & ((2u << CMDQ_LOG2) - 1)) == smmu0.cmdq_prod) return;
    if (cons >> 24 & 0x7f) return; // an error: the queue stops (reported in GERROR)
  }
}

// --- Streams ---

static bool smmu_sid_for(uint32_t rid, uint32_t *sid) {
  for (uint32_t i = 0; i < smmu0.nmaps; i++)
    if (rid >= smmu0.maps[i].rid && rid - smmu0.maps[i].rid < smmu0.maps[i].count) {
      *sid = smmu0.maps[i].sid + (rid - smmu0.maps[i].rid);
      return *sid < (1u << smmu0.sid_bits);
    }
  return false;
}

// The STE for sid, its level-2 table made if need be; nullptr if it cannot be.
static uint64_t *smmu_ste(uint32_t sid) {
  if (!smmu0.two_level) return sid < 256 ? (uint64_t *)phys_to_virt(smmu0.strtab) + 8 * (size_t)sid : nullptr;
  uint32_t hi = sid >> 8;
  if (hi >= 256) return nullptr;
  if (!smmu0.l2[hi]) {
    uint64_t t = phys_alloc_zeroed(2); // 256 STEs of 64 bytes
    if (!t) return nullptr;
    uint64_t *stes = phys_to_virt(t);
    for (uint32_t i = 0; i < 256; i++) stes[8 * (size_t)i] = 1; // valid, Config 0: abort
    for (uint32_t l = 0; l < 16384; l += 64) smmu_clean((uint8_t *)stes + l);
    smmu0.l2[hi] = stes;
    uint64_t *l1 = (uint64_t *)phys_to_virt(smmu0.strtab) + hi;
    *l1 = t | 9; // Span 9: 2^(9 - 1) = 256 STEs
    smmu_clean(l1);
    smmu_barrier();
    smmu_cmd(0x04, 31); // CFGI_ALL: the level-1 descriptor is new
  }
  return smmu0.l2[hi] + 8 * (size_t)(sid & 0xff);
}

// --- Stage-1 tables (LPAE, 4 KiB granule, 39 bits: levels 1 to 3) ---

static constexpr uint64_t SMMU_PTE_ADDR = 0x0000'ffff'ffff'f000;

static uint64_t *smmu_leaf(uint64_t root, uint64_t iova, bool make) {
  uint64_t table = root;
  for (int level = 1; level < 3; level++) {
    uint64_t *e = (uint64_t *)phys_to_virt(table) + ((iova >> (39 - 9 * level)) & 511);
    if (!(*e & 1)) {
      if (!make) return nullptr;
      uint64_t next = phys_alloc_zeroed(0);
      if (!next) return nullptr;
      for (uint32_t l = 0; !smmu0.coherent && l < 4096; l += 64)
        smmu_clean((uint8_t *)phys_to_virt(next) + l);
      *e = next | 3; // a table
      smmu_clean(e);
    }
    table = *e & SMMU_PTE_ADDR;
  }
  return (uint64_t *)phys_to_virt(table) + ((iova >> 12) & 511);
}

// NOLINTNEXTLINE(misc-no-recursion): three levels
static void smmu_free_tables(uint64_t table, int level) {
  if (level < 3) {
    const uint64_t *e = phys_to_virt(table);
    for (uint32_t i = 0; i < 512; i++)
      if (e[i] & 1) smmu_free_tables(e[i] & SMMU_PTE_ADDR, level + 1);
  }
  phys_free(table, 0);
}

static void smmu_tlbi(uint16_t asid) {
  spin_lock(&smmu0.lock);
  smmu_cmd(0x11 | (uint64_t)asid << 48, 0); // TLBI_NH_ASID
  smmu_sync();
  spin_unlock(&smmu0.lock);
}

static bool iommu_map(dma_domain *d, uint64_t iova, const uint64_t *pa, uint64_t pages, uint32_t options) {
  // A page: valid, accessed, inner shareable, normal memory (MAIR index 0),
  // never executed; read-only, or read-write (stage 1 has no write-only),
  // and reachable unprivileged, as a device's transactions are.
  uint64_t ap = options & VX_DMA_WRITE ? 1u << 6 : 3u << 6;
  uint64_t attrs = 3 | 1u << 10 | 3u << 8 | ap | 1ull << 53 | 1ull << 54;
  bool ok = true;
  spin_lock(&d->lock);
  for (uint64_t i = 0; i < pages && ok; i++) {
    uint64_t *e = smmu_leaf(d->io.root, iova + i * 4096, true);
    if (e) {
      *e = (pa[i] & SMMU_PTE_ADDR) | attrs;
      smmu_clean(e);
    }
    ok = e != nullptr;
  }
  spin_unlock(&d->lock);
  smmu_barrier();
  smmu_tlbi(d->io.did);
  return ok;
}

static void iommu_unmap(dma_domain *d, uint64_t iova, uint64_t pages) {
  spin_lock(&d->lock);
  for (uint64_t i = 0; i < pages; i++) {
    uint64_t *e = smmu_leaf(d->io.root, iova + i * 4096, false);
    if (e) *e = 0, smmu_clean(e);
  }
  spin_unlock(&d->lock);
  smmu_barrier();
  smmu_tlbi(d->io.did); // the device cannot reach them when this returns
}

// --- Domains: a stream's STE and context descriptor (§5.2, §5.4) ---

static vx_status iommu_attach(dma_domain *d) {
  uint32_t sid;
  if (!smmu_on || !smmu_sid_for(d->source, &sid)) return VX_OK; // no SMMU in front of it: pass-through
  spin_lock(&smmu_domains_lock);
  uint32_t slot = 0;
  while (slot < SMMU_MAX_DOMAINS && smmu_domains[slot]) slot++;
  bool taken = false;
  for (uint32_t i = 0; i < SMMU_MAX_DOMAINS; i++)
    taken = taken || (smmu_domains[i] && smmu_domains[i]->source == d->source);
  uint32_t nasid = smmu0.asid16 ? 65536 : 256, asid = 0;
  for (uint32_t i = 1; i < nasid && !asid; i++)
    if (!(smmu_asids[i / 64] >> (i % 64) & 1)) asid = i;
  if (slot == SMMU_MAX_DOMAINS || !asid || taken) {
    spin_unlock(&smmu_domains_lock);
    return taken ? VX_ERR_EXISTS : VX_ERR_NO_MEMORY;
  }
  smmu_asids[asid / 64] |= 1ull << (asid % 64);
  smmu_domains[slot] = d;
  spin_unlock(&smmu_domains_lock);
  d->io = (iommu_dom){
      .on = true, .did = (uint16_t)asid, .root = phys_alloc_zeroed(0), .ctx = phys_alloc_zeroed(0)};
  // The ITS doorbell, where the device's MSIs go, at its own address.
  uint64_t bell = arch_msi_doorbell();
  bool ok = d->io.root && d->io.ctx && (!bell || iommu_map(d, bell, &bell, 1, VX_DMA_WRITE));
  if (!ok) {
    iommu_detach(d);
    return VX_ERR_NO_MEMORY;
  }
  // The context descriptor: TTB0 the tables, 39 bits, 4 KiB, cached and
  // inner shareable walks, TTB1 off, AArch64, faults recorded and aborted.
  uint64_t *cd = phys_to_virt(d->io.ctx);
  cd[1] = d->io.root & SMMU_PTE_ADDR;
  cd[3] = 0xff; // MAIR: attribute 0, normal write-back memory
  smmu_clean(cd);
  smmu_barrier();
  cd[0] = 25 | 1u << 8 | 1u << 10 | 3u << 12 | 1u << 30 | 1u << 31 | (uint64_t)smmu0.oas << 32 | 1ull << 41 |
          1ull << 45 | 1ull << 46 | (uint64_t)asid << 48;
  smmu_clean(cd);
  smmu_barrier();
  spin_lock(&smmu0.lock);
  uint64_t *ste = smmu_ste(sid);
  if (ste) {
    ste[1] = 1u << 2 | 1u << 4 | 3u << 6 |
             1ull << 44; // the CD's fetch: write-back, inner shareable; SHCFG incoming
    smmu_clean(ste);
    smmu_barrier();
    ste[0] = 1 | 5u << 1 | (d->io.ctx & 0x000f'ffff'ffff'ffc0); // valid, stage 1 translate, one CD
    smmu_clean(ste);
    smmu_barrier();
    smmu_cmd(0x03 | (uint64_t)sid << 32, 1); // CFGI_STE, leaf
    smmu_cmd(0x11 | (uint64_t)asid << 48, 0);
    smmu_sync();
  }
  spin_unlock(&smmu0.lock);
  if (!ste) {
    iommu_detach(d);
    return VX_ERR_NO_MEMORY;
  }
  return VX_OK;
}

static void iommu_detach(dma_domain *d) {
  if (!d->io.on) return;
  uint32_t sid;
  spin_lock(&smmu0.lock);
  uint64_t *ste = smmu_sid_for(d->source, &sid) ? smmu_ste(sid) : nullptr;
  if (ste && (ste[0] & 0x000f'ffff'ffff'ffc0) == (d->io.ctx & 0x000f'ffff'ffff'ffc0)) { // abort from here
    ste[0] = 1;
    smmu_clean(ste);
    smmu_barrier();
    smmu_cmd(0x03 | (uint64_t)sid << 32, 1);
  }
  smmu_cmd(0x11 | (uint64_t)d->io.did << 48, 0);
  smmu_sync();
  spin_unlock(&smmu0.lock);
  if (d->io.root) smmu_free_tables(d->io.root, 1);
  if (d->io.ctx) phys_free(d->io.ctx, 0);
  spin_lock(&smmu_domains_lock);
  for (uint32_t i = 0; i < SMMU_MAX_DOMAINS; i++)
    if (smmu_domains[i] == d) smmu_domains[i] = nullptr;
  smmu_asids[d->io.did / 64] &= ~(1ull << (d->io.did % 64));
  spin_unlock(&smmu_domains_lock);
  d->io = (iommu_dom){};
}

// --- Faults: the event queue (§7) ---

static void smmu_event_interrupt(void) {
  uint32_t mask = (1u << EVTQ_LOG2) - 1, wrap2 = (2u << EVTQ_LOG2) - 1;
  const uint64_t *q = phys_to_virt(smmu0.evtq);
  for (uint32_t n = 0; n <= mask; n++) {
    uint32_t prod = *(volatile uint32_t *)(smmu0.regs + SMMU_EVENTQ_PROD) & wrap2;
    if (prod == (smmu0.evtq_cons & wrap2)) break;
    const uint64_t *e = q + 4 * (size_t)(smmu0.evtq_cons & mask);
    if (!smmu0.coherent) __asm__ volatile("dc ivac, %0" ::"r"(e) : "memory");
    uint32_t type = (uint32_t)(e[0] & 0xff), sid = (uint32_t)(e[0] >> 32);
    uint64_t addr = e[2];
    smmu0.evtq_cons = (smmu0.evtq_cons + 1) & wrap2;
    kput(VX_STR("vx: iommu: event "));
    kput_hex(type);
    kput(VX_STR(" from stream "));
    kput_hex(sid);
    kput(VX_STR(" at "));
    kput_hex(addr);
    kput(VX_STR("\n"));
    spin_lock(&smmu_domains_lock);
    dma_domain *d = nullptr;
    for (uint32_t k = 0; k < SMMU_MAX_DOMAINS && !d; k++) {
      uint32_t s;
      if (smmu_domains[k] && smmu_sid_for(smmu_domains[k]->source, &s) && s == sid) d = smmu_domains[k];
    }
    if (d) object_ref(&d->obj);
    spin_unlock(&smmu_domains_lock);
    if (d) {
      dma_fault(d);
      object_drop(&d->obj);
    }
  }
  *(volatile uint32_t *)(smmu0.regs + SMMU_EVENTQ_CONS) = smmu0.evtq_cons;
}

// --- Bringing it up ---

// The IORT (DEN 0049): the first SMMUv3, and the root complexes' maps to it.
static uint64_t smmu_from_iort(void) {
  const uint8_t *iort = acpi_table("IORT");
  if (!iort) return 0;
  uint32_t len = read32(iort + 4), nodes = read32(iort + 36), off = read32(iort + 40);
  uint32_t smmu_off = 0;
  uint64_t base = 0;
  for (uint32_t i = 0, at = off; i < nodes && at + 16 <= len; i++) { // the SMMUv3 node first
    uint16_t nlen;
    memcpy(&nlen, iort + at + 1, 2);
    if (nlen < 16 || at + nlen > len) break;
    if (iort[at] == 4 && nlen >= 60 && !base) {
      base = read64(iort + at + 16);
      smmu0.event_intid = read32(iort + at + 44);
      smmu_off = at;
    }
    at += nlen;
  }
  if (!base) return 0;
  for (uint32_t i = 0, at = off; i < nodes && at + 16 <= len; i++) { // root complexes' IDs to it
    uint16_t nlen;
    memcpy(&nlen, iort + at + 1, 2);
    if (nlen < 16 || at + nlen > len) break;
    uint32_t nids = read32(iort + at + 8), ids = read32(iort + at + 12);
    for (uint32_t k = 0;
         iort[at] == 2 && k < nids && ids + 20 * (k + 1) <= nlen && smmu0.nmaps < SMMU_MAX_MAPS; k++) {
      const uint8_t *m = iort + at + ids + (size_t)20 * k;
      if (read32(m + 12) != smmu_off) continue;
      smmu0.maps[smmu0.nmaps++] =
          (smmu_map){.rid = read32(m), .count = read32(m + 4) + 1, .sid = read32(m + 8)};
    }
    at += nlen;
  }
  return base;
}

static void iommu_init(void) {
  uint64_t base = smmu_from_iort();
  if (!base) return; // no SMMUv3: pass-through, as before (docs/milestones.md)
  if (!map_range(kernel_root, boot.hhdm + base, base, 128ull * 1024, MAP_WRITE | MAP_DEVICE))
    panic(VX_STR("smmu: cannot map its registers"));
  smmu0.regs = (volatile uint8_t *)(boot.hhdm + base);
  smmu0.idr0 = smmu_r32(SMMU_IDR0);
  if (!(smmu0.idr0 & 2) || ((smmu0.idr0 >> 2) & 3) == 1) panic(VX_STR("smmu: no AArch64 stage 1"));
  smmu0.two_level = ((smmu0.idr0 >> 27) & 3) >= 1;
  smmu0.coherent = smmu0.idr0 & (1u << 4);
  smmu0.asid16 = smmu0.idr0 & (1u << 12);
  smmu0.sid_bits = smmu_r32(SMMU_IDR1) & 0x3f;
  if (smmu0.sid_bits > 16) smmu0.sid_bits = 16;
  smmu0.oas = smmu_r32(SMMU_IDR5) & 7;
  // Off first, and aborting while off, then the tables and queues.
  smmu_cr0(0);
  smmu_w32(SMMU_GBPA, 1u << 31 | 1u << 20); // UPDATE, ABORT
  for (uint32_t spins = 0; spins < 10'000'000 && smmu_r32(SMMU_GBPA) >> 31; spins++) {}
  if (smmu0.two_level) { // level 1: 256 descriptors, each a bus's 256 STEs, none yet (span 0)
    smmu0.strtab = phys_alloc_zeroed(0);
    smmu_w64(SMMU_STRTAB_BASE, smmu0.strtab | 1ull << 62);
    uint32_t bits = smmu0.sid_bits < 9 ? 9 : smmu0.sid_bits;   // at most 16: 256 level-1 descriptors
    smmu_w32(SMMU_STRTAB_BASE_CFG, 1u << 16 | 8u << 6 | bits); // two-level, split 8
  } else {                                                     // linear: 256 STEs, every one aborting
    smmu0.strtab = phys_alloc_zeroed(2);
    if (smmu0.strtab)
      for (uint32_t i = 0; i < 256; i++) ((uint64_t *)phys_to_virt(smmu0.strtab))[8 * (size_t)i] = 1;
    smmu_w64(SMMU_STRTAB_BASE, smmu0.strtab | 1ull << 62);
    smmu_w32(SMMU_STRTAB_BASE_CFG, 8);
  }
  smmu0.cmdq = phys_alloc_zeroed(0), smmu0.evtq = phys_alloc_zeroed(0);
  if (!smmu0.strtab || !smmu0.cmdq || !smmu0.evtq) panic(VX_STR("smmu: no memory"));
  for (uint32_t l = 0; !smmu0.coherent && l < 16384; l += 64)
    smmu_clean((uint8_t *)phys_to_virt(smmu0.strtab) + l);
  smmu_w64(SMMU_CMDQ_BASE, 1ull << 62 | smmu0.cmdq | CMDQ_LOG2);
  smmu_w32(SMMU_CMDQ_PROD, 0), smmu_w32(SMMU_CMDQ_CONS, 0);
  smmu_w64(SMMU_EVENTQ_BASE, 1ull << 62 | smmu0.evtq | EVTQ_LOG2);
  *(volatile uint32_t *)(smmu0.regs + SMMU_EVENTQ_PROD) = 0;
  *(volatile uint32_t *)(smmu0.regs + SMMU_EVENTQ_CONS) = 0;
  // Queues and tables cached, inner shareable; invalid stream IDs recorded.
  smmu_w32(SMMU_CR1, 3u << 10 | 1u << 8 | 1u << 6 | 3u << 4 | 1u << 2 | 1u);
  smmu_w32(SMMU_CR2, 1u << 1 | 1u << 2); // RECINVSID, PTM
  if (!smmu_cr0(CR0_CMDQEN)) panic(VX_STR("smmu: the command queue would not start"));
  spin_lock(&smmu0.lock);
  smmu_cmd(0x04, 31); // CFGI_ALL
  smmu_cmd(0x10, 0);  // TLBI_NH_ALL
  smmu_sync();
  spin_unlock(&smmu0.lock);
  if (!smmu_cr0(CR0_CMDQEN | CR0_EVTQEN)) panic(VX_STR("smmu: the event queue would not start"));
  if (smmu0.event_intid >= 32) {
    arch_kernel_spi(smmu0.event_intid, true);
    smmu_w32(SMMU_IRQ_CTRL, 1u << 2); // EVENTQ_IRQEN, wired (no MSI configured)
  }
  if (!smmu_cr0(CR0_CMDQEN | CR0_EVTQEN | CR0_SMMUEN)) panic(VX_STR("smmu: translation would not turn on"));
  smmu_on = true;
  kput(VX_STR("vx: SMMUv3: "));
  kput(smmu0.two_level ? VX_STR("two-level") : VX_STR("linear"));
  kput(VX_STR(" stream table, "));
  kput_u64(smmu0.nmaps);
  kput(smmu0.nmaps == 1 ? VX_STR(" root complex") : VX_STR(" root complexes"));
  kput(VX_STR(", deny-all\n"));
}
