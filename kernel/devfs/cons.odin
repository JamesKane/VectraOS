/*
The console device: the two halves of `/dev/cons`.

Output is the easy half. A write goes to the framebuffer console and to the
serial port, which is what every other Vectra sink already does. Input is the
half with a design in it, and there are two decisions worth stating before the
code makes them look inevitable.

**Input arrives on a thread, not on an interrupt.** The 16550 driver is polled,
because it is the one thing that has to work before there are interrupts. So a
thread stands where an interrupt handler will stand. It polls, pushes bytes into
a ring, and wakes whoever waits. Nothing above the ring can tell the difference,
which is the point. The day IRQ 4 is wired up, `cons_input` goes away and the
handler pushes into the same ring.

**The ring buffers what nobody asked for yet.** A key pressed while no
process reads `/dev/cons` is kept, up to `CONS_INPUT_BYTES` of it. A driver that
only moved bytes when somebody waited would lose everything typed between two
reads, which is every character a user types ahead.

## Two locks, and why they are different kinds

`out` is a sleeping lock, and that is not a preference. A write to the console
draws glyphs, and a write at the bottom of the screen scrolls it first. A scroll
copies most of a 1280x800 framebuffer.

A spinlock masks interrupts for as long as it is held. One here would mask them
across four megabytes of memory copy, a thousand times a second. The timer would
then lose ticks it can never get back. See the LAPIC note in
`docs/HANDOFF.md`.

`ring` is a spinlock, for the opposite reason. What it guards is two integers
and a byte, and the producer is a thread that will one day be an interrupt
handler. An interrupt handler cannot park, so the lock it takes may never be one
that parks.

**The kernel log does not take `out`.** `klog` writes to the same console and is
deliberately left alone. It runs from the fault path. A sleeping lock is
forbidden there, and a lock held by a dead thread is worse than a torn line. The
ordering of a log line against a `/dev/cons` write is therefore undefined. What
is defined is that neither can deadlock the other.

## What this is not

There is no line discipline. A read returns bytes as they arrive, rather than
waiting for Enter. Backspace does nothing, because there is no line buffer to
erase from. Plan 9 puts both behind `/dev/consctl`, and so will this. A `ctl`
file that takes `rawon` and `rawoff` is the shape, because Vectra9 adds no
message to 9P for something a file can carry.

One translation happens anyway, and it is the one nothing above could undo. A
terminal sends CR for Enter. A reader that got CR would have to know which
terminal typed at it. `\n` is the newline everywhere else in this tree, so CR
becomes `\n` here.
*/
package devfs

import "base:intrinsics"

import "kernel:drivers/console"
import "kernel:drivers/uart"
import "kernel:sched"
import "kernel:sync"

/*
How many typed bytes survive with nobody reading.

A power of two, so the wrap is a mask. Big enough for a pasted command line,
small enough that it is not worth a heap allocation. An overrun counts itself
in `dropped` rather than blocking the producer. An interrupt handler with
nowhere to put a byte drops it, and this driver behaves the way its replacement
will.
*/
CONS_INPUT_BYTES :: 256
@(private = "file")
RING_MASK :: CONS_INPUT_BYTES - 1

/*
Ticks between polls of the receive register.

One tick, which is one millisecond. Fast enough that typing does not feel
staged, slow enough that the poll costs one port read per tick. `sync.delay`
parks, so the thread is off every run queue in between and the core is free.
*/
@(private = "file")
POLL_TICKS :: 1

Cons :: struct {
	screen: ^console.Console,
	port:   ^uart.Port,

	// The way out. Held across a glyph blit and a possible scroll, so it parks
	// rather than masks -- see the file comment.
	out:    sync.Mutex,

	/*
	The way in.

	`head` and `tail` are monotonic and never wrap by hand. The index is the
	counter masked. That is what makes `head - tail` the count. There is then no
	ambiguity between a full ring and an empty one, which is the bug every other
	arrangement has.
	*/
	ring:   [CONS_INPUT_BYTES]u8,
	head:   u64,
	tail:   u64,
	lock:   sync.Spinlock,

	// Where a reader with nothing to read parks. Woken by the producer, and by
	// the abort hook when a Tflush names the read.
	ready:  sync.Rendez,

	// Whether a byte that arrives is drawn where it was typed. The line
	// discipline this tree does not have yet, in the one form it needs today.
	echo:   bool,

	// Counters, reported at boot and checked by the self-test. Every one of
	// them is written under `lock` or under `out`.
	writes:  u64, // Bytes accepted by a write
	takes:   u64, // Bytes handed to a reader
	typed:   u64, // Bytes the producer put in the ring
	dropped: u64, // ...and bytes it could not, because the ring was full
	blocks:  u64, // Reads that found nothing and parked
}

/*
cons_init points the device at its sinks. Neither may be nil.

`echo` is on. The only reader of `/dev/cons` today is a self-test. The only
writer at a keyboard is a person who wants to see what they typed. An
application that draws its own input turns it off.
*/
cons_init :: proc "contextless" (c: ^Cons, screen: ^console.Console, port: ^uart.Port) {
	c.screen = screen
	c.port = port
	c.head = 0
	c.tail = 0
	c.echo = true
}

// -- Output ------------------------------------------------------------------

/*
cons_write puts `data` on the screen and on the wire, and reports how much.

Always all of it. A console has no back pressure to report and nothing to be
short about. A short write here would mean a bug rather than a busy device.

Parks on `out` if another thread is part-way through a write. That is what
keeps two writers from interleaving inside one line, and it is why this may not
be called with a spinlock held.
*/
cons_write :: proc "contextless" (c: ^Cons, data: []u8) -> int {
	if c == nil || len(data) == 0 {
		return 0
	}

	sync.mutex_lock(&c.out)
	defer sync.mutex_unlock(&c.out)

	if c.screen != nil {
		console.write_string(c.screen, string(data))
	}
	if c.port != nil {
		uart.write_string(c.port, string(data))
	}
	c.writes += u64(len(data))
	return len(data)
}

// -- Input -------------------------------------------------------------------

// cons_available is the condition a parked reader waits on, and the reason it
// is a procedure rather than a flag. See `kernel/sync/rendez.odin`.
cons_available :: proc "contextless" (c: ^Cons) -> bool {
	return intrinsics.volatile_load(&c.head) != intrinsics.volatile_load(&c.tail)
}

/*
cons_take moves what is in the ring into `buf` and reports how much.

Never parks and never returns less than it could. Zero means the ring is empty
right now, which is a caller's cue to wait rather than an end of file. Nothing
below the protocol layer knows the difference between those two, which is why
this reports a count and lets `devfs.odin` decide.
*/
cons_take :: proc "contextless" (c: ^Cons, buf: []u8) -> int #no_bounds_check {
	if c == nil || len(buf) == 0 {
		return 0
	}

	g := sync.acquire(&c.lock)
	defer sync.release(&c.lock, g)

	n := 0
	for n < len(buf) && c.tail != c.head {
		buf[n] = c.ring[c.tail & RING_MASK]
		c.tail += 1
		n += 1
	}
	c.takes += u64(n)
	return n
}

// cons_note_block counts a read that found nothing and is about to park. Under
// the ring lock, because every other counter in here is, and a torn count in a
// self-test is a failure nobody can reproduce.
cons_note_block :: proc "contextless" (c: ^Cons) {
	g := sync.acquire(&c.lock)
	c.blocks += 1
	sync.release(&c.lock, g)
}

/*
cons_push puts one byte in the ring and reports whether it fit.

The producer's half. A full ring drops the byte and counts it. The thread that
runs this becomes an interrupt handler, and an interrupt handler has nowhere to
wait. A driver that blocks its producer to keep a byte is a driver
that stops the machine to keep a byte.
*/
@(private = "file")
cons_push :: proc "contextless" (c: ^Cons, b: u8) -> bool #no_bounds_check {
	g := sync.acquire(&c.lock)
	defer sync.release(&c.lock, g)

	if c.head - c.tail >= CONS_INPUT_BYTES {
		c.dropped += 1
		return false
	}
	c.ring[c.head & RING_MASK] = b
	c.head += 1
	c.typed += 1
	return true
}

/*
cons_feed delivers one byte into the input path, as a keystroke does.

The device's input path with the hardware taken out of it, which is exactly what
a self-test needs. A check that a read parks and then finishes has to be the
thing that finishes it, and it cannot type at a serial port.

It is not a test-only entry point. The day there is a keyboard driver, this is
what it calls.
*/
cons_feed :: proc "contextless" (c: ^Cons, b: u8) -> bool {
	b := b
	if b == '\r' {
		b = '\n'
	}
	if !cons_push(c, b) {
		return false
	}
	if c.echo {
		one := [1]u8{b}
		_ = cons_write(c, one[:])
	}
	sync.wakeup(&c.ready)
	return true
}

/*
cons_input is the producer thread: the interrupt handler this driver does not
have yet.

It polls, and it parks between polls. The park is what makes a poll acceptable
here. A spin would hold a core against every other thread on the machine to
watch a register that changes at typing speed.

Runs until the machine stops. There is nothing to shut it down, because there
is nothing yet that takes a console away.
*/
@(private = "file")
cons_input :: proc "contextless" (arg: rawptr) {
	c := cast(^Cons)arg
	for {
		for {
			b, got := uart.read_byte(c.port)
			if !got {
				break
			}
			_ = cons_feed(c, b)
		}
		sync.delay(POLL_TICKS)
	}
}

/*
cons_start puts the producer thread on the port, and reports whether it could.

Separate from `cons_init` because it needs a scheduler and `cons_init` does not.
A console with no producer still writes, which is the half a boot log needs, and
the half that works before there are threads.

A port that failed its loopback probe gets no thread. `uart.read_byte` on one
answers nothing for ever, and a thread that polls it would be a thread that
never does anything else.
*/
cons_start :: proc(c: ^Cons) -> bool {
	if c == nil || c.port == nil || !c.port.present {
		return false
	}
	return sched.spawn("cons-input", cons_input, c) != nil
}
