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
device tree does, and `set_device_tree` keeps it for the day this reads it.
*/
package arm64

import "base:intrinsics"

GIC_PHYS :: uintptr(0x0800_0000)
GIC_MMIO_SIZE :: u64(0x2_0000)
GICC_OFFSET :: uintptr(0x1_0000)

// The distributor.
GICD_CTLR :: uintptr(0x000)
GICD_TYPER :: uintptr(0x004)
GICD_IIDR :: uintptr(0x008)
GICD_ISENABLER :: uintptr(0x100) // One bit per interrupt, 32 per word
GICD_ICENABLER :: uintptr(0x180)
GICD_ICPENDR :: uintptr(0x280)
GICD_IPRIORITYR :: uintptr(0x400) // One byte per interrupt
GICD_ITARGETSR :: uintptr(0x800) // One byte per interrupt, a bit per core
GICD_ICFGR :: uintptr(0xC00)
GICD_SGIR :: uintptr(0xF00)

// The CPU interface.
GICC_CTLR :: uintptr(0x000)
GICC_PMR :: uintptr(0x004)
GICC_BPR :: uintptr(0x008)
GICC_IAR :: uintptr(0x00C)
GICC_EOIR :: uintptr(0x010)

// One priority for everything. Lower is more urgent, and the mask lets
// anything below 0xF0 through.
PRIORITY_DEFAULT :: u8(0xA0)
PRIORITY_MASK :: u32(0xF0)

SGIR_ALL_BUT_SELF :: u32(1) << 24

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

gic_physical_base :: proc "contextless" () -> uintptr {
	return GIC_PHYS
}

/*
gic_attach takes the mapped register pages and brings the distributor up.

Every shared line is disabled, given the one priority and aimed at core 0.
Firmware leaves routes behind, and an inherited route aimed at a core that
has not enabled its interface is an interrupt nobody takes. Then this core's
own interface, which every other core does for itself in `gic_attach_here`.
*/
gic_attach :: proc "contextless" (virt: rawptr) {
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

	gic_attach_here()
}

// gic_attach_here brings up the calling core's CPU interface and lets its
// private interrupts through: the timer, and every software-generated one.
gic_attach_here :: proc "contextless" () {
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

gic_attached :: proc "contextless" () -> bool {
	return dist != nil
}

gic_available :: proc "contextless" () -> bool {
	return dist != nil
}

// gic_lines is how many shared peripheral lines the distributor has.
gic_lines :: proc "contextless" () -> int {
	if dist == nil || lines < 32 {
		return 0
	}
	return lines - 32
}

gic_version :: proc "contextless" () -> u32 {
	return dist == nil ? 0 : dist_read(GICD_IIDR) >> 16 & 0xF
}

/*
gic_acknowledge takes the pending interrupt's id from the CPU interface and
keeps the whole word for the end-of-interrupt. The read is the acknowledge:
the interrupt is active from here until `gic_eoi` retires it, and nothing at
its priority or below arrives in between.
*/
gic_acknowledge :: proc "contextless" () -> u32 {
	if cpu_if == nil {
		return 1023
	}
	iar := cpu_read(GICC_IAR)
	this_cpu().irq = iar
	return iar
}

gic_eoi :: proc "contextless" (iar: u32) {
	if cpu_if != nil && iar & 0x3FF < 1020 {
		cpu_write(GICC_EOIR, iar)
	}
}

// gic_ack retires the interrupt this core is servicing, which is the one it
// acknowledged last. Must happen once per acknowledge, and the timer's is
// also where the next tick is armed.
gic_ack :: proc "contextless" () {
	iar := this_cpu().irq
	if iar & 0x3FF == VECTOR_TIMER {
		timer_rearm()
	}
	gic_eoi(iar)
	this_cpu().irq = 1023
}

// gic_cpu_number is this core's bit in a target mask, read out of the
// register that reports it: the targets of a private interrupt are the
// reading core alone.
gic_cpu_number :: proc "contextless" () -> u32 {
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
	return dist != nil && gsi >= 0 && gsi < gic_lines()
}

// gic_route aims one shared line at one core and leaves it masked, so a
// driver can register its handler before the first interrupt arrives.
gic_route :: proc "contextless" (gsi: int, vector: u8, cpu: u32) {
	_ = vector
	if !line_valid(gsi) {
		return
	}
	id := uintptr(VECTOR_IRQ_BASE + gsi)
	dist_write_byte(GICD_ITARGETSR + id, u8(1 << (cpu & 7)))
}

gic_set_mask :: proc "contextless" (gsi: int, masked: bool) {
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

gic_masked :: proc "contextless" (gsi: int) -> bool {
	if !line_valid(gsi) {
		return true
	}
	id := VECTOR_IRQ_BASE + gsi
	return dist_read(GICD_ISENABLER + uintptr(id / 32 * 4)) & (u32(1) << u32(id % 32)) == 0
}

// gic_vector_of is the vector a line arrives on, which is its id.
gic_vector_of :: proc "contextless" (gsi: int) -> u8 {
	if !line_valid(gsi) {
		return 0
	}
	return u8(VECTOR_IRQ_BASE + gsi)
}

// -- Software-generated interrupts ---------------------------------------------

// gic_send delivers software interrupt `vector` to core `cpu`.
gic_send :: proc "contextless" (cpu: u32, vector: u8) {
	if dist == nil {
		return
	}
	dsb_ish()
	dist_write(GICD_SGIR, u32(1) << (16 + (cpu & 7)) | u32(vector & 0xF))
}

// gic_stop_others sends the stop to every core but this one.
gic_stop_others :: proc "contextless" () {
	if dist == nil {
		return
	}
	dsb_ish()
	dist_write(GICD_SGIR, SGIR_ALL_BUT_SELF | VECTOR_NMI)
}
