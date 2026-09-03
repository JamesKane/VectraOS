/*
The first thing the kernel can reach: a window onto the serial port.

The protocol maps memory and the framebuffer into the higher half, and
nothing else. The PL011 the `virt` board has at physical `0x0900_0000` is a
device, so it is not there, and the kernel's own page tables do not exist
until `kernel/mem` builds them. A boot that cannot say anything before that
point is a boot that fails in silence, and memory bring-up is the part that
most needs to be able to talk.

`TTBR0_EL1` is the way through. The protocol leaves it unspecified and uses
nothing below the higher half, so the lower half is the kernel's to fill
before it has an allocator. Four static tables, one per level, map exactly
one page: the UART, at its own physical address, as device memory. The
window costs 16 KiB of `.bss` and outlives its purpose, because it is also
what a kernel thread's TTBR0 names once the VMM is up -- see `paging.odin`.

The table addresses have to be physical, and the only way to know one before
there is a memory map is the slide the bootloader reports between where the
image is and where it was linked. `set_boot_layout` receives it from `kmain`
before anything else, and `paging.odin` needs the same number later.
*/
package arm64

import "kernel:arch/neutral"

// Where the `virt` board's first PL011 is. Assumed rather than read from the
// device tree, which this file cannot parse before the runtime is up.
UART_PHYS :: uintptr(0x0900_0000)

// One page-aligned table. The alignment is what the base registers and the
// table descriptors require of anything they point at.
Table :: struct #align(PAGE_SIZE) {
	e: [TABLE_ENTRIES]u64,
}

@(private = "file") window_l0: Table
@(private = "file") window_l1: Table
@(private = "file") window_l2: Table
@(private = "file") window_l3: Table

// The difference between an address in the image and its physical address.
// Zero until `set_boot_layout` has run.
@(private = "file") slide: u64

// set_boot_layout takes the bootloader's word on where memory is. The slide
// is the one number this architecture needs from it.
set_boot_layout :: proc "contextless" (hhdm, kernel_phys, kernel_virt: u64) {
	_ = hhdm
	slide = kernel_phys - kernel_virt
}

kernel_slide :: proc "contextless" () -> u64 {
	return slide
}

// image_phys translates an address inside the kernel image to physical.
image_phys :: proc "contextless" (p: rawptr) -> uintptr {
	return uintptr(u64(uintptr(p)) + slide)
}

// early_window_root is the physical address of the window's top table, the
// value `paging.odin` puts in TTBR0 for a kernel thread.
early_window_root :: proc "contextless" () -> uintptr {
	return image_phys(&window_l0)
}

/*
serial_console builds the window and names the port behind it.

MAIR gets a device attribute in index 2 alongside the two the bootloader
set. TCR keeps everything the bootloader chose except the bit that would
disable TTBR0 walks. Then the four tables, then the base register, then the
TLB, in that order, because a translation cached before the tables were
written would be a translation of nothing.
*/
serial_console :: proc "contextless" () -> Serial_Desc {
	write_mair(read_mair() & 0xFFFF | MAIR_DEVICE << 16)
	write_tcr(read_tcr() &~ TCR_EPD0)
	isb()

	branch :: proc "contextless" (t: ^Table) -> u64 {
		return u64(image_phys(t)) | PTE_VALID | PTE_TABLE
	}
	window_l0.e[table_index(UART_PHYS, 4)] = branch(&window_l1)
	window_l1.e[table_index(UART_PHYS, 3)] = branch(&window_l2)
	window_l2.e[table_index(UART_PHYS, 2)] = branch(&window_l3)
	window_l3.e[table_index(UART_PHYS, 1)] = u64(leaf_encode(UART_PHYS, {.Write, .No_Cache, .No_Execute}, 1))

	dsb_ish()
	write_ttbr0(u64(early_window_root()))
	isb()
	tlbi_all()

	return Serial_Desc{kind = .Pl011, base = UART_PHYS}
}

Serial_Kind :: neutral.Serial_Kind
Serial_Desc :: neutral.Serial_Desc

// This architecture has no firmware console.
console_available :: proc "contextless" () -> bool {
	return false
}

console_write :: proc "contextless" (bytes: []u8) {
	_ = bytes
}

console_write_byte :: proc "contextless" (b: u8) {
	_ = b
}

console_read_byte :: proc "contextless" () -> (u8, bool) {
	return 0, false
}

// The device tree, which nothing here reads: the timer's rate is a register
// on this architecture, and the GIC's address is the `virt` board's.
set_device_tree :: proc "contextless" (dtb: rawptr) {
	_ = dtb
}
