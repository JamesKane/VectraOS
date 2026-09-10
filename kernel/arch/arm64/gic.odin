/*
The generic interrupt controller, version 2 -- how any interrupt reaches a
core here.

One controller does the two jobs the local APIC and the I/O APIC split on
amd64. The *distributor* is the machine's: it owns every shared peripheral
line, routes each to a set of cores, and takes the software-generated
interrupts one core sends another. The *CPU interface* is per core: it
hands the core the id of what is pending, and takes the acknowledgement
back. The two are adjacent register pages on the `virt` board, at
`0x0800_0000` and `0x0801_0000`, and one mapping covers both.

Nothing here locks. Routing happens once per device during boot, before the
line it routes is unmasked. The acknowledge and the end-of-interrupt are
per core by construction.

The base address is assumed rather than discovered, for the same reason the
I/O APIC's is on amd64: nothing here parses the tables that would say. The
device tree does, and the day something reads it for this is the day the
bootloader's tree stops being handed straight back.

This file is the version-2 controller. `gic3.odin` is version 3, the one
the real board has, and `gic_select.odin` picks between them at build time
from `-define:VECTRA_GIC`. The public names both files answer to -- `gic_route`,
`gic_ack` and the rest -- are the ones the select file binds to one version's
`gicv2_*` or `gicv3_*`, so every caller is version-blind.
*/
package arm64

import "base:intrinsics"

GICV2_PHYS :: uintptr(0x0800_0000)
GICV2_MMIO_SIZE :: u64(0x2_0000)

@(private = "file") GICC_OFFSET :: uintptr(0x1_0000)

// The distributor.
@(private = "file") GICD_CTLR :: uintptr(0x000)
@(private = "file") GICD_TYPER :: uintptr(0x004)
@(private = "file") GICD_IIDR :: uintptr(0x008)
@(private = "file") GICD_ISENABLER :: uintptr(0x100) // One bit per interrupt, 32 per word
@(private = "file") GICD_ICENABLER :: uintptr(0x180)
@(private = "file") GICD_ICPENDR :: uintptr(0x280)
@(private = "file") GICD_IPRIORITYR :: uintptr(0x400) // One byte per interrupt
@(private = "file") GICD_ITARGETSR :: uintptr(0x800) // One byte per interrupt, a bit per core
@(private = "file") GICD_ICFGR :: uintptr(0xC00)
@(private = "file") GICD_SGIR :: uintptr(0xF00)

// The CPU interface.
@(private = "file") GICC_CTLR :: uintptr(0x000)
@(private = "file") GICC_PMR :: uintptr(0x004)
@(private = "file") GICC_BPR :: uintptr(0x008)
@(private = "file") GICC_IAR :: uintptr(0x00C)
@(private = "file") GICC_EOIR :: uintptr(0x010)

// One priority for everything. Lower is more urgent, and the mask lets
// anything below 0xF0 through.
@(private = "file") PRIORITY_DEFAULT :: u8(0xA0)
@(private = "file") PRIORITY_MASK :: u32(0xF0)

@(private = "file") SGIR_ALL_BUT_SELF :: u32(1) << 24

@(private = "file") dist: rawptr
@(private = "file") cpu_if: rawptr
@(private = "file") lines: int

@(private = "file")
dist_read :: proc "contextless" (offset: uintptr) -> u32 {
	return intrinsics.volatile_load(cast(^u32)(uintptr(dist) + offset))
}

@(private = "file")
dist_write :: proc "contextless" (offset: uintptr, value: u32) {
	intrinsics.volatile_store(cast(^u32)(uintptr(dist) + offset), value)
}

@(private = "file")
dist_write_byte :: proc "contextless" (offset: uintptr, value: u8) {
	intrinsics.volatile_store(cast(^u8)(uintptr(dist) + offset), value)
}

@(private = "file")
cpu_read :: proc "contextless" (offset: uintptr) -> u32 {
	return intrinsics.volatile_load(cast(^u32)(uintptr(cpu_if) + offset))
}

@(private = "file")
cpu_write :: proc "contextless" (offset: uintptr, value: u32) {
	intrinsics.volatile_store(cast(^u32)(uintptr(cpu_if) + offset), value)
}

gicv2_physical_base :: proc "contextless" () -> uintptr {
	return GICV2_PHYS
}

/*
gicv2_attach takes the mapped register pages and brings the distributor up.

Every shared line is disabled, given the one priority and aimed at core 0.
Firmware leaves routes behind, and an inherited route aimed at a core that
has not enabled its interface is an interrupt nobody takes. Then this core's
own interface, which every other core does for itself in `gicv2_attach_here`.
*/
gicv2_attach :: proc "contextless" (virt: rawptr) {
	dist = virt
	cpu_if = rawptr(uintptr(virt) + GICC_OFFSET)

	typer := dist_read(GICD_TYPER)
	if typer == 0xFFFF_FFFF {
		dist = nil
		cpu_if = nil
		return
	}
	lines = int(typer & 0x1F + 1) * 32
	if lines > 1020 {
		lines = 1020
	}

	dist_write(GICD_CTLR, 0)
	for id := 32; id < lines; id += 32 {
		dist_write(GICD_ICENABLER + uintptr(id / 8), 0xFFFF_FFFF)
		dist_write(GICD_ICPENDR + uintptr(id / 8), 0xFFFF_FFFF)
	}
	for id in 0 ..< lines {
		dist_write_byte(GICD_IPRIORITYR + uintptr(id), PRIORITY_DEFAULT)
		if id >= 32 {
			dist_write_byte(GICD_ITARGETSR + uintptr(id), 1)
		}
	}
	dist_write(GICD_CTLR, 1)

	gicv2_attach_here()
}

// gicv2_attach_here brings up the calling core's CPU interface and lets its
// private interrupts through: the timer, and every software-generated one.
gicv2_attach_here :: proc "contextless" () {
	if cpu_if == nil {
		return
	}
	cpu_write(GICC_CTLR, 0)
	cpu_write(GICC_PMR, PRIORITY_MASK)
	cpu_write(GICC_BPR, 0)
	dist_write(GICD_ICENABLER, 0xFFFF_FFFF)
	dist_write(GICD_ISENABLER, 0x0000_FFFF | u32(1) << VECTOR_TIMER)
	cpu_write(GICC_CTLR, 1)
}

gicv2_attached :: proc "contextless" () -> bool {
	return dist != nil
}

gicv2_available :: proc "contextless" () -> bool {
	return dist != nil
}

// gicv2_lines is how many shared peripheral lines the distributor has.
gicv2_lines :: proc "contextless" () -> int {
	if dist == nil || lines < 32 {
		return 0
	}
	return lines - 32
}

gicv2_version :: proc "contextless" () -> u32 {
	return dist == nil ? 0 : dist_read(GICD_IIDR) >> 16 & 0xF
}

/*
gicv2_acknowledge takes the pending interrupt's id from the CPU interface and
keeps the whole word for the end-of-interrupt. The read is the acknowledge:
the interrupt is active from here until `gicv2_eoi` retires it, and nothing at
its priority or below arrives in between.
*/
gicv2_acknowledge :: proc "contextless" () -> u32 {
	if cpu_if == nil {
		return 1023
	}
	iar := cpu_read(GICC_IAR)
	this_cpu().irq = iar
	return iar
}

gicv2_eoi :: proc "contextless" (iar: u32) {
	if cpu_if != nil && iar & 0x3FF < 1020 {
		cpu_write(GICC_EOIR, iar)
	}
}

// gicv2_ack retires the interrupt this core is servicing, which is the one it
// acknowledged last. Must happen once per acknowledge, and the timer's is
// also where the next tick is armed.
gicv2_ack :: proc "contextless" () {
	iar := this_cpu().irq
	if iar & 0x3FF == VECTOR_TIMER {
		timer_rearm()
	}
	gicv2_eoi(iar)
	this_cpu().irq = 1023
}

// gicv2_cpu_number is this core's bit in a target mask, read out of the
// register that reports it: the targets of a private interrupt are the
// reading core alone.
gicv2_cpu_number :: proc "contextless" () -> u32 {
	if dist == nil {
		return 0
	}
	mask := dist_read(GICD_ITARGETSR) & 0xFF
	for i in u32(0) ..< 8 {
		if mask & (1 << i) != 0 {
			return i
		}
	}
	return 0
}

// -- Shared peripheral lines --------------------------------------------------

@(private = "file")
line_valid :: proc "contextless" (gsi: int) -> bool {
	return dist != nil && gsi >= 0 && gsi < gicv2_lines()
}

// gicv2_route aims one shared line at one core and leaves it masked, so a
// driver can register its handler before the first interrupt arrives.
gicv2_route :: proc "contextless" (gsi: int, vector: u8, cpu: u32) {
	_ = vector
	if !line_valid(gsi) {
		return
	}
	id := uintptr(VECTOR_IRQ_BASE + gsi)
	dist_write_byte(GICD_ITARGETSR + id, u8(1 << (cpu & 7)))

	// Level-sensitive: a shared line stays asserted until its device is
	// serviced, which is the handshake `docs/HARDWARE.md` section 3's `irq`
	// stream keeps -- mask on fire, the driver clears the source, unmask on the
	// next read. `GICD_ICFGR` holds two bits a line, sixteen lines a word; the
	// high bit is edge. Clearing it makes this SPI level, and touches no other
	// line. Reset default is level on this part, so this is the explicit say.
	cfg := GICD_ICFGR + uintptr(id / 16 * 4)
	shift := u32((id % 16) * 2)
	dist_write(cfg, dist_read(cfg) & ~(u32(0b10) << shift))
}

// gicv2_set_edge makes a shared line edge-triggered, for a device that
// pulses its line rather than holds it. The SMMU's event queue is one, and
// its tree entry says so. A pulse on a level line is a fire the controller
// may lose.
gicv2_set_edge :: proc "contextless" (gsi: int) {
	if !line_valid(gsi) {
		return
	}
	id := uintptr(VECTOR_IRQ_BASE + gsi)
	cfg := GICD_ICFGR + uintptr(id / 16 * 4)
	shift := u32((id % 16) * 2)
	dist_write(cfg, dist_read(cfg) | u32(0b10) << shift)
}

gicv2_set_mask :: proc "contextless" (gsi: int, masked: bool) {
	if !line_valid(gsi) {
		return
	}
	id := VECTOR_IRQ_BASE + gsi
	bit := u32(1) << u32(id % 32)
	if masked {
		dist_write(GICD_ICENABLER + uintptr(id / 32 * 4), bit)
	} else {
		dist_write(GICD_ISENABLER + uintptr(id / 32 * 4), bit)
	}
}

gicv2_masked :: proc "contextless" (gsi: int) -> bool {
	if !line_valid(gsi) {
		return true
	}
	id := VECTOR_IRQ_BASE + gsi
	return dist_read(GICD_ISENABLER + uintptr(id / 32 * 4)) & (u32(1) << u32(id % 32)) == 0
}

// gicv2_vector_of is the vector a line arrives on, which is its id.
gicv2_vector_of :: proc "contextless" (gsi: int) -> u8 {
	if !line_valid(gsi) {
		return 0
	}
	return u8(VECTOR_IRQ_BASE + gsi)
}

// -- Software-generated interrupts ---------------------------------------------

// gicv2_send delivers software interrupt `vector` to core `cpu`.
gicv2_send :: proc "contextless" (cpu: u32, vector: u8) {
	if dist == nil {
		return
	}
	dsb_ish()
	dist_write(GICD_SGIR, u32(1) << (16 + (cpu & 7)) | u32(vector & 0xF))
}

// gicv2_stop_others sends the stop to every core but this one.
gicv2_stop_others :: proc "contextless" () {
	if dist == nil {
		return
	}
	dsb_ish()
	dist_write(GICD_SGIR, SGIR_ALL_BUT_SELF | VECTOR_NMI)
}
