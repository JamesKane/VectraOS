/*
The amd64 binding of the architecture interface.

`package arch` is the only thing the portable kernel is allowed to import for
CPU-level work. Each architecture supplies one file, selected by build tag,
that binds the neutral names below to its own implementation. aarch64 therefore
means one new `arch_arm64.odin`, and no edits to call sites in sched/ or mem/.
*/
#+build amd64
package arch

import "kernel:arch/amd64"

NAME :: "amd64"

// -- Execution control -------------------------------------------------------

halt_forever :: amd64.halt_forever
disable_interrupts :: amd64.cli
enable_interrupts :: amd64.sti
wait_for_interrupt :: amd64.hlt
spin_hint :: amd64.pause

/*
-- Paging ---------------------------------------------------------------------

The page table primitives, not a page table walker: `kernel/mem/vmm.odin` owns
the walk and calls through these to encode what it decides. See
`amd64/paging.odin` for why the split falls here.
*/

PAGE_SIZE :: amd64.PAGE_SIZE
TABLE_ENTRIES :: amd64.TABLE_ENTRIES
TABLE_LEVELS :: amd64.TABLE_LEVELS

Page_Table :: amd64.Page_Table
Page_Table_Entry :: amd64.Page_Table_Entry
Page_Flag :: amd64.Page_Flag
Page_Flags :: amd64.Page_Flags

ENTRY_EMPTY :: amd64.ENTRY_EMPTY

enable_paging_features :: amd64.enable_paging_features
nx_available :: amd64.nx_available
global_available :: amd64.global_available
max_leaf_level :: amd64.max_leaf_level

table_index :: amd64.table_index
level_size :: amd64.level_size
is_canonical :: amd64.is_canonical

leaf_encode :: amd64.leaf_encode
branch_encode :: amd64.branch_encode
entry_present :: amd64.entry_present
entry_is_leaf :: amd64.entry_is_leaf
entry_address :: amd64.entry_address
entry_flags :: amd64.entry_flags

load_address_space :: amd64.load_address_space
current_address_space :: amd64.current_address_space
flush_page :: amd64.flush_page
flush_all :: amd64.flush_all

/*
-- Traps ----------------------------------------------------------------------

The GDT, the IDT and the fault reporting that hangs off them. `Trap` is neutral
enough for `kernel/panic.odin` to report a fault with no knowledge of which CPU
it happened on. `register_line` and `describe_error` are the two places that do
know, and they write into a caller's sink rather than print.
*/

Trap :: amd64.Trap
Trap_Kind :: amd64.Trap_Kind
Trap_Handler :: amd64.Trap_Handler
Trap_Frame :: amd64.Trap_Frame

REGISTER_LINES :: amd64.REGISTER_LINES

set_trap_handler :: amd64.set_trap_handler
register_line :: amd64.register_line
describe_error :: amd64.describe_error
breakpoint :: amd64.breakpoint
fault_address :: amd64.read_cr2

// Selector and table readbacks, so the boot self-test can confirm the tables
// took rather than inferring it from the absence of a crash.
code_selector :: amd64.read_cs
task_selector :: amd64.read_tr
idt_limit :: amd64.read_idt_limit

KERNEL_CODE_SELECTOR :: amd64.KERNEL_CODE_SEL
TASK_SELECTOR :: amd64.TSS_SEL

/*
-- Scheduling -----------------------------------------------------------------

The state a thread is resumed from, the tick that preempts it, and what kind of
core it is running on. `kernel/sched` is written against these names and has
never seen a `Trap_Frame`.
*/

Resume :: amd64.Resume
Interrupt_Handler :: amd64.Interrupt_Handler
Cpu_Class :: amd64.Cpu_Class

CAPACITY_FULL :: amd64.CAPACITY_FULL
MIN_STACK_SIZE :: amd64.MIN_STACK_SIZE

VECTOR_TIMER :: amd64.VECTOR_TIMER
VECTOR_YIELD :: amd64.VECTOR_YIELD
VECTOR_SPURIOUS :: amd64.VECTOR_SPURIOUS

set_interrupt_handler :: amd64.set_interrupt_handler
thread_resume_init :: amd64.thread_resume_init
cpu_class :: amd64.cpu_class

// yield_now raises the software interrupt the scheduler listens on, so that a
// voluntary switch and a preemption arrive by the same path.
yield_now :: amd64.yield_trap

// The uniprocessor critical section. See `kernel/sync`, which is what callers
// should be reaching for -- these are what it is made of.
irq_save :: amd64.irq_save
irq_restore :: amd64.irq_restore
interrupts_enabled :: amd64.interrupts_enabled

/*
-- The local timer ------------------------------------------------------------

Split across the arch boundary in three steps, because something has to map the
register page, and that is `kernel/mem`'s job, above this file. Ask where it
is, map it, and hand back the virtual address.
*/

LAPIC_MMIO_SIZE :: amd64.LAPIC_MMIO_SIZE

timer_available :: amd64.lapic_available
timer_physical_base :: amd64.lapic_physical_base
timer_attach :: amd64.lapic_attach
timer_attached :: amd64.lapic_attached
timer_calibrate :: amd64.lapic_calibrate
timer_periodic :: amd64.lapic_timer_periodic
timer_stop :: amd64.lapic_timer_stop
timer_ack :: amd64.lapic_eoi

/*
init_traps replaces the bootloader's tables with our own.

Order matters twice over. The GDT comes first, because an IDT entry names a
code selector. That selector has to exist in the table the CPU actually
consults. The PIC is silenced last, because it is the only step that can
produce an interrupt. By then there is somewhere for one to land.

Safe to call before `kernel/mem` exists, and meant to be. The fault stacks are
static. This is therefore what makes memory bring-up debuggable, rather than
something that has to wait for it.
*/
init_traps :: proc "contextless" () {
	amd64.gdt_init()
	amd64.idt_init()
	amd64.pic_disable()
}

/*
early_init runs before anything else in kmain, including the Odin runtime
startup.

On amd64 that means SSE turned on. Odin's codegen uses XMM registers for plain
struct assignment, so the first line of Odin that is not this one would fault
without it.
*/
early_init :: proc "contextless" () {
	amd64.enable_sse()
}
