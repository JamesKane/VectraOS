// main.c: the architecture-independent start of the kernel.

static void console_u64(uint64_t v) {
    char buf[20];
    size_t i = sizeof buf;
    do {
        buf[--i] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    arch_console_write((vx_str){ buf + i, sizeof buf - i });
}

[[noreturn]] static void panic(vx_str why) {
    arch_console_write(VX_STR("vx: panic: "));
    arch_console_write(why);
    arch_console_write(VX_STR("\n"));
    arch_halt();
}

[[noreturn]] void __stack_chk_fail(void) {
    panic(VX_STR("stack protector tripped"));
}

[[noreturn, clang::no_stack_protector]] static void kernel_main(void) {
    bool ok = boot_read();
    arch_console_init();
    if (!ok) panic(VX_STR("the bootloader does not provide Limine base revision 6"));

    arch_console_write(VX_STR("vx: kernel 0.1.0 " VX_ARCH_NAME ", "));
    console_u64(boot.usable_bytes >> 20);
    arch_console_write(VX_STR(" MiB usable, "));
    console_u64(boot.cpu_count);
    arch_console_write(VX_STR(boot.cpu_count == 1 ? " cpu\n" : " cpus\n"));
    arch_halt();
}
