/*
The byte ring a server keeps between a key's arrival and the read that
takes it.

Three servers share one shape: a proc parked on a device, and a proc of
threads that serves what arrives. The bytes cross between them on a
channel, and this ring is where the serving proc keeps them until a read
asks: the thread that receives the channel pushes, and the handler
drains. The counters are monotonic and the difference is the content, so
full and empty cannot be confused.

Both ends are lockless. The ring once had a lock on its consumer end, for
the worker processes `serve_mux` forked; every drainer is a thread of one
proc now, and a thread runs until it blocks. The volatile stores stay,
because the ring is also correct with a producer in another proc, which
is how the servers used it before `sys/libthread`.
*/
package libuser

import "base:intrinsics"

// Ring is the storage's frame: a slice of the program's own static
// buffer, and the two counters. Built before the fork, so both halves
// hold the same slice.
Ring :: struct {
	buf:  []u8,
	head: u64,
	tail: u64,
}

// ring_push is the producer's half: byte first, then the counter, so
// the consumer never reads a seat the byte has not taken. A full ring
// drops the byte -- a stream nobody serves is not a place to park a
// device behind.
ring_push :: proc "contextless" (r: ^Ring, b: u8) #no_bounds_check {
	h := intrinsics.volatile_load(&r.head)
	t := intrinsics.volatile_load(&r.tail)
	if h - t >= u64(len(r.buf)) {
		return
	}
	r.buf[h % u64(len(r.buf))] = b
	intrinsics.volatile_store(&r.head, h + 1)
}

// ring_drain is the consumer's half: read the producer's counter once,
// take what it covers, then publish the new tail.
ring_drain :: proc "contextless" (r: ^Ring, out: []u8) -> int #no_bounds_check {
	t := intrinsics.volatile_load(&r.tail)
	h := intrinsics.volatile_load(&r.head)
	n := min(int(h - t), len(out))
	for i in 0 ..< n {
		out[i] = r.buf[(t + u64(i)) % u64(len(r.buf))]
	}
	intrinsics.volatile_store(&r.tail, t + u64(n))
	return n
}

/*
ring_drain_line is `ring_drain` that stops after the first `stop` byte.

**One read answers one line, which is `rio`'s rule.** `rio`'s cons drain copies
from the output point and breaks at the newline, so a program that reads gets
one line however many are queued behind it. A drain that emptied the ring would
hand a client two lines in one buffer and leave it to find the boundary, and a
client that only looked at the first would silently lose the rest.

The whole ring, less the stop byte, is what a caller gets when there is no such
byte in it -- which for a queue that only ever receives whole lines cannot
happen, and for one in raw mode is the right answer anyway.
*/
ring_drain_line :: proc "contextless" (r: ^Ring, out: []u8, stop: u8) -> int #no_bounds_check {
	t := intrinsics.volatile_load(&r.tail)
	h := intrinsics.volatile_load(&r.head)
	n := min(int(h - t), len(out))
	took := 0
	for i in 0 ..< n {
		b := r.buf[(t + u64(i)) % u64(len(r.buf))]
		out[i] = b
		took = i + 1
		if b == stop {
			break
		}
	}
	intrinsics.volatile_store(&r.tail, t + u64(took))
	return took
}

// ring_available reports the bytes waiting, for a getattr's size field.
ring_available :: proc "contextless" (r: ^Ring) -> u64 {
	return intrinsics.volatile_load(&r.head) - intrinsics.volatile_load(&r.tail)
}
