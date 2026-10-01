// arch.c (aarch64): the entry point and the early serial console (a PL011).
//
// Limine's direct map covers RAM only (base revision 3 and later), so the
// console maps the UART's registers itself: one 4 KiB device page at
// hhdm + its physical address, written into Limine's own page tables. The page
// uses MAIR attribute 2; Limine guarantees that attributes 2 to 7 are unused.
// The UART is at QEMU virt's address until the kernel reads the device tree.

constexpr uint64_t PL011_PHYS = 0x0900'0000;
constexpr uint64_t PL011_DR   = 0x00 / 4;   // data register, as a u32 index
constexpr uint64_t PL011_FR   = 0x18 / 4;   // flag register
constexpr uint32_t PL011_FR_TXFF = 1u << 5; // transmit FIFO full

constexpr uint64_t PTE_VALID = 1ull << 0;
constexpr uint64_t PTE_TABLE = 1ull << 1;   // a table at levels 0–2, a page at level 3
constexpr uint64_t PTE_ATTR2 = 2ull << 2;   // MAIR index 2: device memory
constexpr uint64_t PTE_AF    = 1ull << 10;
constexpr uint64_t PTE_PXN   = 1ull << 53;
constexpr uint64_t PTE_UXN   = 1ull << 54;
constexpr uint64_t PTE_ADDR  = 0x0000'ffff'ffff'f000;

static volatile uint32_t *pl011;

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

// Maps one device page into the higher half. Fails if no page is left for a
// table, or if a block mapping already covers the address.
static bool map_device_page(uint64_t va, uint64_t pa) {
    uint64_t *table = phys_to_virt(read_ttbr1() & PTE_ADDR);
    for (int level = 0; level < 3; level++) {
        unsigned idx = (va >> (39 - 9 * level)) & 511;
        uint64_t e = table[idx];
        if (!(e & PTE_VALID)) {
            uint64_t page = early_page();
            if (!page) return false;
            e = page | PTE_TABLE | PTE_VALID;
            table[idx] = e;
        } else if (!(e & PTE_TABLE)) {
            return false;
        }
        table = phys_to_virt(e & PTE_ADDR);
    }
    table[(va >> 12) & 511] = pa | PTE_UXN | PTE_PXN | PTE_AF | PTE_ATTR2 | PTE_TABLE | PTE_VALID;
    __asm__ volatile("dsb ishst\n\tisb" : : : "memory");
    return true;
}

static void arch_console_init(void) {
    if (!boot.hhdm) return;
    write_mair(read_mair() & ~(0xffull << 16));   // attribute 2 = 0x00: Device-nGnRnE
    uint64_t va = boot.hhdm + PL011_PHYS;
    if (map_device_page(va, PL011_PHYS)) pl011 = (volatile uint32_t *)va;
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

[[noreturn]] static void arch_halt(void) {
    for (;;) __asm__ volatile("msr daifset, #0xf\n\twfi");
}

// Limine enters here at EL1 (or EL2 with VHE), on its own stack, with the
// higher half mapped.
[[noreturn]] void _start(void) {
    kernel_main();
}
