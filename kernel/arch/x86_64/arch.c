// arch.c (x86_64): the entry point and the early serial console (COM1, a 16550).

static inline void outb(uint16_t port, uint8_t value) {
    __asm__ volatile("outb %0, %1" : : "a"(value), "Nd"(port));
}

static inline uint8_t inb(uint16_t port) {
    uint8_t value;
    __asm__ volatile("inb %1, %0" : "=a"(value) : "Nd"(port));
    return value;
}

constexpr uint16_t COM1 = 0x3f8;

static void arch_console_init(void) {
    outb(COM1 + 1, 0x00);   // no interrupts
    outb(COM1 + 3, 0x80);   // divisor latch on
    outb(COM1 + 0, 0x01);   // divisor 1: 115200 baud
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03);   // 8 bits, no parity, one stop bit; latch off
    outb(COM1 + 2, 0xc7);   // FIFOs on and cleared
}

static void serial_putc(uint8_t c) {
    while (!(inb(COM1 + 5) & 0x20)) {}   // wait for an empty transmit register
    outb(COM1, c);
}

static void arch_console_write(vx_str s) {
    for (size_t i = 0; i < s.len; i++) {
        if (s.ptr[i] == '\n') serial_putc('\r');
        serial_putc((uint8_t)s.ptr[i]);
    }
}

// --- GDT, TSS and IDT ---

// Selectors. SYSRET (step 5) needs user data just below user code.
constexpr uint16_t SEL_KERNEL_CODE = 0x08;
constexpr uint16_t SEL_KERNEL_DATA = 0x10;
constexpr uint16_t SEL_TSS         = 0x28;

typedef struct [[gnu::packed]] tss {
    uint32_t reserved0;
    uint64_t rsp[3];       // stacks for entering rings 0-2 from user mode
    uint64_t reserved1;
    uint64_t ist[7];       // the interrupt stack table: IST1..IST7
    uint64_t reserved2;
    uint16_t reserved3;
    uint16_t iomap_base;
} tss;

typedef struct [[gnu::packed]] descriptor_ptr {
    uint16_t limit;
    uint64_t base;
} descriptor_ptr;

typedef struct idt_entry {
    uint16_t offset_low;
    uint16_t selector;
    uint8_t  ist;
    uint8_t  type;         // 0x8e: present interrupt gate, DPL 0
    uint16_t offset_mid;
    uint32_t offset_high;
    uint32_t reserved;
} idt_entry;
static_assert(sizeof(idt_entry) == 16);

// Double faults, NMIs and machine checks run on stacks of their own, so a
// kernel stack overflow or a fault at the wrong moment still reaches the panic.
enum : uint8_t { IST_DOUBLE_FAULT = 1, IST_NMI = 2, IST_MACHINE_CHECK = 3 };
alignas(16) static uint8_t ist_stacks[3][8192];

static uint64_t gdt[7] = {
    0,
    0x00af9a000000ffff,    // 0x08 kernel code, 64-bit
    0x00cf92000000ffff,    // 0x10 kernel data
    0x00cff2000000ffff,    // 0x18 user data
    0x00affa000000ffff,    // 0x20 user code, 64-bit
    0, 0,                  // 0x28 the TSS, 16 bytes, filled in at run time
};
static tss       cpu_tss = { .iomap_base = sizeof(tss) };
static idt_entry idt[256];

extern const uint64_t x86_vector_table[256];   // entry.S

static inline uint64_t rdmsr(uint32_t msr) {
    uint32_t lo, hi;
    __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr));
    return (uint64_t)hi << 32 | lo;
}

static inline void wrmsr(uint32_t msr, uint64_t v) {
    __asm__ volatile("wrmsr" : : "c"(msr), "a"((uint32_t)v), "d"((uint32_t)(v >> 32)));
}

constexpr uint32_t MSR_EFER = 0xc0000080;

static void arch_cpu_init(void) {
    wrmsr(MSR_EFER, rdmsr(MSR_EFER) | 1ull << 11);   // NXE: the NX bit is honoured
    uint64_t cr0;
    __asm__ volatile("mov %%cr0, %0" : "=r"(cr0));
    __asm__ volatile("mov %0, %%cr0" : : "r"(cr0 | 1ull << 16));   // WP: read-only means read-only, for the kernel too

    for (int i = 0; i < 3; i++) cpu_tss.ist[i] = (uint64_t)&ist_stacks[i][sizeof ist_stacks[i]];
    uint64_t base = (uint64_t)&cpu_tss, limit = sizeof(tss) - 1;
    gdt[5] = (limit & 0xffff) | (base & 0xffffff) << 16 | 0x89ull << 40 | ((limit >> 16) & 0xf) << 48 |
             ((base >> 24) & 0xff) << 56;
    gdt[6] = base >> 32;

    descriptor_ptr gp = { .limit = sizeof gdt - 1, .base = (uint64_t)gdt };
    __asm__ volatile(
        "lgdt %0\n\t"
        "pushq %1\n\t"
        "leaq 1f(%%rip), %%rax\n\t"
        "pushq %%rax\n\t"
        "lretq\n"
        "1:\n\t"
        "movw %2, %%ax\n\t"
        "movw %%ax, %%ds\n\t"
        "movw %%ax, %%es\n\t"
        "movw %%ax, %%ss\n\t"
        "ltr %3"
        : : "m"(gp), "i"((uint64_t)SEL_KERNEL_CODE), "i"(SEL_KERNEL_DATA), "r"(SEL_TSS) : "rax", "memory");

    for (int v = 0; v < 256; v++) {
        uint64_t h = x86_vector_table[v];
        idt[v] = (idt_entry){
            .offset_low = (uint16_t)h, .selector = SEL_KERNEL_CODE, .type = 0x8e,
            .offset_mid = (uint16_t)(h >> 16), .offset_high = (uint32_t)(h >> 32),
        };
    }
    idt[8].ist  = IST_DOUBLE_FAULT;
    idt[2].ist  = IST_NMI;
    idt[18].ist = IST_MACHINE_CHECK;
    descriptor_ptr ip = { .limit = sizeof idt - 1, .base = (uint64_t)idt };
    __asm__ volatile("lidt %0" : : "m"(ip) : "memory");
}

// --- Traps ---

typedef struct trap_frame {   // the layout entry.S builds
    uint64_t rax, rbx, rcx, rdx, rsi, rdi, rbp, r8, r9, r10, r11, r12, r13, r14, r15;
    uint64_t vector, error;
    uint64_t rip, cs, rflags, rsp, ss;   // pushed by the CPU
} trap_frame;

static const char *const EXCEPTION_NAMES[32] = {
    "divide error", "debug", "NMI", "breakpoint", "overflow", "bound range", "invalid opcode",
    "device not available", "double fault", "coprocessor segment overrun", "invalid TSS",
    "segment not present", "stack fault", "general protection fault", "page fault", "reserved",
    "x87 floating-point error", "alignment check", "machine check", "SIMD floating-point error",
    "virtualization exception", "control protection fault",
};

static inline uint64_t read_cr2(void) {
    uint64_t v;
    __asm__ volatile("mov %%cr2, %0" : "=r"(v));
    return v;
}

// --- The clock and the timer: TSC, and the local APIC in x2APIC mode ---
//
// The timer uses TSC-deadline mode where the CPU has it. Otherwise (QEMU
// without KVM, for one) it uses the APIC's own one-shot countdown, calibrated
// against the TSC at boot; time.c re-arms if a countdown ends early.

constexpr uint32_t MSR_APIC_BASE      = 0x1b;
constexpr uint32_t MSR_TSC_DEADLINE   = 0x6e0;
constexpr uint32_t X2APIC_EOI         = 0x80b;
constexpr uint32_t X2APIC_SPURIOUS    = 0x80f;
constexpr uint32_t X2APIC_LVT_TIMER   = 0x832;
constexpr uint32_t X2APIC_INITIAL     = 0x838;
constexpr uint32_t X2APIC_CURRENT     = 0x839;
constexpr uint32_t X2APIC_DIVIDE      = 0x83e;

static bool     tsc_deadline;
static uint64_t apic_per_tsc;   // APIC timer ticks per TSC tick, << 32
constexpr uint8_t  VECTOR_TIMER     = 0x20;
constexpr uint8_t  VECTOR_SPURIOUS  = 0xff;

static inline void cpuid(uint32_t leaf, uint32_t *a, uint32_t *b, uint32_t *c, uint32_t *d) {
    __asm__ volatile("cpuid" : "=a"(*a), "=b"(*b), "=c"(*c), "=d"(*d) : "a"(leaf), "c"(0));
}

static uint64_t arch_counter(void) {
    uint32_t lo, hi;
    __asm__ volatile("lfence\n\trdtsc" : "=a"(lo), "=d"(hi));
    return (uint64_t)hi << 32 | lo;
}

static uint64_t arch_counter_hz(void) {
    return tsc_request.response ? tsc_request.response->frequency : 0;
}

static void arch_timer_init(void) {
    uint32_t a, b, c, d;
    cpuid(1, &a, &b, &c, &d);
    if (!(c & (1u << 21))) panic(VX_STR("the CPU has no x2APIC"));
    tsc_deadline = c & (1u << 24);

    outb(0x21, 0xff);   // mask both legacy PICs: interrupts come through the APICs only
    outb(0xa1, 0xff);
    wrmsr(MSR_APIC_BASE, rdmsr(MSR_APIC_BASE) | 1ull << 11 | 1ull << 10);   // enabled, x2APIC mode
    wrmsr(X2APIC_SPURIOUS, 0x100 | VECTOR_SPURIOUS);                       // software-enabled

    if (tsc_deadline) {
        wrmsr(X2APIC_LVT_TIMER, VECTOR_TIMER | 2u << 17);   // TSC-deadline mode
        __asm__ volatile("mfence" : : : "memory");          // the mode change lands before the first deadline
        return;
    }
    // One-shot mode, masked while it is measured against the TSC for 1 ms.
    wrmsr(X2APIC_DIVIDE, 0xb);   // divide by 1
    wrmsr(X2APIC_LVT_TIMER, VECTOR_TIMER | 1u << 16);
    uint64_t t0 = arch_counter(), wait = clock.hz / 1000;
    wrmsr(X2APIC_INITIAL, 0xffffffff);
    while (arch_counter() - t0 < wait) {}
    uint64_t ticks = 0xffffffff - rdmsr(X2APIC_CURRENT), elapsed = arch_counter() - t0;
    wrmsr(X2APIC_INITIAL, 0);
    apic_per_tsc = (ticks << 32) / elapsed;
    wrmsr(X2APIC_LVT_TIMER, VECTOR_TIMER);   // one-shot, unmasked
}

static void arch_timer_arm(uint64_t count) {
    if (tsc_deadline) {
        wrmsr(MSR_TSC_DEADLINE, count ? count : 1);   // 0 would disarm it
        return;
    }
    uint64_t now = arch_counter();
    uint64_t ticks = count > now ? (uint64_t)(((unsigned __int128)(count - now) * apic_per_tsc) >> 32) : 1;
    wrmsr(X2APIC_INITIAL, ticks == 0 ? 1 : ticks > 0xffffffff ? 0xffffffff : ticks);
}

// Enables interrupts for exactly one halt: sti takes effect after the next
// instruction, so an interrupt cannot slip in between and be missed.
static void arch_wait(void) {
    __asm__ volatile("sti\n\thlt\n\tcli" : : : "memory");
}

void x86_trap(trap_frame *f) {
    if (f->vector == VECTOR_TIMER) {
        wrmsr(X2APIC_EOI, 0);
        timer_interrupt();
        return;
    }
    if (f->vector == VECTOR_SPURIOUS) return;

    panic_start();
    if (f->vector == 14) {
        kput(VX_STR("page fault at "));
        kput_hex(read_cr2());
        kput(f->error & 16 ? VX_STR(" (execute, ") : f->error & 2 ? VX_STR(" (write, ") : VX_STR(" (read, "));
        kput(f->error & 1 ? VX_STR("protection") : VX_STR("not present"));
        kput(f->error & 4 ? VX_STR(", user)") : VX_STR(", kernel)"));
    } else if (f->vector == 6 && ((const uint8_t *)f->rip)[0] == 0x0f && ((const uint8_t *)f->rip)[1] == 0xb9) {
        kput(VX_STR("undefined behaviour (UBSan trap)"));   // -fsanitize-trap emits ud1 (0f b9)
    } else if (f->vector < 32 && EXCEPTION_NAMES[f->vector]) {
        kput_cstr(EXCEPTION_NAMES[f->vector]);
        kput(VX_STR(", error code "));
        kput_hex(f->error);
    } else {
        kput(VX_STR("unexpected interrupt "));
        kput_u64(f->vector);
    }
    kput(VX_STR(" at rip "));
    kput_hex(f->rip);
    panic_end(f->rip, f->rbp);
}

[[noreturn]] static void arch_halt(void) {
    for (;;) __asm__ volatile("cli; hlt");
}

// --- Page tables ---

constexpr uint64_t X86_PRESENT = 1ull << 0;
constexpr uint64_t X86_WRITE   = 1ull << 1;
constexpr uint64_t X86_USER    = 1ull << 2;
constexpr uint64_t X86_PWT     = 1ull << 3;
constexpr uint64_t X86_PCD     = 1ull << 4;
constexpr uint64_t X86_LARGE   = 1ull << 7;   // a 2 MiB or 1 GiB leaf
constexpr uint64_t X86_NX      = 1ull << 63;
constexpr uint64_t X86_ADDR    = 0x000f'ffff'ffff'f000;

static bool     arch_pte_valid(uint64_t e) { return e & X86_PRESENT; }
static bool     arch_pte_is_table(uint64_t e, int level) { return level < 3 && !(e & X86_LARGE); }
static uint64_t arch_pte_addr(uint64_t e) { return e & X86_ADDR; }

// Tables allow everything; the leaf decides.
static uint64_t arch_pte_table(uint64_t pa) { return pa | X86_USER | X86_WRITE | X86_PRESENT; }

static uint64_t arch_pte_leaf(uint64_t pa, uint32_t flags, int level) {
    uint64_t e = pa | X86_PRESENT;
    if (flags & MAP_WRITE) e |= X86_WRITE;
    if (flags & MAP_USER) e |= X86_USER;
    if (!(flags & MAP_EXEC)) e |= X86_NX;
    if (flags & MAP_DEVICE) e |= X86_PCD | X86_PWT;   // uncached under the default PAT
    if (level < 3) e |= X86_LARGE;
    return e;
}

static void arch_kernel_mappings(uint64_t root) {
    (void)root;   // COM1 is an I/O port; nothing to map yet
}

static void arch_switch_tables(uint64_t root) {
    uint64_t cr4;
    __asm__ volatile("mov %%cr4, %0" : "=r"(cr4));
    __asm__ volatile(
        "mov %0, %%cr3\n\t"
        "mov %1, %%cr4\n\t"   // clearing and restoring PGE drops global entries Limine may have left
        "mov %2, %%cr4"
        : : "r"(root), "r"(cr4 & ~(1ull << 7)), "r"(cr4) : "memory");
}

// Limine enters here in long mode, with the higher half mapped, on a stack of
// its own. The kernel moves to its boot stack (the linker script), clears the
// frame pointer so backtraces end here, and never returns.
[[gnu::naked, noreturn]] void _start(void) {
    __asm__("endbr64\n\t"
            "leaq vx_boot_stack_top(%rip), %rsp\n\t"
            "xorl %ebp, %ebp\n\t"
            "call kernel_main\n\t"
            "ud2");
}
