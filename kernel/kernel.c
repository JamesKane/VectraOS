// kernel.c: the unity-build root (docs/04 §1.1). Every other kernel .c file is
// included here, so the kernel is one translation unit.

#include "vx/abi.h"
#include "entry.h"
#include <stdckdint.h>

// -fstack-protector-strong with a global guard (docs/01 §11). boot_read
// replaces this value with entropy from the bootloader.
uintptr_t __stack_chk_guard = 0x595e9fbd94fda766;

// What each architecture provides to the rest of the kernel.
static void arch_console_init(void);
static void arch_console_write(vx_str s);
static void arch_cpu_init(void); // exception vectors, and on x86_64 the GDT, TSS and IDT
[[noreturn]] static void arch_halt(void);

// Page-table entries, in the architecture's format (mm/paging.c).
static bool arch_pte_valid(uint64_t e);
static bool arch_pte_is_table(uint64_t e, int level);
static uint64_t arch_pte_addr(uint64_t e);
static uint64_t arch_pte_table(uint64_t pa);
static uint64_t arch_pte_leaf(uint64_t pa, uint32_t flags, int level);
static void arch_kernel_mappings(uint64_t root); // device pages the kernel itself uses
static void arch_switch_tables(uint64_t root);

// The cycle counter and the deadline timer (time.c).
static uint64_t arch_counter(void);
static uint64_t arch_counter_hz(void);
static void arch_timer_init(void);          // the interrupt controller and the timer, on this CPU
static void arch_timer_arm(uint64_t count); // one interrupt when the counter reaches count
static void arch_wait(void);                // sleep until an interrupt has been handled

static void kput_stamp(void); // time.c

// User address spaces and threads (obj/task.c, sched/sched.c).
static uint64_t arch_new_user_root(void); // a top table sharing the kernel half
static void arch_switch_user_root(uint64_t root);
static bool arch_pte_user_ok(uint64_t e, bool write);
static void arch_set_kernel_stack(uint64_t top); // where traps from user mode land
static uint64_t arch_thread_initial_sp(thread *t);
[[noreturn]] static void arch_enter_user(uint64_t entry, uint64_t sp, uint64_t arg, uint64_t kstack_top);

#include "../lib/vx-mem/mem.c"
#include "boot.c"
#include "panic.c"
#include "mm/phys.c"
#include "mm/paging.c"
#include "time.c"
#include "obj/object.c"
#include "obj/vmo.c"
#include "obj/task.c"
#include "sched/sched.c"
#include "obj/port.c"
#include "syscall/syscall.c"
#include "elf.c"
#include "root.c"

#ifdef __x86_64__
#define VX_ARCH_NAME "x86_64"
#include "arch/x86_64/arch.c"
#elifdef __aarch64__
#define VX_ARCH_NAME "aarch64"
#include "arch/aarch64/arch.c"
#else
#error "unsupported architecture"
#endif

#include "main.c"
