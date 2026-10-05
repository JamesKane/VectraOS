// arch.c (aarch64): the entry point, the early serial console (a PL011),
// exceptions and page-table entries.
//
// Limine's direct map covers RAM only (base revision 3 and later), so the
// console maps the UART's registers itself: one 4 KiB device page at
// hhdm + its physical address, first in Limine's page tables and then in the
// kernel's own. Device pages use MAIR attribute 2; Limine guarantees that
// attributes 2 to 7 are unused. The UART is at QEMU virt's address until the
// kernel reads the device tree.

static constexpr uint64_t PL011_PHYS = 0x0900'0000;
static constexpr uint64_t PL011_DR = 0x00 / 4;     // data register, as a u32 index
static constexpr uint64_t PL011_FR = 0x18 / 4;     // flag register
static constexpr uint32_t PL011_FR_TXFF = 1u << 5; // transmit FIFO full

static volatile uint32_t *pl011;

// --- Page tables ---

static constexpr uint64_t PTE_VALID = 1ull << 0;
static constexpr uint64_t PTE_TABLE = 1ull << 1;     // a table at levels 0-2, a page at level 3
static constexpr uint64_t PTE_DEVICE = 2ull << 2;    // MAIR index 2; index 0 is normal write-back memory
static constexpr uint64_t PTE_USER = 1ull << 6;      // AP[1]
static constexpr uint64_t PTE_READ_ONLY = 1ull << 7; // AP[2]
static constexpr uint64_t PTE_SH_INNER = 3ull << 8;
static constexpr uint64_t PTE_AF = 1ull << 10;
static constexpr uint64_t PTE_NG = 1ull << 11; // not global: user mappings belong to one address space
static constexpr uint64_t PTE_PXN = 1ull << 53;
static constexpr uint64_t PTE_UXN = 1ull << 54;
static constexpr uint64_t PTE_ADDR = 0x0000'ffff'ffff'f000;

static bool arch_pte_valid(uint64_t e) { return e & PTE_VALID; }
static bool arch_pte_is_table(uint64_t e, int level) { return level < 3 && (e & PTE_TABLE); }
static uint64_t arch_pte_addr(uint64_t e) { return e & PTE_ADDR; }
static uint64_t arch_pte_table(uint64_t pa) { return pa | PTE_TABLE | PTE_VALID; }

static uint64_t arch_pte_leaf(uint64_t pa, uint32_t flags, int level) {
  uint64_t e = pa | PTE_AF | PTE_VALID | (level == 3 ? PTE_TABLE : 0);
  e |= flags & MAP_DEVICE ? PTE_DEVICE : PTE_SH_INNER;
  if (!(flags & MAP_WRITE)) e |= PTE_READ_ONLY;
  if (flags & MAP_USER) {
    e |= PTE_USER | PTE_NG | PTE_PXN; // the kernel never executes user pages
    if (!(flags & MAP_EXEC)) e |= PTE_UXN;
  } else {
    e |= PTE_UXN;
    if (!(flags & MAP_EXEC)) e |= PTE_PXN;
  }
  return e;
}

static inline uint64_t read_ttbr1(void) {
  uint64_t v;
  __asm__ volatile("mrs %0, ttbr1_el1" : "=r"(v));
  return v;
}

static inline uint64_t read_mair(void) {
  uint64_t v;
  __asm__ volatile("mrs %0, mair_el1" : "=r"(v));
  return v;
}

static inline void write_mair(uint64_t v) {
  __asm__ volatile("msr mair_el1, %0\n\tisb" : : "r"(v) : "memory");
}

// The GICv3, at QEMU virt's addresses until the kernel reads the device tree:
// the distributor, and one 128 KiB redistributor frame per CPU.
static constexpr uint64_t GICD_PHYS = 0x0800'0000;
static constexpr uint64_t GICD_SIZE = 0x1'0000;
static constexpr uint64_t GICR_PHYS = 0x080a'0000;
static constexpr uint64_t GICR_FRAME_SIZE = 0x2'0000;
// MSIs are LPIs, through the ITS (below).
static constexpr uint64_t ITS_PHYS_DEFAULT = 0x0808'0000; // QEMU virt's, if the MADT has none
static constexpr uint32_t LPI_BASE = 8192, LPI_COUNT = 1024;
static constexpr uint32_t LPI_ID_BITS = 14; // INTIDs up to 2^14: LPIs 8192..16383
static constexpr uint32_t ITS_EVENTS = 32;  // per device

static uint8_t *boot_rd; // the boot CPU's redistributor

[[noreturn]] static void arch_run_on_stack(uint64_t top, void (*fn)(void)) {
  __asm__ volatile("mov sp, %0\n\tmov x29, xzr\n\tblr %1\n\tbrk #0" : : "r"(top), "r"(fn) : "memory");
  __builtin_unreachable();
}

// The user half has its own tables in TTBR0; the kernel's stay in TTBR1.
static uint64_t arch_new_user_root(void) { return phys_alloc_zeroed(0); }

// Without ASIDs yet, switching address spaces drops every cached translation.
static uint64_t empty_user_root; // TTBR0 while a CPU runs no task, shared by all

// Loads a task's tables into TTBR0, or with root 0 (no task, as for the idle
// thread) the empty table.
static void arch_switch_user_root(uint64_t root) {
  if (!root) root = empty_user_root;
  __asm__ volatile("msr ttbr0_el1, %0\n\t"
                   "isb\n\t"
                   "tlbi vmalle1\n\t"
                   "dsb ish\n\t"
                   "isb"
                   :
                   : "r"(root)
                   : "memory");
}

static uint32_t arch_user_top_slots(void) { return 512; }

// A descriptor written by a store is only certain to be seen by the table
// walker after a DSB, and by this CPU's later instructions after an ISB.
static void arch_pte_publish(void) { __asm__ volatile("dsb ishst\n\tisb" ::: "memory"); }

// The Inner Shareable invalidations reach every CPU, and the DSB after them
// waits until all have done them: no interrupts needed. Without ASIDs yet,
// by address for any ASID.
static void arch_tlb_shootdown(uint64_t root, uint64_t va, uint64_t len) {
  (void)root;
  __asm__ volatile("dsb ishst" ::: "memory");
  if (len / 4096 > 64) {
    __asm__ volatile("tlbi vmalle1is" ::: "memory");
  } else {
    for (uint64_t p = va; p < va + len; p += 4096)
      __asm__ volatile("tlbi vaale1is, %0" : : "r"(p >> 12) : "memory");
  }
  __asm__ volatile("dsb ish\n\tisb" ::: "memory");
}

static bool arch_pte_user_ok(uint64_t e, bool write) {
  return (e & PTE_VALID) && (e & PTE_USER) && (!write || !(e & PTE_READ_ONLY));
}

static void arch_kernel_mappings(uint64_t root) {
  uint64_t gicr_size = GICR_FRAME_SIZE * (boot.cpu_count ? boot.cpu_count : 1);
  if (!map_range(root, boot.hhdm + PL011_PHYS, PL011_PHYS, 4096, MAP_WRITE | MAP_DEVICE) ||
      !map_range(root, boot.hhdm + GICD_PHYS, GICD_PHYS, GICD_SIZE, MAP_WRITE | MAP_DEVICE) ||
      !map_range(root, boot.hhdm + GICR_PHYS, GICR_PHYS, gicr_size, MAP_WRITE | MAP_DEVICE))
    panic(VX_STR("cannot map the UART and the GIC"));
}

// Installs the kernel's tables in TTBR1, and an empty table in TTBR0 until
// there is a user address space, then drops every cached translation.
static void arch_switch_tables(uint64_t root) {
  if (!empty_user_root)
    empty_user_root = phys_alloc_zeroed(0); // first on the boot CPU, before the others start
  if (!empty_user_root) panic(VX_STR("no memory for page tables"));
  uint64_t empty = empty_user_root;
  ap_park_tables[0] = root; // for CPUs past MAX_CPUS (ap_park)
  ap_park_tables[1] = empty;
  __asm__ volatile("dsb ishst\n\t"
                   "msr ttbr1_el1, %0\n\t"
                   "msr ttbr0_el1, %1\n\t"
                   "isb\n\t"
                   "tlbi vmalle1\n\t"
                   "dsb ish\n\t"
                   "isb"
                   :
                   : "r"(root), "r"(empty)
                   : "memory");
}

// --- Console ---

static void arch_console_init(void) {
  if (!boot.hhdm) return;
  write_mair(read_mair() & ~(0xffull << 16)); // attribute 2 = 0x00: Device-nGnRnE
  uint64_t va = boot.hhdm + PL011_PHYS;
  if (map_range(read_ttbr1() & PTE_ADDR, va, PL011_PHYS, 4096, MAP_WRITE | MAP_DEVICE))
    pl011 = (volatile uint32_t *)va;
}

static void pl011_putc(uint8_t c) {
  while (pl011[PL011_FR] & PL011_FR_TXFF) {}
  pl011[PL011_DR] = c;
}

static void arch_console_write(vx_str s) {
  if (!pl011) return;
  for (size_t i = 0; i < s.len; i++) {
    if (s.ptr[i] == '\n') pl011_putc('\r');
    pl011_putc((uint8_t)s.ptr[i]);
  }
}

// --- The clock and the timer: the generic timer's virtual counter, through the GICv3 ---

static constexpr uint32_t INTID_RESCHED = 0; // an SGI: another CPU made a thread ready
// The virtual timer's PPI: 27 at EL1. At EL2 with VHE the CNTV_*_EL0 names
// reach the EL2 virtual timer instead, which raises PPI 28 (timer_ppi()).
static constexpr uint32_t INTID_VIRTUAL_TIMER = 27, INTID_EL2_VIRTUAL_TIMER = 28;

static uint32_t timer_ppi(void) {
  uint64_t el;
  __asm__ volatile("mrs %0, CurrentEL" : "=r"(el));
  return (el >> 2 & 3) == 2 ? INTID_EL2_VIRTUAL_TIMER : INTID_VIRTUAL_TIMER;
}

static uint64_t arch_counter(void) {
  uint64_t v;
  __asm__ volatile("isb\n\tmrs %0, cntvct_el0" : "=r"(v));
  return v;
}

// The generic timer's virtual counter: one rate always, and user code reads it.
static uint32_t arch_counter_flags(void) { return VX_CLOCK_USER | VX_CLOCK_INVARIANT | VX_CLOCK_CNTVCT; }

static uint64_t arch_counter_hz(void) {
  uint64_t v;
  __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(v));
  return v;
}

// Sets up the GIC for this CPU: the distributor once, on the boot CPU, then
// this CPU's redistributor, with the timer's PPI and the reschedule SGI enabled.
static void arch_timer_init(void) {
  if (arch_cpu_index() == 0) {
    volatile uint32_t *gicd = (volatile uint32_t *)(boot.hhdm + GICD_PHYS);
    gicd[0] = 1u << 4 | 1u << 1 | 1u << 0; // GICD_CTLR: affinity routing, both groups enabled
  }

  // Find this CPU's redistributor by its affinity.
  uint64_t mpidr;
  __asm__ volatile("mrs %0, mpidr_el1" : "=r"(mpidr));
  uint32_t aff = (uint32_t)((mpidr >> 32 & 0xff) << 24 | (mpidr & 0xffffff));
  uint8_t *rd = nullptr;
  for (uint64_t i = 0; i < (boot.cpu_count ? boot.cpu_count : 1); i++) {
    uint8_t *frame = (uint8_t *)(boot.hhdm + GICR_PHYS + i * GICR_FRAME_SIZE);
    uint64_t typer = *(volatile uint64_t *)(frame + 0x08);
    if ((uint32_t)(typer >> 32) == aff) {
      rd = frame;
      break;
    }
    if (typer & (1u << 4)) break; // the last redistributor
  }
  if (!rd) panic(VX_STR("no GIC redistributor for this CPU"));
  if (arch_cpu_index() == 0) boot_rd = rd; // LPIs (MSIs) go to the boot CPU

  volatile uint32_t *waker = (volatile uint32_t *)(rd + 0x14);
  *waker &= ~(1u << 1);         // clear ProcessorSleep
  while (*waker & (1u << 2)) {} // wait for ChildrenAsleep to clear

  volatile uint32_t *sgi = (volatile uint32_t *)(rd + 0x1'0000); // the SGI and PPI frame
  uint32_t lines = 1u << timer_ppi() | 1u << INTID_RESCHED;
  sgi[0x080 / 4] |= lines;                               // GICR_IGROUPR0: group 1
  ((volatile uint8_t *)sgi)[0x400 + timer_ppi()] = 0x80; // priorities
  ((volatile uint8_t *)sgi)[0x400 + INTID_RESCHED] = 0x80;
  sgi[0x100 / 4] = lines; // GICR_ISENABLER0

  // The CPU interface, through system registers.
  uint64_t sre;
  __asm__ volatile("mrs %0, icc_sre_el1" : "=r"(sre));
  __asm__ volatile("msr icc_sre_el1, %0\n\tisb" : : "r"(sre | 1));
  __asm__ volatile("msr icc_pmr_el1, %0\n\t"
                   "msr icc_bpr1_el1, xzr\n\t"
                   "msr icc_igrpen1_el1, %1\n\t"
                   "isb"
                   :
                   : "r"(0xffull), "r"(1ull));
}

static void arch_timer_arm(uint64_t count) {
  __asm__ volatile("msr cntv_cval_el0, %0\n\t"
                   "msr cntv_ctl_el0, %1\n\t" // enabled, not masked
                   "isb"
                   :
                   : "r"(count), "r"(1ull));
}

// wfi wakes on a pending interrupt even while IRQs are masked; unmasking for a
// moment then takes it.
static void arch_wait(void) {
  __asm__ volatile("wfi\n\t"
                   "msr daifclr, #2\n\t"
                   "isb\n\t"
                   "msr daifset, #2"
                   :
                   :
                   : "memory");
}

static void aarch64_irq(void) {
  uint64_t iar;
  __asm__ volatile("mrs %0, icc_iar1_el1" : "=r"(iar));
  uint32_t intid = (uint32_t)iar & 0xffffff;
  if (intid >= 1020 && intid <= 1023) return; // spurious; LPIs (MSIs) are 8192 and up
  if (intid == INTID_VIRTUAL_TIMER || intid == INTID_EL2_VIRTUAL_TIMER) {
    __asm__ volatile("msr cntv_ctl_el0, xzr\n\tisb"); // disarm before EOI: the line is level-triggered
    timer_interrupt();
  } else if (intid == INTID_RESCHED) {
    this_cpu()->resched = true;
  } else if (intid >= 32 && intid == smmu0.event_intid) {
    smmu_event_interrupt(); // the IOMMU's own line: its faults
  } else if (intid >= LPI_BASE && intid < LPI_BASE + LPI_COUNT) {
    irq_fire(MSI_LINE_BASE + intid - LPI_BASE); // an MSI: edge-triggered, never masked
  } else if (intid >= 32) {
    irq_fire(intid); // a device's SPI: masked before the EOI, as it is level-triggered
  }
  __asm__ volatile("msr icc_eoir1_el1, %0" : : "r"(iar));
}

// --- Devices: GIC SPIs (obj/device.c) ---
//
// SPIs are configured level-triggered, as the GIC starts them, and routed to
// the boot CPU. (A device tree's edge-triggered lines come with bus-dt.)

static uint32_t gic_lines; // INTIDs below this exist

static volatile uint32_t *gicd_regs(void) { return (volatile uint32_t *)(boot.hhdm + GICD_PHYS); }

static void arch_devices_init(void) {
  uint32_t n = 32 * ((gicd_regs()[1] & 0x1f) + 1); // GICD_TYPER.ITLinesNumber
  gic_lines = n < 1020 ? n : 1020;
}

static bool arch_has_io_ports(void) { return false; }

// PSCI SYSTEM_OFF (DEN 0022), by the conduit the FADT's ARM boot flags name
// (hvc or smc); unsupported if they say there is no PSCI. Returns only if the
// firmware did not power off.
static vx_status arch_system_off(void) {
  const uint8_t *fadt = acpi_table("FACP");
  uint16_t flags = 0;
  if (fadt && read32(fadt + 4) >= 131) flags = (uint16_t)(fadt[129] | fadt[130] << 8);
  if (!(flags & 1)) return VX_ERR_UNSUPPORTED; // PSCI_COMPLIANT
  register uint64_t x0 __asm__("x0") = 0x8400'0008;
  // NOLINTNEXTLINE(bugprone-branch-clone): the instructions differ, which clang-tidy does not see
  if (flags & 2) // PSCI_USE_HVC
    __asm__ volatile("hvc #0" : "+r"(x0) : : "x1", "x2", "x3", "memory");
  else
    __asm__ volatile("smc #0" : "+r"(x0) : : "x1", "x2", "x3", "memory");
  return VX_ERR_IO;
}

static bool arch_console_device(bool io, uint64_t base, uint64_t size) {
  return !io && base < PL011_PHYS + 4096 && PL011_PHYS < base + size;
}

static void arch_io_switch(const task *t) { (void)t; }

static vx_status arch_irq_canonical(uint32_t line, uint32_t *out) {
  if (line < 32 || line >= gic_lines) return VX_ERR_RANGE; // SPIs only: SGIs and PPIs are the kernel's
  *out = line;
  return VX_OK;
}

static vx_status arch_irq_route(uint32_t line, bool *level) {
  volatile uint32_t *d = gicd_regs();
  uint32_t bit = 1u << (line % 32);
  d[0x080 / 4 + line / 32] |= bit;                      // GICD_IGROUPR: group 1
  ((volatile uint8_t *)d)[0x400 + line] = 0x80;         // GICD_IPRIORITYR
  d[0xc00 / 4 + line / 16] &= ~(2u << (line % 16 * 2)); // GICD_ICFGR: level-triggered
  *(volatile uint64_t *)((volatile uint8_t *)d + 0x6000 + 8ull * line) =
      cpus[0].arch_id & 0xff'00ff'ffff; // IROUTER
  d[0x100 / 4 + line / 32] = bit;       // GICD_ISENABLER
  *level = true;
  return VX_OK;
}

// --- MSIs: LPIs through the ITS ---
//
// A PCI function's MSI write goes to the ITS's translation register, with the
// function's requester ID as its DeviceID and the data as an EventID. The ITS
// maps the pair to an LPI, through tables in memory it is given, and sends
// the LPI to a redistributor: here always the boot CPU's, through collection
// 0. The kernel sets it all up the first time an MSI is created. LPIs are
// edge-triggered and have no active state; one is turned off by clearing its
// enable bit in the configuration table.

static volatile uint8_t *its;   // the ITS's registers
static uint8_t *lpi_config;     // a byte for each LPI: priority, and bit 0 enables it
static uint64_t *its_queue;     // the command queue, 64 KiB
static uint32_t its_queue_at;   // bytes written
static uint64_t its_target;     // the redistributor, as MAPC and SYNC name it
static uint64_t its_device_ids; // DeviceIDs below this fit the ITS and its device table
static bool its_unusable;       // its setup failed: no MSIs (and no second try)

// The LPI configuration byte: a priority, bit 1 (RES1, group 1), and bit 0, enable.
static constexpr uint8_t LPI_OFF = 0xa2, LPI_ON = 0xa3;

static struct {
  uint32_t id;     // the DeviceID: a requester ID
  uint32_t events; // a bit for each EventID in use
  bool used;
} its_devices[64];

static struct {   // what each LPI in use was mapped from
  uint8_t device; // in its_devices
  uint8_t event;
  bool used;
} lpi_events[LPI_COUNT];

static void its_command(uint64_t d0, uint64_t d1, uint64_t d2, uint64_t d3) {
  uint64_t *c = its_queue + its_queue_at / 8;
  c[0] = d0, c[1] = d1, c[2] = d2, c[3] = d3;
  its_queue_at = (its_queue_at + 32) % (64 * 1024);
  __asm__ volatile("dsb ishst" ::: "memory");
  *(volatile uint64_t *)(its + 0x88) = its_queue_at; // GITS_CWRITER
  for (;;) {                                         // GITS_CREADR: until it has run them
    uint64_t read = *(volatile uint64_t *)(its + 0x90);
    if (read & 1) panic(VX_STR("the GIC's ITS stalled on a command")); // Stalled: a command it refused
    if (read == its_queue_at) break;
  }
}

static void its_sync(void) { its_command(0x05, 0, its_target << 16, 0); }

static uint64_t its_table(unsigned order) {
  uint64_t pa = phys_alloc_zeroed(order);
  if (!pa) panic(VX_STR("no memory for the ITS's tables"));
  return pa;
}

// The kernel's own SPI (the SMMU's event queue): routed to the boot CPU,
// edge-triggered as the SMMU raises it, and never a device's.
static void arch_kernel_spi(uint32_t line, bool edge) {
  volatile uint32_t *d = gicd_regs();
  uint32_t bit = 1u << (line % 32);
  d[0x080 / 4 + line / 32] |= bit;
  ((volatile uint8_t *)d)[0x400 + line] = 0x80;
  if (edge)
    d[0xc00 / 4 + line / 16] |= 2u << (line % 16 * 2);
  else
    d[0xc00 / 4 + line / 16] &= ~(2u << (line % 16 * 2));
  *(volatile uint64_t *)((volatile uint8_t *)d + 0x6000 + 8ull * line) = cpus[0].arch_id & 0xff'00ff'ffff;
  d[0x100 / 4 + line / 32] = bit;
}

// The ITS, as the MADT says (QEMU virt's if it says nothing).
static uint64_t its_phys(void) {
  uint64_t pa = ITS_PHYS_DEFAULT;
  const uint8_t *madt = acpi_table("APIC");
  for (uint32_t off = 44, len = madt ? read32(madt + 4) : 0; off + 2 <= len && madt[off + 1] >= 2;
       off += madt[off + 1])
    if (madt[off] == 0xf && madt[off + 1] >= 20) pa = read64(madt + off + 8); // a GIC ITS structure
  return pa;
}

// The page a device's MSI writes go to: the ITS's translation register's
// (GITS_TRANSLATER, in its second 64 KiB frame), which every IOMMU domain maps.
static uint64_t arch_msi_doorbell(void) { return its_phys() + 0x1'0000; }

static vx_status its_init(void) {
  if (its) return VX_OK;
  if (its_unusable) return VX_ERR_UNSUPPORTED;
  its_unusable = true; // until it has all worked
  if (!boot_rd) return VX_ERR_UNSUPPORTED;
  if (!(gicd_regs()[1] & (1u << 17))) return VX_ERR_UNSUPPORTED; // GICD_TYPER.LPIS
  uint64_t pa = its_phys();
  if (!map_range(kernel_root, boot.hhdm + pa, pa, 128ull * 1024, MAP_WRITE | MAP_DEVICE))
    return VX_ERR_NO_MEMORY;
  volatile uint8_t *regs = (volatile uint8_t *)(boot.hhdm + pa);
  uint64_t typer = *(volatile uint64_t *)(regs + 0x08);

  // The redistributor: its LPI configuration and pending tables, then LPIs on.
  lpi_config = phys_to_virt(its_table(1)); // 8 KiB: a byte for each of 8192 LPIs
  for (uint32_t i = 0; i < LPI_COUNT; i++) lpi_config[i] = LPI_OFF;
  uint64_t pending = its_table(4); // 64 KiB-aligned, as the GIC requires
  *(volatile uint64_t *)(boot_rd + 0x70) =
      ((uint64_t)lpi_config - boot.hhdm) | 1ull << 10 | 7ull << 7 | (LPI_ID_BITS - 1); // GICR_PROPBASER
  *(volatile uint64_t *)(boot_rd + 0x78) = pending | 1ull << 10 | 7ull << 7;           // GICR_PENDBASER
  *(volatile uint32_t *)(boot_rd + 0x00) |= 1;                                         // GICR_CTLR.EnableLPIs

  // The ITS: the tables it asks for (devices and collections), then the command queue.
  for (uint32_t n = 0; n < 8; n++) {
    volatile uint64_t *baser = (volatile uint64_t *)(regs + 0x100 + 8ull * n);
    uint64_t type = *baser >> 56 & 7, entry = (*baser >> 48 & 0x1f) + 1;
    if (type != 1 && type != 4) continue; // devices, collections
    uint32_t bits = type == 1 ? (uint32_t)(typer >> 13 & 0x1f) + 1 : 16;
    uint64_t bytes = entry << bits, pages = (bytes + 4095) / 4096;
    if (pages > 256) pages = 256; // 1 MiB of entries is room for every device QEMU has
    if (type == 1)
      its_device_ids = pages * 4096 / entry < (1ull << bits) ? pages * 4096 / entry : 1ull << bits;
    unsigned order = 0;
    while ((1ull << order) < pages) order++;
    uint64_t want = 1ull << 63 | 7ull << 59 | (entry - 1) << 48 | its_table(order) | 1ull << 10 | (pages - 1);
    *baser = want;
    // The ITS may not take 4 KiB pages or inner-shareable, cached tables; then
    // these tables are the wrong size or need cache maintenance: no MSIs.
    if ((*baser & (3ull << 8 | 3ull << 10)) != (want & (3ull << 8 | 3ull << 10))) return VX_ERR_UNSUPPORTED;
  }
  its_queue = phys_to_virt(its_table(4));
  *(volatile uint64_t *)(regs + 0x80) =
      1ull << 63 | 7ull << 59 | (uint64_t)its_queue - boot.hhdm | 1ull << 10 | 15;
  *(volatile uint64_t *)(regs + 0x88) = 0;
  *(volatile uint32_t *)(regs + 0x00) |= 1; // GITS_CTLR.Enabled
  its = regs;

  // Collection 0 is the boot CPU's redistributor, by address or by number as GITS_TYPER.PTA says.
  uint64_t rd_pa = (uint64_t)boot_rd - boot.hhdm;
  its_target = typer & (1ull << 19) ? rd_pa >> 16 : (*(volatile uint64_t *)(boot_rd + 0x08) >> 8 & 0xffff);
  its_command(0x09, 0, 1ull << 63 | its_target << 16 | 0, 0); // MAPC: valid, target, ICID 0
  its_sync();
  its_unusable = false;
  return VX_OK;
}

static vx_status arch_msi_create(uint32_t source, uint32_t *line, vx_msi *msi) {
  vx_status st = its_init();
  if (st != VX_OK) return st;
  uint32_t lpi = 0;
  while (lpi < LPI_COUNT && irq_lines[MSI_LINE_BASE + lpi]) lpi++;
  if (source >= its_device_ids) return VX_ERR_RANGE; // a DeviceID the ITS has no room for would stall it
  int dev = -1, free_dev = -1;
  for (int i = 0; i < 64; i++) {
    if (its_devices[i].used && its_devices[i].id == source) dev = i;
    if (!its_devices[i].used && free_dev < 0) free_dev = i;
  }
  if (lpi == LPI_COUNT || (dev < 0 && free_dev < 0)) return VX_ERR_NO_MEMORY;
  if (dev < 0) { // a new device: its interrupt translation table, then MAPD
    dev = free_dev;
    its_devices[dev] = (typeof(its_devices[0])){.id = source, .used = true};
    uint64_t itt = its_table(0);
    its_command(0x08 | (uint64_t)source << 32, 4 /* 5 EventID bits */, 1ull << 63 | itt, 0);
  }
  uint32_t event = 0;
  while (event < ITS_EVENTS && its_devices[dev].events & (1u << event)) event++;
  if (event == ITS_EVENTS) return VX_ERR_NO_MEMORY;
  its_devices[dev].events |= 1u << event;
  lpi_events[lpi] = (typeof(lpi_events[0])){.device = (uint8_t)dev, .event = (uint8_t)event, .used = true};
  lpi_config[lpi] = LPI_ON;
  __asm__ volatile("dsb ishst" ::: "memory");
  its_command(0x0a | (uint64_t)source << 32, event | (uint64_t)(LPI_BASE + lpi) << 32, 0,
              0);                                          // MAPTI, to ICID 0
  its_command(0x0c | (uint64_t)source << 32, event, 0, 0); // INV
  its_sync();
  *line = MSI_LINE_BASE + lpi;
  *msi = (vx_msi){.address = ((uint64_t)its - boot.hhdm) + 0x1'0040, .data = event}; // GITS_TRANSLATER
  return VX_OK;
}

// Turns the LPI off and forgets its event. (The ITS keeps the device's
// table: devices come back, as restarted drivers do.)
static void arch_msi_destroy(uint32_t line) {
  uint32_t lpi = line - MSI_LINE_BASE;
  if (lpi >= LPI_COUNT || !lpi_events[lpi].used) return;
  lpi_config[lpi] = LPI_OFF;
  uint32_t dev = lpi_events[lpi].device, event = lpi_events[lpi].event;
  its_command(0x0f | (uint64_t)its_devices[dev].id << 32, event, 0, 0); // DISCARD
  its_sync();
  its_devices[dev].events &= ~(1u << event);
  lpi_events[lpi].used = false;
}

static void arch_irq_mask(uint32_t line, bool masked) {
  if (line >= MSI_LINE_BASE) return; // an MSI: edge-triggered; arch_msi_destroy turns it off
  if (line < 32 || line >= gic_lines) return;
  volatile uint32_t *d = gicd_regs();
  d[(masked ? 0x180 : 0x100) / 4 + line / 32] = 1u << (line % 32); // GICD_ICENABLER or GICD_ISENABLER
  if (masked)
    while (d[0] & (1u << 31)) {} // GICD_CTLR.RWP: until the disable has taken effect
}

// An SGI to one CPU, named by its affinity: ICC_SGI1R_EL1 takes Aff3, Aff2 and
// Aff1, and Aff0 as a bit in a 16-wide target list, with RS choosing which 16.
static void arch_send_resched(cpu *c) {
  uint64_t a = c->arch_id;
  uint64_t v = (a >> 32 & 0xff) << 48 | (a >> 16 & 0xff) << 32 | (uint64_t)INTID_RESCHED << 24 |
               (a >> 8 & 0xff) << 16 | (a >> 4 & 0xf) << 44 | 1ull << (a & 0xf); // RS: which 16 of Aff0
  __asm__ volatile("dsb ishst\n\tmsr icc_sgi1r_el1, %0\n\tisb" : : "r"(v) : "memory");
}

// --- Exceptions ---

extern const uint8_t aarch64_vectors[]; // vectors.S

static bool percpu_ready; // TPIDR_EL1 holds this CPU's index

// Per CPU: the vector table, the CPU's index in TPIDR_EL1, and MAIR attribute 2
// as device memory (arch_console_init sets it early on the boot CPU).
static void arch_cpu_init(uint32_t index) {
  // CPACR_EL1: FP/SIMD on (FPEN), saved at each switch (arch_user_switch);
  // the kernel itself uses none. SVE and SME still trap, until their larger
  // state is saved too.
  __asm__ volatile("msr cpacr_el1, %0\n\tisb" : : "r"(3ull << 20) : "memory");
  // Software step for user threads (exception_resume STEP): the OS lock open,
  // and MDSCR_EL1 with KDE off, so the kernel itself is never stepped. SS is
  // set only on the way to a thread being stepped (step_on_return).
  uint64_t mdscr;
  __asm__ volatile("msr oslar_el1, xzr\n\tisb\n\tmrs %0, mdscr_el1" : "=r"(mdscr));
  __asm__ volatile("msr mdscr_el1, %0\n\tisb" : : "r"(mdscr & ~(1ull << 13 | 1)) : "memory");
  // CNTKCTL_EL1.EL0VCTEN: user code may read the virtual counter (02 §5.1, 05 §9).
  uint64_t cntkctl;
  __asm__ volatile("mrs %0, cntkctl_el1" : "=r"(cntkctl));
  __asm__ volatile("msr cntkctl_el1, %0\n\tisb" : : "r"(cntkctl | 1ull << 1) : "memory");
  __asm__ volatile("msr vbar_el1, %0\n\t"
                   "msr tpidr_el1, %1\n\t"
                   "isb"
                   :
                   : "r"(aarch64_vectors), "r"((uint64_t)index)
                   : "memory");
  write_mair(read_mair() & ~(0xffull << 16));
  percpu_ready = true;
}

static uint32_t arch_cpu_index(void) {
  if (!percpu_ready) return 0;
  uint64_t v;
  __asm__ volatile("mrs %0, tpidr_el1" : "=r"(v));
  return (uint32_t)v;
}

static void arch_pause(void) { __asm__ volatile("yield"); }

typedef struct trap_frame { // the layout vectors.S builds
  uint64_t x[31];           // x29 is the frame pointer, x30 the link register
  uint64_t elr, spsr, esr, far;
  uint64_t sp_el0; // the user stack pointer
} trap_frame;
static_assert(sizeof(trap_frame) == 288); // as vectors.S reserves; a multiple of 16

static const char *const VECTOR_KINDS[4] = {"synchronous exception", "IRQ", "FIQ", "SError"};

// --- Threads ---

static void arch_set_kernel_stack(uint64_t top) {
  (void)top; // SP_EL1 is already the current thread's stack: exceptions land on it
}

extern const uint8_t thread_trampoline[]; // vectors.S

// A new thread's stack, as arch_context_switch will pop it: x19 to x30, with
// x19 carrying the thread and x30 returning into thread_trampoline. It starts
// below the space its first trap frame takes at the top of the stack, so
// arch_enter_user can build that frame without overwriting itself.
static uint64_t arch_thread_initial_sp(thread *t) {
  uint64_t *sp = (uint64_t *)((trap_frame *)thread_kstack_top(t) - 1) - 12;
  sp[0] = (uint64_t)t;                  // x19
  sp[11] = (uint64_t)thread_trampoline; // x30
  return (uint64_t)sp;
}

// Enters EL0 at entry with interrupts unmasked (SPSR = 0: EL0t, DAIF clear).
static void step_on_return(const trap_frame *f); // below, with the user-mode registers

[[noreturn]] static void arch_enter_user(uint64_t entry, uint64_t sp, uint64_t arg, uint64_t arg2,
                                         uint64_t kstack_top) {
  trap_frame *f = (trap_frame *)kstack_top - 1;
  *f = (trap_frame){.x = {arg, arg2}, .elr = entry, .spsr = 0, .sp_el0 = sp};
  step_on_return(f); // a new thread is never being stepped
  arch_enter_frame(f);
}

// Describes an exception: "page fault at 0x... (read, not present, user)", say.
static void kput_exception(const trap_frame *f, uint64_t index) {
  uint32_t ec = (uint32_t)(f->esr >> 26) & 0x3f;
  uint32_t iss = (uint32_t)f->esr & 0x1ffffff;
  if ((index & 3) == 0 && (ec == 0x24 || ec == 0x25)) { // data abort
    kput(VX_STR("page fault at "));
    kput_hex(f->far);
    kput(iss & (1u << 6) ? VX_STR(" (write, ") : VX_STR(" (read, "));
    kput((iss & 0x3c) == 0x04 ? VX_STR("not present") : VX_STR("protection"));
    kput(ec == 0x24 ? VX_STR(", user)") : VX_STR(", kernel)"));
  } else if ((index & 3) == 0 && (ec == 0x20 || ec == 0x21)) {
    kput(VX_STR("page fault at "));
    kput_hex(f->far);
    kput(VX_STR(" (execute)"));
  } else if ((index & 3) == 0 && ec == 0x3c && (iss & 0xff00) == 0x5500) {
    kput(VX_STR("undefined behaviour (UBSan trap)")); // -fsanitize-trap emits brk #0x55xx
  } else {
    kput_cstr(VECTOR_KINDS[index & 3]);
    kput(VX_STR(", ESR "));
    kput_hex(f->esr);
  }
}

static constexpr uint32_t EC_SVC64 = 0x15;

// An exception in the kernel found its stack pointer outside a kernel stack's
// valid half (vectors.S): an overflow into the guard below, or an exception
// before CPU 0 left the boot stack. Either way, the end.
[[noreturn]] void aarch64_kernel_stack_fault(uint64_t sp) {
  uint64_t elr, esr, far;
  __asm__ volatile("mrs %0, elr_el1\n\tmrs %1, esr_el1\n\tmrs %2, far_el1" : "=r"(elr), "=r"(esr), "=r"(far));
  panic_start();
  kput(kstack_in_guard(sp) ? VX_STR("kernel stack overflow") : VX_STR("exception off any kernel stack"));
  kput(VX_STR(": sp "));
  kput_hex(sp);
  kput(VX_STR(", ESR "));
  kput_hex(esr);
  kput(VX_STR(", FAR "));
  kput_hex(far);
  kput(VX_STR(" at pc "));
  kput_hex(elr);
  panic_end(elr, 0);
}

// --- User-mode registers (obj/exception.c) ---

static trap_frame *arch_user_frame(thread *t) { return (trap_frame *)thread_kstack_top(t) - 1; }

static void arch_frame_regs(const trap_frame *f, vx_regs *r) {
  for (int i = 0; i < 31; i++) r->x[i] = f->x[i];
  r->sp = f->sp_el0;
  r->pc = f->elr;
  r->pstate = f->spsr;
}

static vx_status arch_frame_set_regs(trap_frame *f, const vx_regs *r) {
  if (r->pc >= USER_TOP || r->sp > USER_TOP) return VX_ERR_INVALID;
  for (int i = 0; i < 31; i++) f->x[i] = r->x[i];
  f->sp_el0 = r->sp;
  f->elr = r->pc;
  f->spsr = r->pstate & 0xf000'0000ull; // NZCV only: EL0t, every interrupt unmasked
  return VX_OK;
}

// To pc(arg), with arg (16-aligned) as the stack pointer, and no frame or
// return address to go back to.
// TPIDR_EL0 is the user's to write directly; the kernel only keeps it with
// its thread. Idle threads leave the last one in place, unused.
static uint64_t arch_tls_read(void) {
  uint64_t v;
  __asm__ volatile("mrs %0, tpidr_el0" : "=r"(v));
  return v;
}
static void arch_tls_write(uint64_t value) { __asm__ volatile("msr tpidr_el0, %0" : : "r"(value)); }

// The kernel is built without FP/SIMD, so the assembler is told it is here.
// NOLINTNEXTLINE(readability-non-const-parameter): the assembly writes it
static void fp_save(uint8_t *fp) {
  __asm__ volatile(".arch_extension fp\n\t"
                   ".arch_extension simd\n\t"
                   "stp q0, q1, [%1, #0]\n\tstp q2, q3, [%1, #32]\n\t"
                   "stp q4, q5, [%1, #64]\n\tstp q6, q7, [%1, #96]\n\t"
                   "stp q8, q9, [%1, #128]\n\tstp q10, q11, [%1, #160]\n\t"
                   "stp q12, q13, [%1, #192]\n\tstp q14, q15, [%1, #224]\n\t"
                   "stp q16, q17, [%1, #256]\n\tstp q18, q19, [%1, #288]\n\t"
                   "stp q20, q21, [%1, #320]\n\tstp q22, q23, [%1, #352]\n\t"
                   "stp q24, q25, [%1, #384]\n\tstp q26, q27, [%1, #416]\n\t"
                   "stp q28, q29, [%1, #448]\n\tstp q30, q31, [%1, #480]\n\t"
                   "mrs x9, fpcr\n\tmrs x10, fpsr\n\t"
                   "str x9, [%1, #512]\n\tstr x10, [%1, #520]"
                   : "=m"(*(uint8_t (*)[sizeof(vx_fpregs)])fp)
                   : "r"(fp)
                   : "x9", "x10");
}

static void fp_load(const uint8_t *fp) {
  __asm__ volatile(".arch_extension fp\n\t"
                   ".arch_extension simd\n\t"
                   "ldp q0, q1, [%0, #0]\n\tldp q2, q3, [%0, #32]\n\t"
                   "ldp q4, q5, [%0, #64]\n\tldp q6, q7, [%0, #96]\n\t"
                   "ldp q8, q9, [%0, #128]\n\tldp q10, q11, [%0, #160]\n\t"
                   "ldp q12, q13, [%0, #192]\n\tldp q14, q15, [%0, #224]\n\t"
                   "ldp q16, q17, [%0, #256]\n\tldp q18, q19, [%0, #288]\n\t"
                   "ldp q20, q21, [%0, #320]\n\tldp q22, q23, [%0, #352]\n\t"
                   "ldp q24, q25, [%0, #384]\n\tldp q26, q27, [%0, #416]\n\t"
                   "ldp q28, q29, [%0, #448]\n\tldp q30, q31, [%0, #480]\n\t"
                   "ldr x9, [%0, #512]\n\tldr x10, [%0, #520]\n\t"
                   "msr fpcr, x9\n\tmsr fpsr, x10"
                   :
                   : "r"(fp)
                   : "x9", "x10", "memory");
}

// Watchpoints (thread_state SET_WATCH): DBGWVRn_EL1 and DBGWCRn_EL1, for EL0
// only (PAC), so the kernel's own accesses never fire them, with
// MDSCR_EL1.MDE on while a task that has them runs. ID_AA64DFR0_EL1.WRPs says
// how many there are.
static bool watch_loaded[MAX_CPUS];

static uint32_t arch_watch_count(void) {
  uint64_t dfr0;
  __asm__ volatile("mrs %0, id_aa64dfr0_el1" : "=r"(dfr0));
  uint32_t n = (uint32_t)(dfr0 >> 20 & 15) + 1;
  return n < VX_WATCH_MAX ? n : VX_WATCH_MAX;
}

// The registers are named in the instruction, so each slot is its own case.
static void watch_slot(uint32_t i, uint64_t value, uint64_t control) {
  // NOLINTBEGIN(bugprone-branch-clone): each case writes a different register
  switch (i) {
  case 0: __asm__ volatile("msr dbgwvr0_el1, %0\n\tmsr dbgwcr0_el1, %1" : : "r"(value), "r"(control)); break;
  case 1: __asm__ volatile("msr dbgwvr1_el1, %0\n\tmsr dbgwcr1_el1, %1" : : "r"(value), "r"(control)); break;
  case 2: __asm__ volatile("msr dbgwvr2_el1, %0\n\tmsr dbgwcr2_el1, %1" : : "r"(value), "r"(control)); break;
  case 3: __asm__ volatile("msr dbgwvr3_el1, %0\n\tmsr dbgwcr3_el1, %1" : : "r"(value), "r"(control)); break;
  case 4: __asm__ volatile("msr dbgwvr4_el1, %0\n\tmsr dbgwcr4_el1, %1" : : "r"(value), "r"(control)); break;
  case 5: __asm__ volatile("msr dbgwvr5_el1, %0\n\tmsr dbgwcr5_el1, %1" : : "r"(value), "r"(control)); break;
  case 6: __asm__ volatile("msr dbgwvr6_el1, %0\n\tmsr dbgwcr6_el1, %1" : : "r"(value), "r"(control)); break;
  case 7: __asm__ volatile("msr dbgwvr7_el1, %0\n\tmsr dbgwcr7_el1, %1" : : "r"(value), "r"(control)); break;
  case 8: __asm__ volatile("msr dbgwvr8_el1, %0\n\tmsr dbgwcr8_el1, %1" : : "r"(value), "r"(control)); break;
  case 9: __asm__ volatile("msr dbgwvr9_el1, %0\n\tmsr dbgwcr9_el1, %1" : : "r"(value), "r"(control)); break;
  case 10:
    __asm__ volatile("msr dbgwvr10_el1, %0\n\tmsr dbgwcr10_el1, %1" : : "r"(value), "r"(control));
    break;
  case 11:
    __asm__ volatile("msr dbgwvr11_el1, %0\n\tmsr dbgwcr11_el1, %1" : : "r"(value), "r"(control));
    break;
  case 12:
    __asm__ volatile("msr dbgwvr12_el1, %0\n\tmsr dbgwcr12_el1, %1" : : "r"(value), "r"(control));
    break;
  case 13:
    __asm__ volatile("msr dbgwvr13_el1, %0\n\tmsr dbgwcr13_el1, %1" : : "r"(value), "r"(control));
    break;
  case 14:
    __asm__ volatile("msr dbgwvr14_el1, %0\n\tmsr dbgwcr14_el1, %1" : : "r"(value), "r"(control));
    break;
  case 15:
    __asm__ volatile("msr dbgwvr15_el1, %0\n\tmsr dbgwcr15_el1, %1" : : "r"(value), "r"(control));
    break;
  default: break;
  }
  // NOLINTEND(bugprone-branch-clone)
}

static void watch_load(const task *t) {
  uint32_t cpu = arch_cpu_index(), count = arch_watch_count();
  if (!t->watching && !watch_loaded[cpu]) return;
  for (uint32_t i = 0; i < count; i++) {
    const vx_watch *w = &t->watches[i];
    if (!t->watching || w->kind == VX_WATCH_OFF) {
      watch_slot(i, 0, 0);
      continue;
    }
    uint64_t base = w->address & ~7ull, bas = ((1ull << w->len) - 1) << (w->address & 7);
    uint64_t lsc = w->kind == VX_WATCH_WRITE ? 2 : 3;         // stores, or loads and stores
    watch_slot(i, base, bas << 5 | lsc << 3 | 2ull << 1 | 1); // BAS, LSC, PAC = EL0, E
  }
  uint64_t mdscr;
  __asm__ volatile("mrs %0, mdscr_el1" : "=r"(mdscr));
  mdscr = t->watching ? mdscr | 1ull << 15 : mdscr & ~(1ull << 15); // MDE
  __asm__ volatile("msr mdscr_el1, %0\n\tisb" : : "r"(mdscr) : "memory");
  watch_loaded[cpu] = t->watching;
}

// Idle threads have no user state: whoever ran last leaves its TPIDR_EL0 and
// FP/SIMD registers in place, unused, until the next user thread loads its own.
// An area simd_begin filled already holds them: the registers are the kernel's since.
static void arch_user_save(thread *th) {
  th->tls = arch_tls_read();
  if (!th->fp_in_area) fp_save(th->fp);
}

static void arch_fp_load(thread *th) {
  fp_load(th->fp);
  th->fp_in_area = false;
}

static void arch_user_load(thread *th) {
  arch_tls_write(th->tls);
  arch_fp_load(th);
}

// A thread stopped at an exception has saved its own (user_held): what a
// debugger set there since is not overwritten.
static void arch_user_switch(thread *prev, thread *next) {
  if (prev->task && !prev->user_held) arch_user_save(prev);
  if (next->task) {
    arch_user_load(next);
    watch_load(next->task);
  }
}

// The reset's values: every register zero; FPCR zero (round to nearest, no
// traps), FPSR zero.
static void arch_fp_init(uint8_t *fp) { memset(fp, 0, ARCH_FP_MAX); }

// DC ZVA zeroes a block of 4 << DCZID_EL0.BS bytes at once (6c2), where
// DCZID_EL0.DZP does not prohibit it; paired stores otherwise (vx-mem).
static void arch_page_zero(void *va, uint64_t bytes) {
  uint64_t dczid;
  __asm__ volatile("mrs %0, dczid_el0" : "=r"(dczid));
  if (dczid & 1u << 4) {
    memset(va, 0, bytes);
    return;
  }
  uint64_t block = 4ull << (dczid & 0xf);
  for (uint8_t *p = va, *end = p + bytes; p < end; p += block)
    __asm__ volatile("dc zva, %0" : : "r"(p) : "memory");
}

// A page copied with NEON, 64 bytes a round, inside a SIMD section (6c2): the
// kernel is built general-registers-only, so nothing it compiled holds a value
// in q4-q7 (ktest's test_fp checks v7 across it), and simd_begin has saved the user's.
static void arch_page_copy(void *dst, const void *src, uint64_t bytes) {
  simd_begin();
  const uint8_t *s = src;
  uint8_t *d = dst;
  for (uint64_t n = bytes / 64; n; n--)
    __asm__ volatile(".arch_extension simd\n\t"
                     "ldp q4, q5, [%1]\n\tldp q6, q7, [%1, #32]\n\t"
                     "stp q4, q5, [%0]\n\tstp q6, q7, [%0, #32]\n\t"
                     "add %0, %0, #64\n\tadd %1, %1, #64"
                     : "+r"(d), "+r"(s)
                     :
                     : "memory");
  simd_end();
}

// Protection keys: none, as no CPU we run on has Arm's permission overlays
// (FEAT_S1POE: QEMU 10.2's max does not, nor the tiered boards; 6c5,
// ADR-0035). The user copies use LDTR and STTR, as overlays would need.
static uint32_t arch_keys(void) { return 0; }
static bool arch_user_copy_denied(void) { return false; }
static uint64_t arch_rights_read(void) { return 0; }
static void arch_rights_write(uint64_t rights) { (void)rights; }
// NOLINTNEXTLINE(readability-non-const-parameter): x86_64's writes its PKRU; aarch64 has none yet
static void arch_fp_set_rights(uint8_t *fp, uint64_t rights) { (void)fp, (void)rights; }

// The extended state is the vx_fpregs image (ADR-0035): SVE's and SME's join
// it when the kernel saves them, POR_EL0 with a CPU that has overlays.
static uint32_t arch_fp_size(void) { return sizeof(vx_fpregs); }
static void arch_fp_view(const uint8_t *fp, uint8_t *out) { memcpy(out, fp, sizeof(vx_fpregs)); }
static vx_status arch_fp_check(const uint8_t *fp) {
  vx_fpregs f;
  memcpy(&f, fp, sizeof f);
  return f.fpcr & ~0x07ff9f00ull || f.fpsr & ~0xf800009full ? VX_ERR_INVALID : VX_OK;
}
// NOLINTNEXTLINE(readability-non-const-parameter): x86_64's marks its header; aarch64 has none
static void arch_fp_legacy_set(uint8_t *fp) { (void)fp; }

// The ID registers user code needs, as this CPU has them, with the fields of
// what the kernel does not save or support zeroed: SVE (PFR0[35:32], ZFR0),
// SME (PFR1[27:24], SMFR0), MTE (PFR1[11:8]), overlays (MMFR3[19:16]), which
// the kernel does not use. Generic encodings, as the newer names need a newer assembler; IDs a
// CPU lacks read as zero.
static void arch_cpu_info(vx_cpu_info *info) {
  uint64_t isar0, isar1, isar2, pfr0, pfr1, mmfr3;
  __asm__ volatile("mrs %0, s3_0_c0_c6_0\n\tmrs %1, s3_0_c0_c6_1\n\tmrs %2, s3_0_c0_c6_2"
                   : "=r"(isar0), "=r"(isar1), "=r"(isar2));
  __asm__ volatile("mrs %0, s3_0_c0_c4_0\n\tmrs %1, s3_0_c0_c4_1\n\tmrs %2, s3_0_c0_c7_3"
                   : "=r"(pfr0), "=r"(pfr1), "=r"(mmfr3));
  *info = (vx_cpu_info){.xstate_size = sizeof(vx_fpregs),
                        .isar0 = isar0,
                        .isar1 = isar1,
                        .isar2 = isar2,
                        .pfr0 = pfr0 & ~(0xfull << 32),
                        .pfr1 = pfr1 & ~(0xfull << 24 | 0xfull << 8),
                        .mmfr3 = mmfr3 & ~(0xfull << 16)};
}

static constexpr uint64_t SPSR_SS = 1ull << 21; // software step

// Always the current thread's frame: its own exception, or its resumption.
static void arch_frame_step(trap_frame *f, bool on) {
  f->spsr = on ? f->spsr | SPSR_SS : f->spsr & ~SPSR_SS;
  this_cpu()->current->stepping = on;
}

// MDSCR_EL1.SS on only for a return to a thread being stepped: with it on, a
// return with SPSR.SS clear takes a step exception at once (the
// active-pending state), before running anything. Which is what a stepped
// svc needs: the call leaves SPSR.SS clear, the instruction done, and the
// step is reported as the call returns. So it follows the thread's stepping,
// not SPSR.SS, which would lose that step.
static bool step_enabled[MAX_CPUS];

static void step_on_return(const trap_frame *f) {
  (void)f;
  bool want = this_cpu()->current->stepping;
  uint32_t cpu = arch_cpu_index();
  if (step_enabled[cpu] == want) return;
  uint64_t mdscr;
  __asm__ volatile("mrs %0, mdscr_el1" : "=r"(mdscr));
  __asm__ volatile("msr mdscr_el1, %0\n\tisb" : : "r"(want ? mdscr | 1 : mdscr & ~1ull) : "memory");
  step_enabled[cpu] = want;
}

// Code written through the direct map: cleaned to the point of unification,
// then every CPU's instruction cache invalidated.
static void arch_sync_icache(void *p, size_t len) {
  uint64_t ctr;
  __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
  uint64_t line = 4ull << (ctr >> 16 & 15); // DminLine: log2 of words
  for (uint64_t a = (uint64_t)p & ~(line - 1); a < (uint64_t)p + len; a += line)
    __asm__ volatile("dc cvau, %0" : : "r"(a) : "memory");
  __asm__ volatile("dsb ish\n\tic ialluis\n\tdsb ish\n\tisb" ::: "memory");
}

static bool arch_frame_divert(trap_frame *f, uint64_t pc, uint64_t arg) {
  f->elr = pc;
  f->sp_el0 = arg;
  f->x[0] = arg;
  f->x[29] = 0;
  f->x[30] = 0;
  return true;
}

// A user-mode fault as an exception: its kind, code and address (abi.h).
static uint32_t aarch64_exception_kind(const trap_frame *f, uint32_t *code, uint64_t *address) {
  uint32_t ec = (uint32_t)(f->esr >> 26) & 0x3f, iss = (uint32_t)f->esr & 0x1ffffff;
  *code = (uint32_t)f->esr;
  *address = 0;
  switch (ec) {
  case 0x24: // data abort
    *address = f->far;
    *code = iss & (1u << 6) ? 1 : 0;
    return VX_EXCEPTION_PAGE_FAULT;
  case 0x20: // instruction abort
    *address = f->far;
    *code = 2;
    return VX_EXCEPTION_PAGE_FAULT;
  case 0x07: return VX_EXCEPTION_FP_DISABLED;
  case 0x3c: *code = iss & 0xffff; return VX_EXCEPTION_BREAKPOINT; // brk #imm
  case 0x00:
  case 0x0e: return VX_EXCEPTION_ILLEGAL; // undefined, or an illegal execution state
  case 0x22:
  case 0x26: *address = f->far; return VX_EXCEPTION_ALIGNMENT; // PC or SP alignment
  case 0x2c: return VX_EXCEPTION_ARITHMETIC;                   // trapped FP exception
  case 0x32: return VX_EXCEPTION_STEP;                         // software step, from EL0
  case 0x34: {                                                 // a watchpoint, from EL0: before the access
    const task *t = this_cpu()->current->task;
    *code = 0;
    for (uint32_t i = 0; i < VX_WATCH_MAX; i++) { // the slot whose 8-byte span holds what was touched
      const vx_watch *w = &t->watches[i];
      if (w->kind != VX_WATCH_OFF && (w->address & ~7ull) == (f->far & ~7ull)) *code = i;
    }
    *address = t->watches[*code].address;
    return VX_EXCEPTION_WATCHPOINT;
  }
  default: return VX_EXCEPTION_GENERAL;
  }
}

void aarch64_trap(trap_frame *f, uint64_t index) {
  bool from_user = index >= 8;
  uint32_t ec = (uint32_t)(f->esr >> 26) & 0x3f;
  if ((index & 3) == 1) { // IRQ
    aarch64_irq();
  } else if (from_user && (index & 3) == 0 && ec == EC_SVC64) {
    f->x[0] = (uint64_t)syscall_dispatch(f->x[8], f->x);
  } else if (!from_user && (index & 3) == 0 && ec == 0x25 && f->far < USER_TOP && uaccess_fixup(f->elr)) {
    f->elr = uaccess_fixup(f->elr); // a user page gone under a copy: it reports the failure
  } else if (from_user) {
    uint32_t code;
    uint64_t address;
    uint32_t kind = aarch64_exception_kind(f, &code, &address);
    if ((index & 3) != 0 ||
        !exception_raise(f, &kind, code, &address)) { // an SError or FIQ, or nobody took it
      task_fault_start();
      kput_exception(f, index);
      kput(VX_STR(" at pc "));
      kput_hex(f->elr);
      kput(VX_STR("\n"));
      task_fault_exit((index & 3) != 0 ? VX_EXCEPTION_GENERAL : kind, code, address, f->elr);
    }
  } else {
    panic_start();
    kput_exception(f, index);
    kput(VX_STR(" at pc "));
    kput_hex(f->elr);
    panic_end(f->elr, f->x[29]);
  }
  if (from_user) {
    user_return();
    step_on_return(f);
  }
}

[[noreturn]] static void arch_halt(void) {
  for (;;) __asm__ volatile("msr daifset, #0xf\n\twfi");
}

// Limine starts each other CPU here, with its limine_mp_info in x0, in the
// same state as the boot CPU. smp_init left the top of the CPU's idle stack in
// extra_argument, with the CPU's index just above it.
static_assert(offsetof(struct limine_mp_info, extra_argument) == 32);

uint64_t ap_park_tables[2];

[[gnu::naked, noreturn]] void ap_park(struct limine_mp_info *info) {
  __asm__("hint #34\n\t"
          "msr daifset, #0xf\n\t"
          "adrp x1, ap_park_tables\n\t"
          "add x1, x1, :lo12:ap_park_tables\n\t"
          "ldp x2, x3, [x1]\n\t"
          "dsb ish\n\t"
          "msr ttbr1_el1, x2\n\t" // the kernel's tables: Limine's are about to be reclaimed
          "msr ttbr0_el1, x3\n\t"
          "isb\n\t"
          "tlbi vmalle1\n\t"
          "dsb ish\n\t"
          "isb\n"
          "1:\n\t"
          "wfe\n\t"
          "b 1b");
}

// Its idle stack is in the kernel stack region (mm/kstack.c), which only the
// kernel's tables map: it loads them first, as ap_park does.
[[gnu::naked, noreturn]] void ap_start(struct limine_mp_info *info) {
  __asm__("hint #34\n\t"
          "adrp x1, ap_park_tables\n\t"
          "add x1, x1, :lo12:ap_park_tables\n\t"
          "ldp x2, x3, [x1]\n\t"
          "dsb ish\n\t"
          "msr ttbr1_el1, x2\n\t"
          "msr ttbr0_el1, x3\n\t"
          "isb\n\t"
          "tlbi vmalle1\n\t"
          "dsb ish\n\t"
          "isb\n\t"
          "ldr x9, [x0, #32]\n\t"
          "msr spsel, #1\n\t"
          "mov sp, x9\n\t"
          "ldr x0, [sp, #8]\n\t"
          "mov x29, xzr\n\t"
          "mov x30, xzr\n\t"
          "bl ap_main\n\t"
          "brk #0");
}

// Limine enters here at EL1 (or EL2 with VHE), with the higher half mapped,
// running on SP_EL0 (SPSel = 0) on a stack of its own. Exceptions always switch
// to SP_EL1, so the kernel selects SP_EL1, points it at its boot stack (the
// linker script), clears the frame record so backtraces end here, and leaves
// SP_EL0 for user mode. `hint #34` is `bti c`, a no-op on CPUs without BTI.
[[gnu::naked, noreturn]] void _start(void) {
  __asm__("hint #34\n\t"
          "adrp x9, vx_boot_stack_top\n\t"
          "add x9, x9, :lo12:vx_boot_stack_top\n\t"
          "msr spsel, #1\n\t"
          "mov sp, x9\n\t"
          "mov x29, xzr\n\t"
          "mov x30, xzr\n\t"
          "bl kernel_main\n\t"
          "brk #0");
}
