/*
The taps: the console's input streams, served raw.

`/dev/scancode` is the keyboard before translation, and `/dev/eia0` is the
serial port's bytes before the line discipline. Plan 9 names both this way,
and its `kbdfs` is the program these files exist for. A userland driver
reads the raw stream, does its own translation, and serves the cooked
result back as files of its own. That is the whole plan for moving `devfs`
out of the kernel, and these two files are the half of it `/dev/fb` did not
cover.

## A tap diverts the stream, and the last close gives it back

While something holds `/dev/scancode` open, the kernel's own translation
sees nothing. While something holds `/dev/eia0` open, the line discipline
sees nothing from the port. That is what `a process stands where the
kernel's handler stands` has to mean. A copy of the stream would leave two
line disciplines fighting over one keyboard, and every keystroke would act
twice.

The revert on last close is `/dev/consctl`'s rule again, for the same
reason. A program that takes the keyboard and faults must not leave a
machine nobody can type at. The kernel undoes the diversion when the last
fid goes, and the program does not have to survive long enough to do it.

The bytes a closed tap never saw do not queue up for the next opener. The
ring drains on open and on close, the way a mode change discards the line
under construction. Bytes captured under rules that no longer apply belong
to nobody.

## What a tap is not

Not a `ctl` file: nothing here takes commands. Not a stream with an end:
there is no `^D`, so a read answers bytes or parks, and zero bytes never
means anything. And not a second line discipline: a tap hands over exactly
what arrived, in order, and has no opinion about any byte.

A reader that gives up is flushed out with EINTR, through the same abort
hook the console's reads use. Two readers on one tap share the ring the way
two readers of `/dev/cons` share theirs: bytes go to whoever reads first.
*/
package devfs

import "base:intrinsics"

import "kernel:sync"
import "kernel:drivers/uart"

/*
How many raw bytes survive with nobody reading.

The same figure as the console's ring, for the same shape of burst. A
scancode stream runs at twice the typing rate -- every key is a make and a
break -- and a serial paste arrives at line speed. A full ring drops the
byte and counts it. The producers here are the ones that feed the console
-- one is an interrupt handler's bottom half -- and neither can wait.
*/
TAP_BYTES :: 256
@(private = "file")
TAP_MASK :: TAP_BYTES - 1

/*
One raw stream: a ring, a gate, and somewhere for a reader to park.

`open` is the gate, and it is the tap's own copy of a fact the fid table
also knows. The fid table counts under `Dev_Tree.lock`, and the producers
feed under this lock, from threads that must not touch the fid table. The
two locks meet nowhere: the handler moves the fact across on the first
open and the last close, outside both.

`head` and `tail` are monotonic and the index is the counter masked, the
same arrangement as every other ring in the tree.
*/
Tap :: struct {
	ring: [TAP_BYTES]u8,
	head: u64,
	tail: u64,
	open: bool,
	lock: sync.Spinlock,

	// Where a reader with nothing to read parks. Woken by the producer, and
	// by the abort hook when a Tflush names the read.
	ready: sync.Rendez,

	// Counters, reported by the self-test's hand rather than the boot line.
	fed:     u64, // Bytes the producer put in the ring
	dropped: u64, // ...and bytes it could not, because the ring was full
	taken:   u64, // Bytes handed to a reader
	blocks:  u64, // Reads that found nothing and parked
}

/*
tap_start opens the gate, and from here the stream belongs to the file.

The ring is drained first. A closed tap receives nothing, so this is
defensive rather than load-bearing. But a stale byte handed to a fresh
opener would be a bug nobody could reproduce, and two stores close the
door on it.
*/
tap_start :: proc "contextless" (t: ^Tap) {
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)
	t.tail = t.head
	t.open = true
}

// tap_stop closes the gate and throws away what was captured and never
// read. Bytes typed at a program that is gone belong to nobody, and the
// console takes the stream back from silence.
tap_stop :: proc "contextless" (t: ^Tap) {
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)
	t.tail = t.head
	t.open = false
}

// tap_active reports whether the stream is diverted right now. The
// producers ask before every byte.
tap_active :: proc "contextless" (t: ^Tap) -> bool {
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)
	return t.open
}

/*
tap_feed offers one byte to the tap, and reports whether the tap owns the
stream.

**The answer is about the gate, not about the ring.** True means the file
is open and the byte belongs to it -- even a byte the full ring had to
drop. A producer that fell back to the console on a full ring would leak
one keystroke in 257 into the wrong line discipline. Nobody would ever
trace that bug.

The wake-up is outside the lock, like every producer's in this tree.
*/
tap_feed :: proc "contextless" (t: ^Tap, b: u8) -> bool #no_bounds_check {
	g := sync.acquire(&t.lock)
	if !t.open {
		sync.release(&t.lock, g)
		return false
	}
	if t.head - t.tail >= TAP_BYTES {
		t.dropped += 1
		sync.release(&t.lock, g)
		return true
	}
	t.ring[t.head & TAP_MASK] = b
	t.head += 1
	t.fed += 1
	sync.release(&t.lock, g)

	sync.wakeup(&t.ready)
	return true
}

// tap_available is the condition a parked reader waits on: two volatile
// loads and a comparison, which is all a condition may do.
tap_available :: proc "contextless" (t: ^Tap) -> bool {
	return intrinsics.volatile_load(&t.head) != intrinsics.volatile_load(&t.tail)
}

// tap_take moves what is in the ring into `buf` and reports how much. Zero
// means empty right now, which is a cue to park -- a tap has no end of
// file to confuse it with.
tap_take :: proc "contextless" (t: ^Tap, buf: []u8) -> int #no_bounds_check {
	if len(buf) == 0 {
		return 0
	}
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)

	n := 0
	for n < len(buf) && t.tail != t.head {
		buf[n] = t.ring[t.tail & TAP_MASK]
		t.tail += 1
		n += 1
	}
	t.taken += u64(n)
	return n
}

// tap_note_block counts a read that found nothing and is about to park,
// under the same lock as the ring it found empty.
tap_note_block :: proc "contextless" (t: ^Tap) {
	g := sync.acquire(&t.lock)
	t.blocks += 1
	sync.release(&t.lock, g)
}

// -- The two streams, wired to their producers --------------------------------

/*
scancode_tap is the raw hook `kernel/drivers/kbd` calls with every scancode,
before translation.

True consumes the scancode: it went to `/dev/scancode`, or to that file's
full ring, and the driver must not translate it. False means nobody holds
the file and the scancode is the driver's to translate, exactly as before
the file existed. The driver resets its own modifier state when a
diversion ends, and `kbd.odin` says why that is its job rather than this
package's.
*/
scancode_tap :: proc "contextless" (code: u8) -> bool {
	return tap_feed(&dev_tree.scancode, code)
}

/*
serial_deliver routes one byte off the port: to `/dev/eia0` if something
holds it open, to the line discipline if not.

The one call `cons_input` makes per byte, so the diversion has exactly one
seam on the serial side too.
*/
serial_deliver :: proc "contextless" (c: ^Cons, b: u8) {
	if tap_feed(&dev_tree.serial, b) {
		return
	}
	_ = cons_feed(c, b)
}

/*
eia0_write puts bytes on the wire and nowhere else.

Under `Cons.out`, because the console's writes go to the same port and two
writers interleaving inside one line would tear both. The screen is not
touched: this file is the port, and a caller that wants glyphs has
`/dev/cons`.

Always the whole count. A 16550 has no back pressure to report, only a
FIFO to wait for, and `uart.write_byte` waits.
*/
eia0_write :: proc "contextless" (t: ^Dev_Tree, data: []u8) -> int {
	c := &t.cons
	sync.mutex_lock(&c.out)
	defer sync.mutex_unlock(&c.out)

	if c.port != nil && c.port.present {
		uart.write_string(c.port, string(data))
	}
	return len(data)
}
