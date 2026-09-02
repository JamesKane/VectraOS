/*
The devfs self-test: the path from a name to a byte on a screen, checked.

Everything here runs against the boot namespace, over the real mount at `/dev`,
through the real transport with a worker for every request slot. There is no
fixture. A check that passes here is a check that the machine's own `/dev/cons`
passes.

Nine claims, in the order they are checked:

  - `/dev` lists every device in the table and `/dev/cons` is first
  - a write to `/dev/cons` reaches the framebuffer and the serial port
  - `/dev/fb` is the screen at an offset, `/dev/fbctl` reports its geometry,
    and the boundary follows `fbdev.odin`'s three rules
  - `/dev/scancode` and `/dev/eia0` own their streams while held open, and
    the last close gives each stream back
  - a read of `/dev/cons` with nothing typed **parks**, stays parked through a
    character, and finishes on the newline after it
  - **every request slot can hold a parked read at once**, and the one that
    gives up under that load is still answered by a spare worker
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

import "vsys:libodin"
import "base:intrinsics"
import "base:runtime"

import "kernel:drivers/console"
import "kernel:drivers/fb"
import "kernel:mem"
import "kernel:mnt"
import "kernel:sched"
import "kernel:sync"
import "kernel:vfs"
import "vsys:vectra9"

Verify_Result :: struct {
	using tally:   libodin.Tally,
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
	return libodin.tally(&r.tally, ok, what)
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

// -- Many readers at once ----------------------------------------------------

/*
As many parked reads as the transport has request slots.

`mnt.MAX_REQUESTS` is the most requests in flight on the connection at once. So
it is the most reads that can park at once, and `verify_worker_bound` fills every
one of them.
*/
@(private = "file")
MANY :: mnt.MAX_REQUESTS

/*
One reader on its own thread and its own handle.

Its own handle, because two threads reading one fid share a request slot and
would serialise. A separate handle per reader is what puts one read in every
slot. A `deadline` of zero blocks until a line arrives, and anything else gives
up after that many ticks, the way `Reader` does.
*/
@(private = "file")
Many_Reader :: struct {
	c:        ^vfs.Chan,
	deadline: u64,
	got:      [16]u8,
	n:        int,
	err:      vfs.Errno,
	returned: bool,
}

@(private = "file")
many: [MANY]Many_Reader

// The console's park count before the readers start, so `all_parked` can tell
// this test's parks from every earlier one.
@(private = "file")
many_base: u64

@(private = "file")
many_read_thread :: proc "contextless" (arg: rawptr) {
	context = verify_context()
	mr := cast(^Many_Reader)arg
	if mr.deadline == 0 {
		mr.n, mr.err = vfs.chan_read(mr.c, 0, mr.got[:])
	} else {
		mr.n, mr.err = vfs.chan_read_for(mr.c, 0, mr.got[:], mr.deadline)
	}
	intrinsics.volatile_store(&mr.returned, true)
}

// all_parked reports whether every reader parked, which the console's own count
// shows by rising one per reader.
@(private = "file")
all_parked :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&dev_tree.cons.blocks) - many_base >= u64(MANY)
}

// many_done reports whether one reader is back, or every reader when `arg`
// is nil.
@(private = "file")
many_done :: proc "contextless" (arg: rawptr) -> bool {
	if arg != nil {
		return intrinsics.volatile_load(&(cast(^Many_Reader)arg).returned)
	}
	for i in 0 ..< MANY {
		if !intrinsics.volatile_load(&many[i].returned) {
			return false
		}
	}
	return true
}

// many_returned_count is how many readers are back so far.
@(private = "file")
many_returned_count :: proc "contextless" () -> int {
	n := 0
	for i in 0 ..< MANY {
		if intrinsics.volatile_load(&many[i].returned) {
			n += 1
		}
	}
	return n
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

	/*
	-- The screen the console steps off, before anything else holds it -------

	Ahead of `verify_fb` on purpose, and a control is why. This procedure is
	the one that asks whether the copy behind the divert is seeded from the
	glass. An earlier holder of `/dev/fb` diverts and reverts once before this
	runs. An unseeded copy therefore paints the screen before this can sample
	it, and the check then compares damage against damage and passes. The first
	thing to hold the screen has to be the thing that asks.
	*/

	verify_screen(&r, t, ns)

	// -- /dev/fb and /dev/fbctl ----------------------------------------------

	verify_fb(&r, t, ns)

	// -- /dev/scancode and /dev/eia0 -------------------------------------------

	verify_taps(&r, t, ns)

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

	// -- Every request slot parks at once ------------------------------------

	verify_worker_bound(&r, ns)

	// -- Nothing left behind -------------------------------------------------

	r.parked = t.cons.blocks
	r.lines = t.cons.lines
	r.edits = t.cons.erased + t.cons.killed
	check(&r, t.cons.dropped == 0, "no typed byte was dropped for want of ring")
	check(&r, !cons_available(&t.cons), "and the ring is empty again")
	check(&r, t.cons.edit_len == 0, "with no half-typed line left in the editor")
	check(&r, !tap_active(&t.scancode) && !tap_active(&t.serial), "both taps are closed again")
	check(&r, !tap_available(&t.scancode) && !tap_available(&t.serial), "with nothing left in either ring")

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
	if !check(r, sync.await(reader_returned, nil, PATIENCE), "and the parked read comes back") {
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

	/*
	And a key that has no character does not become three that do.

	`kernel/drivers/kbd` answers a *rune* for the extended keys, encoded as
	UTF-8 into this sink -- an arrow is `KF|0x11`, which is `EF 80 91`. Every
	one of those bytes is above `0x20`, so the control-character refusal above
	does not catch them, and a discipline that stored them would put three
	glyphs nobody typed into the line and echo them.

	This one is the console before a window system exists, over a 7-bit font.
	It refuses what it cannot spell, and `sys/libedit` is the discipline that
	decodes them instead.
	*/
	type_in(&t.cons, "a\xEF\x80\x91b\n")
	n, err = read_now(cons, got[:])
	check(
		r,
		err == vfs.OK && same(got[:], n, "ab\n"),
		"an arrow key's rune is refused rather than stored as the bytes that carry it",
	)

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
	if !check(r, sync.await(reader_returned, nil, PATIENCE), "a read that outlives its deadline comes back at all") {
		// It is still inside the handler. Feed it, or the checks below run
		// against a device with a thread parked in it.
		type_in(&t.cons, "x\n")
		_ = sync.await(reader_returned, nil, PATIENCE)
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

/*
verify_worker_bound is the milestone: a parked read holds no worker anyone else
needs.

`WORKERS` is `mnt.MAX_REQUESTS + 1`, so every request slot on the connection can
hold a parked read and one worker still remains. That worker serves the `Tflush`
that unsticks one. This test fills every slot and proves both halves at once.

Seven reads block, and the eighth is given a deadline. All eight park, which
takes a worker for every slot. When the eighth outlives its deadline its client
sends a `Tflush`, which only the spare worker can serve, because the other seven
hold theirs parked. A pool sized to the parked reads alone would leave that
flush waiting behind them, and the give-up would never come back.

Everything blocking is on a thread of its own, and every wait here has a bound.
A pool too small leaves the last reads in the queue, and `all_parked` never
reaches the count. The check fails and the feed at the end still drains every
thread, because a freed worker dequeues a waiting read.
*/
@(private = "file")
verify_worker_bound :: proc(r: ^Verify_Result, ns: ^vfs.Namespace) #no_bounds_check {
	t := &dev_tree
	drain_cons(t)

	opened := 0
	for i in 0 ..< MANY {
		c, e := vfs.open_path(ns, "/dev/cons", vfs.O_RDONLY)
		if e != vfs.OK {
			break
		}
		many[i] = Many_Reader {
			c = c,
		}
		opened += 1
	}
	if !check(r, opened == MANY, "a handle on /dev/cons for every request slot") {
		for i in 0 ..< opened {
			vfs.chan_close(many[i].c)
		}
		return
	}
	defer for i in 0 ..< MANY {
		vfs.chan_close(many[i].c)
	}

	// The eighth reader gives up on a deadline. The other seven wait for a line.
	many[0].deadline = GIVE_UP_TICKS

	many_base = intrinsics.volatile_load(&t.cons.blocks)
	spawned := 0
	for i in 0 ..< MANY {
		if sched.spawn("devfs-many", many_read_thread, &many[i]) == nil {
			break
		}
		spawned += 1
	}
	if !check(r, spawned == MANY, "a thread for each of them") {
		// Wake whatever parked, so the deferred close is not against a live read.
		for _ in 0 ..< MANY {
			type_in(&t.cons, "V\n")
		}
		_ = sync.await(many_done, nil, PATIENCE)
		return
	}

	// Every slot fills with a parked read. A worker for every slot means none of
	// them waits for a worker, and a smaller pool leaves the last reads queued.
	parked := sync.await(all_parked, nil, PATIENCE)
	check(r, parked, "eight reads park at once, one per request slot")
	if parked {
		check(r, many_returned_count() == 0, "and none has answered, because none has a line")
	}

	// The eighth outlives its deadline, and its flush needs the spare worker.
	if check(
		r,
		sync.await(many_done, &many[0], PATIENCE),
		"the read that gives up is answered, so a worker was free for its flush",
	) {
		check(r, many[0].err == vectra9.EINTR, "and reports EINTR, the way a lone give-up does")
	}

	// The seven that waited each get a line of their own, one at a time. A read
	// takes as much as its buffer holds, so a second line in the ring would go
	// to the same reader and strand another. Feeding only when the ring is empty
	// keeps it one line, one reader. The eighth comes back on its flush instead,
	// as a freed worker serves it.
	//
	// This is also the cleanup, and it must leave no read parked. The deferred
	// close is a Tclunk, which is itself a request. A pool with a read still
	// parked in it cannot serve one, and the close would wait for a worker that
	// never comes. So a short pool drains here the same way, one reader as each
	// worker frees, and only then does the close run.
	release_by := sched.ticks() + PATIENCE
	for !many_done(nil) && sched.ticks() < release_by {
		if !cons_available(&t.cons) {
			type_in(&t.cons, "V\n")
		}
		sync.delay(2)
	}
	if !check(r, many_done(nil), "and every waiting read comes back once its line arrives") {
		return
	}
	delivered := true
	for i in 1 ..< MANY {
		if many[i].err != vfs.OK || !same(many[i].got[:], many[i].n, "V\n") {
			delivered = false
		}
	}
	check(r, delivered, "each carrying a whole line")

	// A give-up may have left a line with no reader to take it. The ring goes
	// back empty, the way the next test and the person at the keyboard expect.
	drain_cons(t)
}


/*
verify_screen is the divert, and the divert is what a desktop was waiting for.

**Two things cannot paint one screen.** `servers/intuition` composites windows
into the framebuffer and this console writes the boot log into the same memory.
`/dev/fb` now diverts the console the way `/dev/scancode` diverts the keyboard.
While something holds it the console draws into a copy. The last close gives
the glass back, with everything it drew in the meantime on it.

Three claims, and the middle one is the milestone:

    the divert     opening the screen puts the console somewhere else
    the silence    a console write changes nothing on the glass while it is
                   held, which no counter can fake
    the revert     the last close puts it back, and what the console wrote
                   while it was away is on it

The sensor is the glass, sampled across the console's own region rather than
at a pixel this test would have to predict. A console line lands where the
cursor is, which is a place a self-test has no business knowing. A sample that
is equal before and after is the claim either way.
*/
@(private = "file")
verify_screen :: proc(r: ^Verify_Result, t: ^Dev_Tree, ns: ^vfs.Namespace) #no_bounds_check {
	s := t.raw
	if s == nil || s.pixels == nil {
		return
	}
	check(r, !screen_diverted(), "the console has the glass, with nothing holding the screen")

	before := screen_sample(s, 0, s.height)

	/*
	And the chassis, sampled on its own.

	The console never draws in the top rows -- its well is inset inside the
	bevel `kernel/splash.odin` painted once at boot. So this is the part of the
	frame that must come back *unchanged*. It is what says the copy was seeded
	from the glass rather than started blank. A revert that blitted a shadow
	nobody filled would pass every other check here, and hand back a screen with
	no chassis on it.
	*/
	chrome := screen_sample(s, 0, 24)

	fbc, ferr := vfs.open_path(ns, "/dev/fb", vfs.O_RDWR)
	if !check(r, ferr == vfs.OK, "/dev/fb opens") {
		return
	}
	/*
	A machine that cannot buy the copy keeps two writers on one screen, which
	is what every milestone before this one ran. This check says the divert
	happened, and on a machine too tight for four megabytes it says so by
	failing, which is the honest report.
	*/
	if !check(r, screen_diverted(), "and the console steps off the glass while it is held") {
		vfs.chan_close(fbc)
		return
	}
	check(r, t.cons.screen.surface != s, "drawing into a copy with the same shape instead")

	// The line that proves the silence. It goes to the console the ordinary
	// way, through the file every other write in this test uses.
	cons, cerr := vfs.open_path(ns, "/dev/cons", vfs.O_WRONLY)
	if check(r, cerr == vfs.OK, "/dev/cons opens while the screen is held") {
		line := "-- this line was written while the screen was somebody else's\n"
		n, werr := vfs.chan_write(cons, 0, transmute([]u8)line)
		check(r, werr == vfs.OK && n == len(line), "and takes a line")
		r.written += n
		vfs.chan_close(cons)
	}
	check(r, screen_sample(s, 0, s.height) == before, "which changed nothing at all on the glass")

	/*
	A second holder changes nothing, and the line above is what proves it.

	The screen is already somebody else's, so the first open is the only one
	that moves the console. A second that seeded the copy again would throw away
	everything the console drew into it. The only way to see that is to draw
	something first, so the order of this procedure is the check.
	*/
	second, serr := vfs.open_path(ns, "/dev/fb", vfs.O_RDONLY)
	if check(r, serr == vfs.OK, "a second holder opens the screen too") {
		check(r, screen_diverted(), "and the console is no further away than it was")
		vfs.chan_close(second)
		check(r, screen_diverted(), "and its close is not the last one")
	}
	check(r, screen_sample(s, 0, s.height) == before, "and the glass is still untouched")

	/*
	And the holder paints, far from anywhere the console goes.

	This is what says the revert puts back the *frame* rather than the
	console's own well. Whoever holds the screen may paint any of it, and a
	compositor's windows are most of it. A revert that restored only the
	console's region would hand back a screen with the last holder's work still
	on two thirds of it.

	The bottom corner, which is the far side of the glass from the log.
	*/
	far_x := s.width - 10
	far_y := s.height - 10
	far_was := fb.get_raw(s, far_x, far_y)
	paint: [8]u8
	for i in 0 ..< s.bytes_pp {
		paint[i] = 0xC0 + u8(i) * 5
	}
	far_off := u64(far_y * s.pitch + far_x * s.bytes_pp)
	pn, perr := vfs.chan_write(fbc, far_off, paint[:s.bytes_pp])
	check(r, perr == vfs.OK && pn == s.bytes_pp, "the holder paints a corner of the glass itself")
	check(r, fb.get_raw(s, far_x, far_y) != far_was, "which lands, because the holder has the screen")

	vfs.chan_close(fbc)
	check(r, !screen_diverted(), "the last close gives the screen back")
	check(r, t.cons.screen.surface == s, "and the console draws on it again")
	check(
		r,
		screen_sample(s, 0, s.height) != before,
		"with the line it wrote while it was away now on it",
	)
	check(
		r,
		screen_sample(s, 0, 24) == chrome,
		"and the chassis it never drew still there, because the copy was seeded from the glass",
	)
	check(
		r,
		fb.get_raw(s, far_x, far_y) == far_was,
		"and the corner the holder painted put back, because the revert is the whole frame",
	)
}

/*
screen_sample adds up a spread of a band of the frame, as one number to
compare.

Every eighth pixel of every fourth row, which is enough that a line of text
cannot miss all of them. A sum rather than a copy. A self-test that wanted
four megabytes to hold a screen would be the second thing in this kernel that
did.

Sampled rather than exact on purpose. The claims are `nothing changed` and
`something changed`, and neither one needs to say which pixel.

The band is what lets one procedure ask two questions of one frame. The whole
of it for what the console wrote, and the top of it for what the console never
touches.
*/
@(private = "file")
screen_sample :: proc "contextless" (s: ^fb.Surface, from: int, to: int) -> u64 #no_bounds_check {
	sum := u64(0)
	for y := from; y < min(to, s.height); y += 4 {
		for x := 0; x < s.width; x += 8 {
			sum = sum * 31 + u64(fb.get_raw(s, x, y))
		}
	}
	return sum
}

/*
verify_fb is the raw framebuffer: the first device with contents, checked as
one.

Three claims. The geometry file reports the surface the server actually
holds, rather than a copy of it. A write through the mount puts pixels on
the screen at the offset it named. `fb.get_raw` is what says so -- the
screen itself, not a counter the code under test also maintains. And the
boundary follows `fbdev.odin`'s three rules. Short at the edge, the end of
the file past it for a read, ENOSPC past it for a write.

Every byte this writes goes back before it returns, through the same file.
The screen belongs to whoever is sitting at it.
*/
@(private = "file")
verify_fb :: proc(r: ^Verify_Result, t: ^Dev_Tree, ns: ^vfs.Namespace) #no_bounds_check {
	s := t.raw
	if !check(r, s != nil && s.pixels != nil, "the server holds the screen's surface") {
		return
	}
	limit := fb_size(s)

	fbc, fb_err := vfs.open_path(ns, "/dev/fb", vfs.O_RDWR)
	if !check(r, fb_err == vfs.OK, "/dev/fb opens for reading and writing") {
		return
	}
	defer vfs.chan_close(fbc)

	attr, attr_err := vfs.chan_stat(fbc)
	check(r, attr_err == vfs.OK, "and stats")
	check(r, attr.mode & 0o170000 == 0o020000, "as a character device")
	check(r, limit > 0 && attr.size == limit, "with a real length, the first device that has one")

	// -- The geometry file ----------------------------------------------------

	ctl, ctl_err := vfs.open_path(ns, "/dev/fbctl", vfs.O_RDWR)
	if check(r, ctl_err == vfs.OK, "/dev/fbctl opens") {
		report: [128]u8
		n, err := vfs.chan_read(ctl, 0, report[:])
		check(r, err == vfs.OK && n > 0, "and reads")

		want := [10]u64 {
			u64(s.width),
			u64(s.height),
			u64(s.pitch),
			u64(s.bytes_pp) * 8,
			u64(s.red_size),
			u64(s.red_shift),
			u64(s.green_size),
			u64(s.green_shift),
			u64(s.blue_size),
			u64(s.blue_shift),
		}
		got: [12]u64
		found := report_numbers(report[:n], got[:])
		agree := found == len(want)
		if agree {
			for i in 0 ..< len(want) {
				if got[i] != want[i] {
					agree = false
				}
			}
		}
		check(r, agree, "reporting the geometry of the surface the server holds")

		tail: [128]u8
		tn, terr := vfs.chan_read(ctl, 5, tail[:])
		check(
			r,
			terr == vfs.OK && tn == n - 5 && same(tail[:], tn, string(report[5:n])),
			"a read at an offset starts there",
		)
		tn, terr = vfs.chan_read(ctl, u64(n), tail[:])
		check(r, terr == vfs.OK && tn == 0, "and a read past the end returns nothing")

		_, werr := vfs.chan_write(ctl, 0, transmute([]u8)string("size 640 480\n"))
		check(r, werr == vectra9.EINVAL, "a command is refused, because nothing here can be set yet")
		vfs.chan_close(ctl)
	}

	// -- Pixels through the mount ---------------------------------------------

	bpp := s.bytes_pp
	span := bpp * 2
	x := s.width - 4
	y := s.height - 2
	o := u64(y * s.pitch + x * bpp)

	saved: [16]u8
	for i in 0 ..< span {
		saved[i] = s.pixels[int(o) + i]
	}
	pattern: [16]u8
	for i in 0 ..< span {
		pattern[i] = 0xA1 + u8(i) * 7
	}

	wn, werr := vfs.chan_write(fbc, o, pattern[:span])
	check(r, werr == vfs.OK && wn == span, "a write to /dev/fb lands at the offset it named")
	check(r, fb.get_raw(s, x, y) == assemble(pattern[:bpp]), "and the first pixel is on the screen")
	check(r, fb.get_raw(s, x + 1, y) == assemble(pattern[bpp:span]), "and the second is one pixel along")

	got: [16]u8
	rn, rerr := vfs.chan_read(fbc, o, got[:span])
	readback := rerr == vfs.OK && rn == span
	for i in 0 ..< span {
		if got[i] != pattern[i] {
			readback = false
		}
	}
	check(r, readback, "a read at the same offset answers the bytes the write put there")

	// -- The boundary ---------------------------------------------------------

	rn, rerr = vfs.chan_read(fbc, limit, got[:8])
	check(r, rerr == vfs.OK && rn == 0, "a read at the end of the frame is the end of the file")
	rn, rerr = vfs.chan_read(fbc, limit - 2, got[:8])
	check(r, rerr == vfs.OK && rn == 2, "a read across the edge is short rather than refused")

	edge: [2]u8
	for i in 0 ..< 2 {
		edge[i] = s.pixels[int(limit) - 2 + i]
	}
	// Well past the end, not merely at it. At exactly `limit` the clamp
	// arithmetic answers zero with or without the offset guard. Past it the
	// subtraction wraps, and only the guard stands between a client and a
	// copy from beyond the frame. A control proved the at-the-edge checks
	// alone missed exactly that.
	rn, rerr = vfs.chan_read(fbc, limit + 8, got[:8])
	check(r, rerr == vfs.OK && rn == 0, "a read well past the end answers nothing, with no wrap")

	wn, werr = vfs.chan_write(fbc, limit - 2, pattern[:4])
	check(r, werr == vfs.OK && wn == 2, "a write across the edge takes what fits and says so")
	_, werr = vfs.chan_write(fbc, limit, pattern[:4])
	check(r, werr == vectra9.ENOSPC, "and a write past it is refused for want of room")
	_, werr = vfs.chan_write(fbc, limit + 8, pattern[:4])
	check(r, werr == vectra9.ENOSPC, "from well past it too, with no wrap")

	// The screen goes back the way it was found, through the same file.
	_, _ = vfs.chan_write(fbc, limit - 2, edge[:])
	_, _ = vfs.chan_write(fbc, o, saved[:span])
}

/*
verify_taps is the two raw input streams, and the diversion that defines
them.

The claim with the machinery in it is ownership. While something holds
`/dev/scancode`, a fed scancode is consumed -- the driver would not
translate it -- and the console sees nothing. While something holds
`/dev/eia0`, a byte off the port goes to the file rather than the line
discipline. And the last close gives each stream back, which is the
`consctl` revert again. A program that takes the keyboard and dies must
not keep it.

Both taps are fed through the same entry points their producers use.
`scancode_tap` is what `kernel/drivers/kbd` calls, and `serial_deliver` is
what `cons_input` calls, so the seam under test is the seam in use. The
keyboard driver itself is not up yet at this point in the boot, and does
not need to be. Its half of the contract is checked in `kbd/verify.odin`.
*/
@(private = "file")
verify_taps :: proc(r: ^Verify_Result, t: ^Dev_Tree, ns: ^vfs.Namespace) #no_bounds_check {
	got: [16]u8

	// -- The scancode stream, closed -------------------------------------------

	drain_cons(t)
	check(r, !scancode_tap(0x9C), "a scancode fed while nobody holds the file is the driver's")
	check(r, !tap_available(&t.scancode), "and no closed tap kept it")

	// -- ...and open ------------------------------------------------------------

	sc, sc_err := vfs.open_path(ns, "/dev/scancode", vfs.O_RDONLY)
	if !check(r, sc_err == vfs.OK, "/dev/scancode opens") {
		return
	}
	check(r, t.scan_opens == 1, "and the server counted the open")
	check(r, tap_active(&t.scancode), "and the stream now belongs to the file")

	check(r, scancode_tap(0x81), "a scancode fed while it is held is consumed")
	check(r, !cons_available(&t.cons), "and the console saw nothing of it")
	n, err := read_now(sc, got[:])
	check(r, err == vfs.OK && n == 1 && got[0] == 0x81, "a read gets the raw byte, untranslated")

	// A parked read, finished by one byte. No line discipline stands between
	// a tap and its reader, so there is nothing to wait for past the byte.
	if check(r, start_read(sc, 0), "a thread to read an empty tap") {
		check(r, settled(), "a read of an empty tap does not answer")
		check(r, scancode_tap(0x82), "one scancode arrives")
		if check(r, sync.await(reader_returned, nil, PATIENCE), "and the parked read comes back") {
			check(r, reader.err == vfs.OK && same(reader.got[:], reader.n, "\x82"), "carrying it alone")
		}
	}

	// A read that gives up, which is the abort hook waking a tap's rendez
	// rather than the console's.
	if check(r, start_read(sc, GIVE_UP_TICKS), "a thread to give up on one") {
		if check(r, sync.await(reader_returned, nil, PATIENCE), "a tap read that outlives its deadline comes back") {
			check(r, reader.err == vectra9.EINTR, "and reports EINTR")
		} else {
			_ = scancode_tap(0x83)
			_ = sync.await(reader_returned, nil, PATIENCE)
		}
	}

	// -- The last close gives the stream back -----------------------------------

	check(r, scancode_tap(0x84), "a byte is captured and never read")
	vfs.chan_close(sc)
	check(r, t.scan_opens == 0, "the last close of /dev/scancode is counted")
	check(r, !tap_active(&t.scancode), "and the stream is the console's again")
	check(r, !tap_available(&t.scancode), "with the unread capture thrown away, owed to nobody")
	check(r, !scancode_tap(0x9C), "and a fresh scancode is the driver's to translate")

	// -- The serial stream -------------------------------------------------------

	if t.cons.port == nil || !t.cons.port.present {
		// No port probed on this machine. The open must say so, and the rest
		// of this section has no hardware to be about.
		_, ne := vfs.open_path(ns, "/dev/eia0", vfs.O_RDWR)
		check(r, ne == vectra9.ENXIO, "/dev/eia0 refuses to open where no port answered the probe")
		return
	}

	eia, eia_err := vfs.open_path(ns, "/dev/eia0", vfs.O_RDWR)
	if !check(r, eia_err == vfs.OK, "/dev/eia0 opens") {
		return
	}
	check(r, t.eia_opens == 1, "and the server counted the open")

	// Raw bytes out: the port moves, the screen does not.
	WIRE :: "-- these bytes went straight out the wire\n"
	writes_before := t.cons.writes
	col_before := kcon_col(t)
	wn, werr := vfs.chan_write(eia, 0, transmute([]u8)string(WIRE))
	check(r, werr == vfs.OK && wn == len(WIRE), "a write to /dev/eia0 takes every byte")
	check(r, t.cons.writes == writes_before, "without passing through the console")
	check(r, kcon_col(t) == col_before, "and without drawing a glyph")

	// Raw bytes in: the producer's own seam, diverted and then given back.
	serial_deliver(&t.cons, 'R')
	n, err = read_now(eia, got[:])
	check(r, err == vfs.OK && n == 1 && got[0] == 'R', "a byte off the port reaches the file raw")
	check(r, !cons_available(&t.cons) && t.cons.edit_len == 0, "and the line discipline saw nothing")

	vfs.chan_close(eia)
	check(r, t.eia_opens == 0, "the last close of /dev/eia0 is counted")

	drain_cons(t)
	cons_set_mode(&t.cons, .Cooked, false)
	serial_deliver(&t.cons, 'x')
	check(r, t.cons.edit_len == 1, "and a byte off the port is the line discipline's again")
	drain_cons(t)
}

// assemble builds the pixel word `fb.get_raw` answers from the bytes a
// client would write, low byte first. Independent arithmetic on purpose: a
// check that used the device's own copy path would agree with it whatever
// else was broken.
@(private = "file")
assemble :: proc "contextless" (bytes: []u8) -> u32 #no_bounds_check {
	v := u32(0)
	for i := len(bytes) - 1; i >= 0; i -= 1 {
		v = v << 8 | u32(bytes[i])
	}
	return v
}

// report_numbers pulls every decimal run out of a report, in order, and says
// how many there were. A parser this small cannot drift from the format, because
// it has no opinion about anything but digits.
@(private = "file")
report_numbers :: proc "contextless" (data: []u8, out: []u64) -> int #no_bounds_check {
	found := 0
	i := 0
	for i < len(data) {
		if data[i] < '0' || data[i] > '9' {
			i += 1
			continue
		}
		v := u64(0)
		for i < len(data) && data[i] >= '0' && data[i] <= '9' {
			v = v * 10 + u64(data[i] - '0')
			i += 1
		}
		if found < len(out) {
			out[found] = v
		}
		found += 1
	}
	return found
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
