// main.c: the architecture-independent start of the kernel.

// -fstack-protector-strong with a global guard (docs/01 §11). The value is
// replaced from boot entropy once the kernel has a source of it.
uintptr_t __stack_chk_guard = 0x595e9fbd94fda766;

[[noreturn]] void __stack_chk_fail(void) {
    arch_console_write(VX_STR("vx: panic: stack protector tripped\n"));
    arch_halt();
}

[[noreturn]] static void kernel_main(void) {
    arch_console_write(VX_STR("vx: kernel 0.1.0 " VX_ARCH_NAME "\n"));
    arch_halt();
}
