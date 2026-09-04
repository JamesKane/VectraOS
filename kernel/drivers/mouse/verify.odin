/*
The mouse self-test: the packet on its own, and an interrupt for real.

The same two halves the keyboard's has. Decoding a packet is a pure
question about three bytes and the position before them, and is checked
on a `Mouse` of the test's own. For the interrupt path the test asks the
controller to deliver a packet as though the mouse sent it, and watches
the sink. That is 8042 command 0xD3. The live mouse's sink is swapped for a
recording one for the length of that, so the injected movement does not
reach `/dev/mouse`.
*/
package mouse

import "base:intrinsics"

import "kernel:arch"
import "kernel:sched"
import "kernel:sync"
import "vsys:libodin"

Verify_Result :: struct {
	using tally: libodin.Tally,
	decoded:     int, // Packets run through the decoder
	injected:    int, // Packets the controller delivered as though moved
}

@(private = "file")
check :: proc "contextless" (r: ^Verify_Result, ok: bool, what: string) -> bool {
	return libodin.tally(&r.tally, ok, what)
}

@(private = "file")
PATIENCE :: 20000

// packet feeds three bytes and answers what the third produced.
@(private = "file")
packet :: proc "contextless" (r: ^Verify_Result, m: ^Mouse, b0, b1, b2: u8) -> (x: int, y: int, buttons: u8, done: bool) {
	r.decoded += 1
	_, _, _, d0 := decode(m, b0)
	_, _, _, d1 := decode(m, b1)
	if d0 || d1 {
		return 0, 0, 0, false
	}
	return decode(m, b2)
}

verify :: proc() -> Verify_Result #no_bounds_check {
	r: Verify_Result
	m: Mouse
	m.w = 640
	m.h = 480
	m.x = 320
	m.y = 240

	// -- The packet ----------------------------------------------------------

	x, y, b, done := packet(&r, &m, 0x08, 10, 0)
	check(&r, done && x == 330 && y == 240 && b == 0, "a packet moves the pointer right by what it says")
	x, y, _, done = packet(&r, &m, 0x08, 0, 10)
	check(&r, done && x == 330 && y == 230, "and up on the screen when the mouse says up")
	x, y, _, done = packet(&r, &m, 0x18, 0xF6, 0)
	check(&r, done && x == 320 && y == 230, "a negative movement is the sign bit and the low byte together")
	x, y, _, done = packet(&r, &m, 0x28, 0, 0xF6)
	check(&r, done && x == 320 && y == 240, "in either axis")

	_, _, b, done = packet(&r, &m, 0x09, 0, 0)
	check(&r, done && b == 1, "the left button is 1")
	_, _, b, done = packet(&r, &m, 0x0A, 0, 0)
	check(&r, done && b == 4, "the right button is 4")
	_, _, b, done = packet(&r, &m, 0x0C, 0, 0)
	check(&r, done && b == 2, "and the middle button is 2, which is rio's order and not the packet's")

		// Two movements of -255 from 320 is past the edge, and the edge is
	// where it stops.
	_, _, _, _ = packet(&r, &m, 0x18, 0x01, 0)
	x, _, _, done = packet(&r, &m, 0x18, 0x01, 0)
	check(&r, done && x == 0, "the pointer stops at the left edge")
	x, _, _, done = packet(&r, &m, 0x08, 0x7F, 0)
	_, _, _, _ = packet(&r, &m, 0x08, 0x7F, 0)
	_, _, _, _ = packet(&r, &m, 0x08, 0x7F, 0)
	_, _, _, _ = packet(&r, &m, 0x08, 0x7F, 0)
	_, _, _, _ = packet(&r, &m, 0x08, 0x7F, 0)
	x, _, _, done = packet(&r, &m, 0x08, 0x7F, 0)
	check(&r, done && x == 639, "and at the right one")

	// -- Resynchronisation -----------------------------------------------------

	_, _, _, done = decode(&m, 0x05)
	check(&r, !done && m.bad == 1 && m.have == 0, "a first byte without the always-one bit is dropped and counted")
	_, _, _, done = packet(&r, &m, 0x08, 0, 0)
	check(&r, done, "and the next real packet is read whole")

	// -- The ring, which is the keyboard's ----------------------------------------

	verify_ring(&r)

	// -- The live mouse -------------------------------------------------------------

	verify_interrupt(&r)
	return r
}

@(private = "file")
verify_ring :: proc(r: ^Verify_Result) #no_bounds_check {
	m: Mouse
	for i in 0 ..< RING_BYTES {
		if !push(&m, u8(i)) {
			check(r, false, "the ring takes every byte up to its size")
			return
		}
	}
	check(r, !push(&m, 0xFF) && m.dropped == 1, "the ring refuses one more and counts it")
	ordered := true
	for i in 0 ..< RING_BYTES {
		b, ok := take(&m)
		if !ok || b != u8(i) {
			ordered = false
		}
	}
	check(r, ordered, "and hands the bytes back in order")
}

@(private = "file")
caught_x: int
@(private = "file")
caught_y: int
@(private = "file")
caught_b: u8
@(private = "file")
caught_n: int

@(private = "file")
catch_move :: proc "contextless" (x: int, y: int, buttons: u8, msec: u64) {
	_ = msec
	caught_x = x
	caught_y = y
	caught_b = buttons
	intrinsics.volatile_store(&caught_n, caught_n + 1)
}

@(private = "file")
caught_one :: proc "contextless" (arg: rawptr) -> bool {
	_ = arg
	return intrinsics.volatile_load(&caught_n) > 0
}

/*
verify_interrupt makes the controller deliver a packet nobody moved.

Three bytes through 0xD3, each an interrupt, and the decoded position
out of the sink at the end. The route is read back first. A line that
did not take is a mouse that never interrupts, and the injection would
only ever run out of patience.
*/
@(private = "file")
verify_interrupt :: proc(r: ^Verify_Result) {
	want := u8(arch.VECTOR_IRQ_BASE + MOUSE_IRQ)
	check(r, arch.irq_vector_of(MOUSE_IRQ) == want, "IRQ 12 reads back aimed at the mouse's vector")
	check(r, !arch.irq_masked(MOUSE_IRQ), "with the line unmasked")

	before := stats()
	x0, y0 := position()
	caught_n = 0
	restore := mouse.sink
	mouse.sink = catch_move
	defer mouse.sink = restore

	if !check(r, inject(0x09) && inject(5) && inject(3), "the controller accepts an injected packet") {
		return
	}
	if !check(r, watch(caught_one), "and a movement comes out the far end of the driver") {
		return
	}
	after := stats()
	r.injected = 1
	check(r, caught_x == x0 + 5 && caught_y == y0 - 3, "carrying the position the packet moved to")
	check(r, caught_b == 1, "and the button it held")
	check(r, after.interrupts >= before.interrupts + 3, "three interrupts, one per byte")
	check(r, after.dropped == before.dropped, "with nothing dropped on the way")
}

@(private = "file")
watch :: proc "contextless" (cond: sync.Condition) -> bool {
	for _ in 0 ..< PATIENCE {
		if cond(nil) {
			return true
		}
		sched.yield()
	}
	return false
}
