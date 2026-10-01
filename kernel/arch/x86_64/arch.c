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

[[noreturn]] static void arch_halt(void) {
    for (;;) __asm__ volatile("cli; hlt");
}

// Limine enters here in long mode, on its own stack, with the higher half mapped.
[[noreturn]] void _start(void) {
    kernel_main();
}
