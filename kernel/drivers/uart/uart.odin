/*
16550-compatible UART driver.

This is the first thing Vectra brings up and the last thing that still works
when the framebuffer console is wedged, so it stays free of dependencies on
memory management, interrupts, and the scheduler. Transmit is polled.
*/
package uart

import "kernel:arch/amd64"
import "vsys:libodin"

COM1 :: u16(0x3F8)
COM2 :: u16(0x2F8)

// Register offsets from the port base. DLAB in the line-control register
// re-aims offsets 0 and 1 at the divisor latch, hence the doubled names.
REG_DATA         :: u16(0) // RX/TX buffer  (DLAB=0)
REG_INT_ENABLE   :: u16(1) // Interrupt enable (DLAB=0)
REG_DIVISOR_LO   :: u16(0) // Divisor latch low (DLAB=1)
REG_DIVISOR_HI   :: u16(1) // Divisor latch high (DLAB=1)
REG_FIFO_CTRL    :: u16(2)
REG_LINE_CTRL    :: u16(3)
REG_MODEM_CTRL   :: u16(4)
REG_LINE_STATUS  :: u16(5)

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

// The 16550 divides a fixed 115200 Hz clock; divisor 1 is therefore 115200 baud.
BASE_CLOCK :: 115200

Port :: struct {
	base:    u16,
	present: bool,
}

/*
init configures `base` for 8N1 at `baud` and probes the chip via its own
loopback mode.

The probe matters under QEMU as much as on real hardware: if the port is not
wired up, `present` stays false and every later write becomes a no-op instead
of spinning forever waiting on a transmit-holding bit that will never set.
*/
init :: proc "contextless" (base: u16, baud: u32 = 115200) -> Port {
	port := Port{base = base}
	divisor := u16(BASE_CLOCK / baud)
	if divisor == 0 {
		divisor = 1
	}

	amd64.outb(base + REG_INT_ENABLE, 0x00) // Mask all UART interrupts

	amd64.outb(base + REG_LINE_CTRL, LCR_DLAB)
	amd64.outb(base + REG_DIVISOR_LO, u8(divisor))
	amd64.outb(base + REG_DIVISOR_HI, u8(divisor >> 8))
	amd64.outb(base + REG_LINE_CTRL, LCR_8N1)

	amd64.outb(base + REG_FIFO_CTRL, FCR_ENABLE | FCR_CLEAR_RX | FCR_CLEAR_TX | FCR_TRIGGER_14)

	// Loop the transmitter back to the receiver and check a byte survives.
	amd64.outb(base + REG_MODEM_CTRL, MCR_DTR | MCR_RTS | MCR_LOOPBACK)
	amd64.outb(base + REG_DATA, 0xAE)
	if amd64.inb(base + REG_DATA) != 0xAE {
		return port
	}

	amd64.outb(base + REG_MODEM_CTRL, MCR_DTR | MCR_RTS | MCR_OUT2)
	port.present = true
	return port
}

tx_ready :: proc "contextless" (port: ^Port) -> bool {
	return amd64.inb(port.base + REG_LINE_STATUS) & LSR_TX_HOLD_FREE != 0
}

rx_ready :: proc "contextless" (port: ^Port) -> bool {
	return amd64.inb(port.base + REG_LINE_STATUS) & LSR_DATA_READY != 0
}

write_byte :: proc "contextless" (port: ^Port, b: u8) {
	if !port.present {
		return
	}
	for !tx_ready(port) {
		amd64.pause()
	}
	amd64.outb(port.base + REG_DATA, b)
}

/*
write_string sends `text`, expanding LF to CRLF.

Terminal emulators on the far end of a serial cable do not do that expansion
for us, and a log that stair-steps down the screen is a log nobody reads.
*/
write_string :: proc "contextless" (port: ^Port, text: string) {
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
	return amd64.inb(port.base + REG_DATA), true
}
