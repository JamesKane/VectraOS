/*
The devfs self-test: the path from a name to a byte on a screen, checked.

Everything here runs against the boot namespace, over the real mount at `/dev`,
through the real transport with four workers on it. There is no fixture. A check
that passes here is a check that the machine's own `/dev/cons` passes.

Four claims, in the order they are checked:

  - `/dev` lists three devices and `/dev/cons` is one of them
  - a write to `/dev/cons` reaches the framebuffer and the serial port
  - a read of `/dev/cons` with nothing typed **parks**, and the byte that
    arrives is the byte it hands back
  - a read of `/dev/cons` with a deadline **gives up**, flushes, and reports
    EINTR

The third and fourth are the ones this milestone exists for. Everything that
waited before this file waited because a self-test told it to.

**Neither of them runs on the thread that reports.** A read that parks and is
never woken never returns, so the boot thread inside one would print nothing
from that point on. `docs/TESTING.md` calls that failure worse than a failed
check, and names two earlier occurrences of it. Both reads therefore run on a
spawned thread, watched with a bound. A thread that does not come back is a
check that fails and a boot that carries on.
*/
package devfs

import "base:intrinsics"
import "base:runtime"

import "kernel:mem"
import "kernel:sched"
import "kernel:sync"
import "kernel:vfs"
import "vsys:vectra9"

Verify_Result :: struct {
	checks:        int,
	failures:      int,
	first_failure: string,
	listed:        int, // Names `/dev` reported
	written:       int, // Bytes `/dev/cons` accepted from a write
	delivered:     int, // Bytes a parked read handed back
	parked:        u64, // Reads that found nothing and parked
	gave_up:       u64, // Ticks the read with a deadline actually took
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

/*
How long a read is given before it must give up.

Ten ticks is ten milliseconds. It is long enough that the reader is genuinely
parked when the deadline arrives, and short enough to keep the self-test brief.
*/
@(private = "file")
GIVE_UP_TICKS :: 10

// How many ticks the boot thread watches for something before it calls the
// wait a failure. Well over any of the deadlines here, so a slow machine fails
// nothing and a stuck one still reports.
@(private = "file")
PATIENCE :: 400

// How long a parked read is watched *not* returning, before the test accepts
// that it really parked. A read that answered out of an empty ring would come
// back well inside this.
@(private = "file")
SETTLE_TICKS :: 20

// The byte fed to a parked reader. Anything would do. This one is visible in a
// hex dump and is not a character a stray serial line is likely to carry.
@(private = "file")
FED_BYTE :: u8('V')

@(private = "file")
verify_context :: proc "contextless" () -> runtime.Context {
	ctx := runtime.default_context()
	ctx.allocator = mem.allocator()
	return ctx
}

// watch waits for `cond` and reports whether it came true inside `PATIENCE`.
// It bounds every wait in this file, for the reason the file comment gives.
@(private = "file")
watch :: proc "contextless" (cond: sync.Condition, arg: rawptr) -> bool {
	for _ in 0 ..< PATIENCE {
		if cond(arg) {
			return true
		}
		sync.delay(1)
	}
	return false
}

// -- The reader thread -------------------------------------------------------

/*
One read, on a thread, and everything it came back with.

`deadline` of zero is an ordinary read that waits for as long as it takes.
Anything else is `chan_read_for`, which flushes when the deadline passes.
*/
@(private = "file")
Reader :: struct {
	c:        ^vfs.Chan,
	deadline: u64,
	n:        int,
	err:      vfs.Errno,
	ticks:    u64,
	returned: bool,
	got:      [16]u8,
}

@(private = "file")
reader: Reader

@(private = "file")
reader_returned :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&reader.returned)
}

@(private = "file")
read_thread :: proc "contextless" (arg: rawptr) {
	context = verify_context()
	_ = arg

	started := sched.ticks()
	if reader.deadline == 0 {
		reader.n, reader.err = vfs.chan_read(reader.c, 0, reader.got[:])
	} else {
		reader.n, reader.err = vfs.chan_read_for(reader.c, 0, reader.got[:], reader.deadline)
	}
	reader.ticks = sched.ticks() - started

	intrinsics.volatile_store(&reader.returned, true)
}

// start_read puts one read on a thread and reports whether the thread started.
@(private = "file")
start_read :: proc(c: ^vfs.Chan, deadline: u64) -> bool {
	reader = Reader {
		c        = c,
		deadline = deadline,
	}
	return sched.spawn("devfs-read", read_thread, nil) != nil
}

// -- The test ----------------------------------------------------------------

/*
verify runs every check and reports what failed.

`buf` is the caller's scratch, and a directory listing is the largest thing that
goes in it. A few hundred bytes is enough. It is borrowed for the length of the
call and nothing here keeps it.

Everything it opens it closes, so the fid count at the end is the fid count at
the start. That last check is the one that catches a handler which answered a
Tclunk and forgot the table.
*/
verify :: proc(buf: []u8) -> Verify_Result #no_bounds_check {
	r: Verify_Result
	t := &dev_tree
	ns := vfs.boot_namespace

	if !check(&r, ns != nil, "the boot namespace exists") {
		return r
	}
	fids_before := live_fids()

	/*
	Echo off for the duration.

	Nobody types the bytes this test feeds. To draw them where a cursor happens to
	be would scribble on the boot log for no gain. The write
	check below prints its own line on purpose, and that one is the proof.
	*/
	echo_before := t.cons.echo
	t.cons.echo = false
	defer t.cons.echo = echo_before

	// -- The tree ------------------------------------------------------------

	listed, cons_seen, cons_at, list_err := list_dev(ns, buf)
	r.listed = listed
	check(&r, list_err == vfs.OK, "/dev lists")
	check(&r, listed == DEV_FILES, "and reports every device in the table")
	check(&r, cons_seen == 1, "cons among them, exactly once")
	check(&r, cons_at == 0, "and first, because a listing is in table order")

	// -- /dev/cons -----------------------------------------------------------

	cons, cons_err := vfs.open_path(ns, "/dev/cons", vfs.O_RDWR)
	if !check(&r, cons_err == vfs.OK, "/dev/cons opens for reading and writing") {
		return r
	}
	defer vfs.chan_close(cons)

	check(&r, !vfs.chan_is_dir(cons), "and is a file, not a directory")
	check(&r, vfs.chan_interruptible(cons), "and a read of it can be given up on")

	attr, attr_err := vfs.chan_stat(cons)
	check(&r, attr_err == vfs.OK, "and stats")
	check(&r, attr.mode & 0o170000 == 0o020000, "as a character device")
	check(&r, attr.size == 0, "with no length, because its contents are the future")

	/*
	The one line this test prints on its own.

	It goes out through Twalk, Tlopen and Twrite, a worker thread, and the
	console driver, which is the whole path this milestone exists to build.

	Sent without its newline, and the newline sent after. That is what makes the
	claim checkable rather than asserted. A counter inside the driver goes up
	whether or not a glyph appeared. So the check is the console's own cursor: 49
	bytes written is 49 columns further along. The newline then ends
	the line for whatever logs next.
	*/
	PROOF :: "-- this line reached the screen through /dev/cons"
	written_before := t.cons.writes
	col_before := kcon_col(t)
	n, write_err := vfs.chan_write(cons, 0, transmute([]u8)string(PROOF))
	r.written = n
	check(&r, write_err == vfs.OK, "a write to /dev/cons is accepted")
	check(&r, n == len(PROOF), "and takes every byte of it")
	check(&r, t.cons.writes == written_before + u64(len(PROOF)), "and reaches the console driver")
	check(&r, len(PROOF) < t.cons.screen.cols, "the proof line fits on one console row")
	check(&r, kcon_col(t) == col_before + len(PROOF), "and every byte of it drew a glyph")
	_, _ = vfs.chan_write(cons, 0, transmute([]u8)string("\n"))

	// -- /dev/null and /dev/zero ---------------------------------------------

	null, null_err := vfs.open_path(ns, "/dev/null", vfs.O_RDWR)
	if check(&r, null_err == vfs.OK, "/dev/null opens") {
		nn, ne := vfs.chan_write(null, 0, transmute([]u8)string(PROOF))
		check(&r, ne == vfs.OK && nn == len(PROOF), "and swallows a write whole")
		nn, ne = vfs.chan_read(null, 0, buf[:16])
		check(&r, ne == vfs.OK && nn == 0, "and is at the end of the file when read")
		vfs.chan_close(null)
	}

	zero, zero_err := vfs.open_path(ns, "/dev/zero", vfs.O_RDONLY)
	if check(&r, zero_err == vfs.OK, "/dev/zero opens") {
		for i in 0 ..< 32 {
			buf[i] = 0xFF
		}
		zn, ze := vfs.chan_read(zero, 0, buf[:32])
		clean := ze == vfs.OK && zn == 32
		for i in 0 ..< zn {
			if buf[i] != 0 {
				clean = false
			}
		}
		check(&r, clean, "and reads zeroes over whatever was in the buffer")
		vfs.chan_close(zero)
	}

	// -- What a directory refuses --------------------------------------------

	dev, dev_err := vfs.resolve(ns, "/dev")
	if check(&r, dev_err == vfs.OK, "/dev resolves") {
		check(&r, vfs.chan_open(dev, vfs.O_WRONLY) == vectra9.EISDIR, "and refuses to open for writing")
		if vfs.chan_open(dev, vfs.O_RDONLY) == vfs.OK {
			_, de := vfs.chan_read(dev, 0, buf[:16])
			check(&r, de == vectra9.EISDIR, "and refuses a plain read, which is Treaddir's job")
		}
		vfs.chan_close(dev)
	}

	// -- A read that parks, and the byte that ends it ------------------------

	verify_parked_read(&r, cons)

	// -- A read that gives up ------------------------------------------------

	verify_give_up(&r, cons)

	// -- Nothing left behind -------------------------------------------------

	r.parked = t.cons.blocks
	check(&r, t.cons.dropped == 0, "no typed byte was dropped for want of ring")
	check(&r, !cons_available(&t.cons), "and the ring is empty again")

	// One fid is still out, and it is the `cons` chan this frame holds. The
	// deferred close above releases it after this check runs, which is why the
	// count is one rather than zero.
	check(&r, live_fids() == fids_before + 1, "every fid this test opened came back")
	return r
}

/*
verify_parked_read is the check this milestone is for.

Three facts, and only the first two are interesting. A read of an empty console
does not answer. It stays unanswered for `SETTLE_TICKS`, which is what
distinguishes a parked read from a slow one. And the byte fed to the device
afterwards is the byte the read hands back.

The ring is drained first. Anything typed at the serial port during the boot
would otherwise finish this read before it ever parked. The check would then
pass without testing anything.
*/
@(private = "file")
verify_parked_read :: proc(r: ^Verify_Result, cons: ^vfs.Chan) #no_bounds_check {
	t := &dev_tree

	drain: [CONS_INPUT_BYTES]u8
	_ = cons_take(&t.cons, drain[:])
	blocked_before := t.cons.blocks

	if !check(r, start_read(cons, 0), "a thread to do the reading") {
		return
	}

	// It has to still be in there. `watch` is the wrong tool: this waits for
	// something *not* to happen, so the loop is the check rather than a bound
	// on one.
	still_in := true
	for _ in 0 ..< SETTLE_TICKS {
		sync.delay(1)
		if intrinsics.volatile_load(&reader.returned) {
			still_in = false
			break
		}
	}
	check(r, still_in, "a read of an empty console does not answer")
	check(r, t.cons.blocks > blocked_before, "and parks, rather than spins")

	check(r, cons_feed(&t.cons, FED_BYTE), "a byte arrives at the device")
	if !check(r, watch(reader_returned, nil), "and the parked read comes back") {
		return
	}

	check(r, reader.err == vfs.OK, "with no error")
	check(r, reader.n == 1, "and exactly the one byte there was")
	r.delivered = reader.n
	check(r, reader.n == 1 && reader.got[0] == FED_BYTE, "and it is the byte that was fed")
}

/*
verify_give_up is `Tflush` reached from a path, against a device rather than
against a server built to be flushed.

`kernel/verify_flush.odin` proves the ordering rule with a server whose only
purpose is to not finish. This proves the same machinery in the place it is
for. A real driver, waiting on real hardware, and a caller that will not wait
for ever.

The last check is the one worth keeping. A give-up that left the handler parked,
or that poisoned the session, would read normally exactly once more and then
never again. So the same fid reads again afterwards, and it is fed a byte to
prove it.
*/
@(private = "file")
verify_give_up :: proc(r: ^Verify_Result, cons: ^vfs.Chan) #no_bounds_check {
	t := &dev_tree

	drain: [CONS_INPUT_BYTES]u8
	_ = cons_take(&t.cons, drain[:])

	if !check(r, start_read(cons, GIVE_UP_TICKS), "a thread to do the giving up") {
		return
	}
	if !check(r, watch(reader_returned, nil), "a read that outlives its deadline comes back at all") {
		// It is still inside the handler. Feed it, or the checks below run
		// against a device with a thread parked in it.
		_ = cons_feed(&t.cons, FED_BYTE)
		_ = watch(reader_returned, nil)
		return
	}

	r.gave_up = reader.ticks
	check(r, reader.err == vectra9.EINTR, "and reports EINTR")
	check(r, reader.n == 0, "and hands back no bytes it did not get")
	check(r, reader.ticks >= GIVE_UP_TICKS, "after waiting the deadline it was given")

	// The connection is still a connection. Feed first, so this read finds a
	// byte waiting and cannot park.
	_ = cons_feed(&t.cons, FED_BYTE)
	got: [4]u8
	n, e := vfs.chan_read(cons, 0, got[:])
	check(r, e == vfs.OK && n == 1 && got[0] == FED_BYTE, "and the same fid reads normally afterwards")
}

// -- Helpers -----------------------------------------------------------------

// kcon_col is where the console's cursor is. The one observable a self-test has
// that a byte reached the screen rather than only reached a counter.
@(private = "file")
kcon_col :: proc "contextless" (t: ^Dev_Tree) -> int {
	return t.cons.screen == nil ? -1 : t.cons.screen.col
}

// A listing that would not end is a listing this bound ends. A server that
// returned the same cookie twice would otherwise spin here rather than fail.
@(private = "file")
MAX_LISTING_PASSES :: 8

@(private = "file")
list_dev :: proc(
	ns: ^vfs.Namespace,
	buf: []u8,
) -> (
	total: int,
	cons_seen: int,
	cons_at: int, // Position of `cons` in the listing; -1 if absent
	err: vfs.Errno,
) {
	cons_at = -1
	c: ^vfs.Chan
	c, err = vfs.open_path(ns, "/dev", vfs.O_RDONLY | vfs.O_DIRECTORY)
	if err != vfs.OK {
		return
	}
	defer vfs.chan_close(c)

	offset := u64(0)
	for _ in 0 ..< MAX_LISTING_PASSES {
		n: int
		n, err = vfs.readdir(c, offset, buf)
		if err != vfs.OK || n == 0 {
			return
		}

		cursor := vectra9.cursor_from(buf[:n])
		for {
			entry, more := vectra9.next_dirent(&cursor)
			if !more {
				break
			}
			if entry.name == "cons" {
				cons_seen += 1
				if cons_at < 0 {
					cons_at = total
				}
			}
			total += 1
			offset = entry.offset
		}
	}
	return total, cons_seen, cons_at, vectra9.ELOOP
}
