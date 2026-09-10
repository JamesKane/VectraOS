/*
What every architecture spells the same way.

The three architecture packages each bind the names `kernel/arch` exports,
and the portable kernel switches over some of them: a `Trap_Kind` in the
panic path, a `Page_Flag` in the VMM, a `Serial_Kind` in the UART driver.
Three private copies of one enum have to be kept identical by hand, and
nothing checks that they are. This package is the one copy. It imports
nothing, so any of the three can import it, and `arch_<arch>.odin` binds
its names through.

The paging constants and the two index arithmetics are here for the same
reason: the radix tree `kernel/mem/vmm.odin` walks is 512 entries of eight
bytes, nine bits of address per level, on all three, and a port supplies an
encoding rather than a second shape.
*/
package neutral

import "base:intrinsics"

// -- Paging ------------------------------------------------------------------

PAGE_SHIFT :: 12
PAGE_SIZE :: 1 << PAGE_SHIFT

// Nine bits of virtual address per level, hence 512 entries of 8 bytes. That
// is one page per table, and it is the property the whole scheme rests on.
TABLE_BITS :: 9
TABLE_ENTRIES :: 1 << TABLE_BITS
TABLE_LEVELS :: 4

Page_Table_Entry :: distinct u64
Page_Table :: [TABLE_ENTRIES]Page_Table_Entry

/*
Neutral permission and caching flags.

Deliberately not a 1:1 mirror of any architecture's bits. `Write` and `User`
are positive here, as they are in the entry. `No_Execute` reads as a
permission the caller must ask to remove. A zero `Page_Flags` is therefore
the most restrictive mapping, rather than the most permissive one.
*/
Page_Flag :: enum u8 {
	Write,
	User,
	No_Execute,
	Global,
	No_Cache,
	Write_Through,
}

Page_Flags :: bit_set[Page_Flag; u8]

/*
table_index extracts the nine bits of `virt` that select an entry at `level`.

Level 1 reads bits 12..20, level 2 bits 21..29, and so on -- one TABLE_BITS
stride per level above the page offset.
*/
table_index :: proc "contextless" (virt: uintptr, level: int) -> int {
	shift := uint(PAGE_SHIFT + TABLE_BITS * (level - 1))
	return int((u64(virt) >> shift) & u64(TABLE_ENTRIES - 1))
}

// level_size is the span a single entry at `level` covers: 4 KiB, 2 MiB, 1 GiB,
// 512 GiB.
level_size :: proc "contextless" (level: int) -> uintptr {
	return uintptr(1) << uint(PAGE_SHIFT + TABLE_BITS * (level - 1))
}

align_down :: proc "contextless" (value: uintptr, align: uintptr) -> uintptr {
	return value & ~(align - 1)
}

// An entry that maps nothing, and the test for one that maps something. Bit
// 0 is the present bit on all three encodings, and a zero entry is empty on
// all three.
ENTRY_EMPTY :: Page_Table_Entry(0)

entry_present :: proc "contextless" (e: Page_Table_Entry) -> bool {
	return u64(e) & 1 != 0
}

// is_canonical_47 is the 47-bit rule two of the three ports share: bits
// 63..48 copy bit 47. amd64's 4-level paging and riscv64's Sv48 both refuse
// anything else. arm64 has its own rule, in `arm64/paging.odin`.
is_canonical_47 :: proc "contextless" (virt: uintptr) -> bool {
	top := u64(virt) >> 47
	return top == 0 || top == 0x1FFFF
}

// -- A thread's first stack --------------------------------------------------

// The least a kernel stack may be, and the alignment every port's vector
// image wants.
MIN_STACK_SIZE :: 4096
FPU_AREA_ALIGN :: 16

// kernel_stack_top is the sixteen-byte-aligned end of a stack. Aligned down,
// so the alignment comes out of the space above the stack and not out of it.
kernel_stack_top :: proc "contextless" (stack: []u8) -> uintptr {
	return align_down(uintptr(raw_data(stack)) + uintptr(len(stack)), 16)
}

/*
carve_top finds room for a frame at the very top of `stack` and a vector
image of `fpu_size` bytes directly below it, which is where the trap tail on
arm64 and riscv64 leaves both. It answers the top, the two addresses, and
false when the stack is too small to hold them. The port writes the frame.
*/
carve_top :: proc "contextless" (stack: []u8, frame_size, fpu_size: uintptr) -> (top, frame_at, fpu_at: uintptr, ok: bool) {
	if len(stack) < MIN_STACK_SIZE {
		return 0, 0, 0, false
	}
	top = kernel_stack_top(stack)
	frame_at = top - frame_size
	fpu_at = frame_at - fpu_size
	if fpu_at <= uintptr(raw_data(stack)) {
		return 0, 0, 0, false
	}
	return top, frame_at, fpu_at, true
}

// -- The vector unit, held live ----------------------------------------------

// `vectra_fpu_hold` is `<arch>/fpu_hold.S`, one per port under the one name.
foreign {
	vectra_fpu_hold :: proc "c" (value: ^f64, flag: ^bool, out: ^f64, counter: ^u64) ---
}

// fpu_hold loads four vector registers from `value`, spins until `flag`
// while counting rounds in `counter`, and writes the sum of the four to
// `out`. `docs/TESTING.md` says why the loop is assembly.
fpu_hold :: proc "contextless" (value: ^f64, flag: ^bool, out: ^f64, counter: ^u64) {
	vectra_fpu_hold(value, flag, out, counter)
}

// -- Traps -------------------------------------------------------------------

/*
A neutral description of what went wrong. `kind` is what the portable kernel
branches on; the names are the manuals' where an architecture has one, and
each port maps its own causes onto the nearest.
*/
Trap_Kind :: enum {
	Unknown,
	Divide_By_Zero,
	Debug,
	Non_Maskable,
	Breakpoint,
	Overflow,
	Bound_Range,
	Invalid_Instruction,
	Device_Not_Available,
	Double_Fault,
	Invalid_Task_State,
	Segment_Not_Present,
	Stack_Fault,
	Protection_Fault,
	Page_Fault,
	Arithmetic_Fault,
	Alignment_Fault,
	Machine_Check,
	Control_Protection,
	Interrupt, // External
}

/*
What the CPU said about a fault, in words the self-test can compare across
architectures. Whether the page was there is not here: an architecture's
syndrome may not say, and the VMM always can, so `kernel/user` asks the VMM.
*/
Fault_Bit :: enum {
	Write,
	User,
	Fetch,
}

Fault_Bits :: bit_set[Fault_Bit]

// -- What kind of core this is -----------------------------------------------

/*
Vectra schedules against a core's *class*, not its number.

amd64 has one class, and arm64 will have up to three. The vocabulary is here
so the scheduler never learns what a DynamIQ cluster is. `CAPACITY_FULL` is
relative work per unit time, normalised so the fastest class on a machine
is full.
*/
Cpu_Class :: enum {
	Efficiency,
	Performance,
	Prime,
}

CAPACITY_FULL :: 1024

// -- The console -------------------------------------------------------------

// The consoles `kernel/drivers/uart` drives, and the description an
// architecture answers `serial_console` with.
Serial_Kind :: enum {
	None,
	Port_16550, // A 16550 behind x86 port I/O
	Mmio_16550, // A 16550 with byte registers in memory
	Pl011,      // ARM's PrimeCell UART, in memory
	Firmware,   // The firmware's own console, through `console_write`
}

Serial_Desc :: struct {
	kind: Serial_Kind,
	base: uintptr, // A port number or an address, by `kind`
}

// -- Registers in memory -----------------------------------------------------

// A 32-bit device register, read and written whole and never cached: the
// compiler may not hoist a status read out of a loop or drop a write nothing
// reads back.
mmio_read32 :: proc "contextless" (base: rawptr, offset: uintptr) -> u32 {
	return intrinsics.volatile_load(cast(^u32)(uintptr(base) + offset))
}

mmio_write32 :: proc "contextless" (base: rawptr, offset: uintptr, value: u32) {
	intrinsics.volatile_store(cast(^u32)(uintptr(base) + offset), value)
}

// The same access at the other widths a device presents. Virtio's common
// configuration is a mix of 8-, 16-, 32- and 64-bit fields, and the GIC's
// priority registers are bytes.
mmio_read8 :: proc "contextless" (base: rawptr, offset: uintptr) -> u8 {
	return intrinsics.volatile_load(cast(^u8)(uintptr(base) + offset))
}

mmio_write8 :: proc "contextless" (base: rawptr, offset: uintptr, value: u8) {
	intrinsics.volatile_store(cast(^u8)(uintptr(base) + offset), value)
}

mmio_read16 :: proc "contextless" (base: rawptr, offset: uintptr) -> u16 {
	return intrinsics.volatile_load(cast(^u16)(uintptr(base) + offset))
}

mmio_write16 :: proc "contextless" (base: rawptr, offset: uintptr, value: u16) {
	intrinsics.volatile_store(cast(^u16)(uintptr(base) + offset), value)
}

mmio_read64 :: proc "contextless" (base: rawptr, offset: uintptr) -> u64 {
	return intrinsics.volatile_load(cast(^u64)(uintptr(base) + offset))
}

mmio_write64 :: proc "contextless" (base: rawptr, offset: uintptr, value: u64) {
	intrinsics.volatile_store(cast(^u64)(uintptr(base) + offset), value)
}

// -- What a port has not got -------------------------------------------------
//
// Where a name in the interface has no meaning on an architecture it is still
// bound, to something that says so honestly. These are the honest answers,
// written once, so two ports do not each keep a copy.

// There is no port space on arm64 or riscv64. A driver that probes one, the
// PS/2 keyboard's, reads all-ones, which is what an absent device answers on
// a PC too, and gives up the same way.
no_port_io_inb :: proc "contextless" (port: u16) -> u8 {
	_ = port
	return 0xFF
}

no_port_io_outb :: proc "contextless" (port: u16, value: u8) {
	_, _ = port, value
}

// The firmware console, on an architecture that has none. The four exist so
// `kernel/drivers/uart` can name them on every architecture.
no_console_available :: proc "contextless" () -> bool {
	return false
}

no_console_write :: proc "contextless" (bytes: []u8) {
	_ = bytes
}

no_console_write_byte :: proc "contextless" (b: u8) {
	_ = b
}

no_console_read_byte :: proc "contextless" () -> (u8, bool) {
	return 0, false
}

// no_device_tree takes the flattened device tree on an architecture that
// reads nothing from it.
no_device_tree :: proc "contextless" (dtb: rawptr) {
	_ = dtb
}

// One class of core, at full capacity, with no model name beside it: the
// answer on an architecture with nothing to tell its cores apart.
one_class_cpu_class :: proc "contextless" () -> (class: Cpu_Class, capacity: int) {
	return .Performance, CAPACITY_FULL
}

one_class_cpu_model :: proc "contextless" () -> string {
	return ""
}

// no_irq_set_edge is the answer on a controller with no trigger type to set
// after a route.
no_irq_set_edge :: proc "contextless" (gsi: int) {
	_ = gsi
}

// door_is_trap_entry is the three answers a port gives when its system call
// is an ordinary exception: the door is there, there is nothing to arm, and
// the architecture masks interrupts on the way in.
door_is_trap_entry :: proc "contextless" () -> bool {
	return true
}
