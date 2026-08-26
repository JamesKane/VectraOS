/*
The amd64 binding of the architecture interface.

`package arch` is the only thing the portable kernel is allowed to import for
CPU-level work. Each architecture supplies one file, selected by build tag,
that binds the neutral names below to its own implementation -- so adding
aarch64 means adding `arch_arm64.odin`, not editing call sites in sched/ or
mem/.
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
enough for `kernel/panic.odin` to report a fault without knowing which CPU it
happened on; `register_line` and `describe_error` are the two places that do
know, and they write into a caller's sink rather than printing.
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
init_traps replaces the bootloader's tables with our own.

Order matters twice over. The GDT comes first because an IDT entry names a code
selector, and the selector it names has to exist in the table the CPU is
actually consulting. The PIC is silenced last because it is the only step that
can produce an interrupt, and by then there is somewhere for one to land.

Safe to call before `kernel/mem` exists, and meant to be: the fault stacks are
static, so this is what makes memory bring-up debuggable rather than something
that has to wait for it.
*/
init_traps :: proc "contextless" () {
	amd64.gdt_init()
	amd64.idt_init()
	amd64.pic_disable()
}

/*
early_init runs before anything else in kmain, including the Odin runtime
startup.

On amd64 that means enabling SSE: Odin's codegen uses XMM registers for plain
struct assignment, so the first line of Odin that is not this one would fault
without it.
*/
early_init :: proc "contextless" () {
	amd64.enable_sse()
}
