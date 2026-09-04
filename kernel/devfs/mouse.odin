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

**One reader.** The file is exclusive, because a pointer has one owner
and that is the draw server. A second open answers EBUSY. A machine with
no mouse answers ENXIO at the open, the way a portless machine answers
for `/dev/eia0`. A program learns at once rather than parks for ever.
*/
package devfs

import "base:intrinsics"

import "kernel:sync"

MOUSE_LINE :: 49

Mouse_File :: struct {
	lock:    sync.Spinlock,
	x:       int,
	y:       int,
	buttons: u8,
	msec:    u64,
	seq:     u64, // Movements delivered, which a read compares its own count to
	read:    u64, // The movement the last read answered
	ready:   sync.Rendez,
	present: bool,
	opens:   int,
}

// mouse_sink is what the driver calls with every decoded packet.
mouse_sink :: proc "contextless" (x: int, y: int, buttons: u8, msec: u64) {
	f := &dev_tree.mouse
	g := sync.acquire(&f.lock)
	f.x = x
	f.y = y
	f.buttons = buttons
	f.msec = msec
	f.seq += 1
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

// mouse_available is the condition a parked reader waits on.
mouse_available :: proc "contextless" (f: ^Mouse_File) -> bool {
	return intrinsics.volatile_load(&f.seq) != intrinsics.volatile_load(&f.read)
}

// mouse_line writes the latest movement as a line and marks it read.
// Answers zero when there is nothing newer than the last line.
mouse_line :: proc "contextless" (f: ^Mouse_File, out: []u8) -> int #no_bounds_check {
	if len(out) < MOUSE_LINE {
		return 0
	}
	g := sync.acquire(&f.lock)
	defer sync.release(&f.lock, g)
	if f.seq == f.read {
		return 0
	}
	f.read = f.seq
	out[0] = 'm'
	at := 1
	at = put_field(out, at, u64(f.x))
	at = put_field(out, at, u64(f.y))
	at = put_field(out, at, u64(f.buttons))
	at = put_field(out, at, f.msec)
	return at
}

// put_field is one `%11d` and the space after it.
@(private = "file")
put_field :: proc "contextless" (out: []u8, at: int, v: u64) -> int #no_bounds_check {
	digits: [20]u8
	n := 0
	v := v
	for {
		digits[n] = '0' + u8(v % 10)
		n += 1
		v /= 10
		if v == 0 {
			break
		}
	}
	p := at
	for _ in n ..< 11 {
		out[p] = ' '
		p += 1
	}
	for n > 0 {
		n -= 1
		out[p] = digits[n]
		p += 1
	}
	out[p] = ' '
	return p + 1
}
