// arch.c (aarch64): the entry point. The PL011 console needs an MMIO mapping,
// which comes with the kernel's own page tables in M1. Until then the console
// writes nowhere.

static void arch_console_write(vx_str s) {
    (void)s;
}

[[noreturn]] static void arch_halt(void) {
    for (;;) __asm__ volatile("msr daifset, #0xf\n\twfi");
}

// Limine enters here at EL1, on its own stack, with the higher half mapped.
[[noreturn]] void _start(void) {
    kernel_main();
}
