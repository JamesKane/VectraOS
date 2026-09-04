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
import "kernel:sched"
import "kernel:sync"
import "vsys:libkbd"

// The 8042's two ports. Data carries scancodes in and commands out. The second
// is status when read and command when written.
@(private = "file")
PORT_DATA :: u16(0x60)
@(private = "file")
PORT_STATUS :: u16(0x64)

// The one status bit this driver reads. Set means the controller has a byte
// for us, and reading the data port with it clear returns whatever was there
// last time.
@(private = "file")
STATUS_OUTPUT_FULL :: u8(0x01)

// The ISA interrupt a keyboard asserts, and the vector it is routed to. See
// `kernel/arch/amd64/ioapic.odin` for why the mapping to a global system
// interrupt is an identity here rather than a lookup.
KBD_IRQ :: 1

/*
How many scancodes survive with the bottom half not yet running.

A person types at ten bytes a second, and the bottom half runs at the first
opportunity after a wake. This is deep enough for a burst of key-down and
key-up pairs while something holds the console. A full ring drops the scancode
and counts it, because that is what an interrupt handler with nowhere to put a
byte has to do.
*/
RING_BYTES :: 64
@(private = "file")
RING_MASK :: RING_BYTES - 1

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

`head` and `tail` are monotonic and the index is the counter masked. That is
the same arrangement `devfs.Cons` uses, for the same reason. `head - tail` is
then the count, with no ambiguity between full and empty.

`lock` is a spinlock and may never be anything else. The producer is an
interrupt handler, and an interrupt handler cannot park.
*/
Keyboard :: struct {
	ring: [RING_BYTES]u8,
	head: u64,
	tail: u64,
	lock: sync.Spinlock,

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

	// Counters, reported at boot and checked by the self-test.
	interrupts: u64, // Times the top half ran
	scancodes:  u64, // Bytes it put in the ring
	dropped:    u64, // ...and bytes it could not, because the ring was full
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
	ignored:    u64,
	diverted:   u64,
}

stats :: proc "contextless" () -> Stats {
	g := sync.acquire(&kbd.lock)
	defer sync.release(&kbd.lock, g)
	return Stats {
		interrupts = kbd.interrupts,
		scancodes = kbd.scancodes,
		dropped = kbd.dropped,
		delivered = intrinsics.volatile_load(&kbd.delivered),
		ignored = intrinsics.volatile_load(&kbd.ignored),
		diverted = intrinsics.volatile_load(&kbd.diverted),
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

	if push(&kbd, code) {
		sync.wakeup(&kbd.ready)
	}
	return r
}

/*
push puts one scancode in the ring and reports whether it fit.

Shared with the self-test, which is what lets a check exercise a full ring
without pressing sixty-five keys. A full ring drops the scancode and counts it,
because an interrupt handler with nowhere to put a byte has nowhere to wait
either.
*/
@(private)
push :: proc "contextless" (k: ^Keyboard, code: u8) -> bool #no_bounds_check {
	g := sync.acquire(&k.lock)
	defer sync.release(&k.lock, g)

	k.interrupts += 1
	if k.head - k.tail >= RING_BYTES {
		k.dropped += 1
		return false
	}
	k.ring[k.head & RING_MASK] = code
	k.head += 1
	k.scancodes += 1
	return true
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
	for _ in 0 ..< 1000 {
		// Bit 1 of the status port is `input buffer full`. Writing a command
		// while it is set loses the command.
		if arch.inb(PORT_STATUS) & 0x02 == 0 {
			arch.outb(PORT_STATUS, 0xD2)
			for _ in 0 ..< 1000 {
				if arch.inb(PORT_STATUS) & 0x02 == 0 {
					arch.outb(PORT_DATA, code)
					return true
				}
			}
			return false
		}
	}
	return false
}

// -- The bottom half ---------------------------------------------------------

@(private = "file")
have_scancodes :: proc "contextless" (arg: rawptr) -> bool {
	k := cast(^Keyboard)arg
	return intrinsics.volatile_load(&k.head) != intrinsics.volatile_load(&k.tail)
}

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
		sync.sleep(&k.ready, have_scancodes, k)
		for {
			code, ok := take(k)
			if !ok {
				break
			}
			deliver(k, code)
		}
	}
}

// Package-visible for the same reason `push` is: the self-test drains a ring it
// filled, and neither half is worth a second implementation.
@(private)
take :: proc "contextless" (k: ^Keyboard) -> (code: u8, ok: bool) #no_bounds_check {
	g := sync.acquire(&k.lock)
	defer sync.release(&k.lock, g)

	if k.tail == k.head {
		return 0, false
	}
	code = k.ring[k.tail & RING_MASK]
	k.tail += 1
	return code, true
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
		bump(&k.diverted)
		return
	}
		if k.diverting {
		k.diverting = false
		k.state = {}
	}

	r, produced := step(k, code)
	if !produced {
		bump(&k.ignored)
		return
	}
	bump(&k.delivered)
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

@(private = "file")
bump :: proc "contextless" (p: ^u64) {
	intrinsics.volatile_store(p, intrinsics.volatile_load(p) + 1)
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
