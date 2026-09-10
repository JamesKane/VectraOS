/*
The distributor the two generic interrupt controllers share.

Version 2 and version 3 differ in how a core acknowledges an interrupt and
how one core interrupts another. They differ in how a shared line names its
target core. They do not differ in the distributor's shared lines. The
enable, priority and configuration registers sit at the same offsets and
mean the same thing on both. This file is that layer, written once.
`gic.odin` and `gic3.odin` set the base when they attach and keep what
differs.
*/
package arm64

import "kernel:arch/neutral"

// Distributor registers. The shared ones -- enable, priority, config -- are at
// version 2's offsets. What version 3 adds is group selection by bit, and
// routing by a sixty-four-bit affinity rather than a byte of core mask.
GICD_CTLR :: uintptr(0x0000)
GICD_TYPER :: uintptr(0x0004)
GICD_IIDR :: uintptr(0x0008)
GICD_IGROUPR :: uintptr(0x0080)
GICD_ISENABLER :: uintptr(0x0100) // One bit per interrupt, 32 per word
GICD_ICENABLER :: uintptr(0x0180)
GICD_ICPENDR :: uintptr(0x0280)
GICD_IPRIORITYR :: uintptr(0x0400) // One byte per interrupt
GICD_ITARGETSR :: uintptr(0x0800) // One byte per interrupt, a bit per core
GICD_ICFGR :: uintptr(0x0C00)
GICD_SGIR :: uintptr(0x0F00)
GICD_IROUTER :: uintptr(0x6000)

// The distributor, once the version in use maps it, and how many interrupt
// ids it has. Nil until an attach, and nil again when the attach read
// all-ones.
@(private) gicd: rawptr
@(private) lines: int

@(private)
gicd_read :: proc "contextless" (off: uintptr) -> u32 {
	return neutral.mmio_read32(gicd, off)
}

@(private)
gicd_write :: proc "contextless" (off: uintptr, v: u32) {
	neutral.mmio_write32(gicd, off, v)
}

@(private)
gicd_write_byte :: proc "contextless" (off: uintptr, v: u8) {
	neutral.mmio_write8(gicd, off, v)
}

@(private)
gicd_write64 :: proc "contextless" (off: uintptr, v: u64) {
	neutral.mmio_write64(gicd, off, v)
}

// gicd_lines_from_typer is the interrupt id count `GICD_TYPER` reports: the
// low five bits plus one, in units of 32, and never more than 1020.
gicd_lines_from_typer :: proc "contextless" (typer: u32) -> int {
	n := int(typer & 0x1F + 1) * 32
	if n > 1020 {
		n = 1020
	}
	return n
}

// gicd_lines is how many shared peripheral lines the distributor has.
gicd_lines :: proc "contextless" () -> int {
	if gicd == nil || lines < 32 {
		return 0
	}
	return lines - 32
}

// -- Shared peripheral lines --------------------------------------------------

@(private)
line_valid :: proc "contextless" (gsi: int) -> bool {
	return gicd != nil && gsi >= 0 && gsi < gicd_lines()
}

// gicd_set_trigger makes interrupt `id` edge- or level-sensitive. `GICD_ICFGR`
// holds two bits a line, sixteen lines a word, and the high bit is edge. The
// write touches no other line.
@(private)
gicd_set_trigger :: proc "contextless" (id: int, edge: bool) {
	cfg := GICD_ICFGR + uintptr(id / 16 * 4)
	shift := u32((id % 16) * 2)
	if edge {
		gicd_write(cfg, gicd_read(cfg) | u32(0b10) << shift)
	} else {
		gicd_write(cfg, gicd_read(cfg) & ~(u32(0b10) << shift))
	}
}

// gicd_set_edge makes a shared line edge-triggered, for a device that
// pulses its line rather than holds it. The SMMU's event queue is one, and
// its tree entry says so. A pulse on a level line is a fire the controller
// may lose.
gicd_set_edge :: proc "contextless" (gsi: int) {
	if !line_valid(gsi) {
		return
	}
	gicd_set_trigger(VECTOR_IRQ_BASE + gsi, true)
}

gicd_set_mask :: proc "contextless" (gsi: int, masked: bool) {
	if !line_valid(gsi) {
		return
	}
	id := VECTOR_IRQ_BASE + gsi
	bit := u32(1) << u32(id % 32)
	if masked {
		gicd_write(GICD_ICENABLER + uintptr(id / 32 * 4), bit)
	} else {
		gicd_write(GICD_ISENABLER + uintptr(id / 32 * 4), bit)
	}
}

gicd_masked :: proc "contextless" (gsi: int) -> bool {
	if !line_valid(gsi) {
		return true
	}
	id := VECTOR_IRQ_BASE + gsi
	return gicd_read(GICD_ISENABLER + uintptr(id / 32 * 4)) & (u32(1) << u32(id % 32)) == 0
}

// gicd_vector_of is the vector a line arrives on, which is its id.
gicd_vector_of :: proc "contextless" (gsi: int) -> u8 {
	if !line_valid(gsi) {
		return 0
	}
	return u8(VECTOR_IRQ_BASE + gsi)
}
