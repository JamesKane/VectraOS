/*
The raw framebuffer: the first device in the tree with contents.

`/dev/fb` is the screen's memory as a file. A byte at offset `y * pitch +
x * bytes_pp` is the low byte of the pixel at column x, row y. A write
there changes it. `/dev/fbctl` beside it reports the geometry a client needs
to do that arithmetic.

Every device before this one was a stream. `/dev/cons` has no length and no
position, because its contents are the future. The framebuffer is the
opposite in both ways. It has exactly `height * pitch` bytes, they are all
there at once, and the offset in a read or a write names which of them. So
`Rgetattr` reports a real size here and zero everywhere else, and this file
is the reason that difference exists.

**That is what makes the hardware reachable from ring 3.** A process opens
`/dev/fb` by name, seeks its descriptor, and writes pixel bytes. `sys_seek`
already carries the position and `Twrite` already carries it to this server.
Nothing new crosses the door for this milestone. The new ground is a device
on the far side that honours what arrives.

Two masters wait on this file, and it serves both with one implementation.
A userland devfs needs the kernel to serve the console's raw halves, so a
process can stand where `#c`'s handler stands. And `/dev/draw` is mostly a
protocol over exactly this memory. See `docs/HANDOFF.md` section 6.

## The boundary, in three rules

  - A read at or past the end answers zero bytes, which is the end of the
    file. The size is real, so running out is meaningful here in a way it
    is not on a stream.
  - A read or a write that straddles the end takes what fits and reports a
    short count. The honest count, because the bytes up to the edge did
    move.
  - A write that starts at or past the end is ENOSPC. There is no space at
    that offset and there never will be. A count of zero would read as
    `try again`, which is the one thing it must not say.

## No lock, on purpose

A write here is a memory copy into the frame, under no lock at all. Two
clients that write the same pixels tear, and what tears is the picture
rather than any state of the kernel's. The screen already works that way.
`klog` draws with no lock from the fault path, and the console's own writes
share this surface with both. A server that serialised pixel writes would
buy nothing and hold a worker to buy it.

## `/dev/fbctl`

The report is facts a client cannot draw without:

    size 1280 800
    pitch 5120
    depth 32
    r 8 16
    g 8 8
    b 8 0

One line per fact, `depth` in bits, and each channel as its width and its
shift into the pixel word. The vocabulary of commands is empty today,
because nothing about this hardware can be set. Every write is therefore
EINVAL, which is rule 2 of the ctl convention with no rows in its table.
The day a mode can change, `size` becomes a command. Rule 3 -- the file
reads back as the writes that would restore it -- then starts to hold.
*/
package devfs

import "base:intrinsics"

import "kernel:arch"
import "kernel:drivers/console"
import "kernel:drivers/fb"
import "kernel:mem"
import "kernel:vfs"
import "vsys:vectra9"

// fb_size is how many bytes the framebuffer file has: every scanline,
// padding included. The padding is real memory a client may address, and
// excluding it would make the offset arithmetic lie about every row but the
// first.
fb_size :: proc "contextless" (s: ^fb.Surface) -> u64 {
	if s == nil || s.pixels == nil {
		return 0
	}
	return u64(s.height) * u64(s.pitch)
}

/*
fb_read copies pixel bytes out of the frame, from `offset`.

The answer is built in `buf`, which is the request slot's own storage, the
same as every other read in this server. Zero bytes at or past the end is
the end of the file. It is honest here: unlike `/dev/cons`, this file has
an end to reach.
*/
fb_read :: proc "contextless" (s: ^fb.Surface, offset: u64, buf: []u8) -> []u8 {
	limit := fb_size(s)
	if len(buf) == 0 || offset >= limit {
		return nil
	}
	n := min(u64(len(buf)), limit - offset)
	intrinsics.mem_copy(raw_data(buf), &s.pixels[offset], int(n))
	return buf[:n]
}

/*
fb_write copies pixel bytes into the frame, at `offset`, and reports how
many fit.

Short at the boundary rather than refused, because the bytes up to the edge
did move and the count has to say so. ENOSPC past it, because a write with
nowhere to begin moved nothing. A zero count would invite a retry at the
same offset for ever.
*/
fb_write :: proc "contextless" (s: ^fb.Surface, offset: u64, data: []u8) -> (int, vfs.Errno) {
	limit := fb_size(s)
	if offset >= limit {
		return 0, vectra9.ENOSPC
	}
	if len(data) == 0 {
		return 0, vfs.OK
	}
	n := min(u64(len(data)), limit - offset)
	intrinsics.mem_copy(&s.pixels[offset], raw_data(data), int(n))
	return int(n), vfs.OK
}

/*
fbctl_report renders the geometry, one line per fact.

Generated on every read, like `/dev/consctl`'s report, and for a weaker
reason: nothing here can change yet, so a snapshot would also be correct.
Generation is simply the shape ctl reads have in this tree. `offset` is
honoured so a client with a small buffer can finish the file.
*/
fbctl_report :: proc "contextless" (s: ^fb.Surface, offset: u64, buf: []u8) -> []u8 #no_bounds_check {
	line: [96]u8
	n := 0

	n = put_word(line[:], n, "size ")
	n = put_dec(line[:], n, u64(s.width))
	n = put_word(line[:], n, " ")
	n = put_dec(line[:], n, u64(s.height))
	n = put_word(line[:], n, "\npitch ")
	n = put_dec(line[:], n, u64(s.pitch))
	n = put_word(line[:], n, "\ndepth ")
	n = put_dec(line[:], n, u64(s.bytes_pp) * 8)
	n = put_word(line[:], n, "\nr ")
	n = put_dec(line[:], n, u64(s.red_size))
	n = put_word(line[:], n, " ")
	n = put_dec(line[:], n, u64(s.red_shift))
	n = put_word(line[:], n, "\ng ")
	n = put_dec(line[:], n, u64(s.green_size))
	n = put_word(line[:], n, " ")
	n = put_dec(line[:], n, u64(s.green_shift))
	n = put_word(line[:], n, "\nb ")
	n = put_dec(line[:], n, u64(s.blue_size))
	n = put_word(line[:], n, " ")
	n = put_dec(line[:], n, u64(s.blue_shift))
	n = put_word(line[:], n, "\n")

	if offset >= u64(n) {
		return nil
	}
	start := int(offset)
	end := min(n, start + len(buf))
	copy(buf[:end - start], line[start:end])
	return buf[:end - start]
}

// put_word appends a literal to the report under construction. The report
// buffer is sized for the longest report a mode can produce. Overflow is
// therefore truncation rather than a fault, and the self-test would catch
// it as a wrong report.
@(private = "file")
put_word :: proc "contextless" (line: []u8, at: int, word: string) -> int #no_bounds_check {
	n := at
	for i in 0 ..< len(word) {
		if n >= len(line) {
			return n
		}
		line[n] = word[i]
		n += 1
	}
	return n
}

// put_dec appends a number in decimal. The one formatter this package
// needs, written here rather than imported, because the layer a fault
// handler runs in should not grow a dependency for ten lines.
@(private = "file")
put_dec :: proc "contextless" (line: []u8, at: int, value: u64) -> int #no_bounds_check {
	digits: [20]u8
	v := value
	d := 0
	for {
		digits[d] = '0' + u8(v % 10)
		v /= 10
		d += 1
		if v == 0 {
			break
		}
	}

	n := at
	for d > 0 {
		d -= 1
		if n >= len(line) {
			return n
		}
		line[n] = digits[d]
		n += 1
	}
	return n
}

// -- The console steps aside -------------------------------------------------

/*
While something holds `/dev/fb`, the kernel's console draws somewhere else.

**Two things cannot paint one screen.** `servers/intuition` attaches the
framebuffer and composites windows into it, and this console writes the boot
log into the same memory. Whichever ran last won, and neither knew about the
other. That is the state `docs/DRAW.md` section 11 recorded as the thing
standing between a compositor and a desktop.

The rule is `tap.odin`'s, one device further out. A tap diverts the keyboard's
stream while something holds `/dev/scancode`, and the last close gives it back.
This diverts the screen. The console keeps writing, at its own pace, into a
copy of the glass instead of the glass. Nothing is lost and nothing is
serialised.

**The revert is a blit, and that is why the console needed no scrollback.** The
first idea here was to give the console a grid of cells to repaint from, which
is a terminal's answer and a large one. A shadow surface is smaller and says
more. The console draws with the code it always had, onto a surface with the
same shape, and coming back is one copy. It also carries what a cell grid could
not. That is the boot chassis, which the console never drew.

Whoever held the screen may have painted anywhere. The revert therefore puts
back the whole frame, not the console's own well.

**A shadow that cannot be bought is no divert at all.** Four megabytes of
contiguous frames is the whole cost. A machine too tight for it keeps the
behaviour it had. Two writers on one screen, the way every milestone before
this one ran. That is the safe degradation, and it is checked rather than
assumed.
*/

@(private = "file")
Shadow :: struct {
	surface: fb.Surface,
	pages:   int,
	ready:   bool,
}

@(private = "file")
shadow: Shadow

// Which console is diverted, or nil while the console has the glass. One
// pointer rather than a count, because the count that matters is the fid
// count `devfs.odin` already keeps.
@(private = "file")
diverted: ^console.Console

/*
shadow_ready buys the copy, once, and keeps it.

Once rather than per divert, because a divert happens whenever anything opens
`/dev/fb`. A self-test, a painter, the compositor. Asking the physical
allocator for a thousand contiguous frames on each of those is a way to fail
late for no reason. Nothing frees it. The screen does not get smaller.
*/
@(private = "file")
shadow_ready :: proc "contextless" (raw: ^fb.Surface) -> bool {
	if shadow.ready {
		return true
	}
	span := raw.pitch * raw.height
	if span <= 0 {
		return false
	}
	pages := (span + arch.PAGE_SIZE - 1) / arch.PAGE_SIZE
	base, ok := mem.alloc_pages(pages)
	if !ok {
		return false
	}
	shadow.surface = raw^
	shadow.surface.pixels = cast([^]u8)mem.phys_to_virt(base)
	shadow.pages = pages
	shadow.ready = true
	return true
}

/*
screen_divert points the console at the copy, and seeds the copy with what is
on the glass.

The seed is what makes the revert whole. A console that started on a blank
shadow would give back a screen with no chassis and no earlier log, because it
never drew either.

**Called on the first open of `/dev/fb`, and it does not check that for
itself.** That is `tap_start`'s arrangement exactly, and a control is why it
is this one. The first cut guarded on `diverted` here as well, and the mutation
that made every open divert changed nothing, because this refused the second
call. Two places holding one invariant means neither one holds it, which is the
second time this project ran into that.

So the gate is `mark_open`'s, in one place, where the taps keep theirs. A
second call here would seed the copy again and throw away everything the
console drew into it. The self-test is what says it does not happen.
*/
@(private)
screen_divert :: proc "contextless" (con: ^console.Console, raw: ^fb.Surface) {
	if con == nil || raw == nil || raw.pixels == nil {
		return
	}
	if !shadow_ready(raw) {
		return
	}
	span := raw.pitch * raw.height
	for i in 0 ..< span {
		shadow.surface.pixels[i] = raw.pixels[i]
	}
	con.surface = &shadow.surface
	diverted = con
}

/*
screen_revert gives the glass back, and puts on it everything the console drew
while it was away.

The whole frame, because whoever held `/dev/fb` could have painted any of it.
The console's own well would leave a compositor's last windows on the screen
after the compositor went.

Called on the last close of `/dev/fb`. The `diverted` test here is not the
mirror of the one above. It stops a revert that arrived first from blitting a
copy nobody bought yet. The gate is still `drop_fid`'s.
*/
@(private)
screen_revert :: proc "contextless" (con: ^console.Console, raw: ^fb.Surface) {
	if diverted == nil || con == nil || raw == nil || raw.pixels == nil {
		return
	}
	span := raw.pitch * raw.height
	for i in 0 ..< span {
		raw.pixels[i] = shadow.surface.pixels[i]
	}
	con.surface = raw
	diverted = nil
}

// screen_diverted is the sensor the checks read: whether the console is
// drawing somewhere other than the glass right now.
@(private)
screen_diverted :: proc "contextless" () -> bool {
	return diverted != nil
}

