/*
virtio-input over modern PCI: the keyboard and the mouse the `virt` boards have
no PS/2 for. `docs/PORTS.md` records that those boards answer all-ones from the
8042's port and fall back to the serial line; this is what gives them the
keyboard and pointer amd64 gets from a real controller, so `Workbench` is usable
on all three architectures.

**It does not invent a second path above the drivers.** A virtio-input device
reports Linux input events -- a type, a code and a value -- and this turns them
into the shapes the existing drivers already take: a key becomes a set-1
scancode fed to `kernel/drivers/kbd`, a movement becomes a PS/2 packet fed to
`kernel/drivers/mouse`. Everything over `/dev/cons` and `/dev/mouse` -- kbdfs,
the compositor, the desktop -- is then the same on every board. Linux took its
keycodes from the set-1 scancodes, so the base block is the scancode itself and
only the keys set 1 reaches with an `0xE0` prefix need a table.

**It polls.** `kernel/drivers/virtio` has no interrupt path -- every driver here
reads its used ring -- so a thread sweeps the event queues and sleeps a tick
between. Input is human-paced, so a tick's latency is below noticing, and a
board with no such device never starts the thread.

The translation is pure and tested without a device: `key_scancodes` and
`mouse_packet` answer bytes a check reads, and `feed_event` runs one synthetic
event through the same path the poll thread does, so the plumbing to the
drivers is proven on a machine that has no virtio-input at all.
*/
package virtio

import "kernel:arch"
import "kernel:drivers/kbd"
import "kernel:drivers/mouse"
import "kernel:drivers/pci"
import "kernel:mem"
import "kernel:sched"
import "kernel:sync"

// The device id of a modern virtio input device: `0x1040` plus the type, 18.
VIRTIO_INPUT_DEVICE :: u16(0x1052)

// The one queue, for events the device writes, and the buffers on it. One
// event is eight bytes, and a queue-full of them is plenty for a keyboard.
INPUT_EVENTQ :: u16(0)
INPUT_BUFS :: int(VIRTQ_SIZE)
EVENT_SIZE :: 8

// The Linux event types and codes this driver reads. `docs` for them is
// `include/uapi/linux/input-event-codes.h`, which QEMU's device speaks.
EV_SYN :: u16(0)
EV_KEY :: u16(1)
EV_REL :: u16(2)
EV_ABS :: u16(3)
REL_X :: u16(0)
REL_Y :: u16(1)
BTN_MISC :: u16(0x100) // a key code at or above this is a button, not a key
BTN_LEFT :: u16(0x110)
BTN_RIGHT :: u16(0x111)
BTN_MIDDLE :: u16(0x112)

MAX_INPUTS :: 4
POLL_TICKS :: u64(8) // the nap between event-queue sweeps: ~8 ms at 1 kHz,
// well under human perception for a key or a move, and 1/8th the wakeups of a
// per-tick poll of a queue that is idle almost every tick.

// An event as the device writes it: a type, a code and a signed value. Packed
// and little-endian, which every architecture this runs on reads natively.
Input_Event :: struct #packed {
	type:  u16,
	code:  u16,
	value: u32,
}

Input :: struct {
	used:     bool,
	using t:  Transport,
	eq:       Virtq,
	buf_phys: [INPUT_BUFS]u64,
	buf_virt: [INPUT_BUFS]rawptr,
}

inputs: [MAX_INPUTS]Input
input_n: int

// -- The translation, pure ----------------------------------------------------

// The keys set 1 reaches with an `0xE0` prefix, by the Linux keycode that
// names each: the keypad enter and slash, the right-hand ctrl and alt, and the
// grey navigation block. Everything else in the base range is its own scancode.
@(rodata)
input_ext := [?][2]u16 {
	{96, 0x1C}, // KEY_KPENTER
	{97, 0x1D}, // KEY_RIGHTCTRL
	{98, 0x35}, // KEY_KPSLASH
	{100, 0x38}, // KEY_RIGHTALT
	{102, 0x47}, // KEY_HOME
	{103, 0x48}, // KEY_UP
	{104, 0x49}, // KEY_PAGEUP
	{105, 0x4B}, // KEY_LEFT
	{106, 0x4D}, // KEY_RIGHT
	{107, 0x4F}, // KEY_END
	{108, 0x50}, // KEY_DOWN
	{109, 0x51}, // KEY_PAGEDOWN
	{110, 0x52}, // KEY_INSERT
	{111, 0x53}, // KEY_DELETE
}

/*
key_scancodes writes the set-1 scancode bytes a Linux keycode makes -- pressed
when `down`, released otherwise -- into `out`, and answers how many. A base key
is its own code, `0x80` added for a release; an extended key is `0xE0` and then
the same. A keycode no set reaches makes nothing, which is a key the desktop
does not use.
*/
key_scancodes :: proc "contextless" (code: u16, down: bool, out: []u8) -> int #no_bounds_check {
	brk: u8 = down ? 0 : 0x80
	for e in input_ext {
		if e[0] == code {
			if len(out) < 2 {
				return 0
			}
			out[0] = 0xE0
			out[1] = u8(e[1]) | brk
			return 2
		}
	}
	if code >= 1 && code <= 0x58 {
		if len(out) < 1 {
			return 0
		}
		out[0] = u8(code) | brk
		return 1
	}
	return 0
}

/*
mouse_packet builds the three bytes of a PS/2 mouse packet from a run of
movement and the buttons held. The buttons are already in PS/2 order -- left 1,
right 2, middle 4. PS/2 counts Y up where a screen and virtio count it down, so
the sign is turned; each axis is clamped to one byte, which is a fast move cut
to what a packet can say rather than wrapped into nonsense.
*/
mouse_packet :: proc "contextless" (dx: int, dy: int, buttons: u8) -> (flags: u8, bx: u8, by: u8) {
	px := clamp(dx, -255, 255)
	py := clamp(-dy, -255, 255)
	flags = 0x08 | (buttons & 0x07)
	if px < 0 {
		flags |= 0x10
	}
	if py < 0 {
		flags |= 0x20
	}
	return flags, u8(px), u8(py)
}

// -- The accumulator, one pointer ---------------------------------------------

// A mouse speaks a packet as several events ended by a sync: the movement on
// each axis, the buttons as they change. This gathers them between syncs, and
// `mouse_flush` sends the one packet they add up to. The buttons persist across
// packets, the way the pointer's state does; the movement is spent each time.
@(private = "file") acc_dx: int
@(private = "file") acc_dy: int
@(private = "file") acc_buttons: u8
@(private = "file") acc_dirty: bool

@(private = "file")
mouse_flush :: proc "contextless" () {
	flags, bx, by := mouse_packet(acc_dx, acc_dy, acc_buttons)
	mouse.feed_packet(flags, bx, by)
	acc_dx = 0
	acc_dy = 0
	acc_dirty = false
}

@(private = "file")
key_emit :: proc "contextless" (code: u16, down: bool) #no_bounds_check {
	buf: [2]u8
	n := key_scancodes(code, down, buf[:])
	for i in 0 ..< n {
		kbd.feed(buf[i])
	}
}

/*
feed_event runs one event through the translation and into the drivers: a key
to `kbd`, a movement or a button to the pointer's accumulator, a sync to flush
it. It is the poll thread's inner step, and the seam a check drives with a
synthetic event where there is no device to make a real one.
*/
feed_event :: proc "contextless" (type: u16, code: u16, value: u32) {
	switch type {
	case EV_SYN:
		if acc_dirty {
			mouse_flush()
		}
	case EV_KEY:
		if code >= BTN_MISC {
			bit: u8
			switch code {
			case BTN_LEFT:
				bit = 0x01
			case BTN_RIGHT:
				bit = 0x02
			case BTN_MIDDLE:
				bit = 0x04
			case:
				return
			}
			if value != 0 {
				acc_buttons |= bit
			} else {
				acc_buttons &~= bit
			}
			acc_dirty = true
		} else {
			// Value 2 is autorepeat, which makes the key again; 0 releases it.
			key_emit(code, value != 0)
		}
	case EV_REL:
		switch code {
		case REL_X:
			acc_dx += int(i32(value))
			acc_dirty = true
		case REL_Y:
			acc_dy += int(i32(value))
			acc_dirty = true
		}
	case EV_ABS:
		// A tablet's absolute axes. The board's mouse is relative, so this cut
		// does not place a pointer from them.
	}
}

// -- The device ---------------------------------------------------------------

// input_attach_all brings up every virtio-input function on the bus, in bus
// order, and answers how many. It does not start the poll thread: the caller
// sets up the keyboard and mouse the events feed first, then calls
// `input_start_poll`.
input_attach_all :: proc() -> int {
	for dev in functions() {
		if dev.vendor == VIRTIO_VENDOR && dev.device == VIRTIO_INPUT_DEVICE {
			input_attach(dev.at)
		}
	}
	return input_n
}

input_attach :: proc(at: pci.Address) -> bool #no_bounds_check {
	if input_n >= MAX_INPUTS {
		return false
	}
	ip := &inputs[input_n]
	ip^ = Input {
		t = {at = at},
	}

	pci.enable(at)
	if !map_structures(&ip.t, false) {
		return false
	}

	arch.mmio_write8(ip.common, COMMON_DEVICE_STATUS, 0)
	set_status(&ip.t, STATUS_ACKNOWLEDGE)
	set_status(&ip.t, STATUS_DRIVER)

	// Nothing in word 0 is wanted; the device is modern, and that is word 1.
	if !negotiate(&ip.t, 0, VIRTIO_F_VERSION_1) {
		fail(ip)
		return false
	}

	if !setup_queue(&ip.t, INPUT_EVENTQ, &ip.eq) {
		fail(ip)
		return false
	}
	if !input_setup_buffers(ip) {
		fail(ip)
		return false
	}

	set_status(&ip.t, STATUS_DRIVER_OK)
	input_post_all(ip)

	ip.used = true
	input_n += 1
	return true
}

// input_setup_buffers carves one page into the event buffers, eight bytes
// apiece, which a queue-full of descriptors point into.
@(private = "file")
input_setup_buffers :: proc "contextless" (ip: ^Input) -> bool #no_bounds_check {
	phys, ok := mem.alloc_page_zeroed()
	if !ok {
		return false
	}
	base := mem.phys_to_virt(phys)
	for i in 0 ..< INPUT_BUFS {
		ip.buf_phys[i] = u64(phys) + u64(i * EVENT_SIZE)
		ip.buf_virt[i] = rawptr(uintptr(base) + uintptr(i * EVENT_SIZE))
	}
	return true
}

// input_post_all lays every buffer into its own descriptor, fills the available
// ring with all of them, and rings the doorbell once, so the device has
// somewhere to write every event until the driver takes one back.
@(private = "file")
input_post_all :: proc "contextless" (ip: ^Input) #no_bounds_check {
	q := &ip.eq
	for i in 0 ..< INPUT_BUFS {
		q.desc[i] = Virtq_Desc {
			addr  = ip.buf_phys[i],
			len   = u32(EVENT_SIZE),
			flags = VIRTQ_DESC_WRITE,
			next  = 0,
		}
		q.avail[2 + i] = u16(i)
	}
	q.avail_idx = u16(INPUT_BUFS)
	fence()
	q.avail[1] = q.avail_idx
	fence()
	arch.mmio_write16(q.doorbell, 0, INPUT_EVENTQ)
}

// input_start_poll starts the one thread that sweeps every device's event
// queue. A board with no virtio-input never reaches here.
input_start_poll :: proc() -> bool {
	if input_n == 0 {
		return false
	}
	return sched.spawn("virtio-input", input_poll, nil) != nil
}

@(private = "file")
input_poll :: proc "contextless" (arg: rawptr) {
	_ = arg
	for {
		for i in 0 ..< input_n {
			input_drain(&inputs[i])
		}
		sync.delay(POLL_TICKS)
	}
}

// input_drain takes every event the device has written since the last sweep,
// feeds each through the translation, and posts its buffer again.
@(private = "file")
input_drain :: proc "contextless" (ip: ^Input) #no_bounds_check {
	q := &ip.eq
	for {
		fence()
		if q.used_ring[1] == q.last_used {
			return
		}
		fence()
		head, wrote := used_elem(q)
		id := int(head)
		if id >= 0 && id < INPUT_BUFS && wrote >= EVENT_SIZE {
			ev := (^Input_Event)(ip.buf_virt[id])
			feed_event(ev.type, ev.code, ev.value)
		}
		if id >= 0 && id < INPUT_BUFS {
			kick(q, u16(id), INPUT_EVENTQ)
		}
		q.last_used += 1
	}
}
