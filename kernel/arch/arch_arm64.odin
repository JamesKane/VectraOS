/*
The aarch64 binding of the architecture interface.

The same names `arch_amd64.odin` binds, in the same order, so a reader can
put the two side by side. Where a name has no natural meaning here it is
still bound, to something that says so honestly: port I/O reads all-ones,
the timer has no page to map, the door has nothing to arm. `docs/PORTS.md`
records what each port has and has not got.
*/
#+build arm64
package arch

import "kernel:arch/arm64"

NAME :: "arm64"

// -- The console -------------------------------------------------------------

Serial_Kind :: arm64.Serial_Kind
Serial_Desc :: arm64.Serial_Desc

serial_console :: arm64.serial_console
serial_physical :: arm64.serial_physical
console_available :: arm64.console_available
console_write_byte :: arm64.console_write_byte
console_read_byte :: arm64.console_read_byte
set_device_tree :: arm64.set_device_tree

// -- Execution control -------------------------------------------------------

halt_forever :: arm64.halt_forever
disable_interrupts :: arm64.cli
enable_interrupts :: arm64.sti
wait_for_interrupt :: arm64.wfi
spin_hint :: arm64.yield

in_interrupt :: arm64.in_interrupt

VECTOR_TEST :: arm64.VECTOR_TEST
raise_test_interrupt :: arm64.raise_test_interrupt

fpu_hold :: arm64.fpu_hold

// -- Paging ------------------------------------------------------------------

PAGE_SIZE :: arm64.PAGE_SIZE
TABLE_ENTRIES :: arm64.TABLE_ENTRIES
TABLE_LEVELS :: arm64.TABLE_LEVELS

Page_Table :: arm64.Page_Table
Page_Table_Entry :: arm64.Page_Table_Entry

read_cr3 :: arm64.read_cr3
write_cr3 :: arm64.write_cr3
Page_Flag :: arm64.Page_Flag
Page_Flags :: arm64.Page_Flags

ENTRY_EMPTY :: arm64.ENTRY_EMPTY

enable_paging_features :: arm64.enable_paging_features
nx_available :: arm64.nx_available
global_available :: arm64.global_available
max_leaf_level :: arm64.max_leaf_level

table_index :: arm64.table_index
level_size :: arm64.level_size
is_canonical :: arm64.is_canonical

leaf_encode :: arm64.leaf_encode
branch_encode :: arm64.branch_encode
entry_present :: arm64.entry_present
entry_is_leaf :: arm64.entry_is_leaf
entry_address :: arm64.entry_address
entry_flags :: arm64.entry_flags

load_address_space :: arm64.load_address_space
current_address_space :: arm64.current_address_space
flush_page :: arm64.flush_page
flush_all :: arm64.flush_all

// -- Traps -------------------------------------------------------------------

Trap :: arm64.Trap
Trap_Kind :: arm64.Trap_Kind
Trap_Handler :: arm64.Trap_Handler
Trap_Frame :: arm64.Trap_Frame

REGISTER_LINES :: arm64.REGISTER_LINES

set_trap_handler :: arm64.set_trap_handler
register_line :: arm64.register_line
describe_error :: arm64.describe_error
breakpoint :: arm64.breakpoint
fault_address :: arm64.read_far

BREAKPOINT_NAME :: "brk"
describe_traps :: arm64.describe_traps

frame_ip :: arm64.frame_ip
frame_sp :: arm64.frame_sp
frame_vector :: arm64.frame_vector
syscall_request :: arm64.syscall_request
set_syscall_result :: arm64.set_syscall_result
syscall_result :: arm64.syscall_result
frame_call_handler :: arm64.frame_call_handler
frame_sanitise_user :: arm64.frame_sanitise_user
Fault_Bit :: arm64.Fault_Bit
Fault_Bits :: arm64.Fault_Bits
fault_bits :: arm64.fault_bits

// -- Ring 3 ------------------------------------------------------------------

User_Trap_Handler :: arm64.User_Trap_Handler

thread_user_init :: arm64.thread_user_init
thread_user_clone :: arm64.thread_user_clone
frame_enter_user :: arm64.frame_enter_user
syscall_frame_fpu :: arm64.syscall_frame_fpu
kernel_stack_top :: arm64.kernel_stack_top
set_kernel_stack :: arm64.set_kernel_stack
kernel_stack :: arm64.kernel_stack
set_user_trap_handler :: arm64.set_user_trap_handler
frame_is_user :: arm64.frame_is_user
user_trap_count :: arm64.user_trap_count

// -- The system call door ----------------------------------------------------

VECTOR_SYSCALL :: arm64.VECTOR_SYSCALL

syscall_available :: arm64.syscall_available
syscall_init :: arm64.syscall_init
set_syscall_dispatcher :: arm64.set_syscall_dispatcher
syscall_armed :: arm64.syscall_armed
syscall_masks_interrupts :: arm64.syscall_masks_interrupts
current_sp :: arm64.current_sp
syscall_entry_address :: arm64.syscall_entry_address
percpu_kernel_stack :: arm64.percpu_kernel_stack
percpu_id :: arm64.percpu_id
percpu_critical_depth :: arm64.percpu_critical_depth
percpu_ready :: arm64.percpu_ready
Percpu :: arm64.Percpu

// -- Scheduling --------------------------------------------------------------

Resume :: arm64.Resume
Interrupt_Handler :: arm64.Interrupt_Handler
Cpu_Class :: arm64.Cpu_Class

CAPACITY_FULL :: arm64.CAPACITY_FULL
MIN_STACK_SIZE :: arm64.MIN_STACK_SIZE

VECTOR_TIMER :: arm64.VECTOR_TIMER
VECTOR_IRQ_BASE :: arm64.VECTOR_IRQ_BASE
VECTOR_IRQ_COUNT :: arm64.VECTOR_IRQ_COUNT
VECTOR_YIELD :: arm64.VECTOR_YIELD
VECTOR_SPURIOUS :: arm64.VECTOR_SPURIOUS
VECTOR_WAKE :: arm64.VECTOR_WAKE
VECTOR_SHOOT :: arm64.VECTOR_SHOOT
VECTOR_NMI :: arm64.VECTOR_NMI

set_interrupt_handler :: arm64.set_interrupt_handler

inb :: arm64.inb
outb :: arm64.outb
thread_resume_init :: arm64.thread_resume_init
ap_switch :: arm64.ap_switch
cpu_class :: arm64.cpu_class

yield_now :: arm64.yield_trap

irq_save :: arm64.irq_save
irq_restore :: arm64.irq_restore
interrupts_enabled :: arm64.interrupts_enabled

// -- The local timer ---------------------------------------------------------

TIMER_MMIO_SIZE :: arm64.TIMER_MMIO_SIZE
TIMER_NAME :: "generic"
TIMER_REFERENCE :: "from CNTFRQ_EL0"

timer_available :: arm64.timer_available
timer_physical_base :: arm64.timer_physical_base
timer_attach :: arm64.timer_attach
timer_attach_here :: arm64.timer_attach_here
timer_attached :: arm64.timer_attached
timer_calibrate :: arm64.timer_calibrate
timer_periodic :: arm64.timer_periodic
timer_stop :: arm64.timer_stop
timer_ack :: arm64.gic_ack

// -- The interrupt controller ------------------------------------------------

IRQ_MMIO_SIZE :: arm64.GIC_MMIO_SIZE
IRQ_CONTROLLER_NAME :: "gic"

irq_available :: arm64.gic_available
irq_physical_base :: arm64.gic_physical_base
irq_attach :: arm64.gic_attach
irq_attached :: arm64.gic_attached
irq_lines :: arm64.gic_lines
irq_version :: arm64.gic_version
irq_route :: arm64.gic_route
irq_set_mask :: arm64.gic_set_mask
irq_masked :: arm64.gic_masked
irq_vector_of :: arm64.gic_vector_of
irq_ack :: arm64.gic_ack
cpu_lapic_id :: arm64.gic_cpu_number
ipi_send :: arm64.gic_send
ipi_stop_others :: arm64.gic_stop_others

/*
init_traps installs the kernel's vector table on the boot core and gives it
a per-core record.

Safe to call before `kernel/mem` exists, and meant to be: the table is in
the image and the record is static. There is no descriptor table to build
and no controller to silence; every interrupt is masked until the GIC comes
up, and the GIC comes up masked.
*/
init_traps :: proc "contextless" () {
	arm64.vectors_init()
	arm64.percpu_init(0)
}

// set_boot_cpu_id goes unread: a core's number on the GIC is read back out
// of the GIC.
set_boot_cpu_id :: proc "contextless" (id: u64) {
	_ = id
}

init_traps_ap :: proc "contextless" (id: int, cpu_id: u64) {
	_ = cpu_id
	arm64.vectors_init()
	arm64.percpu_init(id)
}

/*
early_init runs before anything else in kmain, including the Odin runtime
startup.

Two things. The kernel moves onto SP_EL1, because the protocol leaves it on
SP_EL0, which is the register a program will own. And the vector unit comes
on, because base revision 6 hands it over disabled and Odin's codegen uses
vector registers for ordinary struct moves.
*/
early_init :: proc "contextless" () {
	arm64.use_kernel_stack_register()
	arm64.enable_fp()
}
