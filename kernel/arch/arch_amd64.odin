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
fault_address :: amd64.read_cr2

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
