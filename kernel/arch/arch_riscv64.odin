/*
The riscv64 binding of the architecture interface.

The same names `arch_amd64.odin` binds, in the same order, so a reader can
put the two side by side. Where a name has no natural meaning here it is
still bound, to something that says so honestly: port I/O reads all-ones,
the timer has no page to map, the door has nothing to arm. `docs/PORTS.md`
records what each port has and has not got.
*/
#+build riscv64
package arch

import "kernel:arch/neutral"
import "kernel:arch/riscv64"

NAME :: "riscv64"

// -- The console -------------------------------------------------------------

Serial_Kind :: neutral.Serial_Kind
Serial_Desc :: neutral.Serial_Desc

set_boot_layout :: riscv64.set_boot_layout
serial_console :: riscv64.serial_console
mmio_read32 :: neutral.mmio_read32
mmio_write32 :: neutral.mmio_write32
console_available :: riscv64.console_available
console_write :: riscv64.console_write
console_write_byte :: riscv64.console_write_byte
console_read_byte :: riscv64.console_read_byte
set_device_tree :: riscv64.set_device_tree

// -- Execution control -------------------------------------------------------

halt_forever :: riscv64.halt_forever
disable_interrupts :: riscv64.cli
enable_interrupts :: riscv64.sti
wait_for_interrupt :: riscv64.wfi
spin_hint :: riscv64.pause

in_interrupt :: riscv64.in_interrupt

VECTOR_TEST :: riscv64.VECTOR_TEST
raise_test_interrupt :: riscv64.raise_test_interrupt

fpu_hold :: riscv64.fpu_hold

// -- Paging ------------------------------------------------------------------

PAGE_SIZE :: riscv64.PAGE_SIZE
TABLE_ENTRIES :: riscv64.TABLE_ENTRIES
TABLE_LEVELS :: riscv64.TABLE_LEVELS

Page_Table :: riscv64.Page_Table
Page_Table_Entry :: riscv64.Page_Table_Entry

read_cr3 :: riscv64.read_cr3
write_cr3 :: riscv64.write_cr3
Page_Flag :: riscv64.Page_Flag
Page_Flags :: riscv64.Page_Flags

ENTRY_EMPTY :: riscv64.ENTRY_EMPTY

enable_paging_features :: riscv64.enable_paging_features
nx_available :: riscv64.nx_available
global_available :: riscv64.global_available
max_leaf_level :: riscv64.max_leaf_level

table_index :: riscv64.table_index
level_size :: riscv64.level_size
is_canonical :: riscv64.is_canonical

leaf_encode :: riscv64.leaf_encode
branch_encode :: riscv64.branch_encode
entry_present :: riscv64.entry_present
entry_is_leaf :: riscv64.entry_is_leaf
entry_address :: riscv64.entry_address
entry_flags :: riscv64.entry_flags

load_kernel_space :: riscv64.load_address_space
load_address_space :: riscv64.load_address_space
current_address_space :: riscv64.current_address_space
flush_page :: riscv64.flush_page
flush_all :: riscv64.flush_all

// -- Traps -------------------------------------------------------------------

Trap :: riscv64.Trap
Trap_Kind :: riscv64.Trap_Kind
Trap_Handler :: riscv64.Trap_Handler
Trap_Frame :: riscv64.Trap_Frame

REGISTER_LINES :: riscv64.REGISTER_LINES

set_trap_handler :: riscv64.set_trap_handler
register_line :: riscv64.register_line
describe_error :: riscv64.describe_error
breakpoint :: riscv64.breakpoint
fault_address :: riscv64.read_stval

BREAKPOINT_NAME :: "ebreak"

// A program's privileged instruction is an illegal one here: the hart raises
// the same cause for a CSR it may not touch as for an opcode it does not
// have, and this kernel reports what the hart said.
PRIVILEGED_FAULT :: Trap_Kind.Invalid_Instruction
describe_traps :: riscv64.describe_traps

frame_ip :: riscv64.frame_ip
frame_sp :: riscv64.frame_sp
frame_vector :: riscv64.frame_vector
syscall_request :: riscv64.syscall_request
set_syscall_result :: riscv64.set_syscall_result
syscall_result :: riscv64.syscall_result
frame_call_handler :: riscv64.frame_call_handler
frame_sanitise_user :: riscv64.frame_sanitise_user
Fault_Bit :: riscv64.Fault_Bit
Fault_Bits :: riscv64.Fault_Bits
fault_bits :: riscv64.fault_bits

// -- Ring 3 ------------------------------------------------------------------

User_Trap_Handler :: riscv64.User_Trap_Handler

thread_user_init :: riscv64.thread_user_init
thread_user_clone :: riscv64.thread_user_clone
frame_enter_user :: riscv64.frame_enter_user
syscall_frame_fpu :: riscv64.syscall_frame_fpu
// USER_STACK_TILT is how far below a sixteen-aligned top a program's first
// stack pointer sits: the procedure call standard wants the stack pointer sixteen-aligned at every call, and a fresh stack is.
USER_STACK_TILT :: 0

kernel_stack_top :: riscv64.kernel_stack_top
set_kernel_stack :: riscv64.set_kernel_stack
kernel_stack :: riscv64.kernel_stack
set_user_trap_handler :: riscv64.set_user_trap_handler
frame_is_user :: riscv64.frame_is_user
user_trap_count :: riscv64.user_trap_count

// -- The system call door ----------------------------------------------------

VECTOR_SYSCALL :: riscv64.VECTOR_SYSCALL

syscall_available :: riscv64.syscall_available
syscall_init :: riscv64.syscall_init
set_syscall_dispatcher :: riscv64.set_syscall_dispatcher
syscall_armed :: riscv64.syscall_armed
syscall_masks_interrupts :: riscv64.syscall_masks_interrupts
current_sp :: riscv64.current_sp
syscall_entry_address :: riscv64.syscall_entry_address
percpu_kernel_stack :: riscv64.percpu_kernel_stack
percpu_id :: riscv64.percpu_id
percpu_critical_depth :: riscv64.percpu_critical_depth
percpu_ready :: riscv64.percpu_ready
Percpu :: riscv64.Percpu

// -- Scheduling --------------------------------------------------------------

Resume :: riscv64.Resume
Interrupt_Handler :: riscv64.Interrupt_Handler
Cpu_Class :: riscv64.Cpu_Class

CAPACITY_FULL :: riscv64.CAPACITY_FULL
MIN_STACK_SIZE :: riscv64.MIN_STACK_SIZE

VECTOR_TIMER :: riscv64.VECTOR_TIMER
VECTOR_IRQ_BASE :: riscv64.VECTOR_IRQ_BASE
VECTOR_IRQ_COUNT :: riscv64.VECTOR_IRQ_COUNT
VECTOR_YIELD :: riscv64.VECTOR_YIELD
VECTOR_SPURIOUS :: riscv64.VECTOR_SPURIOUS
VECTOR_WAKE :: riscv64.VECTOR_WAKE
VECTOR_SHOOT :: riscv64.VECTOR_SHOOT
VECTOR_NMI :: riscv64.VECTOR_NMI

set_interrupt_handler :: riscv64.set_interrupt_handler

inb :: riscv64.inb
outb :: riscv64.outb
thread_resume_init :: riscv64.thread_resume_init
ap_switch :: riscv64.ap_switch
cpu_class :: riscv64.cpu_class

yield_now :: riscv64.yield_trap

irq_save :: riscv64.irq_save
irq_restore :: riscv64.irq_restore
interrupts_enabled :: riscv64.interrupts_enabled

// -- The local timer ---------------------------------------------------------

TIMER_MMIO_SIZE :: riscv64.TIMER_MMIO_SIZE
TIMER_NAME :: "sbi"
TIMER_REFERENCE :: "from the device tree"

timer_available :: riscv64.timer_available
timer_physical_base :: riscv64.timer_physical_base
timer_attach :: riscv64.timer_attach
timer_attach_here :: riscv64.timer_attach_here
timer_attached :: riscv64.timer_attached
timer_calibrate :: riscv64.timer_calibrate
timer_periodic :: riscv64.timer_periodic
timer_stop :: riscv64.timer_stop
timer_ack :: riscv64.timer_ack

// -- The interrupt controller ------------------------------------------------

IRQ_MMIO_SIZE :: riscv64.PLIC_MMIO_SIZE
IRQ_CONTROLLER_NAME :: "plic"

irq_available :: riscv64.plic_available
irq_physical_base :: riscv64.plic_physical_base
irq_attach :: riscv64.plic_attach
irq_attached :: riscv64.plic_attached
irq_lines :: riscv64.plic_lines
irq_version :: riscv64.plic_version
irq_route :: riscv64.plic_route
irq_set_mask :: riscv64.plic_set_mask
irq_masked :: riscv64.plic_masked
irq_vector_of :: riscv64.plic_vector_of
irq_ack :: riscv64.timer_ack
cpu_lapic_id :: riscv64.cpu_hart_number
ipi_send :: riscv64.ipi_send
ipi_stop_others :: riscv64.ipi_stop_others

/*
init_traps installs the trap entry on the boot hart and gives it a per-core
record.

Safe to call before `kernel/mem` exists, and meant to be: the entry is in
the image and the record is static. Every interrupt stays masked in `sie`
until the timer comes up. `cpu_id` is the boot hart's id, from the
bootloader's list, because a hart cannot read its own from supervisor mode.
*/
init_traps :: proc "contextless" (cpu_id: u64) {
	riscv64.vectors_init()
	riscv64.percpu_init(0, cpu_id)
}

init_traps_ap :: proc "contextless" (id: int, cpu_id: u64) {
	riscv64.vectors_init()
	riscv64.percpu_init(id, cpu_id)
}

/*
early_init runs before anything else in kmain, including the Odin runtime
startup.

The float unit comes on, because base revision 6 hands over `sstatus` with
it off and Odin's codegen keeps floats in float registers. Supervisor
access to user pages comes on with it, because every copy in and out of a
program needs it and the bootloader leaves it off.
*/
early_init :: proc "contextless" () {
	riscv64.enable_fp()
}

// -- PCI configuration space -------------------------------------------------

PCI_CONFIG_MMIO_SIZE :: riscv64.PCI_CONFIG_MMIO_SIZE
PCI_CONFIG_NAME :: riscv64.PCI_CONFIG_NAME

pci_available :: riscv64.pci_available
pci_config_physical_base :: riscv64.pci_config_physical_base
pci_attach :: riscv64.pci_attach
pci_read32 :: riscv64.pci_read32
pci_write32 :: riscv64.pci_write32
