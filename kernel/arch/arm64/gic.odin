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

import "kernel:arch/neutral"

GICV2_PHYS :: uintptr(0x0800_0000)
GICV2_MMIO_SIZE :: u64(0x2_0000)

@(private = "file") GICC_OFFSET :: uintptr(0x1_0000)

// The distributor's registers are `gicd.odin`'s. The CPU interface.
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

@(private = "file") cpu_if: rawptr

@(private = "file")
cpu_read :: proc "contextless" (offset: uintptr) -> u32 {
	return neutral.mmio_read32(cpu_if, offset)
}

@(private = "file")
cpu_write :: proc "contextless" (offset: uintptr, value: u32) {
	neutral.mmio_write32(cpu_if, offset, value)
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
	gicd = virt
	cpu_if = rawptr(uintptr(virt) + GICC_OFFSET)

	typer := gicd_read(GICD_TYPER)
	if typer == 0xFFFF_FFFF {
		gicd = nil
		cpu_if = nil
		return
	}
	lines = gicd_lines_from_typer(typer)

	gicd_write(GICD_CTLR, 0)
	for id := 32; id < lines; id += 32 {
		gicd_write(GICD_ICENABLER + uintptr(id / 8), 0xFFFF_FFFF)
		gicd_write(GICD_ICPENDR + uintptr(id / 8), 0xFFFF_FFFF)
	}
	for id in 0 ..< lines {
		gicd_write_byte(GICD_IPRIORITYR + uintptr(id), PRIORITY_DEFAULT)
		if id >= 32 {
			gicd_write_byte(GICD_ITARGETSR + uintptr(id), 1)
		}
	}
	gicd_write(GICD_CTLR, 1)

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
	gicd_write(GICD_ICENABLER, 0xFFFF_FFFF)
	gicd_write(GICD_ISENABLER, 0x0000_FFFF | u32(1) << VECTOR_TIMER)
	cpu_write(GICC_CTLR, 1)
}

gicv2_attached :: proc "contextless" () -> bool {
	return gicd != nil
}

gicv2_available :: proc "contextless" () -> bool {
	return gicd != nil
}

gicv2_lines :: gicd_lines

gicv2_version :: proc "contextless" () -> u32 {
	return gicd == nil ? 0 : gicd_read(GICD_IIDR) >> 16 & 0xF
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
	if gicd == nil {
		return 0
	}
	mask := gicd_read(GICD_ITARGETSR) & 0xFF
	for i in u32(0) ..< 8 {
		if mask & (1 << i) != 0 {
			return i
		}
	}
	return 0
}

// -- Shared peripheral lines --------------------------------------------------

// gicv2_route aims one shared line at one core and leaves it masked, so a
// driver can register its handler before the first interrupt arrives.
gicv2_route :: proc "contextless" (gsi: int, vector: u8, cpu: u32) {
	_ = vector
	if !line_valid(gsi) {
		return
	}
	id := VECTOR_IRQ_BASE + gsi
	gicd_write_byte(GICD_ITARGETSR + uintptr(id), u8(1 << (cpu & 7)))

	// Level-sensitive: a shared line stays asserted until its device is
	// serviced, which is the handshake `docs/HARDWARE.md` section 3's `irq`
	// stream keeps -- mask on fire, the driver clears the source, unmask on the
	// next read. `GICD_ICFGR` holds two bits a line, sixteen lines a word; the
	// high bit is edge. Clearing it makes this SPI level, and touches no other
	// line. Reset default is level on this part, so this is the explicit say.
	gicd_set_trigger(id, false)
}

// The mask, the trigger and the vector of a shared line are the
// distributor's, in `gicd.odin`.
gicv2_set_edge :: gicd_set_edge
gicv2_set_mask :: gicd_set_mask
gicv2_masked :: gicd_masked
gicv2_vector_of :: gicd_vector_of

// -- Software-generated interrupts ---------------------------------------------

// gicv2_send delivers software interrupt `vector` to core `cpu`.
gicv2_send :: proc "contextless" (cpu: u32, vector: u8) {
	if gicd == nil {
		return
	}
	dsb_ish()
	gicd_write(GICD_SGIR, u32(1) << (16 + (cpu & 7)) | u32(vector & 0xF))
}

// gicv2_stop_others sends the stop to every core but this one.
gicv2_stop_others :: proc "contextless" () {
	if gicd == nil {
		return
	}
	dsb_ish()
	gicd_write(GICD_SGIR, SGIR_ALL_BUT_SELF | VECTOR_NMI)
}
