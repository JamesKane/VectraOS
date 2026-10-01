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
static uint32_t arch_user_top_slots(void); // top-table entries that belong to the user half
// Every CPU drops its translations for [va, va + len) in the address space
// with this root: after it returns, unmapped pages may be freed.
static void arch_tlb_shootdown(uint64_t root, uint64_t va, uint64_t len);

// User memory is touched only through this (syscall.c): a fault inside it
// returns the bytes not copied, never a panic. Assembly, in entry.S or vectors.S.
size_t arch_user_copy(void *dst, const void *src, size_t n);
bool arch_user_load32(const uint32_t *src, uint32_t *dst); // a futex word, in one load; false on a fault
extern char arch_user_copy_fault[], arch_user_copy_end[], arch_user_load32_fault[];

// Where a fault at pc in a user-memory routine resumes, or 0 if pc is not in one.
static uint64_t uaccess_fixup(uint64_t pc) {
  if (pc >= (uint64_t)arch_user_copy && pc < (uint64_t)arch_user_copy_fault)
    return (uint64_t)arch_user_copy_fault;
  if (pc >= (uint64_t)arch_user_load32 && pc < (uint64_t)arch_user_load32_fault)
    return (uint64_t)arch_user_load32_fault;
  return 0;
}
static void arch_set_kernel_stack(uint64_t top); // where traps from user mode land
static uint64_t arch_thread_initial_sp(thread *t);
[[noreturn]] static void arch_enter_user(uint64_t entry, uint64_t sp, uint64_t arg, uint64_t arg2,
                                         uint64_t kstack_top);
[[noreturn]] static void arch_run_on_stack(uint64_t top, void (*fn)(void)); // fn never returns

// User-mode registers, in the frame at the top of a thread's kernel stack
// (obj/exception.c). Setting them checks that the state is a user mode one.
struct trap_frame;
static struct trap_frame *arch_user_frame(thread *t);
static void arch_frame_regs(const struct trap_frame *f, vx_regs *r);
static vx_status arch_frame_set_regs(struct trap_frame *f, const vx_regs *r);
static bool arch_frame_divert(struct trap_frame *f, uint64_t pc,
                              uint64_t arg);                // pc(arg), on a stack just below arg
static void arch_frame_step(struct trap_frame *f, bool on); // trap after one user instruction
static void arch_sync_icache(void *p, size_t len); // code written through a data mapping, made runnable

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
#include "mm/kstack.c"
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
#include "obj/exception.c"
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
