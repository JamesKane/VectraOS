/*
A byte ring between a top half that may not park and a bottom half that may.

The keyboard and the mouse each have one. An interrupt handler puts a byte in
and wakes a thread, and the thread takes the bytes out. `docs/KBD.md` argues
the split. This is the ring both halves meet at.

`head` and `tail` are monotonic and the index is the counter masked. That is
the same arrangement `devfs.Cons` uses, for the same reason. `head - tail` is
then the count, with no ambiguity between full and empty.

`lock` is a spinlock and may never be anything else. The producer is an
interrupt handler, and an interrupt handler cannot park.
*/
package ring

import "base:intrinsics"

import "kernel:sync"

/*
How many bytes survive with the bottom half not yet running.

A person types at ten bytes a second, and the bottom half runs at the first
opportunity after a wake. This is deep enough for a burst of key-down and
key-up pairs while something holds the console. A mouse packet is three bytes
and a burst a few packets. A full ring drops the byte and counts it,
because that is what an interrupt handler with nowhere to put a byte has to
do.
*/
BYTES :: 64
@(private = "file")
MASK :: BYTES - 1

// One ring, its lock, and the counters the top half keeps. They are
// reported at boot and checked by the self-tests.
Byte_Ring :: struct {
	data: [BYTES]u8,
	head: u64,
	tail: u64,
	lock: sync.Spinlock,

	pushed:  u64, // Times the top half ran
	stored:  u64, // Bytes it put in the ring
	dropped: u64, // ...and bytes it could not, because the ring was full
}

/*
push puts one byte in the ring and reports whether it fit.

Shared with the self-tests, which is what lets a check exercise a full ring
without pressing sixty-five keys. A full ring drops the byte and counts it,
because an interrupt handler with nowhere to put a byte has nowhere to wait
either.
*/
push :: proc "contextless" (r: ^Byte_Ring, b: u8) -> bool #no_bounds_check {
	g := sync.acquire(&r.lock)
	defer sync.release(&r.lock, g)

	r.pushed += 1
	if r.head - r.tail >= BYTES {
		r.dropped += 1
		return false
	}
	r.data[r.head & MASK] = b
	r.head += 1
	r.stored += 1
	return true
}

// take is the other half, here for the same reason `push` is. The self-test
// drains a ring it filled, and neither half is worth a second implementation.
take :: proc "contextless" (r: ^Byte_Ring) -> (b: u8, ok: bool) #no_bounds_check {
	g := sync.acquire(&r.lock)
	defer sync.release(&r.lock, g)

	if r.tail == r.head {
		return 0, false
	}
	b = r.data[r.tail & MASK]
	r.tail += 1
	return b, true
}

// pending is the bottom half's wake condition, in `sync.Condition`'s shape:
// `arg` is the ring, and the answer is whether a byte is waiting.
pending :: proc "contextless" (arg: rawptr) -> bool {
	r := cast(^Byte_Ring)arg
	return intrinsics.volatile_load(&r.head) != intrinsics.volatile_load(&r.tail)
}

// bump adds one to a counter the bottom half owns, through a volatile store,
// so a reader on another core sees the count move.
bump :: proc "contextless" (p: ^u64) {
	intrinsics.volatile_store(p, intrinsics.volatile_load(p) + 1)
}

// -- For the self-tests -----------------------------------------------------------------

// fill pushes every byte up to the size and then one more, for a self-test.
// It answers whether every byte fit and whether the one more was refused.
fill :: proc "contextless" (r: ^Byte_Ring) -> (filled, refused: bool) {
	for i in 0 ..< BYTES {
		if !push(r, u8(i)) {
			return false, false
		}
	}
	return true, !push(r, 0xFF)
}

// drain takes every byte back, then one more, then pushes one, for the same
// self-test. It answers three things. The bytes came back in the order they
// went in, the empty ring handed back nothing, and the drained ring took a byte
// again.
drain :: proc "contextless" (r: ^Byte_Ring) -> (ordered, empty, again: bool) {
	ordered = true
	for i in 0 ..< BYTES {
		b, ok := take(r)
		if !ok || b != u8(i) {
			ordered = false
		}
	}
	_, got := take(r)
	empty = !got
	again = push(r, 1)
	return ordered, empty, again
}
