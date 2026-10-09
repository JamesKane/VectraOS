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

// A thread's FP/SIMD save area, a page of its own (ADR-0035): on x86_64
// XSAVE's standard image of every component XCR0 enables, arch_fp_size()
// bytes as CPUID gives them (about 2.7 KiB with AVX-512); on aarch64 v0-v31,
// FPCR and FPSR. Its first sizeof(vx_fpregs) bytes are the legacy part.
static constexpr uint32_t ARCH_FP_MAX = 4096;

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
static uint32_t arch_counter_flags(void);   // its vx_clock_flags, for /sys/clock/info
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
size_t arch_user_copy_in(void *dst, const void *src, size_t n);  // from user memory
size_t arch_user_copy_out(void *dst, const void *src, size_t n); // to it
extern char arch_user_copy[];                                    // where the two begin, for uaccess_fixup
bool arch_user_load32(const uint32_t *src, uint32_t *dst); // a futex word, in one load; false on a fault
// A compare-and-swap on a user word (a robust lock's, ADR-0037): *seen gets what
// was there, and new went in if it was old. False on a fault.
bool arch_user_cas32(uint32_t *word, uint32_t old, uint32_t new, uint32_t *seen);
extern char arch_user_copy_fault[], arch_user_copy_end[], arch_user_load32_fault[], arch_user_cas32_fault[];

// Where a fault at pc in a user-memory routine resumes, or 0 if pc is not in one.
static uint64_t uaccess_fixup(uint64_t pc) {
  if (pc >= (uint64_t)arch_user_copy && pc < (uint64_t)arch_user_copy_fault)
    return (uint64_t)arch_user_copy_fault;
  if (pc >= (uint64_t)arch_user_load32 && pc < (uint64_t)arch_user_load32_fault)
    return (uint64_t)arch_user_load32_fault;
  if (pc >= (uint64_t)arch_user_cas32 && pc < (uint64_t)arch_user_cas32_fault)
    return (uint64_t)arch_user_cas32_fault;
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
// A user thread's state that traps do not save: the thread pointer (x86_64's
// FS base, aarch64's TPIDR_EL0) and the FP/SIMD registers. Saved and loaded
// with each switch between threads; the kernel itself never touches FP/SIMD
// (-mgeneral-regs-only), so nothing else needs to.
static void arch_user_switch(thread *prev, thread *next);
static void arch_user_save(thread *th); // the current thread's TLS and FP/SIMD registers, into th
static void arch_user_load(thread *th); // and back
static void arch_fp_load(thread *th); // the FP/SIMD registers alone, from th (user_return, after simd_begin)
static void arch_page_copy(void *dst, const void *src, uint64_t bytes); // whole pages, page-aligned
static void arch_fp_init(uint8_t *fp); // a new thread's: the architecture's reset values
static uint32_t arch_fp_size(void);    // the save area's bytes in use (GET_XSTATE's)
// A debugger's view of a saved area: components the hardware left in their
// initial state without writing (x86's XSAVEOPT) given their initial values.
static void arch_fp_view(const uint8_t *fp, uint8_t *out);
// A debugger's area made one the thread may load: INVALID if not (SET_XSTATE).
static vx_status arch_fp_check(const uint8_t *fp);
// After SET_FPREGS wrote the legacy part: marked to be loaded, not left initial.
static void arch_fp_legacy_set(uint8_t *fp);
static void arch_cpu_info(vx_cpu_info *info);         // GET_CPU's
static void arch_page_zero(void *va, uint64_t bytes); // whole pages, page-aligned: the fastest way there is
// Protection keys (ADR-0035): how many a task may allocate (0: none); whether
// the last user copy that failed was stopped by the caller's key rights; the
// current thread's rights, live in the register (x86's PKRU).
static uint32_t arch_keys(void);
static bool arch_user_copy_denied(void);
static uint64_t arch_rights_read(void);
static void arch_rights_write(uint64_t rights);
static void arch_fp_set_rights(uint8_t *fp,
                               uint64_t rights); // a saved area's: a new thread's from its creator
static uint64_t arch_tls_read(void);
static void arch_tls_write(uint64_t value);

// Device interrupts and I/O for user-space drivers (obj/device.c).
static vx_status arch_irq_canonical(uint32_t line, uint32_t *out); // the number the line is known by
static vx_status arch_irq_route(uint32_t line, bool *level);       // to the boot CPU, unmasked
static void arch_irq_mask(uint32_t line, bool masked);
struct vx_msi;
static vx_status arch_msi_create(uint32_t source, uint32_t *line,
                                 struct vx_msi *msi); // a free MSI line, routed
static void arch_msi_destroy(uint32_t line);
static bool arch_has_io_ports(void);
static void arch_devices_init(void);    // finds the interrupt controllers' device lines, after paging_init
static vx_status arch_system_off(void); // PSCI SYSTEM_OFF where there is one; returns only if it failed
static bool arch_console_device(bool io, uint64_t base,
                                uint64_t size); // overlaps the kernel console's device
struct task;
static void arch_io_switch(const struct task *t); // this CPU's I/O port permissions become t's; t may be null
static uint32_t arch_watch_count(void);           // the debug registers' watchpoints (thread_state SET_WATCH)
// The PMU (pmu.c, ADR-0050): what it has; this CPU's first n counters
// started, counting events[i] in user mode from start[i] (as wide as
// arch_pmu_probe says), readable by the thread if user_read; read; stopped.
static void arch_pmu_probe(vx_pmu_info *info);
static void arch_pmu_start(uint32_t n, const uint32_t *events, const uint64_t *start, bool user_read);
static void arch_pmu_read(uint32_t n, uint64_t *now);
static void arch_pmu_stop(uint32_t n);

#include "../lib/vx-mem/mem.c"
#include "../abi/vx/utf.h"
#include "../lib/vx-note/note.c"
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
#include "../lib/vx-rand/drbg.c" // the kernel's random bases (as_reserve, ADR-0042)
#include "obj/task.c"
#include "trace.h"
#include "pmu.h"
#include "sched/sched.c"
#include "obj/port.c"
#include "obj/channel.c"
#include "obj/counter.c"
#include "obj/futex.c"
#include "obj/device.c"
#include "obj/pager.c"
#include "../lib/vx-ring/ring.c"
#include "obj/ring.c"
#include "obj/process.c"
#include "syscall/syscall.c"
#include "trace.c"
#include "pmu.c"
#include "obj/exception.c"
#include "elf.c"
#include "acpi.c"
#include "../lib/vx-ndb/ndb.c"
#include "root.c"
#include "sched/smp.c"

#ifdef __x86_64__
#define VX_ARCH_NAME "x86_64"
#include "iommu/vtd.c"
#include "arch/x86_64/arch.c"
#elifdef __aarch64__
#define VX_ARCH_NAME "aarch64"
#include "iommu/smmuv3.c"
#include "arch/aarch64/arch.c"
#else
#error "unsupported architecture"
#endif

#include "main.c"
