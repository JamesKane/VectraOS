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

## Cooked and raw

A byte that arrives does not go straight into the ring. It goes into a line
under construction, and the whole line reaches the ring when the user presses
Enter. That is *cooked* mode, and it is the default because it is what a person
at a keyboard wants. A typed character can be taken back until the moment the
line is sent.

    printable   appended to the line, and echoed where it was typed
    \b or DEL   the last character comes off the line, and off the screen
    ^U          the whole line goes, and the echo starts a fresh one
    \r or \n    the line, with a newline on the end, reaches the ring
    ^D          the line so far reaches the ring with no newline
                ...and on an empty line, it is an end of file instead

*Raw* mode is the other half. Every byte reaches the ring as it arrives, none
of the characters above mean anything, and nothing is echoed. That is what a
program which draws its own input needs, and it is what a program which reads a
password needs.

`/dev/consctl` is how a client moves between them, because Vectra9 adds no
message to 9P for something a file can carry. See `devfs.odin` for the file and
`docs/DEVFS.md` for the convention it sets.

**Raw mode turns echo off, and cooked mode turns it back on.** They are separate
fields and one command sets both, because a raw read that echoed would be a
password on a screen. `echoon` and `echooff` are there for a client that wants
the other combination on purpose.

## One translation nothing above could undo

A terminal sends CR for Enter. A reader that got CR would have to know which
terminal typed at it. `\n` is the newline everywhere else in this tree, so CR
becomes `\n` here. It is the one substitution raw mode makes as well, because
no mode makes a reader want to know what kind of terminal it has.
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

/*
How long a line may get before Enter.

A line that reaches the limit stops accepting characters. It does not send
itself, and it does not drop what the user typed so far. Both of those
would lose work the user can still see on the screen. The typist gets no echo
for the character that did not fit, which is the same feedback a terminal gives.

Half the ring, so a full line always fits in the space a line goes into.
*/
CONS_LINE_BYTES :: CONS_INPUT_BYTES / 2

// The control characters cooked mode acts on. Named because `0x15` in a switch
// is a number somebody has to look up, and package-visible because the
// self-test has to type them.
@(private)
CTRL_D :: u8(0x04) // End of transmission: send the line, or end the file
@(private)
CTRL_U :: u8(0x15) // Kill: the line under construction goes
@(private)
BACKSPACE :: u8(0x08)
@(private)
DEL :: u8(0x7F)

/*
What a byte that arrives does to the console.

Not a mode of the *device* so much as a mode of the line discipline. That is
why raw mode is describable as `there is no line discipline`. `Cooked` is the
default, and the one `/dev/consctl` reverts to when its last fid closes.
*/
Cons_Mode :: enum u8 {
	Cooked,
	Raw,
}

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

	/*
	The line under construction, in cooked mode.

	Between the keyboard and the ring. Nothing here is visible to a reader, and
	everything here can still be taken back. `edit_len` of zero is both an empty
	line and no line at all. That is why `^D` on it means an end of file rather
	than an empty send.

	Guarded by `lock`, like the ring it feeds.
	*/
	edit:     [CONS_LINE_BYTES]u8,
	edit_len: int,

	/*
	End-of-file marks a reader has not taken yet.

	A count rather than a flag, because two `^D` presses are two end-of-file
	answers and a flag would merge them. It is read only when the ring is empty:
	an end of file is something a reader reaches, not something that overtakes
	bytes already typed.
	*/
	eofs:     int,

	// Where a reader with nothing to read parks. Woken by the producer, and by
	// the abort hook when a Tflush names the read.
	ready:  sync.Rendez,

	// What a byte that arrives does, and whether it is drawn where it was
	// typed. `/dev/consctl` is the only thing that changes either. Guarded by
	// `lock`, so a reader parked on the mode sees one value or the other.
	mode:   Cons_Mode,
	echo:   bool,

	// Counters, reported at boot and checked by the self-test. Every one of
	// them is written under `lock` or under `out`.
	writes:  u64, // Bytes accepted by a write
	takes:   u64, // Bytes handed to a reader
	typed:   u64, // Bytes the producer put in the ring
	dropped: u64, // ...and bytes it could not, because the ring was full
	blocks:  u64, // Reads that found nothing and parked
	lines:   u64, // Lines cooked mode sent whole
	erased:  u64, // Characters a backspace took back
	killed:  u64, // Lines a ^U threw away
	refused: u64, // Characters that did not fit the line under construction
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
	c.edit_len = 0
	c.eofs = 0
	c.mode = .Cooked
	c.echo = true
}

/*
cons_set_mode changes what an arriving byte does, and reports the mode it left.

The line under construction goes when the mode changes, and that is deliberate.
Those characters were typed under rules that no longer apply. A raw reader
handed a line the user was still editing would get characters the user already
backspaced over. A backspace only ever reached the edit buffer.

`/dev/consctl` is the only caller. Nothing else should be changing the rules
under a reader.
*/
cons_set_mode :: proc "contextless" (c: ^Cons, mode: Cons_Mode, echo: bool) -> Cons_Mode {
	g := sync.acquire(&c.lock)
	defer sync.release(&c.lock, g)

	was := c.mode
	if mode != c.mode {
		c.edit_len = 0
	}
	c.mode = mode
	c.echo = echo
	return was
}

// cons_mode reports what an arriving byte does now, and whether it is echoed.
cons_mode :: proc "contextless" (c: ^Cons) -> (mode: Cons_Mode, echo: bool) {
	g := sync.acquire(&c.lock)
	defer sync.release(&c.lock, g)
	return c.mode, c.echo
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

/*
cons_erase takes the last character back on both sinks.

Two sinks, two different sequences, which is the one place they disagree. A
terminal at the end of a serial line erases with `\b \b`: step back, overwrite
with a space, step back again. The framebuffer console cannot do that. Nothing
in it paints a background, so a space glyph composites nothing over the
character already there. `console.backspace` fills the cell instead.

One acquisition of `out` for the pair, so the two sinks cannot be interleaved
half-way through an erase by a write from somewhere else.
*/
cons_erase :: proc "contextless" (c: ^Cons) {
	if c == nil {
		return
	}

	sync.mutex_lock(&c.out)
	defer sync.mutex_unlock(&c.out)

	if c.screen != nil {
		console.backspace(c.screen)
	}
	if c.port != nil {
		uart.write_string(c.port, "\b \b")
	}
}

// -- Input -------------------------------------------------------------------

/*
cons_available is the condition a parked reader waits on, and the reason it is a
procedure rather than a flag. See `kernel/sync/rendez.odin`.

An end of file counts as something to find. A reader parked through a `^D` that
went on waiting would wait for bytes the typist already said will not come.
*/
cons_available :: proc "contextless" (c: ^Cons) -> bool {
	if intrinsics.volatile_load(&c.head) != intrinsics.volatile_load(&c.tail) {
		return true
	}
	return intrinsics.volatile_load(&c.eofs) > 0
}

/*
cons_take_eof consumes one end-of-file mark, and only when the ring is empty.

The ordering is the whole of it. An end of file is something a reader *reaches*,
so it must never overtake bytes that were typed before the `^D`. A caller
therefore drains first and asks this second, which is what `devfs_read` does.
*/
cons_take_eof :: proc "contextless" (c: ^Cons) -> bool {
	g := sync.acquire(&c.lock)
	defer sync.release(&c.lock, g)

	if c.head != c.tail || c.eofs <= 0 {
		return false
	}
	c.eofs -= 1
	return true
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
ring_push puts one byte in the ring and reports whether it fit.

The producer's half. A full ring drops the byte and counts it. The thread that
runs this becomes an interrupt handler, and an interrupt handler has nowhere to
wait. A driver that blocks its producer to keep a byte is a driver
that stops the machine to keep a byte.

Caller holds `lock`.
*/
@(private = "file")
ring_push :: proc "contextless" (c: ^Cons, b: u8) -> bool #no_bounds_check {
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
What a fed byte asks the caller to draw.

The line discipline runs inside `lock` and the echo cannot. A glyph blit takes
`out`, which parks, and a spinlock forbids that. So the decision comes out of
the locked part as one of these, and `cons_feed` acts on it with the lock down.

`Erase` is not `Show` with a backspace in it, because the two sinks erase
differently. See `cons_erase`.
*/
@(private = "file")
Echo :: enum u8 {
	Nothing,
	Show, // Draw the byte in `echo_byte`
	Erase, // Take the last character back
	Newline, // Start a fresh line, with nothing taken back
}

/*
cons_feed delivers one byte into the input path, as a keystroke does.

The device's input path with the hardware taken out of it, which is exactly what
a self-test needs. A check that a read parks and then finishes has to be the
thing that finishes it, and it cannot type at a serial port.

It is not a test-only entry point. The day there is a keyboard driver, this is
what it calls.

Reports whether the byte changed anything. False is a character the line had no
room for, or a byte that arrived at a full ring. Neither is an error a keyboard
can do anything about, and both are counted.

**The wake-up is outside the lock and after the echo**, which costs a typist
nothing and buys the ordering a reader wants. A reader woken first would run
while the echo of its own byte is still going to the screen, and the two writes
would interleave.
*/
cons_feed :: proc "contextless" (c: ^Cons, b: u8) -> bool {
	if c == nil {
		return false
	}

	b := b
	if b == '\r' {
		b = '\n'
	}

	echo, shown, ok, woke := cons_accept(c, b)

	switch echo {
	case .Nothing:
	case .Show:
		one := [1]u8{shown}
		_ = cons_write(c, one[:])
	case .Erase:
		cons_erase(c)
	case .Newline:
		_ = cons_write(c, transmute([]u8)string("\n"))
	}

	if woke {
		sync.wakeup(&c.ready)
	}
	return ok
}

/*
cons_accept is the line discipline, and the whole of it runs under `lock`.

Reports what the caller must echo, whether the byte changed anything, and
whether a reader now has something to find. Nothing in here draws, writes to a
port or parks, because all three are forbidden inside a spinlock.

Raw mode is the first branch and it is the short one. Every byte goes to the
ring as it arrives and none of the control characters mean anything. A raw
reader gets what a raw reader asked for.
*/
@(private = "file")
cons_accept :: proc "contextless" (
	c: ^Cons,
	b: u8,
) -> (
	echo: Echo,
	shown: u8,
	ok: bool,
	woke: bool,
) #no_bounds_check {
	g := sync.acquire(&c.lock)
	defer sync.release(&c.lock, g)

	if c.mode == .Raw {
		if !ring_push(c, b) {
			return .Nothing, 0, false, false
		}
		return c.echo ? .Show : .Nothing, b, true, true
	}

	switch b {
	case BACKSPACE, DEL:
		if c.edit_len == 0 {
			// Nothing left to take back. A backspace at the start of a line
			// must not erase the prompt somebody else wrote.
			return .Nothing, 0, false, false
		}
		c.edit_len -= 1
		c.erased += 1
		return c.echo ? .Erase : .Nothing, 0, true, false

	case CTRL_U:
		if c.edit_len == 0 {
			return .Nothing, 0, false, false
		}
		c.edit_len = 0
		c.killed += 1
		// A fresh line rather than a full erase. Erasing one cell at a time
		// would be one `out` acquisition per character. A kill is also a
		// deliberate abandonment, and seeing where the old line stopped is
		// better feedback.
		return c.echo ? .Newline : .Nothing, 0, true, false

	case '\n':
		if c.edit_len >= CONS_LINE_BYTES {
			// The newline itself has to fit, and the refusal below kept the
			// line one short of the array for exactly this.
			return .Nothing, 0, false, false
		}
		c.edit[c.edit_len] = '\n'
		c.edit_len += 1
		sent := edit_flush(c)
		return c.echo ? .Show : .Nothing, '\n', sent, sent

	case CTRL_D:
		if c.edit_len == 0 {
			/*
			An end of file, and the one place a read of `/dev/cons` may answer
			with nothing.

			`^D` on a line with characters on it sends those characters and no newline.
			That is how a reader gets a line nobody ended. On
			an empty line there is nothing to send, and the only remaining
			meaning is `there will be no more`.
			*/
			c.eofs += 1
			return .Nothing, 0, true, true
		}
		sent := edit_flush(c)
		return .Nothing, 0, sent, sent
	}

	if b < 0x20 {
		// Every other control character is refused rather than stored. A line
		// discipline that puts a bell or a form feed in the buffer hands a
		// reader a byte it has no way to interpret.
		return .Nothing, 0, false, false
	}

	if c.edit_len >= CONS_LINE_BYTES - 1 {
		// One short of the array, so a newline always has somewhere to go. A
		// line that could fill completely would be a line Enter could not end.
		c.refused += 1
		return .Nothing, 0, false, false
	}
	c.edit[c.edit_len] = b
	c.edit_len += 1
	return c.echo ? .Show : .Nothing, b, true, false
}

/*
edit_flush moves the line under construction into the ring, and reports whether
all of it fit.

A line that does not fit is dropped whole rather than in part. Half a command
line is worse than none: a reader cannot tell it from a line the user meant, and
a shell would run it. The ring holds two full lines by construction, so this
only happens to a reader that stopped reading.

Caller holds `lock`.
*/
@(private = "file")
edit_flush :: proc "contextless" (c: ^Cons) -> bool #no_bounds_check {
	if c.edit_len == 0 {
		return false
	}
	if int(c.head - c.tail) + c.edit_len > CONS_INPUT_BYTES {
		c.dropped += u64(c.edit_len)
		c.edit_len = 0
		return false
	}

	for i in 0 ..< c.edit_len {
		c.ring[c.head & RING_MASK] = c.edit[i]
		c.head += 1
		c.typed += 1
	}
	c.edit_len = 0
	c.lines += 1
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
