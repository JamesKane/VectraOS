/*
The devfs self-test: the path from a name to a byte on a screen, checked.

Everything here runs against the boot namespace, over the real mount at `/dev`,
through the real transport with four workers on it. There is no fixture. A check
that passes here is a check that the machine's own `/dev/cons` passes.

Six claims, in the order they are checked:

  - `/dev` lists four devices and `/dev/cons` is one of them
  - a write to `/dev/cons` reaches the framebuffer and the serial port
  - a read of `/dev/cons` with nothing typed **parks**, stays parked through a
    character, and finishes on the newline after it
  - the line under construction can be edited, and `^D` ends the file
  - `/dev/consctl` moves the console to raw mode, and reads back the commands
    that would restore it
  - the **last close of `/dev/consctl` reverts the mode**, which is the property
    the whole file exists for

## Two rules this file follows, and one it bends

**Nothing blocking runs on the thread that reports.** A read that parks and is
never woken never returns. The boot thread inside one would print nothing from
that point on. `docs/TESTING.md` calls that failure worse than a failed check,
and names two earlier occurrences of it.

The two checks that mean to park therefore run on a spawned thread, watched with
a bound. A thread that does not come back is a check that fails and a boot that
carries on.

**The bend is `read_now`.** The line-editing checks read bytes that are already
in the ring, so they are not meant to park at all. They use `chan_read_for` with
a short deadline rather than a thread. A read that cannot fail to return is not
the blocking thing the rule is about. A bug that made one park comes back as
EINTR and a failed check, rather than as a hang.

**Every check leaves the console as it found it.** The mode, the echo flag and
the ring all go back. The next thing to use this console is whoever is sitting
at it.
*/
package devfs

import "base:intrinsics"
import "base:runtime"

import "kernel:drivers/console"
import "kernel:drivers/fb"
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
	lines:         u64, // Lines cooked mode sent whole
	edits:         u64, // Characters erased, plus lines killed
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

// How long a read that should not park at all is given anyway. See `read_now`.
@(private = "file")
READ_NOW_TICKS :: 20

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

/*
settled waits for the reader *not* to return, and reports whether it stayed put.

The one wait in this file that is not `watch`, because it waits for something
not to happen. The loop is the check rather than a bound on one.
*/
@(private = "file")
settled :: proc "contextless" () -> bool {
	for _ in 0 ..< SETTLE_TICKS {
		sync.delay(1)
		if intrinsics.volatile_load(&reader.returned) {
			return false
		}
	}
	return true
}

/*
read_now reads what is already there, and cannot hang if it is not.

For every check whose bytes reached the ring before the read started. The
deadline is a backstop rather than the point. A working console answers at once,
and a broken one comes back as EINTR instead of never.
*/
@(private = "file")
read_now :: proc(c: ^vfs.Chan, buf: []u8) -> (int, vfs.Errno) {
	return vfs.chan_read_for(c, 0, buf, READ_NOW_TICKS)
}

// same reports whether a read returned exactly `want`.
@(private = "file")
same :: proc "contextless" (got: []u8, n: int, want: string) -> bool #no_bounds_check {
	if n != len(want) {
		return false
	}
	for i in 0 ..< n {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}

// type_in feeds a string one byte at a time, as somebody at a keyboard would.
@(private = "file")
type_in :: proc "contextless" (c: ^Cons, text: string) {
	for i in 0 ..< len(text) {
		_ = cons_feed(c, text[i])
	}
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
	The console goes back exactly as it was found.

	Not merely tidiness. The next thing to use this console is a person at a
	keyboard. A self-test that left raw mode on would hand them one with no echo
	and no way to correct a mistake.
	*/
	mode_before, echo_before := cons_mode(&t.cons)
	defer cons_set_mode(&t.cons, mode_before, echo_before)

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
	The proof line, then the echo checks, then the newline that ends it.

	In that order on purpose, and the order is two things at once. A backspace at
	the end of a line with characters on it is the case that matters. It has a
	real glyph beside it, which is where `console.backspace` has to get the emboss
	shadow right. The erase also leaves `\b \b` on the serial line. That belongs
	inside a line somebody is already reading, rather than in front of the next
	log line.
	*/
	verify_write(&r, t, cons)
	verify_echo(&r, t)
	_, _ = vfs.chan_write(cons, 0, transmute([]u8)string("\n"))

	// -- /dev/null and /dev/zero ---------------------------------------------

	null, null_err := vfs.open_path(ns, "/dev/null", vfs.O_RDWR)
	if check(&r, null_err == vfs.OK, "/dev/null opens") {
		nn, ne := vfs.chan_write(null, 0, transmute([]u8)string("swallowed"))
		check(&r, ne == vfs.OK && nn == 9, "and swallows a write whole")
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

	// -- A read that parks, and the line that ends it ------------------------

	verify_parked_read(&r, cons)

	// -- The line discipline -------------------------------------------------

	verify_line_editing(&r, t, cons)

	// -- /dev/consctl, and the mode it owns ----------------------------------

	verify_consctl(&r, t, ns, cons)

	// -- A read that gives up ------------------------------------------------

	verify_give_up(&r, cons)

	// -- Nothing left behind -------------------------------------------------

	r.parked = t.cons.blocks
	r.lines = t.cons.lines
	r.edits = t.cons.erased + t.cons.killed
	check(&r, t.cons.dropped == 0, "no typed byte was dropped for want of ring")
	check(&r, !cons_available(&t.cons), "and the ring is empty again")
	check(&r, t.cons.edit_len == 0, "with no half-typed line left in the editor")

	// One fid is still out, and it is the `cons` chan this frame holds. The
	// deferred close above releases it after this check runs, which is why the
	// count is one rather than zero.
	check(&r, live_fids() == fids_before + 1, "every fid this test opened came back")
	return r
}

/*
verify_write sends the one line this test prints on its own.

It goes out through Twalk, Tlopen and Twrite, a worker thread, and the console
driver, which is the whole path this milestone exists to build.

Sent without its newline, and the newline sent after. That is what makes the
claim checkable rather than asserted. A counter inside the driver goes up
whether or not a glyph appeared. So the check is the console's own cursor: 49
bytes written is 49 columns further along.
*/
@(private = "file")
verify_write :: proc(r: ^Verify_Result, t: ^Dev_Tree, cons: ^vfs.Chan) {
	PROOF :: "-- this line reached the screen through /dev/cons"

	written_before := t.cons.writes
	col_before := kcon_col(t)
	n, write_err := vfs.chan_write(cons, 0, transmute([]u8)string(PROOF))
	r.written = n

	check(r, write_err == vfs.OK, "a write to /dev/cons is accepted")
	check(r, n == len(PROOF), "and takes every byte of it")
	check(r, t.cons.writes == written_before + u64(len(PROOF)), "and reaches the console driver")
	check(r, len(PROOF) < t.cons.screen.cols, "the proof line fits on one console row")
	check(r, kcon_col(t) == col_before + len(PROOF), "and every byte of it drew a glyph")
}

/*
verify_echo checks that a typed character is drawn, and that a backspace takes
it back off the screen.

Two cursor positions and nothing else. The console cannot be read back, so where
the cursor stands is the only observable this side of a camera.

Leaves the screen as it found it on purpose. The character goes on and the erase
takes it off, so the check about scribbling is not the one that scribbles.
*/
@(private = "file")
verify_echo :: proc(r: ^Verify_Result, t: ^Dev_Tree) {
	drain_cons(t)
	cons_set_mode(&t.cons, .Cooked, true)

	col_before := kcon_col(t)
	check(r, col_before > 0, "the echo lands beside a glyph, which is the case a backspace must get right")
	check(r, cell_lit(t, col_before) == 0, "and on a cell nothing has drawn on yet")

	_ = cons_feed(&t.cons, 'X')
	check(r, kcon_col(t) == col_before + 1, "an echoed character advances the console cursor")
	check(r, cell_lit(t, col_before) > 0, "and lights pixels in the cell it landed on")

	_ = cons_feed(&t.cons, '\b')
	check(r, kcon_col(t) == col_before, "a backspace puts the cursor back")
	check(r, cell_lit(t, col_before) == 0, "and takes the pixels off the screen, rather than only the cursor")
	check(r, t.cons.edit_len == 0, "and takes the character off the line as well")

	// The rest of the test types a great deal and none of it is a person's, so
	// echo goes off until something puts it back.
	cons_set_mode(&t.cons, .Cooked, false)

	col_before = kcon_col(t)
	_ = cons_feed(&t.cons, 'X')
	check(r, kcon_col(t) == col_before, "with echo off, a character draws nothing")
	check(r, cell_lit(t, col_before) == 0, "and leaves the screen alone")
	_ = cons_feed(&t.cons, '\b')
}

/*
verify_parked_read is the check this milestone is for, and cooked mode made it
stronger.

Three facts now, and the middle one is new. A read of an empty console does not
answer. **It still does not answer once a character arrives**, because a
character is not a line. And the newline after it finishes the read, with both
bytes in the answer.

That middle check is the line discipline tested from the outside. A console that
delivered characters as they arrived would fail it, and nothing else here would
notice.

The ring is drained first. Anything typed at the serial port during the boot
would otherwise finish this read before it ever parked. The check would then
pass without testing anything.
*/
@(private = "file")
verify_parked_read :: proc(r: ^Verify_Result, cons: ^vfs.Chan) #no_bounds_check {
	t := &dev_tree

	drain_cons(t)
	blocked_before := t.cons.blocks

	if !check(r, start_read(cons, 0), "a thread to do the reading") {
		return
	}

	check(r, settled(), "a read of an empty console does not answer")
	check(r, t.cons.blocks > blocked_before, "and parks, rather than spins")

	check(r, cons_feed(&t.cons, FED_BYTE), "a character arrives at the device")
	check(r, settled(), "and the read still does not answer, because a character is not a line")

	check(r, cons_feed(&t.cons, '\n'), "the newline after it arrives")
	if !check(r, watch(reader_returned, nil), "and the parked read comes back") {
		return
	}

	check(r, reader.err == vfs.OK, "with no error")
	r.delivered = reader.n
	check(r, same(reader.got[:], reader.n, "V\n"), "carrying the whole line, newline included")
}

/*
verify_line_editing checks the characters cooked mode treats specially.

Every read here is of bytes that are already in the ring, so none of them means
to park. `read_now` is what keeps a bug from turning that into a hang.

`^D` gets two checks because it means two things, and which one depends on
whether there is a line to send. On a line with characters, it sends them with
no newline, which is how a reader receives a line nobody ended. On an empty
line, it is the end of the file, and it is the only way a read of `/dev/cons`
answers with nothing.
*/
@(private = "file")
verify_line_editing :: proc(r: ^Verify_Result, t: ^Dev_Tree, cons: ^vfs.Chan) #no_bounds_check {
	got: [32]u8
	drain_cons(t)

	erased_before := t.cons.erased
	type_in(&t.cons, "ab\bc\n")
	n, err := read_now(cons, got[:])
	check(r, err == vfs.OK && same(got[:], n, "ac\n"), "a backspace takes the last character off the line")
	check(r, t.cons.erased == erased_before + 1, "and says so")

	killed_before := t.cons.killed
	type_in(&t.cons, "xy")
	_ = cons_feed(&t.cons, CTRL_U)
	type_in(&t.cons, "z\n")
	n, err = read_now(cons, got[:])
	check(r, err == vfs.OK && same(got[:], n, "z\n"), "a kill throws the whole line away")
	check(r, t.cons.killed == killed_before + 1, "and says so")

	type_in(&t.cons, "q")
	_ = cons_feed(&t.cons, CTRL_D)
	n, err = read_now(cons, got[:])
	check(r, err == vfs.OK && same(got[:], n, "q"), "an end of transmission sends the line with no newline")

	check(r, cons_feed(&t.cons, CTRL_D), "an end of transmission on an empty line is accepted")
	n, err = read_now(cons, got[:])
	check(r, err == vfs.OK && n == 0, "and is the end of the file, the only read that answers nothing")

	// A control character with no meaning here must not reach a reader. There
	// is nothing a reader could do with a bell.
	type_in(&t.cons, "\x07m\n")
	n, err = read_now(cons, got[:])
	check(r, err == vfs.OK && same(got[:], n, "m\n"), "a control character with no meaning never reaches the line")
}

/*
verify_consctl is the file this milestone is named for.

Four things, and the last is the one worth the machinery. The commands work. An
unknown command is refused rather than ignored. The file reads back as the
commands that would restore it. And **the last close reverts the mode**. A
program that turns raw mode on and then dies leaves no console nobody can type
at.

The only way to check the revert is to close the chan and look at the console. Nothing in the reply to a Tclunk says what the
server did afterwards.
*/
@(private = "file")
verify_consctl :: proc(
	r: ^Verify_Result,
	t: ^Dev_Tree,
	ns: ^vfs.Namespace,
	cons: ^vfs.Chan,
) #no_bounds_check {
	got: [64]u8

	ctl, ctl_err := vfs.open_path(ns, "/dev/consctl", vfs.O_RDWR)
	if !check(r, ctl_err == vfs.OK, "/dev/consctl opens") {
		return
	}
	check(r, t.ctl_opens == 1, "and the server counted the open")

	// Cooked with echo off is where `verify_line_editing` left it. The file has
	// to say that, rather than say what the default was.
	n, err := read_now(ctl, got[:])
	check(r, err == vfs.OK, "and reads")
	check(r, same(got[:], n, "rawoff\nechooff\n"), "as the commands that would restore it")

	/*
	A line nobody sent, left under construction across the mode change.

	Those four characters were typed under rules that stop applying one line
	below. A raw reader handed them would get characters the typist may already
	regret. A backspace only ever reached the edit buffer.
	*/
	type_in(&t.cons, "half")
	check(r, t.cons.edit_len == 4, "a half-typed line is waiting")

	wn, werr := vfs.chan_write(ctl, 0, transmute([]u8)string("rawon\n"))
	check(r, werr == vfs.OK && wn == 6, "rawon is accepted whole")
	mode, echo := cons_mode(&t.cons)
	check(r, mode == .Raw, "and the console is raw")
	check(r, !echo, "with echo off, because a raw read that echoed would show a password")
	check(r, t.cons.edit_len == 0, "and the half-typed line went with the rules that accepted it")

	n, err = read_now(ctl, got[:])
	check(r, err == vfs.OK && same(got[:], n, "rawon\nechooff\n"), "and the file reads back the new state")

	/*
	An offset into the file, and one past the end of it.

	A ctl file is short enough that every client reads it in one go. That is
	exactly why the offset arithmetic needs a check of its own. Nothing else
	here would ever notice it was wrong.
	*/
	full := n
	n, err = vfs.chan_read(ctl, 6, got[:])
	check(r, err == vfs.OK && same(got[:], n, "echooff\n"), "a read at an offset starts there")
	n, err = vfs.chan_read(ctl, u64(full), got[:])
	check(r, err == vfs.OK && n == 0, "and a read past the end returns nothing rather than repeats")

	// The point of raw mode, from the outside: one character, no newline, and
	// the read is finished.
	drain_cons(t)
	cons_set_mode(&t.cons, .Raw, false)
	check(r, cons_feed(&t.cons, FED_BYTE), "a character arrives in raw mode")
	n, err = read_now(cons, got[:])
	check(r, err == vfs.OK && same(got[:], n, "V"), "and a read gets it with no newline in sight")

	_, werr = vfs.chan_write(ctl, 0, transmute([]u8)string("  echoon  \n"))
	check(r, werr == vfs.OK, "surrounding whitespace is ignored")
	_, echo = cons_mode(&t.cons)
	check(r, echo, "and echo moves on its own")

	_, werr = vfs.chan_write(ctl, 0, transmute([]u8)string("rawsideways\n"))
	check(r, werr == vectra9.EINVAL, "a command nothing recognises is refused")
	mode, _ = cons_mode(&t.cons)
	check(r, mode == .Raw, "and changed nothing on the way out")

	// -- The last close reverts ----------------------------------------------

	cons_set_mode(&t.cons, .Raw, false)
	vfs.chan_close(ctl)
	check(r, t.ctl_opens == 0, "the last close of /dev/consctl is counted")

	mode, echo = cons_mode(&t.cons)
	check(r, mode == .Cooked, "and puts the console back in cooked mode")
	check(r, echo, "with echo on, which is where a person needs to find it")

	// Echo goes off again for the read that gives up. It types nothing, and
	// should not be the check that scribbles if it ever does.
	cons_set_mode(&t.cons, .Cooked, false)
}

/*
verify_give_up is `Tflush` reached from a path, against a device rather than
against a server built to be flushed.

`kernel/verify_flush.odin` proves the ordering rule with a server whose only
purpose is to not finish. This proves the same machinery in the place it is for.
A real driver, waiting on real hardware, and a caller that will not wait for
ever.

The last check is the one worth keeping. A give-up that left the handler parked,
or that poisoned the session, would read normally exactly once more and then
never again. So the same fid reads again afterwards, and it is fed a line to
prove it.
*/
@(private = "file")
verify_give_up :: proc(r: ^Verify_Result, cons: ^vfs.Chan) #no_bounds_check {
	t := &dev_tree
	drain_cons(t)

	if !check(r, start_read(cons, GIVE_UP_TICKS), "a thread to do the giving up") {
		return
	}
	if !check(r, watch(reader_returned, nil), "a read that outlives its deadline comes back at all") {
		// It is still inside the handler. Feed it, or the checks below run
		// against a device with a thread parked in it.
		type_in(&t.cons, "x\n")
		_ = watch(reader_returned, nil)
		return
	}

	r.gave_up = reader.ticks
	check(r, reader.err == vectra9.EINTR, "and reports EINTR")
	check(r, reader.n == 0, "and hands back no bytes it did not get")
	check(r, reader.ticks >= GIVE_UP_TICKS, "after waiting the deadline it was given")

	// The connection is still a connection. Type first, so this read finds a
	// whole line waiting and cannot park.
	type_in(&t.cons, "ok\n")
	got: [8]u8
	n, e := read_now(cons, got[:])
	check(r, e == vfs.OK && same(got[:], n, "ok\n"), "and the same fid reads normally afterwards")
}

// -- Helpers -----------------------------------------------------------------

// kcon_col is where the console's cursor is. The one observable a self-test has
// that a byte reached the screen rather than only reached a counter.
@(private = "file")
kcon_col :: proc "contextless" (t: ^Dev_Tree) -> int {
	return t.cons.screen == nil ? -1 : t.cons.screen.col
}

/*
cell_lit counts the pixels in one console cell that are not the background.

The only observable that says a glyph reached the framebuffer. A cursor position
is bookkeeping the console keeps, and a mutation that stops drawing without
stopping the cursor passes every check built on it. `docs/TESTING.md` records
that lesson twice over, and this is the third.

`col` is a column on the row the cursor is on. The plain cell, not the extra
pixel `console.backspace` clears, so this never counts a neighbour's emboss.
*/
@(private = "file")
cell_lit :: proc "contextless" (t: ^Dev_Tree, col: int) -> int {
	s := t.cons.screen
	if s == nil || s.surface == nil {
		return -1
	}

	bg := fb.pack(s.surface, s.bg)
	px := s.bounds.x + col * console.FONT_WIDTH
	py := s.bounds.y + s.row * console.cell_height(s)

	lit := 0
	for y in 0 ..< console.FONT_HEIGHT {
		for x in 0 ..< console.FONT_WIDTH {
			if fb.get_raw(s.surface, px + x, py + y) != bg {
				lit += 1
			}
		}
	}
	return lit
}

/*
drain_cons empties the ring, the line under construction and any end of file.

Every check that means to park has to start from nothing. A byte typed at the
serial port during the boot would otherwise finish a read before it parked. The
check would then pass without testing anything.

The mode goes through raw and back, because a mode change is what discards the
line under construction. See `cons_set_mode`.
*/
@(private = "file")
drain_cons :: proc "contextless" (t: ^Dev_Tree) #no_bounds_check {
	scratch: [CONS_INPUT_BYTES]u8
	for cons_take(&t.cons, scratch[:]) > 0 {
	}
	for cons_take_eof(&t.cons) {
	}
	cons_set_mode(&t.cons, .Raw, false)
	cons_set_mode(&t.cons, .Cooked, false)
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
