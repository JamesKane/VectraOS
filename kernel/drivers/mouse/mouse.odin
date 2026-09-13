/*
The PS/2 mouse: the 8042's second port, and the first pointing device.

`docs/WORKBENCH.md` step 1. The keyboard driver beside this one is the
shape, and `docs/KBD.md` argues it. A top half that may not park takes
the byte off the port at the interrupt and puts it in a ring. A bottom
half that is an ordinary thread takes it out and makes sense of it. What
differs is what the bytes mean. A keyboard sends a scancode and a mouse
sends a packet of three, and a packet is a movement rather than a key.

## The packet

    byte 0    Y overflow, X overflow, Y sign, X sign, 1, middle, right, left
    byte 1    the X movement, low eight bits, the sign above it
    byte 2    the Y movement, the same, and up is positive

The bit that is always one is what a stream is resynchronised on. A byte
that arrives as the first of a packet without it is not the first of a
packet, and is dropped and counted.

The driver adds the movement to a
position it keeps, clamped to the screen it was told the size of. Y is
turned over, because the screen's rows go down. What leaves the driver is
the position, the buttons and the tick. The buttons are as `rio` numbers
them: 1 for the left, 2 for the middle, 4 for the right. `kernel/devfs`
makes a line of it for `/dev/mouse`.

## Bringing the port up

The 8042 keeps its second port off until asked, and asks the mouse
nothing on its own. `init` enables the port, sets the mouse's defaults,
tells it to report, and then and only then lets its interrupt through.
It polls for the two acknowledgements, before the interrupt is enabled
in the controller, so they cannot arrive at a handler. Every wait on the
controller is bounded. A controller that never answers is a machine with
no mouse, and not a reason to stop the boot.

## What is not here

Acceleration, a scaling, a resolution, the wheel. Each is a command to
the mouse, and `/dev/mousectl` is the file they belong behind, on the
convention `/dev/consctl` set. The wheel wants a fourth byte and the
protocol dance that asks for it, which is the day something scrolls.
*/
package mouse

import "base:intrinsics"

import "kernel:arch"
import "kernel:drivers/kbd"
import "kernel:drivers/ring"
import "kernel:sched"
import "kernel:sync"

// The controller's ports and its two buffer bits are the keyboard driver's,
// in `kbd/i8042.odin`. This bit is set when the byte in the output buffer
// came from the second port.
@(private = "file")
STATUS_AUX :: u8(0x20)

// How many turns every wait on the controller is bounded to.
@(private = "file")
BOUND :: 10000

// The controller's commands this driver uses, and the mouse's.
@(private = "file")
CMD_READ_CONFIG :: u8(0x20)
@(private = "file")
CMD_WRITE_CONFIG :: u8(0x60)
@(private = "file")
CMD_ENABLE_AUX :: u8(0xA8)
@(private = "file")
CMD_WRITE_AUX_OUTPUT :: u8(0xD3)
@(private = "file")
CMD_WRITE_AUX :: u8(0xD4)
@(private = "file")
MOUSE_DEFAULTS :: u8(0xF6)
@(private = "file")
MOUSE_REPORT :: u8(0xF4)
@(private = "file")
MOUSE_ACK :: u8(0xFA)

// The configuration byte's two bits about the second port: its interrupt
// enabled, and its clock held off.
@(private = "file")
CONFIG_AUX_INTERRUPT :: u8(0x02)
@(private = "file")
CONFIG_AUX_CLOCK_OFF :: u8(0x20)

// The ISA interrupt a mouse asserts, and the same identity mapping the
// keyboard's line takes. See `kernel/arch/amd64/ioapic.odin`.
MOUSE_IRQ :: 12

// A packet is three bytes and a burst is a few packets, so the keyboard's
// ring is deep enough here too.
RING_BYTES :: ring.BYTES

// Where a decoded packet goes: a position, the buttons, and the tick.
// `kernel/devfs` sets this, and nothing here knows that.
Sink :: #type proc "contextless" (x: int, y: int, buttons: u8, msec: u64)

/*
Everything one mouse is. The ring and its lock are the keyboard's
arrangement, `ring.Byte_Ring`, with the top half's counters. The position
and the packet under construction belong to the bottom half alone.
*/
Mouse :: struct {
	using fifo: ring.Byte_Ring,
	ready: sync.Rendez,
	sink:  Sink,

	// The packet under construction, and where the pointer is.
	packet:  [3]u8,
	have:    int,
	x:       int,
	y:       int,
	w:       int,
	h:       int,
	buttons: u8,

	// The bottom half's counters, reported at boot and checked by the
	// self-test. The top half's are the ring's.
	packets:    u64,
	bad:        u64, // Bytes dropped to find the start of a packet
}

@(private)
mouse: Mouse

/*
init brings the second port up, starts the bottom half, and lets the
interrupt through, in that order. `w` and `h` are the screen the pointer
is kept inside, and the pointer starts at its middle. False when there is
no controller, no interrupt controller to route through, or no mouse that
answers, and `why` says which, for the boot line.
*/
init :: proc(vector: int, w: int, h: int, sink: Sink) -> (ok: bool, why: string) {
	if sink == nil || w <= 0 || h <= 0 || !arch.irq_attached() || !arch.irq_available() {
		return false, "no interrupt controller to route through"
	}
	if arch.inb(kbd.PORT_STATUS) == 0xFF {
		return false, "no 8042 on the port bus"
	}

	mouse.sink = sink
	mouse.w = w
	mouse.h = h
	mouse.x = w / 2
	mouse.y = h / 2
	mouse.head = 0
	mouse.tail = 0

	if !controller_command(CMD_ENABLE_AUX) {
		return false, "the controller would not take a command"
	}
	if !mouse_command(MOUSE_DEFAULTS) {
		return false, "nothing on the second port acknowledged its defaults"
	}
	if !mouse_command(MOUSE_REPORT) {
		return false, "the mouse would not agree to report"
	}

			/*
	The interrupt last, in the controller's configuration byte, after the
	two acknowledgements above came back to the poll.

	**The configuration byte comes out on the keyboard's side of the
		controller, and the keyboard's handler is live.** It raises IRQ 1 as a
	scancode would. The handler would read it into the keyboard's ring
	before this poll saw it, which is what happened the first time this
	ran. So the keyboard's line is masked for the length of the exchange,
	and the byte it would have taken is ours.
	*/
	arch.irq_set_mask(kbd.KBD_IRQ, true)
	defer arch.irq_set_mask(kbd.KBD_IRQ, false)
	if !controller_command(CMD_READ_CONFIG) {
		return false, "the controller would not say its configuration"
	}
	config, got := kbd.wait_output(BOUND)
	if !got {
		return false, "the controller never answered its configuration"
	}
	config |= CONFIG_AUX_INTERRUPT
	config &~= CONFIG_AUX_CLOCK_OFF
	if !controller_command(CMD_WRITE_CONFIG) || !kbd.wait_input(BOUND) {
		return false, "the controller would not take its configuration"
	}
	arch.outb(kbd.PORT_DATA, config)

	if sched.spawn("mouse-bottom", bottom_half, &mouse) == nil {
		return false, "no thread for the bottom half"
	}
	arch.set_interrupt_handler(vector, on_interrupt)
	arch.irq_route(MOUSE_IRQ, u8(vector), arch.cpu_lapic_id())
	arch.irq_set_mask(MOUSE_IRQ, false)
	return true, ""
}

// controller_command is the keyboard driver's, at this driver's bound.
@(private = "file")
controller_command :: proc "contextless" (cmd: u8) -> bool {
	return kbd.controller_command(cmd, BOUND)
}

// mouse_command sends one byte to the mouse through the controller and
// waits for the mouse to acknowledge it. A byte that is not the
// acknowledgement is the keyboard's, left over, and is skipped.
@(private = "file")
mouse_command :: proc "contextless" (cmd: u8) -> bool {
	if !controller_command(CMD_WRITE_AUX) || !kbd.wait_input(BOUND) {
		return false
	}
	arch.outb(kbd.PORT_DATA, cmd)
	for _ in 0 ..< 8 {
		b, ok := kbd.wait_output(BOUND)
		if !ok {
			return false
		}
		if b == MOUSE_ACK {
			return true
		}
	}
	return false
}

Stats :: struct {
	interrupts: u64,
	bytes:      u64,
	dropped:    u64,
	packets:    u64,
	bad:        u64,
}

stats :: proc "contextless" () -> Stats {
	g := sync.acquire(&mouse.lock)
	defer sync.release(&mouse.lock, g)
	return Stats {
		interrupts = mouse.pushed,
		bytes = mouse.stored,
		dropped = mouse.dropped,
		packets = intrinsics.volatile_load(&mouse.packets),
		bad = intrinsics.volatile_load(&mouse.bad),
	}
}

// position is where the pointer is, for the file that reports it before
// the first movement.
position :: proc "contextless" () -> (x: int, y: int) {
	return intrinsics.volatile_load(&mouse.x), intrinsics.volatile_load(&mouse.y)
}

// -- The top half ------------------------------------------------------------

// on_interrupt is the keyboard's: read the port, acknowledge, put the byte
// in the ring, wake the bottom half. A byte that is not the second port's
// is the keyboard's arriving on the wrong line, and is left for it.
@(private = "file")
on_interrupt :: proc "contextless" (r: arch.Resume) -> arch.Resume {
	status := arch.inb(kbd.PORT_STATUS)
	if status & kbd.STATUS_OUTPUT_FULL != 0 && status & STATUS_AUX != 0 {
		b := arch.inb(kbd.PORT_DATA)
		arch.irq_ack()
		if ring.push(&mouse.fifo, b) {
			sync.wakeup(&mouse.ready)
		}
		return r
	}
	arch.irq_ack()
	return r
}

/*
inject asks the controller to deliver a byte as though the mouse sent it.

8042 command 0xD3 puts a byte in the second port's output buffer, which
raises IRQ 12 exactly as a movement does. Every step after the mouse
itself is real, which is what lets a machine with no mouse check the
driver and the file above it.
*/
@(private)
inject :: proc "contextless" (b: u8) -> bool {
	if !controller_command(CMD_WRITE_AUX_OUTPUT) || !kbd.wait_input(BOUND) {
		return false
	}
	arch.outb(kbd.PORT_DATA, b)
	return true
}

/*
feed puts one byte straight into the fifo and wakes the bottom half. This is
how a packet reaches the driver when no 8042 sits under it: `inject` above goes
through the controller's second port, which a `virt` board does not have.
`kernel/drivers/virtio`'s input driver builds PS/2-shaped packets from another
bus's events and feeds them here, where the same bottom half decodes them; and
a self-test outside this package feeds one the same way with `feed_packet`, the
mouse's analog of the keyboard's `scancode_tap` -- delivery to the driver on
every board, with the 8042 second-port path proven separately by
`verify_interrupt`.
*/
feed :: proc "contextless" (b: u8) {
	if ring.push(&mouse.fifo, b) {
		sync.wakeup(&mouse.ready)
	}
}

// feed_packet is `feed` three times: one movement, the three bytes a PS/2
// packet is.
feed_packet :: proc "contextless" (flags: u8, dx: u8, dy: u8) {
	feed(flags)
	feed(dx)
	feed(dy)
}

/*
init_headless starts the bottom half with no port under it: the fifo, the sink,
the pointer centred on the screen, and the decoding thread, for a mouse whose
packets arrive through `feed` rather than an 8042. The `virt` boards have no
PS/2; `kernel/drivers/virtio`'s input driver feeds this instead.
*/
init_headless :: proc(w: int, h: int, sink: Sink) -> bool {
	if sink == nil || w <= 0 || h <= 0 {
		return false
	}
	mouse.sink = sink
	mouse.w = w
	mouse.h = h
	mouse.x = w / 2
	mouse.y = h / 2
	mouse.head = 0
	mouse.tail = 0
	return sched.spawn("mouse-bottom", bottom_half, &mouse) != nil
}

// -- The bottom half ---------------------------------------------------------

@(private = "file")
bottom_half :: proc "contextless" (arg: rawptr) {
	m := cast(^Mouse)arg
	for {
		sync.sleep(&m.ready, ring.pending, &m.fifo)
		for {
			b, ok := ring.take(&m.fifo)
			if !ok {
				break
			}
			if x, y, buttons, done := decode(m, b); done && m.sink != nil {
				m.sink(x, y, buttons, sched.ticks())
			}
		}
	}
}

/*
decode takes one byte into the packet under construction, and answers the
new position and buttons when the packet completes.

Split out so the self-test can drive it with no interrupt and no thread.
The first byte of a packet has its bit 3 set. A byte that arrives first
without it is dropped, which is how the stream finds its frame again
after a byte went missing. A movement is nine bits signed, the sign in
the first byte. The position is clamped to the screen, and Y is
turned over, because the mouse counts up and the screen counts down.
*/
@(private)
decode :: proc "contextless" (m: ^Mouse, b: u8) -> (x: int, y: int, buttons: u8, done: bool) #no_bounds_check {
	if m.have == 0 && b & 0x08 == 0 {
		ring.bump(&m.bad)
		return 0, 0, 0, false
	}
	m.packet[m.have] = b
	m.have += 1
	if m.have < 3 {
		return 0, 0, 0, false
	}
	m.have = 0

	flags := m.packet[0]
	dx := int(m.packet[1])
	if flags & 0x10 != 0 {
		dx -= 256
	}
	dy := int(m.packet[2])
	if flags & 0x20 != 0 {
		dy -= 256
	}
	m.x = clamp(m.x + dx, 0, m.w - 1)
	m.y = clamp(m.y - dy, 0, m.h - 1)
	// `rio`'s numbering: 1 left, 2 middle, 4 right. The packet has the
	// middle button above the right one.
	m.buttons = (flags & 0x01) | (flags & 0x04) >> 1 | (flags & 0x02) << 1
	ring.bump(&m.packets)
	return m.x, m.y, m.buttons, true
}
