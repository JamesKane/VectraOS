/*
The pipe self-test: bytes across, parks in both directions, and two ends that
die differently.

The claims, in the order the checks make them:

  - bytes cross in order, in both directions, and wrap the ring
  - a reader with nothing to read parks, and the write is what wakes it
  - a writer with no room parks, and the read is what wakes it
  - a closed far end is EOF after the drain, and EPIPE to a writer, and both
    wake anything parked at the moment of the close
  - the ends work as chans, which is what a descriptor table holds
  - a pipe both ends of which closed gives its rings back

The park checks matter most. A pipe that polls would pass every byte-moving
check here and waste the machine. The test proves the park by watching the
helper thread *not* finish while there is nothing to do. That is the same
shape `kernel/devfs` uses for a console read.
*/
package pipe

import "base:intrinsics"

import "kernel:sched"
import "kernel:sync"
import "kernel:vfs"

Verify_Result :: struct {
	checks:        int,
	failures:      int,
	first_failure: string,
	moved:         int, // Bytes this test pushed through pipes
	parked:        int, // Helper threads observed parked before their wake
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

// How long a bounded wait spins before calling the condition failed. Fifty
// ticks is generous for a wake that should take one.
@(private = "file")
PATIENCE :: 50

@(private = "file")
wait_for :: proc "contextless" (flag: ^bool) -> bool {
	for _ in 0 ..< PATIENCE {
		if intrinsics.volatile_load(flag) {
			return true
		}
		sync.delay(1)
	}
	return intrinsics.volatile_load(flag)
}

/*
One helper thread's whole world.

The flags are the protocol: `entered` says the helper reached its blocking
call, `done` says the call returned. Between the two, the helper is either
parked or about to be, and a delay long enough for several slices settles
which.
*/
@(private = "file")
Xfer :: struct {
	p:    ^Pipe,
	end:  int,
	data: []u8,
	got:  int,
	err:  vfs.Errno,

	entered: bool,
	done:    bool,
}

@(private = "file")
read_helper :: proc "contextless" (arg: rawptr) {
	x := cast(^Xfer)arg
	intrinsics.volatile_store(&x.entered, true)
	x.got = read(x.p, x.end, x.data)
	intrinsics.volatile_store(&x.done, true)
}

@(private = "file")
write_helper :: proc "contextless" (arg: rawptr) {
	x := cast(^Xfer)arg
	intrinsics.volatile_store(&x.entered, true)
	x.got, x.err = write(x.p, x.end, x.data)
	intrinsics.volatile_store(&x.done, true)
}

verify :: proc(buf: []u8) -> Verify_Result #no_bounds_check {
	r: Verify_Result

	if !check(&r, len(buf) >= RING_SIZE + 64, "the scratch buffer is large enough") {
		return r
	}

	// -- Bytes across, both directions, and around the ring ------------------

	before := count()
	p := create()
	if !check(&r, p != nil, "a pipe can be made") {
		return r
	}
	check(&r, count() == before + 1, "and the count says so")

	hello := "nine bytes"
	n, werr := write(p, 0, transmute([]u8)hello)
	check(&r, n == len(hello) && werr == vfs.OK, "a write takes every byte when there is room")

	got := read(p, 1, buf[:64])
	check(&r, got == len(hello), "the far end reads exactly what was written")
	same := got == len(hello)
	for i in 0 ..< got {
		same = same && buf[i] == hello[i]
	}
	check(&r, same, "and the bytes are the same bytes")
	r.moved += got

	n, werr = write(p, 1, buf[:4])
	check(&r, n == 4 && werr == vfs.OK, "the other direction carries bytes too")
	check(&r, read(p, 0, buf[64:][:8]) == 4, "and they arrive")
	r.moved += 4

	// Three ring-filling laps, drained as they go, so head and tail wrap.
	laps_ok := true
	for lap in 0 ..< 3 {
		fill := buf[:RING_SIZE]
		for i in 0 ..< len(fill) {
			fill[i] = u8(lap * 31 + i)
		}
		n, werr = write(p, 0, fill)
		laps_ok = laps_ok && n == RING_SIZE && werr == vfs.OK
		drained := 0
		for drained < RING_SIZE {
			k := read(p, 1, buf[RING_SIZE:][:64])
			if k <= 0 {
				break
			}
			for i in 0 ..< k {
				laps_ok = laps_ok && buf[RING_SIZE + i] == u8(lap * 31 + drained + i)
			}
			drained += k
		}
		laps_ok = laps_ok && drained == RING_SIZE
		r.moved += drained
	}
	check(&r, laps_ok, "the ring wraps and the bytes stay in order")

	// -- A reader parks, and the write wakes it -------------------------------

	rx := Xfer {
		p    = p,
		end  = 1,
		data = buf[:16],
	}
	if check(&r, sched.spawn("pipe-reader", read_helper, &rx) != nil, "a reader thread starts") {
		check(&r, wait_for(&rx.entered), "and reaches its read")
		sync.delay(3)
		still := !intrinsics.volatile_load(&rx.done)
		check(&r, still, "an empty pipe holds the reader")
		if still {
			r.parked += 1
		}
		n, werr = write(p, 0, transmute([]u8)string("wake"))
		check(&r, n == 4 && werr == vfs.OK, "the write goes through")
		check(&r, wait_for(&rx.done), "and the reader comes back")
		check(&r, rx.got == 4, "with the bytes that woke it")
		r.moved += 4
	}

	// -- A writer parks, and the read wakes it --------------------------------

	n, werr = write(p, 0, buf[:RING_SIZE])
	check(&r, n == RING_SIZE && werr == vfs.OK, "a write of one whole ring fits")
	wx := Xfer {
		p    = p,
		end  = 0,
		data = buf[RING_SIZE:][:8],
	}
	if check(&r, sched.spawn("pipe-writer", write_helper, &wx) != nil, "a writer thread starts") {
		check(&r, wait_for(&wx.entered), "and reaches its write")
		sync.delay(3)
		still := !intrinsics.volatile_load(&wx.done)
		check(&r, still, "a full ring holds the writer")
		if still {
			r.parked += 1
		}
		drained := 0
		for drained < RING_SIZE + 8 {
			k := read(p, 1, buf[:256])
			if k <= 0 {
				break
			}
			drained += k
		}
		check(&r, wait_for(&wx.done), "the drain lets the writer finish")
		check(&r, drained == RING_SIZE + 8, "and every byte of both writes arrives")
		check(&r, wx.got == 8 && wx.err == vfs.OK, "the writer reports all eight")
		r.moved += drained
	}

	// -- Close: EOF one way, EPIPE the other, and parked threads wake ---------

	ex := Xfer {
		p    = p,
		end  = 1,
		data = buf[:16],
	}
	if check(&r, sched.spawn("pipe-eof", read_helper, &ex) != nil, "a last reader starts") {
		check(&r, wait_for(&ex.entered), "and parks on the empty pipe")
		sync.delay(2)
		close_end(p, 0)
		check(&r, wait_for(&ex.done), "closing the far end wakes it")
		check(&r, ex.got == 0, "with zero bytes, which is EOF")
	}
	check(&r, read(p, 1, buf[:8]) == 0, "EOF is final")
	n, werr = write(p, 1, buf[:8])
	check(&r, n == 0 && werr != vfs.OK, "a write toward the closed end is refused")

	// -- The ends as chans ----------------------------------------------------

	created, freed_before := stats()
	_ = created
	p2 := create()
	if check(&r, p2 != nil, "a second pipe comes up for the chan checks") {
		c0, e0 := open_end(p2, 0)
		c1, e1 := open_end(p2, 1)
		check(&r, e0 == vfs.OK && e1 == vfs.OK, "both ends attach as chans")
		if e0 == vfs.OK && e1 == vfs.OK {
			wn, we := vfs.chan_write(c0, 0, transmute([]u8)string("via chans"))
			check(&r, wn == 9 && we == vfs.OK, "a chan write crosses the pipe")
			rn, re := vfs.chan_read(c1, 0, buf[:32])
			check(&r, rn == 9 && re == vfs.OK, "and a chan read collects it")
			r.moved += rn

			vfs.chan_close(c0)
			rn, re = vfs.chan_read(c1, 0, buf[:32])
			check(&r, rn == 0 && re == vfs.OK, "a clunked far end reads as EOF")
			vfs.chan_close(c1)
		}
		_, freed_after := stats()
		check(&r, freed_after == freed_before + 1, "the second pipe's rings went back")
	}

	// The first pipe still holds one open end. Close it and the slot clears.
	close_end(p, 1)
	check(&r, count() == before, "every pipe this test made is gone")

	// An attach that names no pipe is refused, which is what keeps a fid from
	// meaning a slot's next occupant.
	_, aerr := vfs.attach(&pipes.server, "9999.0")
	check(&r, aerr != vfs.OK, "an attach naming no pipe is refused")
	_, aerr = vfs.attach(&pipes.server, "junk")
	check(&r, aerr != vfs.OK, "and so is one naming nonsense")

	sched.reap()
	return r
}
