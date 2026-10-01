// kernel.c: the unity-build root (docs/04 §1.1). Every other kernel .c file is
// included here, so the kernel is one translation unit.

#include "vx/abi.h"
#include "entry.h"
#include <stdckdint.h>

// -fstack-protector-strong with a global guard (docs/01 §11). boot_read
// replaces this value with entropy from the bootloader.
uintptr_t __stack_chk_guard = 0x595e9fbd94fda766;

// The most CPUs the kernel runs on. Limine's others stay parked.
static constexpr uint32_t MAX_CPUS = 64;

// What each architecture provides to the rest of the kernel.
static void arch_console_init(void);
static void arch_console_write(vx_str s);
static void arch_cpu_init(uint32_t index); // this CPU: vectors, per-CPU data; on x86_64 the GDT, TSS and IDT
static uint32_t arch_cpu_index(void);      // 0 until arch_cpu_init has run on the boot CPU
static void arch_pause(void);              // a spin-wait hint
[[noreturn]] static void arch_halt(void);
struct cpu;
static void arch_send_resched(struct cpu *c); // a reschedule interrupt to another CPU

// Page-table entries, in the architecture's format (mm/paging.c).
static bool arch_pte_valid(uint64_t e);
static bool arch_pte_is_table(uint64_t e, int level);
static uint64_t arch_pte_addr(uint64_t e);
static uint64_t arch_pte_table(uint64_t pa);
static uint64_t arch_pte_leaf(uint64_t pa, uint32_t flags, int level);
static void arch_kernel_mappings(uint64_t root); // device pages the kernel itself uses
static void arch_switch_tables(uint64_t root);
static void arch_pte_publish(void); // table writes so far are seen by the table walker, before any use

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
static uint32_t arch_user_top_slots(void);       // top-table entries that belong to the user half
static void arch_tlb_flush_page(uint64_t va);    // this CPU only
static void arch_set_kernel_stack(uint64_t top); // where traps from user mode land
static uint64_t arch_thread_initial_sp(thread *t);
[[noreturn]] static void arch_enter_user(uint64_t entry, uint64_t sp, uint64_t arg, uint64_t arg2,
                                         uint64_t kstack_top);

// Device interrupts and I/O for user-space drivers (obj/device.c).
static vx_status arch_irq_canonical(uint32_t line, uint32_t *out); // the number the line is known by
static vx_status arch_irq_route(uint32_t line, bool *level);       // to the boot CPU, unmasked
static void arch_irq_mask(uint32_t line, bool masked);
struct vx_msi;
static vx_status arch_msi_create(uint32_t source, uint32_t *line,
                                 struct vx_msi *msi); // a free MSI line, routed
static void arch_msi_destroy(uint32_t line);
static bool arch_has_io_ports(void);
static void arch_devices_init(void); // finds the interrupt controllers' device lines, after paging_init
static bool arch_console_device(bool io, uint64_t base,
                                uint64_t size); // overlaps the kernel console's device
struct task;
static void arch_io_switch(const struct task *t); // this CPU's I/O port permissions become t's; t may be null

#include "../lib/vx-mem/mem.c"
#include "sync.c"
#include "boot.c"
#include "panic.c"
#include "mm/phys.c"
#include "mm/paging.c"
#include "time_math.c"
#include "time.c"
#include "obj/object.c"
#include "obj/vmo.c"
#include "obj/task.c"
#include "sched/sched.c"
#include "obj/port.c"
#include "obj/channel.c"
#include "obj/counter.c"
#include "obj/futex.c"
#include "obj/device.c"
#include "../lib/vx-ring/ring.c"
#include "obj/ring.c"
#include "obj/process.c"
#include "syscall/syscall.c"
#include "elf.c"
#include "acpi.c"
#include "../lib/vx-ndb/ndb.c"
#include "root.c"
#include "sched/smp.c"

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
