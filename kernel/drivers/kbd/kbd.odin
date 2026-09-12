/*
The PS/2 keyboard: the first device in Vectra that interrupts.

Every interrupt before this one was the LAPIC timer, which the kernel armed and
therefore expected. A keystroke arrives because somebody outside the machine
decided it should, at a moment nothing chose. That difference is the whole
content of this file.

`kernel/devfs` predicted this arrival and got half of it right. `cons.odin`
calls the polling thread "where an interrupt handler will stand". It goes on:
the day a real one exists, "`cons_input` goes away and the handler pushes into
the same ring". The first half held. The second did not, and the reason is worth more
than the driver.

## Why the handler cannot push into the console's ring

`cons_feed` echoes. Echo is `cons_write`, which takes `Cons.out`, and that is a
*sleeping* lock. A write draws glyphs, and a write at the bottom of the screen
scrolls first. A spinlock across four megabytes of memory copy would cost the
timer ticks it can never get back. `docs/DEVFS.md` argues that at
length and the argument still holds.

**An interrupt handler that took a sleeping lock would park the interrupt.** Not
the thread it interrupted -- the interrupt itself, with its frame on whatever
stack it landed on and no scheduler entry to bring it back. `sync.can_sleep`
would not catch it either: it counts spinlocks, and a bare handler holds none.
It would look legal and run correctly under a test that never contended. It
would stop the machine the first time two things wanted the console at once.

So the work is split where the constraint falls:

    top half     read the port, put the scancode in a ring, wake the bottom
                 half. A spinlock and nothing else, which an interrupt may hold.
    bottom half  an ordinary thread. It translates, it echoes, and it is
                 allowed to park doing either.

The thread `kernel/devfs` predicted would go away therefore does not go away. It
changes what wakes it. A poll became a rendezvous, so nothing runs between
keystrokes, and that is the difference that mattered.

## What is translated here, and what is not

Scancode set 1, which is what an 8042 with translation enabled produces and
what every PC delivers by default. The translation is `sys/libkbd`'s, one
package both rings call, since `docs/WORKBENCH.md` step 1: a position on
the keyboard to the rune a US layout puts there, with shift, caps lock,
control and the 0xE0 prefix inside it. What this driver keeps is the rule
for a byte stream. That is a press and not a release, a character and
not a modifier, and never a chord.

Everything else a terminal wants is absent: key repeat rates, the LEDs, a
compose key. `docs/KBD.md` says which of those want a `ctl` file and which
want a layout in a file.
*/
package kbd

import "base:intrinsics"

import "core:unicode/utf8"

import "kernel:arch"
import "kernel:drivers/ring"
import "kernel:sched"
import "kernel:sync"
import "vsys:libkbd"

// The ISA interrupt a keyboard asserts, and the vector it is routed to. See
// `kernel/arch/amd64/ioapic.odin` for why the mapping to a global system
// interrupt is an identity here rather than a lookup.
KBD_IRQ :: 1

// How many scancodes survive with the bottom half not yet running. The ring
// is `kernel/drivers/ring`'s, which says why this many.
RING_BYTES :: ring.BYTES

// Where a translated byte goes. `kernel/devfs` sets this to `cons_feed`, and
// nothing here knows that. A driver that named its consumer would be a driver
// that could only ever have one.
Sink :: #type proc "contextless" (b: u8)

/*
First refusal on every scancode, before translation.

True consumes the scancode: something raw wants the stream -- `kernel/devfs`
wires this to `/dev/scancode` -- and this driver must not translate it.
False means the scancode is this driver's, exactly as before the hook
existed. The same anonymity rule as `Sink`: nothing here knows what is on
the other end.
*/
Raw :: #type proc "contextless" (code: u8) -> bool

/*
Everything one keyboard is.

The ring, its lock and the top half's counters are `ring.Byte_Ring`'s, which
says why the lock is a spinlock and may never be anything else.
*/
Keyboard :: struct {
	using fifo: ring.Byte_Ring,

	// Where the bottom half waits. Woken by the top half, and by nothing else.
	ready: sync.Rendez,

	sink: Sink,
	raw:  Raw,

		// The modifier state, which belongs to the bottom half alone. The top half
	// never looks at it, so it needs no lock. The state machine that moves
	// it is `sys/libkbd`'s.
	state:    libkbd.State,

	// Whether the last scancode was consumed raw. The transition back is
	// what resets the modifier state -- see `deliver`.
	diverting: bool,

	// The bottom half's counters, reported at boot and checked by the
	// self-test. The top half's are the ring's.
	delivered:  u64, // Bytes the bottom half handed to the sink
	ignored:    u64, // Scancodes that produce no byte: releases, modifiers
	diverted:   u64, // Scancodes the raw hook consumed before translation
}

@(private)
kbd: Keyboard

/*
init claims the line, starts the bottom half, and lets the first interrupt
through -- in that order, and the order is the point.

The vector is claimed before the line is unmasked, so an interrupt cannot arrive
at a handler that is not there. The bottom half is started before that too,
because a top half with nobody to wake fills a ring and drops the rest.

`vector` is the caller's to choose, because the vector space belongs to the
portable kernel rather than to a driver. `sink` is where a translated byte goes.

Fails if there is no I/O APIC to route through. There is no fallback to the
8259, deliberately: see `kernel/arch/amd64/ioapic.odin`.
*/
init :: proc(vector: int, sink: Sink, raw: Raw = nil) -> bool {
	if sink == nil || !arch.irq_attached() || !arch.irq_available() {
		return false
	}
	// A status register that reads all-ones is no controller. That is what
	// an absent device answers on a PC's port bus, and what a machine with
	// no port bus answers for every port. Either way there is nothing here
	// to drive, and a line routed to it would only ever carry silence.
	if arch.inb(PORT_STATUS) == 0xFF {
		return false
	}

	kbd.sink = sink
	kbd.raw = raw
	kbd.head = 0
	kbd.tail = 0

	drain_controller()

	if sched.spawn("kbd-bottom", bottom_half, &kbd) == nil {
		return false
	}

	arch.set_interrupt_handler(vector, on_interrupt)
	arch.irq_route(KBD_IRQ, u8(vector), arch.cpu_lapic_id())
	arch.irq_set_mask(KBD_IRQ, false)
	return true
}

/*
drain_controller empties whatever the firmware left behind.

A byte sitting in the output buffer at the moment the line is unmasked is a byte
that was pressed before this kernel existed. On some controllers it is also a
reason no further interrupt arrives. The 8042 asserts its line while the buffer
is full, and does not re-assert for the next byte until something reads it.

Bounded rather than looped until clear. A controller that always reports a byte
is a broken controller. A driver that spun on one would hang the boot, with no
line printed to say why.
*/
@(private = "file")
drain_controller :: proc "contextless" () {
	for _ in 0 ..< 16 {
		if arch.inb(PORT_STATUS) & STATUS_OUTPUT_FULL == 0 {
			return
		}
		_ = arch.inb(PORT_DATA)
	}
}

// stats reports what this driver saw. For the boot line and the self-test.
Stats :: struct {
	interrupts: u64,
	scancodes:  u64,
	dropped:    u64,
	delivered:  u64,
}

stats :: proc "contextless" () -> Stats {
	g := sync.acquire(&kbd.lock)
	defer sync.release(&kbd.lock, g)
	return Stats {
		interrupts = kbd.pushed,
		scancodes = kbd.stored,
		dropped = kbd.dropped,
		delivered = intrinsics.volatile_load(&kbd.delivered),
	}
}

// -- The top half ------------------------------------------------------------

/*
on_interrupt is everything that happens with interrupts off.

Three things, and the shortness is the specification rather than an
optimisation. Read the port, because the controller will not deliver another
interrupt until its buffer is empty. Put the byte somewhere. Say so.

It acknowledges the APIC *before* it wakes anybody. A wake can make a thread
runnable, and the scheduler is entitled to switch to it on the way out of this
handler. An EOI that came after the switch would come after an arbitrary delay.

Returns the state it interrupted. A keystroke is a device to service rather
than a reason to schedule. The woken thread runs when the scheduler next picks
it, which on an idle machine is at once. The timer is the one handler here that
returns a different `Resume`. It earns that by being the thing that measures a
slice.
*/
@(private = "file")
on_interrupt :: proc "contextless" (r: arch.Resume) -> arch.Resume {
	code := arch.inb(PORT_DATA)
	arch.irq_ack()
	feed(code)
	return r
}

/*
feed puts one scancode into the ring as though the port had raised it, and
wakes the bottom half. The top half calls it from the interrupt; a keyboard
with no 8042 -- `kernel/drivers/virtio`'s input driver on the `virt` boards --
calls it with the set-1 scancodes it made from another bus's events, so the
bottom half translates them the one way it knows.
*/
feed :: proc "contextless" (code: u8) {
	if ring.push(&kbd.fifo, code) {
		sync.wakeup(&kbd.ready)
	}
}

/*
init_headless starts the bottom half with no port under it: the ring, the sink
and the translating thread, for a keyboard whose scancodes arrive through
`feed` rather than an 8042. `docs/PORTS.md` says the `virt` boards have no PS/2;
`kernel/drivers/virtio`'s input driver feeds this instead.
*/
init_headless :: proc(sink: Sink, raw: Raw = nil) -> bool {
	if sink == nil {
		return false
	}
	kbd.sink = sink
	kbd.raw = raw
	kbd.head = 0
	kbd.tail = 0
	return sched.spawn("kbd-bottom", bottom_half, &kbd) != nil
}

/*
inject asks the controller to deliver a byte as though somebody typed it.

8042 command 0xD2 puts a byte in the first port's output buffer, which raises
IRQ 1 exactly as a keystroke does. Every step after the key itself is real: the
line, the vector, the handler, the ring, the thread.

That is the only way a self-test can check an interrupt path. A check that has
to be typed at is a check nobody runs.

Reports whether the controller accepted the command. A full input buffer means
it is busy, and waiting for one that never empties would hang the boot.
*/
@(private)
inject :: proc "contextless" (code: u8) -> bool {
	if !controller_command(0xD2, 1000) || !wait_input(1000) {
		return false
	}
	arch.outb(PORT_DATA, code)
	return true
}

// -- The bottom half ---------------------------------------------------------

/*
bottom_half is an ordinary thread, and that is what buys it the right to park.

It translates and it echoes, and both may take a sleeping lock. Neither could
happen in the handler that woke it.

Runs until the machine stops. There is nothing to shut it down, because nothing
yet takes a keyboard away.
*/
@(private = "file")
bottom_half :: proc "contextless" (arg: rawptr) {
	k := cast(^Keyboard)arg
	for {
		sync.sleep(&k.ready, ring.pending, &k.fifo)
		for {
			code, ok := ring.take(&k.fifo)
			if !ok {
				break
			}
			deliver(k, code)
		}
	}
}

/*
deliver runs one scancode through the state machine and sends what it produced.

Split out from the loop above so the self-test can drive it with no interrupt
and no thread. What a keyboard does with a scancode is a pure question about
the scancode and the modifier state. A check that has to press a key to ask it
is a check nobody writes.

The raw hook gets first refusal, before the state machine sees anything. A
consumed scancode is diverted whole, modifiers included. The far side is a
driver with a translation of its own, and needs the presses and the
releases both.

**The first scancode back resets the modifier state.** A shift pressed
before a diversion and released into it would otherwise leave this state
machine shifted for ever. The modifiers are unknowable after a diversion,
and cleared is the only honest value for unknowable.
*/
@(private)
deliver :: proc "contextless" (k: ^Keyboard, code: u8) {
	if k.raw != nil && k.raw(code) {
		k.diverting = true
		ring.bump(&k.diverted)
		return
	}
		if k.diverting {
		k.diverting = false
		k.state = {}
	}

	r, produced := step(k, code)
	if !produced {
		ring.bump(&k.ignored)
		return
	}
	ring.bump(&k.delivered)
	if k.sink == nil {
		return
	}
	/*
	One rune, as the bytes that carry it.

	The sink stays byte-wide. ASCII is one byte and takes the path it always
	took, and a key with no character arrives as the three its rune needs --
	which is what `sys/libkey` means by the encoding being the thing that lets
	a keyboard say more than a byte can.
	*/
	if r < 0x80 {
		k.sink(u8(r))
		return
	}
	buf, n := utf8.encode_rune(r)
	for i in 0 ..< n {
		k.sink(buf[i])
	}
}

// -- Scancode set 1 ----------------------------------------------------------

/*
The state machine is `sys/libkbd`'s, one copy for both rings. What is
left here is the rule for a byte stream. A press produces the rune the
position means now, unless the key is a modifier or a chord. A release
produces nothing. The positions the self-test presses are named there
too, and aliased here so a check reads as a key rather than a hex
number.
*/
@(private)
SC_EXTENDED :: libkbd.SC_EXTENDED
@(private)
SC_RELEASE :: libkbd.SC_RELEASE
@(private)
SC_LSHIFT :: libkbd.SC_LSHIFT
@(private)
SC_RSHIFT :: libkbd.SC_RSHIFT
@(private)
SC_CTRL :: libkbd.SC_CTRL
@(private)
SC_CAPS :: libkbd.SC_CAPS

/*
step advances the modifier state and reports the rune a scancode produced.

`false` means the scancode produced nothing, which is the common case.
That is every key release, every modifier in both directions, and every
position with no character on it. It is also every key pressed with alt
held, which is a chord and not a character. See `libkbd.char_of`.
*/
@(private)
step :: proc "contextless" (k: ^Keyboard, code: u8) -> (r: rune, produced: bool) {
	key, down, ok := libkbd.step(&k.state, code)
	if !ok || !down {
		return 0, false
	}
	return libkbd.char_of(&k.state, key)
}
