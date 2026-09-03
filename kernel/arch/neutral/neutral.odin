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
