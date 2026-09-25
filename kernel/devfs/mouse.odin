/*
`/dev/mouse`: the pointer, as `rio`'s line.

    m 312 200 1 48213

An `m`, the position, the buttons as a bit per button, and the tick, in
the fixed widths Plan 9's `/dev/mouse` uses. A line is always 49 bytes.
A read parks until the mouse moves or a button changes since the last
line it answered, and answers one line. The driver in
`kernel/drivers/mouse` keeps the position and delivers a movement to
`mouse_sink` here. This file keeps the latest one and a count of them,
and a read is behind when its count is.

**A button change is queued, and a movement is not.** A movement the
reader missed is overtaken by the next, and only the latest position
matters. A press is different. When a press and its release both land
before the reader comes back, the latest state is the release, and the
click never happened.

So each change of the buttons also goes on a queue of `MOUSE_QUEUE`, and a
read answers the oldest queued change first. A full queue takes no more
until a read drains one, as 9front's `devmouse.c` does. The draw server,
busy with a large paint, lost clicks this way in one self-test boot of
three.

**One reader.** The file is exclusive, because a pointer has one owner
and that is the draw server. A second open answers EBUSY. A machine with
no mouse answers ENXIO at the open, the way a portless machine answers
for `/dev/eia0`. A program learns at once rather than parks for ever.
*/
package devfs

import "base:intrinsics"

import "kernel:sync"
import "vsys:libodin"

MOUSE_LINE :: 49

// Button changes kept for a reader that fell behind. 9front keeps sixteen.
MOUSE_QUEUE :: 16

Mouse_State :: struct {
	x, y:    int,
	buttons: u8,
	msec:    u64,
}

Mouse_File :: struct {
	lock:    sync.Spinlock,
	x:       int,
	y:       int,
	buttons: u8,
	msec:    u64,
	seq:     u64, // Movements delivered, which a read compares its own count to
	read:    u64, // The movement the last read answered
	// Button changes not yet read, oldest at `qr`. The counts only grow,
	// and an entry is `queue[i % MOUSE_QUEUE]`.
	queue:   [MOUSE_QUEUE]Mouse_State,
	qr:      u64,
	qw:      u64,
	lost:    u64, // Button changes a full queue refused
	ready:   sync.Rendez,
	present: bool,
	opens:   int,
}

// mouse_sink is what the driver calls with every decoded packet.
mouse_sink :: proc "contextless" (x: int, y: int, buttons: u8, msec: u64) {
	f := &dev_tree.mouse
	g := sync.acquire(&f.lock)
	changed := buttons != f.buttons
	f.x = x
	f.y = y
	f.buttons = buttons
	f.msec = msec
	f.seq += 1
	if changed {
		if f.qw - f.qr < MOUSE_QUEUE {
			f.queue[f.qw % MOUSE_QUEUE] = Mouse_State{x = x, y = y, buttons = buttons, msec = msec}
			f.qw += 1
		} else {
			f.lost += 1
		}
	}
	sync.release(&f.lock, g)
	sync.wakeup(&f.ready)
}

// mouse_present says the driver came up, which is what makes the file
// openable. Set once at boot.
mouse_present :: proc "contextless" (x: int, y: int) {
	f := &dev_tree.mouse
	f.x = x
	f.y = y
	f.present = true
}

// mouse_forget drops the button changes nobody read, at an open. A new owner
// of the pointer hears only what happens after it took it, as in 9front.
mouse_forget :: proc "contextless" (f: ^Mouse_File) {
	g := sync.acquire(&f.lock)
	f.qr = f.qw
	sync.release(&f.lock, g)
}

// mouse_available is the condition a parked reader waits on.
mouse_available :: proc "contextless" (f: ^Mouse_File) -> bool {
	return intrinsics.volatile_load(&f.seq) != intrinsics.volatile_load(&f.read) ||
		intrinsics.volatile_load(&f.qw) != intrinsics.volatile_load(&f.qr)
}

// mouse_line writes the oldest queued button change as a line, or else the
// latest movement, and marks it read. Answers zero when there is nothing
// newer than the last line.
mouse_line :: proc "contextless" (f: ^Mouse_File, out: []u8) -> int #no_bounds_check {
	if len(out) < MOUSE_LINE {
		return 0
	}
	g := sync.acquire(&f.lock)
	defer sync.release(&f.lock, g)
	m: Mouse_State
	if f.qr != f.qw {
		m = f.queue[f.qr % MOUSE_QUEUE]
		f.qr += 1
		// The last change read is the latest state, so the reader is not
		// behind on movement either.
		if f.qr == f.qw && m.buttons == f.buttons && m.x == f.x && m.y == f.y {
			f.read = f.seq
		}
	} else if f.seq != f.read {
		m = Mouse_State{x = f.x, y = f.y, buttons = f.buttons, msec = f.msec}
		f.read = f.seq
	} else {
		return 0
	}
	sink := libodin.sink_from(out)
	libodin.put_byte(&sink, 'm')
	put_field(&sink, u64(m.x))
	put_field(&sink, u64(m.y))
	put_field(&sink, u64(m.buttons))
	put_field(&sink, m.msec)
	return len(libodin.str(&sink))
}

// put_field is one `%11d` and the space after it. `libodin.put_uint` pads
// with zeroes, so the blanks are counted here.
@(private = "file")
put_field :: proc "contextless" (sink: ^libodin.Sink, v: u64) {
	digits := 1
	for rest := v; rest >= 10; rest /= 10 {
		digits += 1
	}
	libodin.put_pad(sink, ' ', 11 - digits)
	libodin.put_uint(sink, v)
	libodin.put_byte(sink, ' ')
}
