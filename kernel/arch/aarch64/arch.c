// arch.c (aarch64): the entry point, the early serial console (a PL011),
// exceptions and page-table entries.
//
// Limine's direct map covers RAM only (base revision 3 and later), so the
// console maps the UART's registers itself: one 4 KiB device page at
// hhdm + its physical address, first in Limine's page tables and then in the
// kernel's own. Device pages use MAIR attribute 2; Limine guarantees that
// attributes 2 to 7 are unused. The UART is at QEMU virt's address until the
// kernel reads the device tree.

constexpr uint64_t PL011_PHYS = 0x0900'0000;
constexpr uint64_t PL011_DR   = 0x00 / 4;   // data register, as a u32 index
constexpr uint64_t PL011_FR   = 0x18 / 4;   // flag register
constexpr uint32_t PL011_FR_TXFF = 1u << 5; // transmit FIFO full

static volatile uint32_t *pl011;

// --- Page tables ---

constexpr uint64_t PTE_VALID     = 1ull << 0;
constexpr uint64_t PTE_TABLE     = 1ull << 1;    // a table at levels 0-2, a page at level 3
constexpr uint64_t PTE_DEVICE    = 2ull << 2;    // MAIR index 2; index 0 is normal write-back memory
constexpr uint64_t PTE_USER      = 1ull << 6;    // AP[1]
constexpr uint64_t PTE_READ_ONLY = 1ull << 7;    // AP[2]
constexpr uint64_t PTE_SH_INNER  = 3ull << 8;
constexpr uint64_t PTE_AF        = 1ull << 10;
constexpr uint64_t PTE_NG        = 1ull << 11;   // not global: user mappings belong to one address space
constexpr uint64_t PTE_PXN       = 1ull << 53;
constexpr uint64_t PTE_UXN       = 1ull << 54;
constexpr uint64_t PTE_ADDR      = 0x0000'ffff'ffff'f000;

static bool     arch_pte_valid(uint64_t e) { return e & PTE_VALID; }
static bool     arch_pte_is_table(uint64_t e, int level) { return level < 3 && (e & PTE_TABLE); }
static uint64_t arch_pte_addr(uint64_t e) { return e & PTE_ADDR; }
static uint64_t arch_pte_table(uint64_t pa) { return pa | PTE_TABLE | PTE_VALID; }

static uint64_t arch_pte_leaf(uint64_t pa, uint32_t flags, int level) {
    uint64_t e = pa | PTE_AF | PTE_VALID | (level == 3 ? PTE_TABLE : 0);
    e |= flags & MAP_DEVICE ? PTE_DEVICE : PTE_SH_INNER;
    if (!(flags & MAP_WRITE)) e |= PTE_READ_ONLY;
    if (flags & MAP_USER) {
        e |= PTE_USER | PTE_NG | PTE_PXN;   // the kernel never executes user pages
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
constexpr uint64_t GICD_PHYS       = 0x0800'0000;
constexpr uint64_t GICD_SIZE       = 0x1'0000;
constexpr uint64_t GICR_PHYS       = 0x080a'0000;
constexpr uint64_t GICR_FRAME_SIZE = 0x2'0000;

// The user half has its own tables in TTBR0; the kernel's stay in TTBR1.
static uint64_t arch_new_user_root(void) { return phys_alloc_zeroed(0); }

// Without ASIDs yet, switching address spaces drops every cached translation.
static void arch_switch_user_root(uint64_t root) {
    __asm__ volatile("msr ttbr0_el1, %0\n\t"
                     "isb\n\t"
                     "tlbi vmalle1\n\t"
                     "dsb ish\n\t"
                     "isb"
                     : : "r"(root) : "memory");
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
    uint64_t empty = phys_alloc_zeroed(0);
    if (!empty) panic(VX_STR("no memory for page tables"));
    __asm__ volatile(
        "dsb ishst\n\t"
        "msr ttbr1_el1, %0\n\t"
        "msr ttbr0_el1, %1\n\t"
        "isb\n\t"
        "tlbi vmalle1\n\t"
        "dsb ish\n\t"
        "isb"
        : : "r"(root), "r"(empty) : "memory");
}

// --- Console ---

static void arch_console_init(void) {
    if (!boot.hhdm) return;
    write_mair(read_mair() & ~(0xffull << 16));   // attribute 2 = 0x00: Device-nGnRnE
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

constexpr uint32_t INTID_VIRTUAL_TIMER = 27;   // a PPI

static uint64_t arch_counter(void) {
    uint64_t v;
    __asm__ volatile("isb\n\tmrs %0, cntvct_el0" : "=r"(v));
    return v;
}

static uint64_t arch_counter_hz(void) {
    uint64_t v;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(v));
    return v;
}

static volatile uint32_t *gicr_sgi;   // this CPU's redistributor, SGI and PPI frame

static void arch_timer_init(void) {
    volatile uint32_t *gicd = (volatile uint32_t *)(boot.hhdm + GICD_PHYS);
    gicd[0] = 1u << 4 | 1u << 1 | 1u << 0;   // GICD_CTLR: affinity routing, both groups enabled

    // Find this CPU's redistributor by its affinity.
    uint64_t mpidr;
    __asm__ volatile("mrs %0, mpidr_el1" : "=r"(mpidr));
    uint32_t aff = (uint32_t)((mpidr >> 32 & 0xff) << 24 | (mpidr & 0xffffff));
    uint8_t *rd = nullptr;
    for (uint64_t i = 0; i < (boot.cpu_count ? boot.cpu_count : 1); i++) {
        uint8_t *frame = (uint8_t *)(boot.hhdm + GICR_PHYS + i * GICR_FRAME_SIZE);
        uint64_t typer = *(volatile uint64_t *)(frame + 0x08);
        if ((uint32_t)(typer >> 32) == aff) { rd = frame; break; }
        if (typer & (1u << 4)) break;   // the last redistributor
    }
    if (!rd) panic(VX_STR("no GIC redistributor for this CPU"));

    volatile uint32_t *waker = (volatile uint32_t *)(rd + 0x14);
    *waker &= ~(1u << 1);           // clear ProcessorSleep
    while (*waker & (1u << 2)) {}   // wait for ChildrenAsleep to clear

    gicr_sgi = (volatile uint32_t *)(rd + 0x1'0000);
    gicr_sgi[0x080 / 4] |= 1u << INTID_VIRTUAL_TIMER;   // GICR_IGROUPR0: group 1
    ((volatile uint8_t *)gicr_sgi)[0x400 + INTID_VIRTUAL_TIMER] = 0x80;   // priority
    gicr_sgi[0x100 / 4] = 1u << INTID_VIRTUAL_TIMER;   // GICR_ISENABLER0

    // The CPU interface, through system registers.
    uint64_t sre;
    __asm__ volatile("mrs %0, icc_sre_el1" : "=r"(sre));
    __asm__ volatile("msr icc_sre_el1, %0\n\tisb" : : "r"(sre | 1));
    __asm__ volatile("msr icc_pmr_el1, %0\n\t"
                     "msr icc_bpr1_el1, xzr\n\t"
                     "msr icc_igrpen1_el1, %1\n\t"
                     "isb"
                     : : "r"(0xffull), "r"(1ull));
}

static void arch_timer_arm(uint64_t count) {
    __asm__ volatile("msr cntv_cval_el0, %0\n\t"
                     "msr cntv_ctl_el0, %1\n\t"   // enabled, not masked
                     "isb"
                     : : "r"(count), "r"(1ull));
}

// wfi wakes on a pending interrupt even while IRQs are masked; unmasking for a
// moment then takes it.
static void arch_wait(void) {
    __asm__ volatile("wfi\n\t"
                     "msr daifclr, #2\n\t"
                     "isb\n\t"
                     "msr daifset, #2"
                     : : : "memory");
}

static void aarch64_irq(void) {
    uint64_t iar;
    __asm__ volatile("mrs %0, icc_iar1_el1" : "=r"(iar));
    uint32_t intid = (uint32_t)iar & 0xffffff;
    if (intid >= 1020) return;   // spurious
    if (intid == INTID_VIRTUAL_TIMER) {
        __asm__ volatile("msr cntv_ctl_el0, xzr\n\tisb");   // disarm: the line is level-triggered
        timer_interrupt();
    }
    __asm__ volatile("msr icc_eoir1_el1, %0" : : "r"(iar));
}

// --- Exceptions ---

extern const uint8_t aarch64_vectors[];   // vectors.S

static void arch_cpu_init(void) {
    __asm__ volatile("msr vbar_el1, %0\n\tisb" : : "r"(aarch64_vectors) : "memory");
}

typedef struct trap_frame {   // the layout vectors.S builds
    uint64_t x[31];           // x29 is the frame pointer, x30 the link register
    uint64_t elr, spsr, esr, far;
    uint64_t sp_el0;          // the user stack pointer
} trap_frame;
static_assert(sizeof(trap_frame) == 288);   // as vectors.S reserves; a multiple of 16

static const char *const VECTOR_KINDS[4] = { "synchronous exception", "IRQ", "FIQ", "SError" };

// --- Threads ---

static void arch_set_kernel_stack(uint64_t top) {
    (void)top;   // SP_EL1 is already the current thread's stack: exceptions land on it
}

extern const uint8_t thread_trampoline[];   // vectors.S
[[noreturn]] void arch_enter_frame(trap_frame *f);

// A new thread's stack, as arch_context_switch will pop it: x19 to x30, with
// x19 carrying the thread and x30 returning into thread_trampoline. It starts
// below the space its first trap frame takes at the top of the stack, so
// arch_enter_user can build that frame without overwriting itself.
static uint64_t arch_thread_initial_sp(thread *t) {
    uint64_t *sp = (uint64_t *)((trap_frame *)thread_kstack_top(t) - 1) - 12;
    sp[0]  = (uint64_t)t;                   // x19
    sp[11] = (uint64_t)thread_trampoline;   // x30
    return (uint64_t)sp;
}

// Enters EL0 at entry with interrupts unmasked (SPSR = 0: EL0t, DAIF clear).
[[noreturn]] static void arch_enter_user(uint64_t entry, uint64_t sp, uint64_t arg, uint64_t kstack_top) {
    trap_frame *f = (trap_frame *)kstack_top - 1;
    *f = (trap_frame){ .x = { arg }, .elr = entry, .spsr = 0, .sp_el0 = sp };
    arch_enter_frame(f);
}

// Describes an exception: "page fault at 0x... (read, not present, user)", say.
static void kput_exception(const trap_frame *f, uint64_t index) {
    uint32_t ec  = (uint32_t)(f->esr >> 26) & 0x3f;
    uint32_t iss = (uint32_t)f->esr & 0x1ffffff;
    if ((index & 3) == 0 && (ec == 0x24 || ec == 0x25)) {   // data abort
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
        kput(VX_STR("undefined behaviour (UBSan trap)"));   // -fsanitize-trap emits brk #0x55xx
    } else {
        kput_cstr(VECTOR_KINDS[index & 3]);
        kput(VX_STR(", ESR "));
        kput_hex(f->esr);
    }
}

constexpr uint32_t EC_SVC64 = 0x15;

void aarch64_trap(trap_frame *f, uint64_t index) {
    bool from_user = index >= 8;
    uint32_t ec    = (uint32_t)(f->esr >> 26) & 0x3f;
    if ((index & 3) == 1) {   // IRQ
        aarch64_irq();
    } else if (from_user && (index & 3) == 0 && ec == EC_SVC64) {
        f->x[0] = (uint64_t)syscall_dispatch(f->x[8], f->x);
    } else if (from_user) {
        task_fault_start();
        kput_exception(f, index);
        kput(VX_STR(" at pc "));
        kput_hex(f->elr);
        kput(VX_STR("\n"));
        thread_kill_current();
    } else {
        panic_start();
        kput_exception(f, index);
        kput(VX_STR(" at pc "));
        kput_hex(f->elr);
        panic_end(f->elr, f->x[29]);
    }
    if (from_user && sched.resched) schedule();
}

[[noreturn]] static void arch_halt(void) {
    for (;;) __asm__ volatile("msr daifset, #0xf\n\twfi");
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
