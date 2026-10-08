// arch.c (x86_64): the entry point and the early serial console (COM1, a 16550).

static inline void outb(uint16_t port, uint8_t value) {
  __asm__ volatile("outb %0, %1" : : "a"(value), "Nd"(port));
}

static inline uint8_t inb(uint16_t port) {
  uint8_t value;
  __asm__ volatile("inb %1, %0" : "=a"(value) : "Nd"(port));
  return value;
}

static constexpr uint16_t COM1 = 0x3f8;

static void arch_console_init(void) {
  outb(COM1 + 1, 0x00); // no interrupts
  outb(COM1 + 3, 0x80); // divisor latch on
  outb(COM1 + 0, 0x01); // divisor 1: 115200 baud
  outb(COM1 + 1, 0x00);
  outb(COM1 + 3, 0x03); // 8 bits, no parity, one stop bit; latch off
  outb(COM1 + 2, 0xc7); // FIFOs on and cleared
}

static void serial_putc(uint8_t c) {
  while (!(inb(COM1 + 5) & 0x20)) {} // wait for an empty transmit register
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
static constexpr uint16_t SEL_KERNEL_CODE = 0x08;
static constexpr uint16_t SEL_KERNEL_DATA = 0x10;
static constexpr uint16_t SEL_USER_DATA = 0x18 | 3;
static constexpr uint16_t SEL_USER_CODE = 0x20 | 3;
static constexpr uint16_t SEL_TSS = 0x28;

typedef struct [[gnu::packed]] tss {
  uint32_t reserved0;
  uint64_t rsp[3]; // stacks for entering rings 0-2 from user mode
  uint64_t reserved1;
  uint64_t ist[7]; // the interrupt stack table: IST1..IST7
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
  uint8_t ist;
  uint8_t type; // 0x8e: present interrupt gate, DPL 0
  uint16_t offset_mid;
  uint32_t offset_high;
  uint32_t reserved;
} idt_entry;
static_assert(sizeof(idt_entry) == 16);

// Double faults, NMIs and machine checks run on stacks of their own, so a
// kernel stack overflow or a fault at the wrong moment still reaches the panic.
enum : uint8_t { IST_DOUBLE_FAULT = 1, IST_NMI = 2, IST_MACHINE_CHECK = 3 };
static constexpr size_t IST_STACK_SIZE = 8192;
alignas(16) static uint8_t boot_ist_stacks[3][IST_STACK_SIZE]; // the boot CPU's, before the allocator exists

static const uint64_t GDT_TEMPLATE[7] = {
    0,
    0x00af9a000000ffff, // 0x08 kernel code, 64-bit
    0x00cf92000000ffff, // 0x10 kernel data
    0x00cff2000000ffff, // 0x18 user data
    0x00affa000000ffff, // 0x20 user code, 64-bit
    0,
    0, // 0x28 the TSS, 16 bytes, filled in per CPU
};

// Per-CPU data at %gs while in the kernel; entry.S reads the first two fields.
typedef struct cpu_local {
  uint64_t kernel_rsp; // the current thread's kernel stack top
  uint64_t user_rsp;   // scratch for SYSCALL
  uint64_t index;      // this CPU's index, for arch_cpu_index
} cpu_local;

// Each CPU has its own GDT (for its own TSS descriptor), TSS and GS data. The
// IDT is shared. The TSS's I/O permission bitmap follows it: a 0 bit lets user
// code use that port. It holds the ports of the task this CPU runs
// (arch_io_switch), and `open` remembers which, to close them again.
static constexpr uint32_t IO_PORTS = 0x1'0000;

typedef struct x86_cpu {
  uint64_t gdt[7];
  tss tss;
  uint8_t iomap[IO_PORTS / 8 + 1]; // one bit a port, then the 0xff the CPU requires after the last
  uint32_t open;
  uint16_t open_base[TASK_MAX_IO];
  uint32_t open_count[TASK_MAX_IO];
  cpu_local local;
} x86_cpu;
static_assert(offsetof(x86_cpu, iomap) == offsetof(x86_cpu, tss) + sizeof(tss));

static x86_cpu x86_cpus[MAX_CPUS];
static idt_entry idt[256];
static bool percpu_ready; // %gs holds this CPU's cpu_local

extern const uint64_t x86_vector_table[256]; // entry.S

static inline uint64_t rdmsr(uint32_t msr) {
  uint32_t lo, hi;
  __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr));
  return (uint64_t)hi << 32 | lo;
}

static inline void wrmsr(uint32_t msr, uint64_t v) {
  __asm__ volatile("wrmsr" : : "c"(msr), "a"((uint32_t)v), "d"((uint32_t)(v >> 32)));
}

static constexpr uint32_t MSR_EFER = 0xc0000080;
static constexpr uint32_t MSR_STAR = 0xc0000081;
static constexpr uint32_t MSR_LSTAR = 0xc0000082;
static constexpr uint32_t MSR_FMASK = 0xc0000084;
static constexpr uint32_t MSR_GS_BASE = 0xc0000101;
static constexpr uint32_t MSR_KERNEL_GS_BASE = 0xc0000102;

extern const uint8_t syscall_entry[]; // entry.S

static uint32_t arch_cpu_index(void) {
  if (!percpu_ready) return 0;
  uint64_t index;
  __asm__ volatile("movq %%gs:16, %0" : "=r"(index));
  return (uint32_t)index;
}

static void arch_pause(void) { __asm__ volatile("pause"); }

static void build_idt(void) {
  for (int v = 0; v < 256; v++) {
    uint64_t h = x86_vector_table[v];
    idt[v] = (idt_entry){
        .offset_low = (uint16_t)h,
        .selector = SEL_KERNEL_CODE,
        .type = 0x8e,
        .offset_mid = (uint16_t)(h >> 16),
        .offset_high = (uint32_t)(h >> 32),
    };
  }
  idt[3].type = 0xee; // int3 may come from user mode (DPL 3): a breakpoint, not a #GP
  idt[8].ist = IST_DOUBLE_FAULT;
  idt[2].ist = IST_NMI;
  idt[18].ist = IST_MACHINE_CHECK;
}

// --- FP/SIMD state (ADR-0035) ---
//
// Every user component the CPU has, saved with XSAVE (XSAVEOPT where there is
// one) in the standard format: x87, SSE and AVX, and AVX-512's opmask, upper
// ZMM halves and ZMM16-31 when it has all three. Not MPX, which is gone, nor
// AMX, whose 8 KiB of tiles want a permission first (as Linux asks). The
// layout is CPUID's, the same on every CPU.

static constexpr uint64_t XFEATURES_USER = 0x7 | 0xe0;
static constexpr uint64_t XFEATURE_PKRU = 1ull << 9;  // protection keys' rights, saved with the rest (6c4)
static constexpr uint32_t PKRU_DEFAULT = 0x5555'5554; // key 0 open; every other key's access disabled
static constexpr uint64_t XFEATURES_AVX512 = 0xe0;
static uint64_t xcr0; // the components saved: set on every CPU from the boot CPU's
static uint32_t xsave_size, mxcsr_mask = 0xffbf;
static uint32_t xcomp_off[10], xcomp_size[10]; // each component's place, 2 to 9
static bool have_xsaveopt, have_pku;           // PKU: CPUID.7.0:ECX[3], and CR4.PKE set

typedef struct cpuid4 {
  uint32_t a, b, c, d;
} cpuid4;

static cpuid4 cpuid_sub(uint32_t leaf, uint32_t sub) {
  cpuid4 r;
  __asm__ volatile("cpuid" : "=a"(r.a), "=b"(r.b), "=c"(r.c), "=d"(r.d) : "a"(leaf), "c"(sub));
  return r;
}

// XCR0 for this CPU (CR4.OSXSAVE set already); on the boot CPU, first what to
// save and its layout. VectraOS's userland is x86-64-v3, so XSAVE is required.
static void xsave_init(uint32_t index) {
  cpuid4 r;
  if (index == 0) {
    r = cpuid_sub(1, 0);
    if (!(r.c & 1u << 26)) panic(VX_STR("no XSAVE: VectraOS needs x86-64-v3 (AVX2)"));
    r = cpuid_sub(0xd, 0);
    uint64_t can = (uint64_t)r.d << 32 | r.a;
    xcr0 = can & XFEATURES_USER;
    if (have_pku && (can & XFEATURE_PKRU)) xcr0 |= XFEATURE_PKRU;
    have_pku = xcr0 & XFEATURE_PKRU;
    if ((xcr0 & XFEATURES_AVX512) != XFEATURES_AVX512) xcr0 &= ~XFEATURES_AVX512; // all three, or none
    r = cpuid_sub(0xd, 1);
    have_xsaveopt = r.a & 1;
    for (uint32_t i = 2; i < 10; i++)
      if (xcr0 & 1ull << i) r = cpuid_sub(0xd, i), xcomp_size[i] = r.a, xcomp_off[i] = r.b;
  }
  __asm__ volatile("xsetbv" : : "c"(0), "a"((uint32_t)xcr0), "d"((uint32_t)(xcr0 >> 32)));
  if (index == 0) {
    r = cpuid_sub(0xd, 0); // EBX: the standard format's size for XCR0 as it is now
    xsave_size = r.b;
    if (xsave_size > ARCH_FP_MAX) panic(VX_STR("the XSAVE area is larger than a page"));
    alignas(16) uint8_t fx[512] = {};
    __asm__ volatile("fxsave64 %0" : "=m"(fx));
    uint32_t mask;
    memcpy(&mask, fx + 28, sizeof mask); // MXCSR_MASK: 0 means the default
    if (mask) mxcsr_mask = mask;
  }
}

// Per CPU: control registers and MSRs, this CPU's GDT, TSS and GS data, and
// the shared IDT (built by the boot CPU).
static void arch_cpu_init(uint32_t index) {
  x86_cpu *xc = &x86_cpus[index];
  // NXE: the NX bit is honoured. SCE: SYSCALL and SYSRET are enabled.
  wrmsr(MSR_EFER, rdmsr(MSR_EFER) | 1ull << 11 | 1ull << 0);
  // SYSCALL loads CS 0x08 and SS 0x10. SYSRET (not used yet; returns go
  // through IRETQ) would load SS 0x18|3 and CS 0x20|3.
  wrmsr(MSR_STAR, (uint64_t)0x10 << 48 | (uint64_t)SEL_KERNEL_CODE << 32);
  wrmsr(MSR_LSTAR, (uint64_t)syscall_entry);
  wrmsr(MSR_FMASK, 0x47700); // clear TF, IF, DF, NT and AC on entry
  xc->local.index = index;
  wrmsr(MSR_GS_BASE, (uint64_t)&xc->local);
  wrmsr(MSR_KERNEL_GS_BASE, 0);
  uint64_t cr0;
  __asm__ volatile("mov %%cr0, %0" : "=r"(cr0));
  // WP: read-only means read-only, for the kernel too. MP and NE, without EM
  // or TS: x87 and SSE run, their errors as exceptions, and the kernel saves
  // them with XSAVE at each switch (arch_user_switch). The kernel itself
  // uses none.
  __asm__ volatile("mov %0, %%cr0"
                   :
                   : "r"((cr0 | 1ull << 16 | 1ull << 5 | 1ull << 1) & ~(1ull << 2 | 1ull << 3)));
  uint64_t cr4;
  __asm__ volatile("mov %%cr4, %0" : "=r"(cr4));
  // PKE: protection keys (ADR-0035), where the CPU has PKU, their rights a
  // thread's PKRU in its XSAVE state.
  if (index == 0) have_pku = cpuid_sub(7, 0).c >> 3 & 1;
  // OSFXSR and OSXMMEXCPT: SSE, with its exceptions as #XM. OSXSAVE: XSAVE,
  // and AVX and AVX-512 for user code, saved whole (xsave_init). FSGSBASE off: user code
  // changes its FS base only through thread_state, and never its GS base,
  // which swapgs relies on. TSD off: user code may always read the cycle
  // counter (02 §5.1, 05 §9), whatever the firmware left.
  __asm__ volatile("mov %0, %%cr4"
                   :
                   : "r"((cr4 | 1ull << 9 | 1ull << 10 | 1ull << 18 | (have_pku ? 1ull << 22 : 0)) &
                         ~(1ull << 2 | 1ull << 16)));
  xsave_init(index);

  uint8_t *ist = index == 0 ? &boot_ist_stacks[0][0] : nullptr;
  if (!ist) {
    uint64_t pa = phys_alloc_zeroed(3); // 32 KiB: three 8 KiB stacks
    if (!pa) panic(VX_STR("no memory for interrupt stacks"));
    ist = phys_to_virt(pa);
  }
  xc->tss = (tss){.iomap_base = sizeof(tss)};
  memset(xc->iomap, 0xff, sizeof xc->iomap); // no ports for user code
  xc->open = 0;
  for (size_t i = 0; i < 3; i++) xc->tss.ist[i] = (uint64_t)(ist + (i + 1) * IST_STACK_SIZE);

  memcpy(xc->gdt, GDT_TEMPLATE, sizeof xc->gdt);
  uint64_t base = (uint64_t)&xc->tss, limit = sizeof(tss) + sizeof xc->iomap - 1;
  xc->gdt[5] = (limit & 0xffff) | (base & 0xffffff) << 16 | 0x89ull << 40 | ((limit >> 16) & 0xf) << 48 |
               ((base >> 24) & 0xff) << 56;
  xc->gdt[6] = base >> 32;

  descriptor_ptr gp = {.limit = sizeof xc->gdt - 1, .base = (uint64_t)xc->gdt};
  __asm__ volatile("lgdt %0\n\t"
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
                   :
                   : "m"(gp), "i"((uint64_t)SEL_KERNEL_CODE), "i"(SEL_KERNEL_DATA), "r"(SEL_TSS)
                   : "rax", "memory");

  if (index == 0) build_idt();
  descriptor_ptr ip = {.limit = sizeof idt - 1, .base = (uint64_t)idt};
  __asm__ volatile("lidt %0" : : "m"(ip) : "memory");
  percpu_ready = true;
}

// --- Traps ---

typedef struct trap_frame { // the layout entry.S builds
  uint64_t rax, rbx, rcx, rdx, rsi, rdi, rbp, r8, r9, r10, r11, r12, r13, r14, r15;
  uint64_t vector, error;
  uint64_t rip, cs, rflags, rsp, ss; // pushed by the CPU
} trap_frame;

static const char *const EXCEPTION_NAMES[32] = {
    "divide error",
    "debug",
    "NMI",
    "breakpoint",
    "overflow",
    "bound range",
    "invalid opcode",
    "device not available",
    "double fault",
    "coprocessor segment overrun",
    "invalid TSS",
    "segment not present",
    "stack fault",
    "general protection fault",
    "page fault",
    "reserved",
    "x87 floating-point error",
    "alignment check",
    "machine check",
    "SIMD floating-point error",
    "virtualization exception",
    "control protection fault",
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

static constexpr uint32_t MSR_APIC_BASE = 0x1b;
static constexpr uint32_t MSR_TSC_DEADLINE = 0x6e0;
static constexpr uint32_t X2APIC_EOI = 0x80b;
static constexpr uint32_t X2APIC_SPURIOUS = 0x80f;
static constexpr uint32_t X2APIC_LVT_TIMER = 0x832;
static constexpr uint32_t X2APIC_INITIAL = 0x838;
static constexpr uint32_t X2APIC_CURRENT = 0x839;
static constexpr uint32_t X2APIC_DIVIDE = 0x83e;

static bool tsc_deadline;
static uint64_t apic_per_tsc; // APIC timer ticks per TSC tick, << 32
static constexpr uint32_t X2APIC_ICR = 0x830;
static constexpr uint8_t VECTOR_TIMER = 0x20;
static constexpr uint8_t VECTOR_RESCHED = 0x21; // another CPU made a thread ready
static constexpr uint8_t VECTOR_SHOOTDOWN =
    0x22; // another CPU unmapped user pages: flush (arch_tlb_shootdown)
static constexpr uint8_t VECTOR_SPURIOUS = 0xff;
static constexpr uint8_t VECTOR_IRQ_BASE = 0x30; // device interrupts: VECTOR_IRQ_BASE + GSI
static constexpr uint32_t MAX_GSI = 0x50;        // up to vector 0x7f
static constexpr uint8_t VECTOR_MSI_FIRST = 0x80, VECTOR_MSI_LAST = 0xef; // MSIs: line MSI_LINE_BASE + vector

typedef struct cpuid_regs {
  uint32_t a, b, c, d;
} cpuid_regs;

static inline cpuid_regs cpuid(uint32_t leaf) {
  cpuid_regs r;
  __asm__ volatile("cpuid" : "=a"(r.a), "=b"(r.b), "=c"(r.c), "=d"(r.d) : "a"(leaf), "c"(0));
  return r;
}

static uint64_t arch_counter(void) {
  uint32_t lo, hi;
  __asm__ volatile("lfence\n\trdtsc" : "=a"(lo), "=d"(hi));
  return (uint64_t)hi << 32 | lo;
}

static uint64_t arch_counter_hz(void) { return tsc_request.response ? tsc_request.response->frequency : 0; }

// The counter's properties for /sys/clock/info: the TSC runs at one rate in
// every power state (CPUID 80000007h, EDX bit 8), and user code reads it.
static uint32_t arch_counter_flags(void) {
  uint32_t a = 0x8000'0000, b, c, d;
  __asm__ volatile("cpuid" : "+a"(a), "=b"(b), "=c"(c), "=d"(d));
  bool invariant = false;
  if (a >= 0x8000'0007) {
    a = 0x8000'0007;
    __asm__ volatile("cpuid" : "+a"(a), "=b"(b), "=c"(c), "=d"(d));
    invariant = d & (1u << 8);
  }
  return VX_CLOCK_USER | (invariant ? VX_CLOCK_INVARIANT : 0) | VX_CLOCK_TSC;
}

// Per CPU: this CPU's local APIC and its timer. The boot CPU also masks the
// legacy PICs and, without TSC-deadline mode, measures the APIC timer once.
static void arch_timer_init(void) {
  cpuid_regs features = cpuid(1);
  if (!(features.c & (1u << 21))) panic(VX_STR("the CPU has no x2APIC"));
  tsc_deadline = features.c & (1u << 24);

  if (arch_cpu_index() == 0) {
    outb(0x21, 0xff); // mask both legacy PICs: interrupts come through the APICs only
    outb(0xa1, 0xff);
  }
  wrmsr(MSR_APIC_BASE, rdmsr(MSR_APIC_BASE) | 1ull << 11 | 1ull << 10); // enabled, x2APIC mode
  wrmsr(X2APIC_SPURIOUS, 0x100 | VECTOR_SPURIOUS);                      // software-enabled

  if (tsc_deadline) {
    wrmsr(X2APIC_LVT_TIMER, VECTOR_TIMER | 2u << 17); // TSC-deadline mode
    __asm__ volatile("mfence" : : : "memory");        // the mode change lands before the first deadline
    return;
  }
  // One-shot mode, masked while it is measured against the TSC for 1 ms.
  wrmsr(X2APIC_DIVIDE, 0xb); // divide by 1
  if (apic_per_tsc) {        // measured on the boot CPU: every APIC timer runs at the same rate
    wrmsr(X2APIC_LVT_TIMER, VECTOR_TIMER);
    return;
  }
  wrmsr(X2APIC_LVT_TIMER, VECTOR_TIMER | 1u << 16);
  uint64_t t0 = arch_counter(), wait = clock.hz / 1000;
  wrmsr(X2APIC_INITIAL, 0xffffffff);
  while (arch_counter() - t0 < wait) {}
  uint64_t ticks = 0xffffffff - rdmsr(X2APIC_CURRENT), elapsed = arch_counter() - t0;
  wrmsr(X2APIC_INITIAL, 0);
  apic_per_tsc = (ticks << 32) / elapsed;
  wrmsr(X2APIC_LVT_TIMER, VECTOR_TIMER); // one-shot, unmasked
}

static void arch_timer_arm(uint64_t count) {
  if (tsc_deadline) {
    wrmsr(MSR_TSC_DEADLINE, count ? count : 1); // 0 would disarm it
    return;
  }
  uint64_t now = arch_counter();
  uint64_t ticks = count > now ? (uint64_t)(((unsigned __int128)(count - now) * apic_per_tsc) >> 32) : 1;
  if (ticks == 0) ticks = 1;
  if (ticks > 0xffffffff) ticks = 0xffffffff;
  wrmsr(X2APIC_INITIAL, ticks);
}

// A fixed interrupt to one CPU by its x2APIC ID: one 64-bit write to the ICR.
static void arch_send_resched(cpu *c) { wrmsr(X2APIC_ICR, c->arch_id << 32 | VECTOR_RESCHED); }

// Enables interrupts for exactly one halt: sti takes effect after the next
// instruction, so an interrupt cannot slip in between and be missed.
static void arch_wait(void) { __asm__ volatile("sti\n\thlt\n\tcli" : : : "memory"); }

static constexpr uint64_t VECTOR_SYSCALL = 0x100; // entry.S

// Describes an exception: "page fault at 0x... (read, not present, user)", say.
struct cpu;
static void tlb_answer(struct cpu *c); // below, with arch_tlb_shootdown

static void kput_exception(const trap_frame *f) {
  if (f->vector == 14) {
    kput(VX_STR("page fault at "));
    kput_hex(read_cr2());
    vx_str access = VX_STR(" (read, ");
    if (f->error & 2) access = VX_STR(" (write, ");
    if (f->error & 16) access = VX_STR(" (execute, ");
    kput(access);
    kput(f->error & 1 ? VX_STR("protection") : VX_STR("not present"));
    kput(f->error & 4 ? VX_STR(", user)") : VX_STR(", kernel)"));
  } else if (f->vector == 6 && !(f->cs & 3) && ((const uint8_t *)f->rip)[0] == 0x0f &&
             ((const uint8_t *)f->rip)[1] == 0xb9) {
    kput(VX_STR("undefined behaviour (UBSan trap)")); // -fsanitize-trap emits ud1 (0f b9)
  } else if (f->vector < 32 && EXCEPTION_NAMES[f->vector]) {
    kput_cstr(EXCEPTION_NAMES[f->vector]);
    kput(VX_STR(", error code "));
    kput_hex(f->error);
  } else {
    kput(VX_STR("unexpected interrupt "));
    kput_u64(f->vector);
  }
}

// --- User-mode registers (obj/exception.c) ---

static trap_frame *arch_user_frame(thread *t) { return (trap_frame *)thread_kstack_top(t) - 1; }

static void arch_frame_regs(const trap_frame *f, vx_regs *r) {
  *r = (vx_regs){.rax = f->rax,
                 .rbx = f->rbx,
                 .rcx = f->rcx,
                 .rdx = f->rdx,
                 .rsi = f->rsi,
                 .rdi = f->rdi,
                 .rbp = f->rbp,
                 .rsp = f->rsp,
                 .r8 = f->r8,
                 .r9 = f->r9,
                 .r10 = f->r10,
                 .r11 = f->r11,
                 .r12 = f->r12,
                 .r13 = f->r13,
                 .r14 = f->r14,
                 .r15 = f->r15,
                 .rip = f->rip,
                 .rflags = f->rflags};
}

// The flags user code may set: carry, parity, adjust, zero, sign, direction,
// overflow, alignment check and ID. Interrupts stay on; trap (single step)
// comes with the debugger.
static constexpr uint64_t USER_FLAGS = 0x1 | 0x4 | 0x10 | 0x40 | 0x80 | 0x400 | 0x800 | 0x40000 | 0x200000;

static vx_status arch_frame_set_regs(trap_frame *f, const vx_regs *r) {
  if (r->rip >= USER_TOP || r->rsp > USER_TOP)
    return VX_ERR_INVALID; // iretq would fault on them, in the kernel
  f->rax = r->rax, f->rbx = r->rbx, f->rcx = r->rcx, f->rdx = r->rdx, f->rsi = r->rsi, f->rdi = r->rdi;
  f->rbp = r->rbp, f->rsp = r->rsp, f->r8 = r->r8, f->r9 = r->r9, f->r10 = r->r10, f->r11 = r->r11;
  f->r12 = r->r12, f->r13 = r->r13, f->r14 = r->r14, f->r15 = r->r15, f->rip = r->rip;
  f->rflags = (r->rflags & USER_FLAGS) | 0x202; // IF, and bit 1, which is always set
  return VX_OK;                                 // cs and ss stay user mode's
}

static constexpr uint32_t MSR_FS_BASE = 0xc0000100;

// Watchpoints (thread_state SET_WATCH): DR0-DR3 and DR7, loaded on the way
// into a task that has them, and DR7 cleared on the way into one that does
// not. They fire in the kernel too, when it copies to or from a watched
// address; x86_trap ignores those.
static bool watch_loaded[MAX_CPUS];

static uint32_t arch_watch_count(void) { return 4; }

static const uint8_t DR7_LEN[9] = {[1] = 0, [2] = 1, [4] = 3, [8] = 2}; // LEN's odd encoding, by bytes

static void watch_load(const task *t) {
  uint32_t cpu = arch_cpu_index();
  if (!t->watching && !watch_loaded[cpu]) return;
  uint64_t dr7 = 0, addr[4] = {};
  for (uint32_t i = 0; t->watching && i < 4; i++) {
    const vx_watchpoint *w = &t->watches[i];
    if (w->kind == VX_WATCH_OFF) continue;
    uint64_t rw = w->kind == VX_WATCH_WRITE ? 1 : 3; // 01 writes, 11 reads and writes
    uint64_t len = DR7_LEN[w->len];
    dr7 |= 1ull << (2 * i) | rw << (16 + 4 * i) | len << (18 + 4 * i);
    addr[i] = w->address;
  }
  __asm__ volatile("mov %0, %%dr7" : : "r"(0ull)); // off while the addresses change
  __asm__ volatile("mov %0, %%dr0\n\tmov %1, %%dr1\n\tmov %2, %%dr2\n\tmov %3, %%dr3"
                   :
                   : "r"(addr[0]), "r"(addr[1]), "r"(addr[2]), "r"(addr[3]));
  __asm__ volatile("mov %0, %%dr7" : : "r"(dr7));
  watch_loaded[cpu] = dr7 != 0;
}

static uint64_t read_dr6(void) {
  uint64_t v;
  __asm__ volatile("mov %%dr6, %0" : "=r"(v));
  return v;
}
static void clear_dr6(void) { __asm__ volatile("mov %0, %%dr6" : : "r"(0xffff'0ff0ull)); }

// Idle threads have no user state: whoever ran last leaves its FS base and
// FP/SIMD registers in place, unused, until the next user thread loads its own.
// Every component XCR0 enables (EDX:EAX all ones asks for them all).
// An area simd_begin filled already holds them: the registers are the kernel's since.
static void arch_user_save(thread *th) {
  th->tls = rdmsr(MSR_FS_BASE);
  if (th->fp_in_area) return;
  if (have_xsaveopt) // NOLINT(bugprone-branch-clone): two instructions, XSAVEOPT and XSAVE
    __asm__ volatile("xsaveopt64 (%0)" : : "r"(th->fp), "a"(~0u), "d"(~0u) : "memory");
  else
    __asm__ volatile("xsave64 (%0)" : : "r"(th->fp), "a"(~0u), "d"(~0u) : "memory");
}

static void arch_fp_load(thread *th) {
  __asm__ volatile("xrstor64 (%0)" : : "r"(th->fp), "a"(~0u), "d"(~0u) : "memory");
  th->fp_in_area = false;
}

static void arch_user_load(thread *th) {
  wrmsr(MSR_FS_BASE, th->tls);
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

// FINIT's and the reset's values: the x87 control word 0x37f, MXCSR 0x1f80
// (every exception masked, round to nearest); every register zero. The
// header's XSTATE_BV is 0, so XRSTOR gives each component its initial state;
// MXCSR it loads from the area whatever the header says.
static void arch_fp_init(uint8_t *fp) {
  memset(fp, 0, ARCH_FP_MAX);
  uint16_t fcw = 0x37f;
  uint32_t mxcsr = 0x1f80;
  memcpy(fp, &fcw, sizeof fcw);
  memcpy(fp + 24, &mxcsr, sizeof mxcsr);
  if (have_pku) arch_fp_set_rights(fp, PKRU_DEFAULT); // a new task's first thread: key 0 alone
}

// A saved area's PKRU, written: the component marked present, so XRSTOR loads it.
static void arch_fp_set_rights(uint8_t *fp, uint64_t rights) {
  if (!have_pku) return;
  uint32_t pkru = (uint32_t)rights;
  memcpy(fp + xcomp_off[9], &pkru, sizeof pkru);
  uint64_t bv;
  memcpy(&bv, fp + 512, sizeof bv);
  bv |= XFEATURE_PKRU;
  memcpy(fp + 512, &bv, sizeof bv);
}

static uint32_t arch_keys(void) { return have_pku ? 15 : 0; }

static uint64_t arch_rights_read(void) {
  if (!have_pku) return 0;
  uint32_t pkru, edx;
  __asm__ volatile("rdpkru" : "=a"(pkru), "=d"(edx) : "c"(0));
  return pkru;
}

static void arch_rights_write(uint64_t rights) {
  if (have_pku) __asm__ volatile("wrpkru" : : "a"((uint32_t)rights), "c"(0), "d"(0) : "memory");
}

// Set by x86_trap when a user copy's fault was a protection key's (#PF's PK bit).
static bool copy_denied[MAX_CPUS];
static bool arch_user_copy_denied(void) {
  bool d = copy_denied[arch_cpu_index()];
  copy_denied[arch_cpu_index()] = false;
  return d;
}

static uint32_t arch_fp_size(void) { return xsave_size; }

static void arch_page_zero(void *va, uint64_t bytes) { memset(va, 0, bytes); } // rep stosb (vx-mem)

// rep movsb (vx-mem): with ERMS and FSRM as fast as AVX2 for a page, so no SIMD section (6c2).
static void arch_page_copy(void *dst, const void *src, uint64_t bytes) { memcpy(dst, src, bytes); }

static constexpr uint32_t XHDR = 512; // the XSAVE header: XSTATE_BV, XCOMP_BV, then 48 reserved bytes

static void arch_fp_view(const uint8_t *fp, uint8_t *out) {
  memcpy(out, fp, xsave_size);
  uint64_t bv;
  memcpy(&bv, out + XHDR, sizeof bv);
  if (!(bv & 1)) { // x87 initial: FCW 0x37f, the rest (FSW, FTW, pointers, ST0-7) zero
    memset(out, 0, 24), memset(out + 32, 0, 128);
    uint16_t fcw = 0x37f;
    memcpy(out, &fcw, sizeof fcw);
  }
  if (!(bv & 2)) memset(out + 160, 0, 256); // XMM0-15 initial; MXCSR is always the area's
  for (uint32_t i = 2; i < 10; i++)
    if ((xcr0 & 1ull << i) && !(bv & 1ull << i)) memset(out + xcomp_off[i], 0, xcomp_size[i]);
  bv = xcr0; // every component, now written out
  memcpy(out + XHDR, &bv, sizeof bv);
}

static vx_status arch_fp_check(const uint8_t *fp) {
  uint64_t bv, comp;
  uint32_t mxcsr;
  memcpy(&bv, fp + XHDR, sizeof bv);
  memcpy(&comp, fp + XHDR + 8, sizeof comp);
  memcpy(&mxcsr, fp + 24, sizeof mxcsr);
  if (bv & ~xcr0 || comp || mxcsr & ~mxcsr_mask) return VX_ERR_INVALID;
  for (uint32_t i = 16; i < 64; i++)
    if (fp[XHDR + i]) return VX_ERR_INVALID;
  return VX_OK;
}

static void arch_fp_legacy_set(uint8_t *fp) {
  uint64_t bv;
  memcpy(&bv, fp + XHDR, sizeof bv);
  bv |= 3; // x87 and SSE: what was written, not their initial state
  memcpy(fp + XHDR, &bv, sizeof bv);
}

static void arch_cpu_info(vx_cpu_info *info) {
  *info = (vx_cpu_info){
      .xstate_size = xsave_size, .keys = arch_keys(), .xfeatures = xcr0, .mxcsr_mask = mxcsr_mask};
}

static uint64_t arch_tls_read(void) { return rdmsr(MSR_FS_BASE); }
static void arch_tls_write(uint64_t value) { wrmsr(MSR_FS_BASE, value); }

static constexpr uint64_t RFLAGS_TF = 0x100; // trap after the next instruction

// The thread's stepping is what holds, not the frame's TF (as aarch64's,
// 002a9a8): FMASK clears TF as a syscall enters, and a frame replaced (an
// in-task handler leaving with its registers) has none. user_return's way
// out sets it again, and reports a stepped syscall as the call returns.
static void arch_frame_step(trap_frame *f, bool on) {
  f->rflags = on ? f->rflags | RFLAGS_TF : f->rflags & ~RFLAGS_TF;
  this_cpu()->current->stepping = on;
}

static void arch_sync_icache(void *p, size_t len) { (void)p, (void)len; } // x86 keeps it coherent itself

// To pc(arg) as if called: a zero return address below arg, which is 16-aligned.
static bool arch_frame_divert(trap_frame *f, uint64_t pc, uint64_t arg) {
  uint64_t zero = 0;
  if (copy_to_user(arg - 8, &zero, sizeof zero) != VX_OK) return false;
  f->rip = pc;
  f->rsp = arg - 8;
  f->rdi = arg;
  f->rflags &= ~(uint64_t)0x400; // the ABI starts functions with the direction flag clear
  return true;
}

// A user-mode fault as an exception: its kind, code and address (abi.h).
static uint32_t x86_exception_kind(const trap_frame *f, uint32_t *code, uint64_t *address) {
  *code = (uint32_t)f->error;
  *address = 0;
  switch (f->vector) {
  case 0: return VX_EXCEPTION_ARITHMETIC; // divide error
  case 1: { // a watchpoint (DR6's B0-B3), or the trap flag (exception_raise clears it, or sets it again)
    uint64_t dr6 = read_dr6();
    clear_dr6();
    if (!(dr6 & 15)) return VX_EXCEPTION_STEP;
    *code = (uint32_t)__builtin_ctzll(dr6 & 15);
    task *t = this_cpu()->current->task;
    *address = t->watches[*code].address; // a trap: the access is done
    return VX_EXCEPTION_WATCHPOINT;
  }
  case 3: return VX_EXCEPTION_BREAKPOINT;
  case 6: return VX_EXCEPTION_ILLEGAL;
  case 7: return VX_EXCEPTION_FP_DISABLED;
  case 14:
    *address = read_cr2();
    *code = 0;                                                                    // read
    if (f->error & 2) *code = 1;                                                  // write
    if (f->error & 16) *code = 2;                                                 // execute
    return f->error & 32 ? VX_EXCEPTION_PROTECTION_KEY : VX_EXCEPTION_PAGE_FAULT; // PK: the page's key
  case 16:
  case 19: return VX_EXCEPTION_ARITHMETIC; // x87 and SIMD FP exceptions
  case 17: return VX_EXCEPTION_ALIGNMENT;
  default: *code = (uint32_t)f->vector; return VX_EXCEPTION_GENERAL;
  }
}

void x86_trap(trap_frame *f) {
  bool from_user = f->cs & 3;
  if (f->vector == VECTOR_SYSCALL) {
    uint64_t args[6] = {f->rdi, f->rsi, f->rdx, f->r10, f->r8, f->r9};
    f->rax = (uint64_t)syscall_dispatch(f->rax, args);
  } else if (f->vector == VECTOR_TIMER) {
    wrmsr(X2APIC_EOI, 0);
    timer_interrupt(from_user);
  } else if (f->vector == VECTOR_RESCHED) {
    wrmsr(X2APIC_EOI, 0);
    this_cpu()->resched = true;
  } else if (f->vector == VECTOR_SHOOTDOWN) {
    wrmsr(X2APIC_EOI, 0);
    tlb_answer(this_cpu());
  } else if (f->vector == VECTOR_SPURIOUS) {
    return;
  } else if (f->vector == VECTOR_IOMMU) {
    vtd_fault_interrupt();
    wrmsr(X2APIC_EOI, 0);
  } else if (f->vector >= VECTOR_MSI_FIRST && f->vector <= VECTOR_MSI_LAST) {
    irq_fire(MSI_LINE_BASE + (uint32_t)f->vector);
    wrmsr(X2APIC_EOI, 0);
  } else if (f->vector >= VECTOR_IRQ_BASE && f->vector < VECTOR_IRQ_BASE + MAX_GSI) {
    irq_fire((uint32_t)(f->vector - VECTOR_IRQ_BASE)); // a level line is masked before the EOI
    wrmsr(X2APIC_EOI, 0);
  } else if (f->vector == 1 && !from_user) {
    clear_dr6(); // the kernel touched a watched user address for the task: not the task's access
  } else if (f->vector == 14 && !from_user && read_cr2() < USER_TOP && uaccess_fixup(f->rip)) {
    copy_denied[arch_cpu_index()] = f->error & 32; // PK: the caller's key rights, not a missing page
    f->rip = uaccess_fixup(f->rip);                // a user page gone under a copy: it reports the failure
  } else if (from_user) {
    uint32_t code;
    uint64_t address;
    uint32_t kind = x86_exception_kind(f, &code, &address);
    if (!exception_raise(f, &kind, code, &address)) { // nobody took it
      task_fault_start();
      kput_exception(f);
      kput(VX_STR(" at rip "));
      kput_hex(f->rip);
      kput(VX_STR("\n"));
      task_fault_exit(kind, code, address, f->rip);
    }
  } else {
    panic_start();
    if ((f->vector == 8 || f->vector == 14) && kstack_in_guard(read_cr2()))
      kput(VX_STR("kernel stack overflow: ")); // a double fault: the page fault had nowhere to push its frame
    kput_exception(f);
    kput(VX_STR(" at rip "));
    kput_hex(f->rip);
    panic_end(f->rip, f->rbp);
  }
  if (from_user && f->vector == VECTOR_SYSCALL && this_cpu()->current->stepping) {
    // A stepped syscall: the step is the instruction, done (the Rust port's
    // finding, as aarch64's svc): reported now, not after the next one.
    uint32_t kind = VX_EXCEPTION_STEP;
    uint64_t address = 0;
    exception_raise(f, &kind, 0, &address);
  }
  if (from_user && this_cpu()->current->stepping) f->rflags |= RFLAGS_TF; // a frame replaced keeps its step
  if (from_user) user_return();
}

// --- Devices: I/O ports, the IOAPICs and the MADT (obj/device.c) ---

static bool arch_has_io_ports(void) { return true; }

static bool arch_console_device(bool io, uint64_t base, uint64_t size) {
  return io && base < COM1 + 8u && COM1 < base + size;
}

static void iomap_set(uint8_t *map, uint32_t base, uint32_t count, bool allow) {
  for (uint32_t p = base; p < base + count; p++) {
    if (allow)
      map[p / 8] &= (uint8_t)~(1u << (p % 8));
    else
      map[p / 8] |= (uint8_t)(1u << (p % 8));
  }
}

static void arch_io_switch(const task *t) {
  x86_cpu *xc = &x86_cpus[arch_cpu_index()];
  for (uint32_t i = 0; i < xc->open; i++) iomap_set(xc->iomap, xc->open_base[i], xc->open_count[i], false);
  xc->open = 0;
  for (uint32_t i = 0; t && i < t->io_ranges && i < TASK_MAX_IO; i++) {
    iomap_set(xc->iomap, t->io_base[i], t->io_count[i], true);
    xc->open_base[i] = t->io_base[i];
    xc->open_count[i] = t->io_count[i];
    xc->open++;
  }
}

typedef struct ioapic {
  volatile uint32_t *regs; // IOREGSEL at 0, IOWIN at 0x10
  uint32_t gsi_base, count;
} ioapic;

static ioapic ioapics[8];
static uint32_t ioapic_count;
static struct {
  bool present;
  uint32_t gsi;
  uint16_t flags; // MPS INTI flags: polarity in bits 0-1, trigger mode in bits 2-3
} isa_overrides[16];
static spinlock ioapic_lock;

static uint32_t ioapic_read(const ioapic *a, uint32_t reg) {
  a->regs[0] = reg;
  return a->regs[4];
}

static void ioapic_write(const ioapic *a, uint32_t reg, uint32_t v) {
  a->regs[0] = reg;
  a->regs[4] = v;
}

// Finds the IOAPICs and the ISA overrides in the MADT, maps the IOAPICs and
// masks every line. Without a MADT, irq_create has no lines to give.
// x86_64 powers off through ACPI's S5, which takes AML: bus-acpi's.
static vx_status arch_system_off(void) { return VX_ERR_UNSUPPORTED; }

static void arch_devices_init(void) {
  const uint8_t *madt = acpi_table("APIC");
  if (!madt) return;
  uint32_t len = read32(madt + 4);
  for (uint32_t off = 44; off + 2 <= len && madt[off + 1] >= 2 && off + madt[off + 1] <= len;
       off += madt[off + 1]) {
    const uint8_t *e = madt + off;
    if (e[0] == 1 && e[1] >= 12 && ioapic_count < sizeof ioapics / sizeof ioapics[0]) {
      uint64_t pa = read32(e + 4);
      if (!map_range(kernel_root, boot.hhdm + pa, pa, 4096, MAP_WRITE | MAP_DEVICE))
        panic(VX_STR("cannot map an IOAPIC"));
      ioapic *a = &ioapics[ioapic_count++];
      a->regs = (volatile uint32_t *)(boot.hhdm + pa);
      a->gsi_base = read32(e + 8);
      a->count = (ioapic_read(a, 1) >> 16 & 0xff) + 1;
      for (uint32_t i = 0; i < a->count; i++) ioapic_write(a, 0x10 + 2 * i, 1u << 16); // masked
    } else if (e[0] == 2 && e[1] >= 10 && e[2] == 0 && e[3] < 16) {
      isa_overrides[e[3]].present = true;
      isa_overrides[e[3]].gsi = read32(e + 4);
      uint16_t flags;
      memcpy(&flags, e + 8, 2);
      isa_overrides[e[3]].flags = flags;
    }
  }
}

static const ioapic *ioapic_for(uint32_t gsi) {
  for (uint32_t i = 0; i < ioapic_count; i++)
    if (gsi >= ioapics[i].gsi_base && gsi - ioapics[i].gsi_base < ioapics[i].count) return &ioapics[i];
  return nullptr;
}

// An ISA IRQ (below 16) becomes its GSI through the MADT's overrides; any
// other number is a GSI already.
static vx_status arch_irq_canonical(uint32_t line, uint32_t *out) {
  uint32_t gsi = line < 16 && isa_overrides[line].present ? isa_overrides[line].gsi : line;
  if (gsi >= MAX_GSI || !ioapic_for(gsi)) return VX_ERR_RANGE;
  *out = gsi;
  return VX_OK;
}

// ISA lines are edge-triggered and active high unless an override says
// otherwise; the rest (PCI) are level-triggered and active low.
static vx_status arch_irq_route(uint32_t line, bool *level) {
  bool isa = false;
  uint16_t flags = 0;
  for (uint32_t i = 0; i < 16; i++) { // the ISA IRQ that lands on this GSI, if any (line: a GSI)
    uint32_t to = isa_overrides[i].present ? isa_overrides[i].gsi : i;
    if (to != line) continue;
    isa = true;
    flags = isa_overrides[i].present ? isa_overrides[i].flags : 0;
  }
  bool active_low = !isa;
  *level = !isa;
  if ((flags & 3) == 1) active_low = false; // the override's polarity and trigger mode, where it gives them
  if ((flags & 3) == 3) active_low = true;
  if ((flags >> 2 & 3) == 1) *level = false;
  if ((flags >> 2 & 3) == 3) *level = true;
  const ioapic *a = ioapic_for(line);
  uint32_t pin = line - a->gsi_base;
  spin_lock(&ioapic_lock);
  ioapic_write(a, 0x10 + 2 * pin + 1, (uint32_t)(cpus[0].arch_id << 24)); // to the boot CPU
  ioapic_write(a, 0x10 + 2 * pin,
               (VECTOR_IRQ_BASE + line) | (active_low ? 1u << 13 : 0) | (*level ? 1u << 15 : 0)); // unmasked
  spin_unlock(&ioapic_lock);
  return VX_OK;
}

// An MSI is a write to the boot CPU's local APIC (x2APIC IDs above 255 need
// interrupt remapping, which comes with the IOMMU) with a free vector. The
// PCI function does not matter: any vector can come from any device.
static vx_status arch_msi_create(uint32_t source, uint32_t *line, vx_msi *msi) {
  (void)source;
  for (uint32_t v = VECTOR_MSI_FIRST; v <= VECTOR_MSI_LAST; v++) {
    if (irq_lines[MSI_LINE_BASE + v]) continue;
    if (cpus[0].arch_id > 0xff) return VX_ERR_UNSUPPORTED;
    *line = MSI_LINE_BASE + v;
    *msi = (vx_msi){.address = 0xfee0'0000 | cpus[0].arch_id << 12, .data = v}; // fixed, edge
    return VX_OK;
  }
  return VX_ERR_NO_MEMORY;
}

static void arch_msi_destroy(uint32_t line) { (void)line; } // nothing routes it but the device

static void arch_irq_mask(uint32_t line, bool masked) {
  if (line >= MSI_LINE_BASE) return; // an MSI: edge-triggered, and the device masks it if anything does
  const ioapic *a = ioapic_for(line);
  if (!a) return;
  uint32_t reg = 0x10 + 2 * (line - a->gsi_base);
  spin_lock(&ioapic_lock);
  uint32_t low = ioapic_read(a, reg);
  ioapic_write(a, reg, masked ? low | 1u << 16 : low & ~(1u << 16));
  spin_unlock(&ioapic_lock);
}

[[noreturn]] static void arch_halt(void) {
  for (;;) __asm__ volatile("cli; hlt");
}

// --- Page tables ---

static constexpr uint64_t X86_PRESENT = 1ull << 0;
static constexpr uint64_t X86_WRITE = 1ull << 1;
static constexpr uint64_t X86_USER = 1ull << 2;
static constexpr uint64_t X86_PWT = 1ull << 3;
static constexpr uint64_t X86_PCD = 1ull << 4;
static constexpr uint64_t X86_LARGE = 1ull << 7; // a 2 MiB or 1 GiB leaf
static constexpr uint64_t X86_NX = 1ull << 63;
static constexpr uint64_t X86_ADDR = 0x000f'ffff'ffff'f000;

static bool arch_pte_valid(uint64_t e) { return e & X86_PRESENT; }
static bool arch_pte_is_table(uint64_t e, int level) { return level < 3 && !(e & X86_LARGE); }
static uint64_t arch_pte_addr(uint64_t e) { return e & X86_ADDR; }

// Tables allow everything; the leaf decides.
static uint64_t arch_pte_table(uint64_t pa) { return pa | X86_USER | X86_WRITE | X86_PRESENT; }

static uint64_t arch_pte_leaf(uint64_t pa, uint32_t flags, int level) {
  uint64_t e = pa | X86_PRESENT;
  if (flags & MAP_WRITE) e |= X86_WRITE;
  if (flags & MAP_USER) e |= X86_USER;
  if (!(flags & MAP_EXEC)) e |= X86_NX;
  if (flags & MAP_DEVICE) e |= X86_PCD | X86_PWT; // uncached under the default PAT
  e |= (uint64_t)(flags >> 8 & 0xf) << 59;        // the protection key, bits 59-62 (PKU)
  if (level < 3) e |= X86_LARGE;
  return e;
}

// Every task's top table shares the kernel's upper half by copying its 256
// upper entries, so they must exist before the first task: fill them now with
// empty tables (1 MiB in all), and later kernel mappings land in tables every
// task already shares. COM1 is an I/O port, so there is nothing else to map.
static void arch_kernel_mappings(uint64_t root) {
  uint64_t *top = table_at(root);
  for (int i = 256; i < 512; i++) {
    if (arch_pte_valid(top[i])) continue;
    uint64_t page = phys_alloc_zeroed(0);
    if (!page) panic(VX_STR("no memory for page tables"));
    top[i] = arch_pte_table(page);
  }
}

static uint64_t arch_new_user_root(void) {
  uint64_t root = phys_alloc_zeroed(0);
  if (root) memcpy(table_at(root) + 256, table_at(kernel_root) + 256, 256 * sizeof(uint64_t));
  return root;
}

// Loads a task's tables, or with root 0 (no task, as for the idle thread) the
// kernel's own, whose user half is empty.
static void arch_switch_user_root(uint64_t root) {
  if (!root) root = kernel_root;
  __asm__ volatile("mov %0, %%cr3" : : "r"(root) : "memory");
}

static uint32_t arch_user_top_slots(void) { return 256; }

// x86's table walker sees stores in order: only the compiler must not move them.
static void arch_pte_publish(void) { __asm__ volatile("" ::: "memory"); }

static void arch_tlb_flush_page(uint64_t va) { __asm__ volatile("invlpg (%0)" : : "r"(va) : "memory"); }

// Drops this CPU's user translations (loading CR3 again keeps only global,
// kernel, entries) if a shootdown has asked it to since it last did.
static void tlb_answer(cpu *c) {
  uint64_t asked = atomic_load_explicit(&c->tlb_asked, memory_order_acquire);
  if (atomic_load_explicit(&c->tlb_done, memory_order_relaxed) >= asked) return;
  uint64_t cr3;
  __asm__ volatile("mov %%cr3, %0\n\tmov %0, %%cr3" : "=r"(cr3) : : "memory");
  atomic_store_explicit(&c->tlb_done, asked, memory_order_release);
}

static _Atomic uint64_t shootdown_gen;

// x86 has no broadcast invalidation: every other CPU with the tables loaded
// gets an interrupt, and this one waits until each has flushed, or loaded
// other tables since (a load flushes too). While waiting it answers any
// shootdown asked of it, so two at once cannot wait for each other. The
// caller holds no lock that a CPU it waits for might be spinning on.
static void arch_tlb_shootdown(uint64_t root, uint64_t va, uint64_t len) {
  cpu *me = this_cpu();
  if (atomic_load_explicit(&me->user_root, memory_order_relaxed) == root) {
    if (len / 4096 > 32) {
      uint64_t cr3;
      __asm__ volatile("mov %%cr3, %0\n\tmov %0, %%cr3" : "=r"(cr3) : : "memory");
    } else {
      for (uint64_t p = va; p < va + len; p += 4096) arch_tlb_flush_page(p);
    }
  }
  uint64_t gen = atomic_fetch_add_explicit(&shootdown_gen, 1, memory_order_relaxed) + 1;
  uint64_t loads[MAX_CPUS];
  bool waiting[MAX_CPUS] = {};
  for (uint32_t i = 0; i < cpu_total && i < MAX_CPUS; i++) {
    cpu *c = &cpus[i];
    if (c == me || atomic_load_explicit(&c->user_root, memory_order_acquire) != root) continue;
    loads[i] = atomic_load_explicit(&c->root_loads, memory_order_acquire);
    uint64_t old = atomic_load_explicit(&c->tlb_asked, memory_order_relaxed);
    while (old < gen && !atomic_compare_exchange_weak_explicit(&c->tlb_asked, &old, gen, memory_order_release,
                                                               memory_order_relaxed)) {}
    waiting[i] = true;
    wrmsr(X2APIC_ICR, c->arch_id << 32 | VECTOR_SHOOTDOWN);
  }
  for (uint32_t i = 0; i < cpu_total && i < MAX_CPUS; i++) {
    cpu *c = &cpus[i];
    while (waiting[i] && atomic_load_explicit(&c->tlb_done, memory_order_acquire) < gen &&
           atomic_load_explicit(&c->root_loads, memory_order_acquire) == loads[i]) {
      tlb_answer(me);
      arch_pause();
    }
  }
}

static bool arch_pte_user_ok(uint64_t e, bool write) {
  return (e & X86_PRESENT) && (e & X86_USER) && (!write || (e & X86_WRITE));
}

static void arch_switch_tables(uint64_t root) {
  ap_park_tables[0] = root; // for CPUs past MAX_CPUS (ap_park)
  uint64_t cr4;
  __asm__ volatile("mov %%cr4, %0" : "=r"(cr4));
  __asm__ volatile("mov %0, %%cr3\n\t"
                   "mov %1, %%cr4\n\t" // clearing and restoring PGE drops global entries Limine may have left
                   "mov %2, %%cr4"
                   :
                   : "r"(root), "r"(cr4 & ~(1ull << 7)), "r"(cr4)
                   : "memory");
}

// --- Threads ---

[[noreturn]] static void arch_run_on_stack(uint64_t top, void (*fn)(void)) {
  __asm__ volatile("mov %0, %%rsp\n\txor %%ebp, %%ebp\n\tcall *%1\n\tud2" : : "r"(top), "r"(fn) : "memory");
  __builtin_unreachable();
}

static void arch_set_kernel_stack(uint64_t top) {
  x86_cpu *xc = &x86_cpus[arch_cpu_index()];
  xc->tss.rsp[0] = top;       // interrupts and exceptions from user mode
  xc->local.kernel_rsp = top; // SYSCALL
}

extern const uint8_t thread_trampoline[]; // entry.S

// A new thread's stack, as arch_context_switch will pop it: six callee-saved
// registers (r12 carrying the thread), then a return into thread_trampoline.
// It starts below the space its first trap frame takes at the top of the
// stack, so arch_enter_user can build that frame without overwriting itself.
static uint64_t arch_thread_initial_sp(thread *t) {
  uint64_t *sp = (uint64_t *)((trap_frame *)thread_kstack_top(t) - 1) - 7;
  sp[3] = (uint64_t)t;                 // r12
  sp[6] = (uint64_t)thread_trampoline; // the return address
  return (uint64_t)sp;
}

[[noreturn]] static void arch_enter_user(uint64_t entry, uint64_t sp, uint64_t arg, uint64_t arg2,
                                         uint64_t kstack_top) {
  // As if called (thread_start, abi.h): a zero return address below sp. If
  // it cannot be written, the thread faults on its first use of its stack.
  uint64_t zero = 0;
  (void)copy_to_user(sp - 8, &zero, sizeof zero);
  trap_frame *f = (trap_frame *)kstack_top - 1;
  *f = (trap_frame){
      .rdi = arg,
      .rsi = arg2,
      .rip = entry,
      .cs = SEL_USER_CODE,
      .rflags = 0x202,
      .rsp = sp - 8,
      .ss = SEL_USER_DATA,
  };
  arch_enter_frame(f);
}

// Limine starts each other CPU here, with its limine_mp_info in rdi, in the
// same state as the boot CPU. smp_init left the top of the CPU's idle stack in
// extra_argument, with the CPU's index just above it.
static_assert(offsetof(struct limine_mp_info, extra_argument) == 24);

uint64_t ap_park_tables[2];

[[gnu::naked, noreturn]] void ap_park(struct limine_mp_info *info) {
  __asm__("endbr64\n\t"
          "cli\n\t"
          "movq ap_park_tables(%rip), %rax\n\t"
          "movq %rax, %cr3\n" // the kernel's tables: Limine's are about to be reclaimed
          "1:\n\t"
          "hlt\n\t"
          "jmp 1b");
}

// Its idle stack is in the kernel stack region (mm/kstack.c), which only the
// kernel's tables map: it loads them first, as ap_park does.
[[gnu::naked, noreturn]] void ap_start(struct limine_mp_info *info) {
  __asm__("endbr64\n\t"
          "movq ap_park_tables(%rip), %rax\n\t"
          "movq %rax, %cr3\n\t"
          "movq 24(%rdi), %rsp\n\t"
          "movq 8(%rsp), %rdi\n\t"
          "xorl %ebp, %ebp\n\t"
          "call ap_main\n\t"
          "ud2");
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
