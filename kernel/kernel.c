// kernel.c: the unity-build root (docs/04 §1.1). Every other kernel .c file is
// included here, so the kernel is one translation unit.

#include "vx/abi.h"

// -fstack-protector-strong with a global guard (docs/01 §11). boot_read
// replaces this value with entropy from the bootloader.
uintptr_t __stack_chk_guard = 0x595e9fbd94fda766;

// What each architecture provides to the rest of the kernel.
static void arch_console_init(void);
static void arch_console_write(vx_str s);
static void arch_cpu_init(void);   // exception vectors, and on x86_64 the GDT, TSS and IDT
[[noreturn]] static void arch_halt(void);

// Page-table entries, in the architecture's format (mm/paging.c).
static bool     arch_pte_valid(uint64_t e);
static bool     arch_pte_is_table(uint64_t e, int level);
static uint64_t arch_pte_addr(uint64_t e);
static uint64_t arch_pte_table(uint64_t pa);
static uint64_t arch_pte_leaf(uint64_t pa, uint32_t flags, int level);
static void     arch_kernel_mappings(uint64_t root);   // device pages the kernel itself uses
static void     arch_switch_tables(uint64_t root);

// The cycle counter and the deadline timer (time.c).
static uint64_t arch_counter(void);
static uint64_t arch_counter_hz(void);
static void     arch_timer_init(void);           // the interrupt controller and the timer, on this CPU
static void     arch_timer_arm(uint64_t count);  // one interrupt when the counter reaches count
static void     arch_wait(void);                 // sleep until an interrupt has been handled

static void kput_stamp(void);   // time.c

// What the rest of the kernel provides to the architecture's entry point, which
// calls it from assembly on the boot stack the linker script reserves
// (vx_boot_stack_top), with an unmapped guard page below it.
[[noreturn]] void kernel_main(void);

#include "lib.c"
#include "boot.c"
#include "panic.c"
#include "mm/phys.c"
#include "mm/paging.c"
#include "time.c"

#if defined(__x86_64__)
#  define VX_ARCH_NAME "x86_64"
#  include "arch/x86_64/arch.c"
#elif defined(__aarch64__)
#  define VX_ARCH_NAME "aarch64"
#  include "arch/aarch64/arch.c"
#else
#  error "unsupported architecture"
#endif

#include "main.c"
