/*
The legacy 8259 interrupt controllers -- remapped and then silenced.

Vectra will drive interrupts through the local APIC and the I/O APIC, not
through these. They are here because the pair exists on every PC, powers up
mapped over vectors 8 to 15, and cannot be assumed to have been left masked by
whatever ran before us.

Vectors 8 to 15 are the double fault, the invalid TSS, the segment faults, the
general protection fault and the page fault. So a stray IRQ from an unmasked PIC
does not arrive as a stray IRQ -- it arrives as a *page fault*, with a garbage
error code and a CR2 left over from something else, and the panic screen says
so with total confidence. That is the bug this file exists to prevent, and it is
worth twenty lines to prevent it before the first `sti` rather than after.

The controllers are remapped before being masked rather than only masked,
because masking is not absolute: a spurious IRQ 7 can still get through, and it
is far better for it to land on vector 39 and be reported as an unexpected
external interrupt.
*/
package amd64

PIC1_COMMAND :: u16(0x20)
PIC1_DATA :: u16(0x21)
PIC2_COMMAND :: u16(0xA0)
PIC2_DATA :: u16(0xA1)

// Where the two controllers are remapped to: the first sixteen vectors above
// the architectural exceptions.
PIC1_VECTOR_BASE :: u8(32)
PIC2_VECTOR_BASE :: u8(40)

ICW1_INIT :: u8(0x11) // Begin initialisation, and expect an ICW4
ICW4_8086 :: u8(0x01) // 8086/88 mode rather than MCS-80/85

/*
pic_disable remaps both controllers clear of the exception vectors and masks
every line.

The `io_wait` between writes is not superstition: the 8259 needs time to settle
between initialisation words, and on hardware fast enough to matter the writes
otherwise run together and the controller ends up in a state that is neither the
old one nor the new one.
*/
pic_disable :: proc "contextless" () {
	// ICW1: start the initialisation sequence on both controllers.
	outb(PIC1_COMMAND, ICW1_INIT)
	io_wait()
	outb(PIC2_COMMAND, ICW1_INIT)
	io_wait()

	// ICW2: the vector each controller's IRQ 0 maps to.
	outb(PIC1_DATA, PIC1_VECTOR_BASE)
	io_wait()
	outb(PIC2_DATA, PIC2_VECTOR_BASE)
	io_wait()

	// ICW3: how they are wired to each other. The slave hangs off the master's
	// IRQ 2 -- a bitmask on the master, a plain identity on the slave.
	outb(PIC1_DATA, 1 << 2)
	io_wait()
	outb(PIC2_DATA, 2)
	io_wait()

	// ICW4: 8086 mode.
	outb(PIC1_DATA, ICW4_8086)
	io_wait()
	outb(PIC2_DATA, ICW4_8086)
	io_wait()

	// OCW1: mask everything. The APIC will take over from here.
	outb(PIC1_DATA, 0xFF)
	outb(PIC2_DATA, 0xFF)
}
