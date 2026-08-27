/*
The I/O APIC -- how a device interrupt reaches a core.

`pic.odin` remaps the 8259s and masks every line, and says why: Vectra drives
interrupts through the local APIC and this. That was a statement of intent for
five milestones. The keyboard is the first device that needed it to be true.

## Why not the 8259, given it is already there

Two reasons, and the second is the one that settles it.

The legacy path needs *virtual wire mode*. The LAPIC's LINT0 pin programmed as
ExtINT, the 8259 delivering through it, and an INTA cycle to fetch the vector.
`lapic_attach` masks LINT0 deliberately, because firmware sometimes leaves LINT1
set to deliver an NMI. Undoing that to keep a controller the tree has already
disowned would be work aimed backwards.

The second reason is that the 8259's vector base collides with the timer's.
`PIC1_VECTOR_BASE` is 32 and `VECTOR_TIMER` is 0x20, which is the same number.
The collision is harmless while every line is masked, and it stops being
harmless the moment one is not.

## The register window

Two registers in a page, and everything goes through them. `IOREGSEL` takes the
index, `IOWIN` reads or writes the value there. A redirection entry is 64 bits
and therefore two indices, low half first.

**Nothing here locks.** Routing happens once per device during boot, before the
line it routes is unmasked, and a masked line delivers nothing. When a second
core can route an interrupt, this needs a lock word of its own. It is the same
conversation as every other one in `docs/HANDOFF.md` section 6.

## What is assumed rather than discovered

The base address, and the mapping from an ISA IRQ to a global system interrupt.
Both come from ACPI's MADT on a machine that has one, and Vectra parses no ACPI
tables yet.

    IOAPIC_PHYS      0xFEC00000, which is where every PC-compatible puts the
                     first one, QEMU included
    ISA IRQ -> GSI identity, which holds for IRQ 1 on every machine anyone
    names

Neither assumption is safe in general and both are safe here. The one that
genuinely bites is IRQ 0. Firmware very often overrides it to GSI 2, and a MADT
is the only way to learn that. Vectra does not route IRQ 0 -- the LAPIC timer
is its clock -- so the case that would break is the case that does not arise.

A MADT parse retires both assumptions, and it pays for itself twice: the same
table lists the cores that SMP will need to start. That is why it is worth
waiting for a reason rather than doing it here.
*/
package amd64

import "base:intrinsics"

// Where the first I/O APIC lives on a PC. See the file comment for what makes
// this an assumption rather than a fact.
IOAPIC_PHYS :: uintptr(0xFEC0_0000)

// One page, which is more than the two registers need and the least the mapping
// can be.
IOAPIC_MMIO_SIZE :: u64(0x1000)

@(private = "file")
IOREGSEL :: uintptr(0x00)
@(private = "file")
IOWIN :: uintptr(0x10)

@(private = "file")
IOAPIC_ID :: u32(0x00)
@(private = "file")
IOAPIC_VER :: u32(0x01)
@(private = "file")
IOAPIC_REDIR :: u32(0x10) // Entry n is at 0x10 + n*2, low half first

/*
The bits of a redirection entry this kernel sets.

Everything not named here is left zero, and zero is the wanted value for all of
it: fixed delivery, physical destination, active high, edge triggered. Those are
the ISA defaults, and a level-triggered PCI line will need `LEVEL` and possibly
`ACTIVE_LOW` when there is one.
*/
@(private = "file")
REDIR_MASKED :: u32(1) << 16
@(private = "file")
REDIR_LEVEL :: u32(1) << 15
@(private = "file")
REDIR_ACTIVE_LOW :: u32(1) << 13

@(private = "file")
mmio: rawptr

/*
ioapic_attach takes the mapped register page.

Every line is masked on the way in. Firmware leaves entries behind. An
inherited route aimed at a vector this kernel never claimed arrives as an
unexpected interrupt, with nothing to service it.
*/
ioapic_attach :: proc "contextless" (virt: rawptr) {
	mmio = virt
	for gsi in 0 ..< ioapic_lines() {
		ioapic_set_mask(gsi, true)
	}
}

ioapic_attached :: proc "contextless" () -> bool {
	return mmio != nil
}

// ioapic_physical_base is where the caller must map from. A separate call from
// `ioapic_attach` because mapping is the portable kernel's job and this is the
// only architecture that knows the address.
ioapic_physical_base :: proc "contextless" () -> uintptr {
	return IOAPIC_PHYS
}

/*
ioapic_available reports whether there is one to talk to.

Read after the mapping rather than before it, because there is no way to ask
without the register window. A version register of all-ones is a read that went
nowhere, which is what an unmapped or absent controller answers.
*/
ioapic_available :: proc "contextless" () -> bool {
	if mmio == nil {
		return false
	}
	v := ioapic_read(IOAPIC_VER)
	return v != 0xFFFF_FFFF && v != 0
}

// ioapic_lines is how many redirection entries this controller has. The version
// register carries one less than the count, in its second byte.
ioapic_lines :: proc "contextless" () -> int {
	if mmio == nil {
		return 0
	}
	v := ioapic_read(IOAPIC_VER)
	if v == 0xFFFF_FFFF {
		return 0
	}
	return int((v >> 16) & 0xFF) + 1
}

ioapic_version :: proc "contextless" () -> u32 {
	return mmio == nil ? 0 : ioapic_read(IOAPIC_VER) & 0xFF
}

/*
ioapic_route aims one global system interrupt at a vector on one core, and
leaves it masked.

Masked deliberately. Routing and unmasking are two calls so that a driver can
claim its line, register its handler, and only then let the first interrupt
arrive. The other order has a window where a device that is already asserting
lands on a vector whose handler is not there yet.

Writes the high half first, which is the half carrying the destination. A
low-half write is what makes an entry live. One that became live between the
two writes would go to whatever core the previous half named.
*/
ioapic_route :: proc "contextless" (gsi: int, vector: u8, lapic: u32) {
	if mmio == nil || gsi < 0 || gsi >= ioapic_lines() {
		return
	}
	index := IOAPIC_REDIR + u32(gsi) * 2
	ioapic_write(index + 1, lapic << 24)
	ioapic_write(index, REDIR_MASKED | u32(vector))
}

// ioapic_set_mask stops or starts delivery on one line. A masked line is not a
// lost interrupt: an edge asserted while masked is remembered and delivered
// when the mask lifts.
ioapic_set_mask :: proc "contextless" (gsi: int, masked: bool) {
	if mmio == nil || gsi < 0 || gsi >= ioapic_lines() {
		return
	}
	index := IOAPIC_REDIR + u32(gsi) * 2
	low := ioapic_read(index)
	if masked {
		low |= REDIR_MASKED
	} else {
		low &~= REDIR_MASKED
	}
	ioapic_write(index, low)
}

// ioapic_masked reports whether a line is stopped. For a self-test, which
// cannot see an interrupt that did not happen and can see the bit that would
// have stopped it.
ioapic_masked :: proc "contextless" (gsi: int) -> bool {
	if mmio == nil || gsi < 0 || gsi >= ioapic_lines() {
		return true
	}
	return ioapic_read(IOAPIC_REDIR + u32(gsi) * 2) & REDIR_MASKED != 0
}

// ioapic_vector_of is the vector a line is aimed at. Also for the self-test:
// a route that did not take reads back as something other than what was
// written, and nothing else would notice.
ioapic_vector_of :: proc "contextless" (gsi: int) -> u8 {
	if mmio == nil || gsi < 0 || gsi >= ioapic_lines() {
		return 0
	}
	return u8(ioapic_read(IOAPIC_REDIR + u32(gsi) * 2) & 0xFF)
}

/*
The two accesses, and the ordering rule that makes them work.

`IOREGSEL` and `IOWIN` are one conversation in two writes, so the compiler may
not reorder them or drop either. Volatile is what says so. It is the same reason
`kernel/sync` marks its counters volatile, in a place where being wrong is
quieter.
*/
@(private = "file")
ioapic_read :: proc "contextless" (index: u32) -> u32 {
	sel := cast(^u32)(uintptr(mmio) + IOREGSEL)
	win := cast(^u32)(uintptr(mmio) + IOWIN)
	intrinsics.volatile_store(sel, index)
	return intrinsics.volatile_load(win)
}

@(private = "file")
ioapic_write :: proc "contextless" (index: u32, value: u32) {
	sel := cast(^u32)(uintptr(mmio) + IOREGSEL)
	win := cast(^u32)(uintptr(mmio) + IOWIN)
	intrinsics.volatile_store(sel, index)
	intrinsics.volatile_store(win, value)
}
