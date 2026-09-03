/*
The serial console: four ways to reach one, behind one `Port`.

This is the first thing Vectra starts, and the last thing that still works when
the framebuffer console is wedged. It therefore depends on no memory
management, no interrupts, and no scheduler. Transmit is polled.

Which chip, and how it is reached, is the architecture's to say --
`arch.serial_console` answers with a `Serial_Desc`, and this file drives what
it names:

    Port_16550   a 16550 behind x86 port I/O, which is every PC's COM1
    Mmio_16550   the same chip with its registers in memory, one byte apart,
                 which is what QEMU's riscv64 `virt` board has at 0x10000000
    Pl011        ARM's PrimeCell UART, a different register file altogether,
                 which is what the aarch64 `virt` board has at 0x09000000
    Firmware     no chip at all: the firmware's own console, reached by a
                 call the architecture supplies. riscv64's SBI is one, and
                 it is the only console that needs no mapping to reach

The 16550 and the PL011 share nothing but the job, so each has its own
register table below and its own arm of every switch. What they share is
`Port`, which is all the logger and `/dev/eia0` ever hold.
*/
package uart

import "base:intrinsics"

import "kernel:arch"
import "vsys:libodin"

// -- The 16550 ---------------------------------------------------------------

// Register offsets from the port base. DLAB in the line-control register
// re-aims offsets 0 and 1 at the divisor latch, hence the doubled names.
REG_DATA         :: uintptr(0) // RX/TX buffer  (DLAB=0)
REG_INT_ENABLE   :: uintptr(1) // Interrupt enable (DLAB=0)
REG_DIVISOR_LO   :: uintptr(0) // Divisor latch low (DLAB=1)
REG_DIVISOR_HI   :: uintptr(1) // Divisor latch high (DLAB=1)
REG_FIFO_CTRL    :: uintptr(2)
REG_LINE_CTRL    :: uintptr(3)
REG_MODEM_CTRL   :: uintptr(4)
REG_LINE_STATUS  :: uintptr(5)

LCR_8N1  :: u8(0x03) // 8 data bits, no parity, one stop bit
LCR_DLAB :: u8(0x80)

FCR_ENABLE     :: u8(0x01)
FCR_CLEAR_RX   :: u8(0x02)
FCR_CLEAR_TX   :: u8(0x04)
FCR_TRIGGER_14 :: u8(0xC0)

MCR_DTR      :: u8(0x01)
MCR_RTS      :: u8(0x02)
MCR_OUT2     :: u8(0x08) // Gates the UART's IRQ line on PC hardware
MCR_LOOPBACK :: u8(0x10)

LSR_DATA_READY   :: u8(0x01)
LSR_TX_HOLD_FREE :: u8(0x20)

// The 16550 divides a fixed 115200 Hz clock. Divisor 1 is therefore 115200
// baud.
BASE_CLOCK :: 115200

// -- The PL011 ---------------------------------------------------------------

PL011_DR    :: uintptr(0x00) // Data
PL011_FR    :: uintptr(0x18) // Flags
PL011_IBRD  :: uintptr(0x24) // Integer baud rate divisor
PL011_FBRD  :: uintptr(0x28) // Fractional baud rate divisor
PL011_LCR_H :: uintptr(0x2C) // Line control
PL011_CR    :: uintptr(0x30) // Control
PL011_IMSC  :: uintptr(0x38) // Interrupt mask
PL011_ICR   :: uintptr(0x44) // Interrupt clear
PL011_PID0  :: uintptr(0xFE0) // Peripheral id, byte 0: 0x11 on a PL011

PL011_FR_RXFE :: u32(1) << 4 // Receive FIFO empty
PL011_FR_TXFF :: u32(1) << 5 // Transmit FIFO full

PL011_LCR_FEN  :: u32(1) << 4 // FIFOs on
PL011_LCR_WLEN8 :: u32(3) << 5

PL011_CR_UARTEN :: u32(1) << 0
PL011_CR_TXE    :: u32(1) << 8
PL011_CR_RXE    :: u32(1) << 9

// The reference clock QEMU's PL011 divides. Real boards differ, and a board
// that does is a board whose firmware already set the divisor.
PL011_CLOCK :: 24_000_000

Port :: struct {
	kind:    arch.Serial_Kind,
	base:    uintptr, // A port number or a virtual address, by `kind`
	present: bool,
}

// -- Register access ---------------------------------------------------------
//
// The 16550 is bytes, wherever it is. The PL011 is 32-bit words. Both go
// through volatile accesses when they are memory, because a status register
// read in a loop is exactly what the compiler would otherwise hoist.

@(private = "file")
reg_read :: proc "contextless" (p: ^Port, reg: uintptr) -> u8 {
	#partial switch p.kind {
	case .Port_16550: return arch.inb(u16(p.base + reg))
	case .Mmio_16550: return intrinsics.volatile_load(cast(^u8)(p.base + reg))
	}
	return 0xFF
}

@(private = "file")
reg_write :: proc "contextless" (p: ^Port, reg: uintptr, value: u8) {
	#partial switch p.kind {
	case .Port_16550: arch.outb(u16(p.base + reg), value)
	case .Mmio_16550: intrinsics.volatile_store(cast(^u8)(p.base + reg), value)
	}
}

@(private = "file")
pl011_read :: proc "contextless" (p: ^Port, reg: uintptr) -> u32 {
	return arch.mmio_read32(rawptr(p.base), reg)
}

@(private = "file")
pl011_write :: proc "contextless" (p: ^Port, reg: uintptr, value: u32) {
	arch.mmio_write32(rawptr(p.base), reg, value)
}

/*
init brings up the console the architecture named, and probes it.

The probe matters under QEMU as much as on real hardware. If nothing wired the
port up, `present` stays false, and every later write becomes a no-op.
Without it, a write spins forever on a transmit-holding bit that will never
set.

A 16550 is probed through its own loopback mode: a byte sent to itself has
to come back. A PL011 is probed through its peripheral id register, which is
a constant the chip carries and an unmapped bus does not. The firmware
console is present whenever the architecture says it has one.
*/
init :: proc "contextless" (desc: arch.Serial_Desc, baud: u32 = 115200) -> Port {
	port := Port{kind = desc.kind, base = desc.base}
	switch desc.kind {
	case .None:
		return port
	case .Port_16550, .Mmio_16550:
		init_16550(&port, baud)
	case .Pl011:
		init_pl011(&port, baud)
	case .Firmware:
		port.present = arch.console_available()
	}
	return port
}

@(private = "file")
init_16550 :: proc "contextless" (port: ^Port, baud: u32) {
	divisor := u16(BASE_CLOCK / baud)
	if divisor == 0 {
		divisor = 1
	}

	reg_write(port, REG_INT_ENABLE, 0x00) // Mask all UART interrupts

	reg_write(port, REG_LINE_CTRL, LCR_DLAB)
	reg_write(port, REG_DIVISOR_LO, u8(divisor))
	reg_write(port, REG_DIVISOR_HI, u8(divisor >> 8))
	reg_write(port, REG_LINE_CTRL, LCR_8N1)

	reg_write(port, REG_FIFO_CTRL, FCR_ENABLE | FCR_CLEAR_RX | FCR_CLEAR_TX | FCR_TRIGGER_14)

	// Loop the transmitter back to the receiver and check a byte survives.
	reg_write(port, REG_MODEM_CTRL, MCR_DTR | MCR_RTS | MCR_LOOPBACK)
	reg_write(port, REG_DATA, 0xAE)
	if reg_read(port, REG_DATA) != 0xAE {
		return
	}

	reg_write(port, REG_MODEM_CTRL, MCR_DTR | MCR_RTS | MCR_OUT2)
	port.present = true
}

/*
init_pl011 programs the PrimeCell for 8N1 at `baud`.

The control register is cleared first, because the divisor and the line
control take effect only while the UART is off, and the interrupts are all
cleared and masked, because nothing here handles one yet. The divisor is
written for the clock QEMU's board has. A real board's firmware has already
set one that suits its own, and this overwrites it. That is the same trade
the 16550 makes with its 115200 Hz assumption.
*/
@(private = "file")
init_pl011 :: proc "contextless" (port: ^Port, baud: u32) {
	if pl011_read(port, PL011_PID0) & 0xFF != 0x11 {
		return
	}
	pl011_write(port, PL011_CR, 0)
	pl011_write(port, PL011_ICR, 0x7FF)
	pl011_write(port, PL011_IMSC, 0)

	// 16 * baud divides the clock. The integer part, then the fraction in
	// sixty-fourths, as the chip wants them.
	div := u32(PL011_CLOCK) * 4 / baud
	pl011_write(port, PL011_IBRD, div >> 6)
	pl011_write(port, PL011_FBRD, div & 0x3F)
	pl011_write(port, PL011_LCR_H, PL011_LCR_WLEN8 | PL011_LCR_FEN)
	pl011_write(port, PL011_CR, PL011_CR_UARTEN | PL011_CR_TXE | PL011_CR_RXE)
	port.present = true
}

tx_ready :: proc "contextless" (port: ^Port) -> bool {
	switch port.kind {
	case .None:                   return false
	case .Port_16550, .Mmio_16550: return reg_read(port, REG_LINE_STATUS) & LSR_TX_HOLD_FREE != 0
	case .Pl011:                  return pl011_read(port, PL011_FR) & PL011_FR_TXFF == 0
	case .Firmware:               return true
	}
	return false
}

rx_ready :: proc "contextless" (port: ^Port) -> bool {
	switch port.kind {
	case .None:                   return false
	case .Port_16550, .Mmio_16550: return reg_read(port, REG_LINE_STATUS) & LSR_DATA_READY != 0
	case .Pl011:                  return pl011_read(port, PL011_FR) & PL011_FR_RXFE == 0
	case .Firmware:               return true // The firmware answers "nothing" itself
	}
	return false
}

write_byte :: proc "contextless" (port: ^Port, b: u8) {
	if !port.present {
		return
	}
	for !tx_ready(port) {
		arch.spin_hint()
	}
	switch port.kind {
	case .None:
	case .Port_16550, .Mmio_16550: reg_write(port, REG_DATA, b)
	case .Pl011:                  pl011_write(port, PL011_DR, u32(b))
	case .Firmware:               arch.console_write_byte(b)
	}
}

/*
write_string sends `text`, expanding LF to CRLF.

A terminal emulator at the far end of a serial cable does not do that
expansion. A log that stair-steps down the screen is a log nobody reads.
*/
write_string :: proc "contextless" (port: ^Port, text: string) {
	if port.kind == .Firmware {
		// The firmware takes a run at a time, so a line goes as its runs
		// between newlines and a CRLF for each, rather than a call per byte.
		if !port.present {
			return
		}
		start := 0
		for i in 0 ..< len(text) {
			if text[i] == '\n' {
				arch.console_write(transmute([]u8)text[start:i])
				arch.console_write(transmute([]u8)string("\r\n"))
				start = i + 1
			}
		}
		arch.console_write(transmute([]u8)text[start:])
		return
	}
	for i in 0 ..< len(text) {
		if text[i] == '\n' {
			write_byte(port, '\r')
		}
		write_byte(port, text[i])
	}
}

// write_sink flushes a libodin.Sink and marks truncated output inline.
write_sink :: proc "contextless" (port: ^Port, s: ^libodin.Sink) {
	write_string(port, libodin.str(s))
	if s.overflowed {
		write_string(port, "<truncated>")
	}
}

read_byte :: proc "contextless" (port: ^Port) -> (b: u8, ok: bool) {
	if !port.present || !rx_ready(port) {
		return 0, false
	}
	switch port.kind {
	case .None:                   return 0, false
	case .Port_16550, .Mmio_16550: return reg_read(port, REG_DATA), true
	case .Pl011:                  return u8(pl011_read(port, PL011_DR)), true
	case .Firmware:               return arch.console_read_byte()
	}
	return 0, false
}

// needs_mapping says whether a port's registers are in memory the kernel's
// own tables have yet to map, and where they are: a console that came up
// through an early window is at its physical address until the VMM exists.
needs_mapping :: proc "contextless" (port: ^Port) -> (phys: uintptr, needs: bool) {
	#partial switch port.kind {
	case .Mmio_16550, .Pl011:
		return port.base, port.present
	}
	return 0, false
}

// rebase moves such a port to the address the kernel mapped its registers at.
rebase :: proc "contextless" (port: ^Port, base: uintptr) {
	port.base = base
}
