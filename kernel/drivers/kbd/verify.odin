/*
The keyboard self-test: a state machine on its own, and an interrupt for real.

Two halves, and the split is the same one the driver has.

**The translation is a pure question** and is checked on a `Keyboard` of the
test's own. What a scancode produces depends on the code and the modifier state
and nothing else. A check for it needs no hardware, no interrupt and no thread. That is what makes the awkward cases -- caps lock over digits, control
over a letter, the extended prefix -- cheap enough to check exhaustively.

**The interrupt path cannot be checked that way, and is checked anyway.** 8042
command 0xD2 asks the controller to deliver a byte as though somebody typed it,
which raises IRQ 1 exactly as a keystroke does. Everything after the key itself
is then real: the routed line, the vector, the handler, the ring, the wake, the
thread. A check that had to be typed at is a check nobody runs.

The live keyboard's sink is swapped for a recording one for the length of that,
and put back. Otherwise the injected byte lands on `/dev/cons` and the boot log
grows a character nobody typed.
*/
package kbd

import "base:intrinsics"

import "kernel:arch"
import "kernel:sched"
import "kernel:sync"

Verify_Result :: struct {
	checks:        int,
	failures:      int,
	first_failure: string,
	translated:    int, // Scancodes run through the state machine
	injected:      int, // Bytes the controller delivered as though typed
	vector:        int, // What IRQ 1 is routed to
}

@(private = "file")
check :: proc "contextless" (r: ^Verify_Result, ok: bool, what: string) -> bool {
	r.checks += 1
	if !ok {
		r.failures += 1
		if r.first_failure == "" {
			r.first_failure = what
		}
	}
	return ok
}

// Scancode set 1 make codes this test names rather than spells as hex.
@(private = "file")
SC_A :: u8(0x1E)
@(private = "file")
SC_D :: u8(0x20)
@(private = "file")
SC_U :: u8(0x16)
@(private = "file")
SC_2 :: u8(0x03)
@(private = "file")
SC_ENTER :: u8(0x1C)
@(private = "file")
SC_BACKSPACE :: u8(0x0E)
@(private = "file")
SC_TAB :: u8(0x0F)
@(private = "file")
SC_F1 :: u8(0x3B) // A key with no character on it

/*
How many yields the boot thread spends waiting for the bottom half.

**Yields rather than ticks, and a control is what taught that.** A bound
measured in `sync.delay` is not a bound when the failure being tested stops the
clock. Remove the EOI from this driver's top half and the LAPIC delivers
nothing further at or below that priority, the timer included. A tick-bounded
wait then waits forever, and the boot prints nothing from that point on.

`docs/TESTING.md` records that exact failure twice already, in two other
subsystems. This is the third, and the first where the check itself was the
thing measuring in the units the bug destroys.

A yield is a software interrupt. It executes rather than arriving, so it works
after the APIC stops delivering, and it still lets the bottom half run before
that.
*/
@(private = "file")
PATIENCE :: 20000

/*
typed runs one scancode through the state machine and reports what came out.

`produced` false means the scancode makes no byte, which is the common case:
every release, every modifier, and every position with no character on it.
*/
@(private = "file")
typed :: proc "contextless" (r: ^Verify_Result, k: ^Keyboard, code: u8) -> (u8, bool) {
	r.translated += 1
	return step(k, code)
}

// pressed is the make and the break together, which is what a key actually
// sends. The byte comes from the make, and the break must add nothing.
@(private = "file")
pressed :: proc "contextless" (r: ^Verify_Result, k: ^Keyboard, code: u8) -> (u8, bool) {
	b, ok := typed(r, k, code)
	_, up := typed(r, k, code | 0x80)
	if up {
		return 0, false
	}
	return b, ok
}

verify :: proc() -> Verify_Result #no_bounds_check {
	r: Verify_Result
	k: Keyboard

	// -- Plain keys ----------------------------------------------------------

	b, ok := pressed(&r, &k, SC_A)
	check(&r, ok && b == 'a', "a key produces its letter")
	b, ok = pressed(&r, &k, SC_2)
	check(&r, ok && b == '2', "and a digit its digit")

	_, ok = typed(&r, &k, SC_A | 0x80)
	check(&r, !ok, "a release on its own produces nothing")
	_, ok = pressed(&r, &k, SC_F1)
	check(&r, !ok, "and neither does a key with no character on it")

	b, ok = pressed(&r, &k, SC_ENTER)
	check(&r, ok && b == '\n', "enter is a newline")
	b, ok = pressed(&r, &k, SC_BACKSPACE)
	check(&r, ok && b == '\b', "backspace is one, which the line discipline erases with")
	b, ok = pressed(&r, &k, SC_TAB)
	check(&r, ok && b == '\t', "and tab is a tab")

	// -- Shift ---------------------------------------------------------------

	_, ok = typed(&r, &k, SC_LSHIFT)
	check(&r, !ok, "shift down produces nothing itself")
	check(&r, k.shift, "and is held")

	b, ok = pressed(&r, &k, SC_A)
	check(&r, ok && b == 'A', "a letter under shift is upper case")
	b, ok = pressed(&r, &k, SC_2)
	check(&r, ok && b == '@', "and a digit is the symbol above it, which no rule predicts")

	_, ok = typed(&r, &k, SC_LSHIFT | 0x80)
	check(&r, !k.shift, "shift up releases it")
	b, ok = pressed(&r, &k, SC_A)
	check(&r, ok && b == 'a', "and the next letter is lower case again")

	// -- Caps lock, which is not another shift -------------------------------

	_, ok = pressed(&r, &k, SC_CAPS)
	check(&r, k.caps, "caps lock latches on the press")

	b, ok = pressed(&r, &k, SC_A)
	check(&r, ok && b == 'A', "and a letter under it is upper case")
	b, ok = pressed(&r, &k, SC_2)
	check(&r, ok && b == '2', "a digit under it is unchanged, which is what makes it not a shift")

	_, ok = typed(&r, &k, SC_LSHIFT)
	b, ok = pressed(&r, &k, SC_A)
	check(&r, ok && b == 'a', "and shift under caps lock is lower case, as a keyboard does")
	_, ok = typed(&r, &k, SC_LSHIFT | 0x80)

	_, ok = pressed(&r, &k, SC_CAPS)
	check(&r, !k.caps, "a second press latches it off")

	// -- Control -------------------------------------------------------------

	_, ok = typed(&r, &k, SC_CTRL)
	b, ok = pressed(&r, &k, SC_D)
	check(&r, ok && b == 4, "control and D is the end of transmission")
	b, ok = pressed(&r, &k, SC_U)
	check(&r, ok && b == 21, "control and U is the kill")
	_, ok = pressed(&r, &k, SC_2)
	check(&r, !ok, "control and a digit is nothing, rather than a byte nobody meant")
	_, ok = typed(&r, &k, SC_CTRL | 0x80)

	b, ok = pressed(&r, &k, SC_D)
	check(&r, ok && b == 'd', "and the letter comes back once control is released")

	// -- The extended prefix -------------------------------------------------

	_, ok = typed(&r, &k, SC_EXTENDED)
	check(&r, !ok && k.extended, "the extended prefix is swallowed and remembered")
	_, ok = pressed(&r, &k, SC_ENTER)
	check(&r, !ok, "and the key after it produces nothing, so an arrow types no letter")
	check(&r, !k.extended, "the prefix applies to one key only")
	b, ok = pressed(&r, &k, SC_ENTER)
	check(&r, ok && b == '\n', "and the next ordinary key is ordinary again")

	// -- The ring ------------------------------------------------------------

	verify_ring(&r)

	// -- The live keyboard ---------------------------------------------------

	verify_route(&r)
	verify_interrupt(&r)
	return r
}

/*
verify_ring fills the ring past its end and drains it.

A dropped scancode is a key that did nothing, which is the least bad thing an
interrupt handler with a full ring can do. The check is that it drops rather
than overruns, and that the bytes that did fit come back in order.
*/
@(private = "file")
verify_ring :: proc(r: ^Verify_Result) #no_bounds_check {
	k: Keyboard

	for i in 0 ..< RING_BYTES {
		if !push(&k, u8(i)) {
			check(r, false, "the ring takes every scancode up to its size")
			return
		}
	}
	check(r, k.scancodes == RING_BYTES, "the ring takes exactly its size")
	check(r, !push(&k, 0xFF), "and refuses one more")
	check(r, k.dropped == 1, "counting what it dropped")
	check(r, k.interrupts == RING_BYTES + 1, "and what it was asked for")

	ordered := true
	for i in 0 ..< RING_BYTES {
		code, ok := take(&k)
		if !ok || code != u8(i) {
			ordered = false
		}
	}
	check(r, ordered, "and hands the scancodes back in the order they arrived")

	_, empty := take(&k)
	check(r, !empty, "an empty ring hands back nothing")
	check(r, push(&k, 1), "and takes a scancode again once it has drained")
}

/*
verify_route reads the redirection entry back.

A route that did not take is a keyboard that never interrupts. Nothing else
here would notice until the injection below ran out of patience. Reading the entry
says which of the two went wrong.
*/
@(private = "file")
verify_route :: proc(r: ^Verify_Result) {
	want := u8(arch.VECTOR_IRQ_BASE + KBD_IRQ)
	r.vector = int(want)

	check(r, arch.irq_attached(), "the I/O APIC is attached")
	check(r, arch.irq_vector_of(KBD_IRQ) == want, "and IRQ 1 reads back aimed at the keyboard's vector")
	check(r, !arch.irq_masked(KBD_IRQ), "with the line unmasked")
	check(r, kbd.sink != nil, "and the driver has somewhere to put a byte")
}

/*
The recording sink, and the state the injection check watches.

A byte that arrives came the whole way. The controller raised the line and the
I/O APIC delivered it to a vector. The handler put it in the ring, and the
bottom half woke, translated and delivered it.
*/
@(private = "file")
caught: [8]u8
@(private = "file")
caught_len: int

@(private = "file")
catch_byte :: proc "contextless" (b: u8) #no_bounds_check {
	if caught_len < len(caught) {
		caught[caught_len] = b
		intrinsics.volatile_store(&caught_len, caught_len + 1)
	}
}

@(private = "file")
caught_one :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&caught_len) > 0
}

@(private = "file")
caught_two :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&caught_len) > 1
}

/*
verify_interrupt makes the controller deliver a keystroke nobody typed.

The one check in this file that covers the path the driver exists for. The
translation above would pass with the line never routed and the handler never
registered, and this is what says otherwise.

The sink is swapped for a recording one and put back, so the injected byte does
not land in the boot log. The swap is safe because the bottom half is parked:
nothing reads `sink` until the injection wakes it.
*/
@(private = "file")
verify_interrupt :: proc(r: ^Verify_Result) #no_bounds_check {
	before := stats()

	caught_len = 0
	restore := kbd.sink
	kbd.sink = catch_byte
	defer kbd.sink = restore

	if !check(r, inject(SC_A), "the controller accepts an injected scancode") {
		return
	}
	if !check(r, watch(caught_one, nil), "and a byte comes out the far end of the driver") {
		return
	}

	mid := stats()
	check(r, caught[0] == 'a', "carrying the character the scancode names")
	check(r, mid.interrupts > before.interrupts, "an interrupt really did arrive")
	check(r, mid.scancodes > before.scancodes, "the handler put it in the ring")
	check(r, mid.delivered > before.delivered, "and the bottom half took it out again")

	/*
	A second key, and it is the one that says the port was read.

	The 8042 asserts its line while its output buffer is full, and does not
	re-assert for the next byte until something reads it. So a top half that
	acknowledged the APIC without reading the port passes the checks above and
	never interrupts again. One keystroke cannot tell the difference. Two can,
	and a control that made the first version of this look correct is why there
	are two.
	*/
	if !check(r, inject(SC_D), "the controller accepts a second scancode") {
		return
	}
	if !check(r, watch(caught_two, nil), "and it arrives too, so the port really was read") {
		return
	}

	after := stats()
	r.injected = caught_len
	check(r, caught[1] == 'd', "carrying its own character")
	check(r, after.interrupts >= before.interrupts + 2, "two interrupts, rather than one and a stuck line")
	check(r, after.dropped == before.dropped, "with nothing dropped on the way")
}

// watch waits for `cond` and reports whether it came true inside `PATIENCE`.
// Bounded, because a keyboard that never interrupts must fail a check rather
// than stop the boot.
@(private = "file")
watch :: proc "contextless" (cond: sync.Condition, arg: rawptr) -> bool {
	for _ in 0 ..< PATIENCE {
		if cond(arg) {
			return true
		}
		sched.yield()
	}
	return false
}
