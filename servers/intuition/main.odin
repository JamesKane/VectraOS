/*
intuition -- the draw server `docs/DRAW.md` designed, with windows.

**Image zero is the session's window, not the screen.** That sentence was
the test this topology was chosen to pass, and it cost the protocol
nothing: the six verbs, their bodies and their rules are what they were,
and a client that drew to image zero before this milestone draws to its
own window now without changing a line.

A client cannot name the screen. It has no verb that reaches past its
window's edge, no way to learn where its window sits, and no way to ask
for another. That is the whole of the isolation, and it is one clip in
`run_fill` and `run_blit`.

**And now a window has pixels of its own.** Each one holds a run of
anonymous memory from `segalloc`, and a draw is a store into that rather
than onto the glass. `flush` is what walks the damage onto the screen,
which is the promise `docs/DRAW.md` section 6 made without saying how.

**And under them, a desktop.** This server owns every pixel of the screen
while it runs, because `/dev/fb` diverts the kernel's console for as long
as it holds the descriptor. So a window is opaque over its whole rectangle,
and what a window uncovers is ground rather than whatever was there before.

Three things follow, and the third is the one worth the milestone:

    windows overlap    placement kept them apart because a window was a
                       clip. It is a store now, so the overlap is this
                       server's arithmetic
    slots stack        slot order is stacking order, and `composite`
                       paints back to front. That is all of occlusion
    nobody repaints    a covered client is never told, because it has
                       nothing to redraw. Its pixels were its own the
                       whole time it was hidden

**There is no expose event, and a backing store is the reason there is
none.** `docs/DRAW.md` section 9 deferred refresh events with windows as
their trigger. The trigger arrived and retired the feature instead: a
compositor that holds the pixels answers the question the event was going
to ask.

The tenant shape is `ramfs`'s, not `consrv`'s, because nothing here
parks. A draw command runs to completion -- the framebuffer takes a write
at its own pace and never waits for hardware -- so one serve loop answers
everything inline, and the server needs no fork, no worker, and no lock.

The tree is `docs/DRAW.md` section 4's:

    /data    the command stream, one session per fid, one window per session
    /ctl     text lines in, the geometry of a window out

**`ctl` reports the window rather than the screen**, and that is the second
half of a client not knowing where it is. Every window is the same size, so
one report answers for all of them, and a client that reads it learns how
big it is and nothing about the glass.

A session's images live in a static pool, because ring 3 has no
allocator. The pool is eight images of 2048 pixels each, which is a
cursor and a glyph set's worth. The pool is a cap to raise, not a design:
a fid owns what it allocates, and a clunk gives it back.

**The screen is memory, not a file this server writes to.** `/dev/fb` is
opened for the namespace's sake and attached with `segattach`, and every
draw after that is a store. `docs/DRAW.md` section 7 argued the mapping a
milestone before it existed, and named its trigger: the day this server
touches whole frames every round.

That is the one privilege this process has over its clients, and section 2
is why it is not a feature the protocol owes them. A client sends commands.
The server, which *is* the compositor, holds the glass.

Every draw is still clipped to its destination first, so a client's mistake
is an answer rather than a store past the end of its window. The bound is
this server's arithmetic now, where it used to be the file's.
*/
package intuition

import "base:runtime"

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libpal"
import "vsys:libuser"
import "vsys:vectra9"

/*
The tree, and the numbered directories `docs/DRAW.md` section 4 said it would
grow into.

    /new       read it, and it answers which window has no session
    /N/data    the command stream, and the claim on window N
    /N/ctl     window N's geometry out, and its control lines in

**A flat tree could not say which window a `ctl` line was about.** A session
was a fid on `data`, and a `ctl` fid opened from the root belonged to nobody.
That was fine while `ctl` only reported a geometry every window shared. A line
that moves a window has to name one.

Plan 9's `/dev/draw` is numbered directories for this reason, and section 4
recorded the growth as a thing that would cost the wire nothing. It did not:
these are ordinary walks of ordinary names.

`new` is advice rather than an allocation. It answers the lowest window with no
session, and the *claim* is the `Tlopen` of that window's `data`. A client that
loses a race opens a window somebody else took and is refused, which is the
same answer it would get from any other allocator this server could write.
*/
NODE_ROOT :: i32(0)
NODE_NEW :: i32(1)

// A window's three nodes, in one block apiece after the two fixed ones.
NODE_BASE :: i32(2)
NODE_PER :: i32(3)
PART_DIR :: i32(0)
PART_DATA :: i32(1)
PART_CTL :: i32(2)

// A window's directory name is `libdraw.win_name`, which both this server and
// its clients read so the tree's layout is stated once. One digit per window,
// which is the bound `MAX_WINDOWS` has to stay inside.
#assert(MAX_WINDOWS <= 10)

node_of :: proc "contextless" (win: int, part: i32) -> i32 {
	return NODE_BASE + i32(win) * NODE_PER + part
}

// node_win is which window a node belongs to, or -1 for the two fixed ones.
node_win :: proc "contextless" (node: i32) -> int {
	if node < NODE_BASE {
		return -1
	}
	w := int((node - NODE_BASE) / NODE_PER)
	if w >= MAX_WINDOWS {
		return -1
	}
	return w
}

node_part :: proc "contextless" (node: i32) -> i32 {
	if node < NODE_BASE {
		return -1
	}
	return (node - NODE_BASE) % NODE_PER
}

/*
The windows, and the placement policy that hands them out.

Two, and they **overlap**. A session gets one when it opens `data` and gives it
back when the fid goes, which makes the assignment as automatic as the image
pool's and needs no protocol for it.

**They did not overlap before this milestone, and the placement was what
stopped them.** A window was a clip onto the glass, so two clients on the same
pixel would have taken turns destroying each other's work. Placement had to
keep them apart. A window with pixels of its own removes that reason: the
overlap is the compositor's arithmetic now, and a covered client is not even
told, because it has nothing to redraw.

So the policy is a cascade. Window `i` sits half a window to the right of
window `i-1`, and **a higher slot is higher in the stack**. Slot order is
stacking order, which is the simplest rule that has an answer for every pixel
and is what makes occlusion testable at all.

**A client cannot choose.** `docs/DRAW.md` section 5 names scope creep as the
failure mode the verb table guards, and a window a client places is a verb or a
`ctl` line that nothing yet needs. The day something does, it is a line on
`ctl` and not a seventh verb.

`MAX_WINDOWS` is a cap to raise rather than a design. Two is what the self-test
needs to prove that a second client cannot reach the first's pixels, and now
that one client's pixels survive being covered by the other.
*/
MAX_WINDOWS :: 2

// A half-open rectangle, in whichever coordinates its holder keeps.
Rect :: struct {
	x0: int,
	y0: int,
	x1: int,
	y1: int,
}

rect_empty :: proc "contextless" (r: Rect) -> bool {
	return r.x0 >= r.x1 || r.y0 >= r.y1
}

/*
How many rectangles one region holds before it gives up and becomes a box.

Sixteen, chosen against the client that draws the most rectangles per flush.
`apps/terminal` blits one image per glyph, forty-two of them across a line, and
the merge below folds a row of them into one. What survives to be counted is
the number of *bands* a client draws, and a client that draws more than sixteen
disjoint bands in one batch is asking for a bounding box.
*/
MAX_RECTS :: 16

/*
A region: a bounded bag of rectangles whose union is what it means.

**Overlaps are allowed, and that is the simplification the whole file rests
on.** A region of disjoint rectangles needs a subtract, and a subtract needs a
split, and a split is where rectangle algebra goes wrong. Nothing here needs
disjointness, because everything a region drives is *idempotent*: painting a
pixel from a window's store twice puts the same value there twice. So a region
may say a pixel twice, and the only cost is the second copy.

**Running out of rectangles is a collapse to the bounding box.** That is
exactly what this file did before it had regions, so the degradation is to the
last milestone's behaviour rather than to a wrong answer. A region is never
smaller than the truth, which is the invariant that makes the collapse safe:
too much damage is a slow flush, and too much *coverage* would be a wrong
pixel, which is why only damage ever collapses.
*/
Region :: struct {
	rects: [MAX_RECTS]Rect,
	n:     int,
}

region_clear :: proc "contextless" (r: ^Region) {
	r.n = 0
}

/*
region_add puts one rectangle in, and tries three cheaper answers first.

Contained in one already, adjacent to one along a shared edge, or new. The
merge is what keeps a line of glyphs from costing a rectangle apiece: each
blit lands beside the last with the same top and bottom, so the second widens
the first and the region stays at one.

A full region collapses to its bounding box and stays there. See `Region`.
*/
region_add :: proc "contextless" (r: ^Region, x: int, y: int, w: int, h: int) #no_bounds_check {
	if w <= 0 || h <= 0 {
		return
	}
	nx0, ny0, nx1, ny1 := x, y, x + w, y + h

	for i in 0 ..< r.n {
		e := &r.rects[i]
		// Already said.
		if e.x0 <= nx0 && e.y0 <= ny0 && e.x1 >= nx1 && e.y1 >= ny1 {
			return
		}
		// Side by side, same band: widen.
		if e.y0 == ny0 && e.y1 == ny1 && nx0 <= e.x1 && e.x0 <= nx1 {
			e.x0 = min(e.x0, nx0)
			e.x1 = max(e.x1, nx1)
			return
		}
		// Stacked, same columns: heighten.
		if e.x0 == nx0 && e.x1 == nx1 && ny0 <= e.y1 && e.y0 <= ny1 {
			e.y0 = min(e.y0, ny0)
			e.y1 = max(e.y1, ny1)
			return
		}
	}

	if r.n < MAX_RECTS {
		r.rects[r.n] = Rect{nx0, ny0, nx1, ny1}
		r.n += 1
		return
	}

	box := Rect{nx0, ny0, nx1, ny1}
	for i in 0 ..< r.n {
		e := r.rects[i]
		box.x0 = min(box.x0, e.x0)
		box.y0 = min(box.y0, e.y0)
		box.x1 = max(box.x1, e.x1)
		box.y1 = max(box.y1, e.y1)
	}
	r.rects[0] = box
	r.n = 1
}

/*
The desktop, and the three colours this server owns.

**`sys/libpal` named `SLATE_DEEP` the desktop ground a milestone before there
was a desktop.** These are that table, packed at compile time -- the shift is
written out because `xrgb` is a procedure and a procedure cannot be the
right-hand side of a constant. `libpal` records that shape rather than leaving
each call site to work it out.

The grid is `VOID`, which is *darker* than the ground. A lighter grid draws
attention to itself. A darker one reads as engraved, which is the same trick
`console.Style.Engraved` plays on text and the reason the whole chassis looks
like metal.

`WIN_GROUND` is `SLATE`, the palette's recessed well. A window is a sunken
panel in this idiom, and a client that draws nothing gets one.
*/
DESK_GROUND :: u32(libpal.SLATE_DEEP[0]) << 16 | u32(libpal.SLATE_DEEP[1]) << 8 | u32(libpal.SLATE_DEEP[2])
DESK_GRID :: u32(libpal.VOID[0]) << 16 | u32(libpal.VOID[1]) << 8 | u32(libpal.VOID[2])
DESK_STEP :: 32
WIN_GROUND :: u32(libpal.SLATE[0]) << 16 | u32(libpal.SLATE[1]) << 8 | u32(libpal.SLATE[2])

/*
The desktop's own chrome: the edge it is sunk into, and a lamp per window.

**This is `kernel/splash.odin`'s vocabulary one privilege level out.** The
chassis file says its window frames should be recognisably the same object as
the screen the kernel painted, and that could not happen while bevels were
surface painters in ring 0. `sys/libdraw`'s `panel`, `well` and `lamp` are that
vocabulary as rectangles, and this is a server drawing with it.

The screen is a recessed well, so the desktop reads as sunk into a machine
rather than as a colour somebody chose. The lamps sit down the right edge,
which is the one column of desktop two half-screen windows never cover, and
each says whether that window has a session. A compositor knows that and has
nothing else worth a lamp yet.
*/
DESK_EDGE :: 2
LAMP :: 12
LAMP_GAP :: 6
LAMP_INSET :: 20

// desk_at is the desktop's colour at one screen pixel. Positional rather than
// stored, so any rectangle of it can be repainted exactly, in any order, with
// nothing to keep between.
desk_at :: proc "contextless" (x: int, y: int) -> u32 {
	if x % DESK_STEP == 0 || y % DESK_STEP == 0 {
		return DESK_GRID
	}
	return DESK_GROUND
}

/*
desk_paint puts the desktop on one screen rectangle.

Called for the whole screen once at start, and for what a window uncovers when
it closes. Never per flush: nothing else paints the glass while this server
holds it, so the desktop under a window that has not moved is still there.
*/
desk_paint :: proc "contextless" (sx0: int, sy0: int, sx1: int, sy1: int) #no_bounds_check {
	x0 := max(sx0, 0)
	y0 := max(sy0, 0)
	x1 := min(sx1, scr_w)
	y1 := min(sy1, scr_h)
	/*
	The row test is hoisted out of the column loop, because it is the same
	answer for every pixel of a row.

	A grid row is one colour across. Any other row is ground with a stripe
	every `DESK_STEP` columns, so the columns are strided rather than tested.
	Two modulo operations per pixel became one per row, over a loop that runs a
	million times at start and half that on every close, move and resize.
	*/
	for y in y0 ..< y1 {
		dst := screen_at(y)
		if y % DESK_STEP == 0 {
			for x in x0 ..< x1 {
				dst[x] = DESK_GRID
			}
			continue
		}
		for x in x0 ..< x1 {
			dst[x] = DESK_GROUND
		}
		for x := ((x0 + DESK_STEP - 1) / DESK_STEP) * DESK_STEP; x < x1; x += DESK_STEP {
			dst[x] = DESK_GRID
		}
	}
	desk_chrome(x0, y0, x1, y1)
}

/*
desk_band lays ground on the part of one rectangle a second one of the same
size does not cover.

Two rectangles of equal extent overlap in at most one rectangle, so what the
first one frees is at most two bands: a vertical one where they do not share
columns, and a horizontal one where they do not share rows. Each is skipped
when it is empty, so a window that does not move paints nothing.
*/
desk_band :: proc "contextless" (ox: int, oy: int, w: int, h: int, nx: int, ny: int) {
	dx := nx - ox
	dy := ny - oy
	if dx >= w || -dx >= w || dy >= h || -dy >= h {
		// Nothing shared: the whole of it is freed.
		desk_paint(ox, oy, ox + w, oy + h)
		return
	}
	if dx > 0 {
		desk_paint(ox, oy, ox + dx, oy + h)
	} else if dx < 0 {
		desk_paint(ox + w + dx, oy, ox + w, oy + h)
	}
	// The horizontal band, clipped to the columns the vertical one did not
	// already take, so a diagonal move pays for each pixel once.
	kx0 := dx > 0 ? ox + dx : ox
	kx1 := dx < 0 ? ox + w + dx : ox + w
	if dy > 0 {
		desk_paint(kx0, oy, kx1, oy + dy)
	} else if dy < 0 {
		desk_paint(kx0, oy + h + dy, kx1, oy + h)
	}
}

/*
desk_chrome paints the parts of the desktop that are not ground: the edge the
screen is sunk into, and the lamps.

Clipped to the rectangle asked for, like everything else here, so the same call
serves the whole screen at start and the strip a window uncovers when it moves.
Both are `pieces` walked through one clipped fill.
*/
desk_chrome :: proc "contextless" (sx0: int, sy0: int, sx1: int, sy1: int) #no_bounds_check {
	pieces: [libdraw.MAX_PIECES]libdraw.Piece

	n := libdraw.panel(
		pieces[:],
		0,
		0,
		scr_w,
		scr_h,
		.Recessed,
		libpal.SLATE_DEEP,
		libpal.MAGNESIUM_LIT,
		libpal.VOID,
		DESK_EDGE,
	)
	// The face is the ground `desk_paint` already laid, grid and all. Only the
	// edges are this call's, so the first piece is skipped.
	desk_pieces(pieces[1:n], sx0, sy0, sx1, sy1)

	for i in 0 ..< MAX_WINDOWS {
		x, y := lamp_at(i)
		ln := libdraw.lamp(pieces[:], x, y, LAMP, libpal.PHOSPHOR, windows[i].used)
		desk_pieces(pieces[:ln], sx0, sy0, sx1, sy1)
	}
}

// lamp_at is where window `i`'s indicator sits: down the right edge, in the
// one column of desktop two half-screen windows never reach.
lamp_at :: proc "contextless" (i: int) -> (int, int) {
	return scr_w - LAMP_INSET - LAMP, LAMP_INSET + i * (LAMP + LAMP_GAP)
}

// desk_pieces stores a run of chrome onto the glass, each rectangle clipped to
// the region being repainted and to the screen.
desk_pieces :: proc "contextless" (pieces: []libdraw.Piece, sx0: int, sy0: int, sx1: int, sy1: int) #no_bounds_check {
	for p in pieces {
		x0 := max(max(p.x, sx0), 0)
		y0 := max(max(p.y, sy0), 0)
		x1 := min(min(p.x + p.w, sx1), scr_w)
		y1 := min(min(p.y + p.h, sy1), scr_h)
		word := libpal.xrgb(p.color)
		for y in y0 ..< y1 {
			dst := screen_at(y)
			for x in x0 ..< x1 {
				dst[x] = word
			}
		}
	}
}

/*
One window: where it sits, the memory behind it, and the damage it owes.

`pixels` is a run of anonymous memory from `segalloc`, `w * h` words of it,
and **it belongs to the slot rather than to the session**. A clunk gives the
slot back and keeps the run, because there is no call that gives a run back.
`docs/USER.md` names the three Plan 9 has and Vectra does not, and `segfree` is
the one this line is waiting for.

`dmg` is what this client drew since its last `flush`, and it is the only
region a window keeps now.

**A window owns its whole rectangle.** That sentence took three milestones and
cost two mechanisms on the way. First a magic pixel value said which pixels a
window had drawn on, and a client paid for it by not being able to paint black.
Then a `covered` region said the same thing without the colour. Both existed
because there was nothing underneath a window: what lay under one was the
kernel's own boot chassis, and painting over it was worse than holding back.

There is a desktop under one now, so a window is opaque and the question is
gone. `docs/DEVFS.md` has what actually unblocked it, and it was not a graphics
change: `/dev/fb` diverts the console, so this server owns the glass for as long
as it holds the screen.

The cost came back the other way. A store handed to a new session must be
cleared, because every pixel of it is on the screen now whether the client drew
it or not. That is two megabytes at each `Tlopen`, which `covered` had bought
its way out of and a desktop buys back.
*/
Window :: struct {
	owner:  vectra9.Fid,
	x:      int,
	y:      int,
	w:      int,
	h:      int,

	// The store. Every window's run is `win_w` by `win_h`, allocated once at
	// the birth size and never grown, so those two globals are the stride and
	// the bound and this struct does not carry a second copy of them. `w` and
	// `h` move inside that. A `size` line past it is refused, and `segbrk` is
	// the Plan 9 call that would lift that -- see `docs/USER.md`.
	pixels: [^]u32,

	dmg:    Region,
	used:   bool,

	// The `ctl` file is exclusive the way `data` is. One fid at a time holds
	// a window's controls, so two clients cannot both move one window.
	ctl_fid:  vectra9.Fid,
	ctl_held: bool,
}

/*
The stacking order, bottom to top, as window indices.

Slot order was stacking order until a client could ask to be raised. It cannot
be both, so the stack is its own list now: `raise` lifts one entry to the end
and `composite` walks it in order. A window's index is where its memory is, and
its place in here is where it is on the screen.
*/
stack: [MAX_WINDOWS]int
stack_n: int

// stack_add puts a new window on top. stack_drop takes one out and closes the
// gap, which keeps the order of everything under it.
stack_add :: proc "contextless" (win: int) #no_bounds_check {
	stack_drop(win)
	stack[stack_n] = win
	stack_n += 1
}

stack_drop :: proc "contextless" (win: int) #no_bounds_check {
	at := -1
	for i in 0 ..< stack_n {
		if stack[i] == win {
			at = i
			break
		}
	}
	if at < 0 {
		return
	}
	for i in at ..< stack_n - 1 {
		stack[i] = stack[i + 1]
	}
	stack_n -= 1
}

/*
Where a composite builds the screen-coordinate region it is about to paint.

A package variable rather than a local, because a `Region` is half a kilobyte
and this server's stack is a program's. Safe as a single variable for the
reason this file has no lock: one serve loop, inline, nothing parks.
*/
scratch: Region

windows: [MAX_WINDOWS]Window

// The image pool. Image zero is the session's window and lives nowhere; these
// are the client's own images, owned by the fid that allocated each.
MAX_IMAGES :: 8
IMG_PIXELS :: 2048

Image :: struct {
	owner:  vectra9.Fid,
	id:     u32,
	w:      int,
	h:      int,
	used:   bool,
}

images: [MAX_IMAGES]Image
pixels: [MAX_IMAGES][IMG_PIXELS]u32

/*
The screen itself, once `segattach` answers.

A `[^]u32` rather than bytes, because every mode this server accepts is 32
bits per pixel and `read_geometry` refuses anything else at start. The pitch
is in bytes and is divided down once, so the per-row arithmetic is an index
rather than a multiply and a cast.
*/
glass: [^]u32
glass_stride: int

/*
The screen's geometry, read from `/dev/fbctl` once at start, and the window
geometry served on `/ctl` in its place.

Two reports, and the second is the only one a client sees. `/dev/fbctl` says
how big the glass is, which is what the placement arithmetic below needs. A
window's own `/N/ctl` says how big *that* window is, built when it is asked
because a client can change it. See `window_report`.
*/
geo: [160]u8
scr_w: int
scr_h: int
scr_pitch: int
win_w: int
win_h: int

// The framebuffer descriptor. Open for the server's whole life, because the
// attach is a claim on the file rather than a copy of it.
fb_fd: int



fids: libuser.Fid_Table

FRAME :: 1200
frame_in: [FRAME]u8
frame_out: [FRAME]u8
payload: [1024]u8

/*
_start opens the screen, learns its shape, and serves.

The exits each name their failure. 0x74 is a framebuffer that would not
open, 0x76 a geometry this server cannot draw on -- fewer than four
numbers, a depth other than 32, or a cascade that would not fit -- 0x77 a
screen that would not map, 0x78 a window that could not buy its pixels,
and 0x71 a post that failed. The serve loop's three endings are `ramfs`'s,
numbers and all.
*/
@(export, link_name = "_start")
start :: proc "sysv" (data: uintptr, arg: u64, arg2: u64) {
	context = {}
	#force_no_inline runtime._startup_runtime()

	fd := libuser.open("/dev/fb", abi.O_WRONLY)
	if fd < 0 {
		libuser.exit(0x74)
	}
	fb_fd = int(fd)

	ctl := libuser.open("/dev/fbctl", abi.O_RDONLY)
	if ctl < 0 {
		libuser.exit(0x74)
	}
	n := libuser.read(int(ctl), geo[:])
	_ = libuser.close(int(ctl))
	if n <= 0 || !read_geometry(geo[:int(n)]) {
		libuser.exit(0x76)
	}


	// The mapping, and the reason this server has no write path left. A
	// failure here is fatal rather than a fallback: a second path to the same
	// pixels would be a second thing to keep correct, and the self-test could
	// not tell which one drew.
	base, aerr := libuser.segattach(fb_fd)
	if aerr < 0 {
		libuser.exit(0x77)
	}
	glass = ([^]u32)(base)
	glass_stride = scr_pitch / 4

	// And the windows' own memory, which is the other call that answers with
	// an address rather than with bytes. Fatal for the reason the mapping is:
	// a window without a store is a window this server cannot serve.
	if !windows_init() {
		libuser.exit(0x78)
	}

	// And the ground everything stands on. From here this server owns every
	// pixel of the screen: `/dev/fb` diverts the console for as long as the
	// descriptor above is open, so nothing else is painting.
	desk_paint(0, 0, scr_w, scr_h)

	sfd, perr := libuser.post("/srv/draw")
	if perr < 0 {
		libuser.exit(0x71)
	}

	_, why := libuser.serve(sfd, handler, nil, frame_in[:], frame_out[:], payload[:])
	switch why {
	case .Removed:
		libuser.exit(0)
	case .Hangup:
		libuser.exit(0x68)
	case .Broken:
		libuser.exit(0x72)
	}
}

/*
read_geometry takes what `libdraw.parse_geometry` decodes and keeps only
a shape this server can draw on. The channel lines after the numbers are
not read -- one pixel format is the v1 rule, and a depth other than 32
is refused at start rather than mid-draw.
*/
read_geometry :: proc "contextless" (report: []u8) -> bool {
	w, h, pitch, depth, ok := libdraw.parse_geometry(report)
	if !ok || depth != 32 {
		return false
	}
	scr_w = w
	scr_h = h
	scr_pitch = pitch
	if scr_w <= 0 || scr_h <= 0 || scr_pitch < scr_w * 4 || scr_pitch % 4 != 0 {
		return false
	}

	/*
	Columns, full height, cascaded by half a window.

	The width is still the screen over `MAX_WINDOWS`, so a window is the size
	it always was and every client reads the same `ctl` report it read before.
	What changed is where the second one goes: half a window right of the
	first, so the two overlap by half. `windows_init` does the placement, and
	this only has to prove it fits.

	The last window ends at `(MAX_WINDOWS - 1) * win_w / 2 + win_w`. At two
	windows on this screen that is 960 of 1280. A cascade that ran off the
	right edge would be a placement policy this server cannot honour, and a
	geometry it cannot draw on is what it already refuses at start.
	*/
	win_w = scr_w / MAX_WINDOWS
	win_h = scr_h
	if win_w <= 0 {
		return false
	}
	return (MAX_WINDOWS - 1) * (win_w / 2) + win_w <= scr_w
}

/*
window_report writes the geometry a client reads off `/ctl`.

The same four numbers `/dev/fbctl` uses, so `libdraw.parse_geometry` reads
either. The pitch is the window's own row in bytes, which is a number a client
never needs and would be wrong to act on: nothing here lets a client address
its window by offset.
*/
window_report :: proc "contextless" (out: []u8, win: ^Window) -> int #no_bounds_check {
	at := 0
	at = put_report(out, at, "size ")
	at = put_number(out, at, win.w)
	at = put_report(out, at, " ")
	at = put_number(out, at, win.h)
	at = put_report(out, at, " ")
	at = put_number(out, at, win.w * 4)
	at = put_report(out, at, " 32\n")
	return at
}

/*
The control lines, and the whole of what a client may say about its window.

    move X Y     put it somewhere else
    size W H     make it another shape, inside the run it was born with
    raise        bring it to the front

Three lines rather than three verbs, which is the distinction `docs/DRAW.md`
section 5 has guarded since there were six verbs and nothing else. A verb is
about pixels. A window is not a pixel.

**A line is refused unless the window has a session.** A `ctl` fid outlives
nothing, but a window with no client is not a window, and moving one would be
moving furniture in an empty room.

Unknown lines are `EINVAL`, and a malformed number is the same answer. There is
no partial application: a line either happens or does not.
*/
run_ctl :: proc "contextless" (win_at: int, data: []u8) -> vectra9.Errno #no_bounds_check {
	if win_at < 0 || win_at >= MAX_WINDOWS {
		return vectra9.EINVAL
	}
	win := &windows[win_at]
	if !win.used {
		return vectra9.EBADF
	}

	verb, at := ctl_word(data, 0)
	switch verb {
	case "move":
		x, y, ok := ctl_pair(data, &at)
		if !ok {
			return vectra9.EINVAL
		}
		return window_move(win, x, y)
	case "size":
		w, h, ok := ctl_pair(data, &at)
		if !ok {
			return vectra9.EINVAL
		}
		return window_size(win, w, h)
	case "raise":
		if !ctl_end(data, at) {
			return vectra9.EINVAL
		}
		window_raise(win, win_at)
		return vectra9.Errno(0)
	}
	return vectra9.EINVAL
}

// ctl_word takes the next run of non-space bytes, and answers where it ended.
@(private = "file")
ctl_word :: proc "contextless" (data: []u8, from: int) -> (string, int) #no_bounds_check {
	at := from
	for at < len(data) && (data[at] == ' ' || data[at] == '\t') {
		at += 1
	}
	start := at
	for at < len(data) && data[at] != ' ' && data[at] != '\t' && data[at] != '\n' {
		at += 1
	}
	return string(data[start:at]), at
}

/*
ctl_pair takes the two numbers every line here carries, and the end of the
line with them.

Both lines that take operands take exactly two, and neither wants half of a
malformed one. `libdraw.scan_int` is the digit loop, shared with the report
`parse_geometry` reads and with the client that reads `new` -- one scanner for
one text convention, which is the rule `parse_geometry`'s own comment sets.
*/
@(private = "file")
ctl_pair :: proc "contextless" (data: []u8, at: ^int) -> (int, int, bool) {
	a, ok1 := libdraw.scan_int(data, at)
	b, ok2 := libdraw.scan_int(data, at)
	return a, b, ok1 && ok2 && ctl_end(data, at^)
}

// ctl_end reports whether what is left is nothing but space and one newline.
// A line with a word too many is a line this server did not understand.
@(private = "file")
ctl_end :: proc "contextless" (data: []u8, from: int) -> bool #no_bounds_check {
	for i in from ..< len(data) {
		if data[i] != ' ' && data[i] != '\t' && data[i] != '\n' && data[i] != '\r' {
			return false
		}
	}
	return true
}

@(private = "file")
put_report :: proc "contextless" (out: []u8, at: int, text: string) -> int #no_bounds_check {
	n := at
	for i in 0 ..< len(text) {
		if n >= len(out) {
			return n
		}
		out[n] = text[i]
		n += 1
	}
	return n
}

@(private = "file")
put_number :: proc "contextless" (out: []u8, at: int, value: int) -> int #no_bounds_check {
	digits: [20]u8
	n := 0
	v := u64(value)
	if v == 0 {
		digits[0] = '0'
		n = 1
	}
	for v > 0 {
		digits[n] = u8('0' + v % 10)
		v /= 10
		n += 1
	}
	out_at := at
	for i := n - 1; i >= 0; i -= 1 {
		if out_at >= len(out) {
			return out_at
		}
		out[out_at] = digits[i]
		out_at += 1
	}
	return out_at
}

// -- The windows --------------------------------------------------------------

/*
windows_init places every window and buys its pixels, once, at start.

**The run is asked for here rather than at `Tlopen`, and that is what having
no `segfree` means.** A slot's memory cannot go back, so it must not be tied to
a session that comes and goes. It is bought once, for the life of the server,
and lent to whichever session holds the slot. A failure here is a server that
does not start, which is the honest place for it: the alternative is a
`Tlopen` that fails for a reason the client cannot act on.

`MAX_WINDOWS` runs of `win_w * win_h * 4` bytes each. At 640 by 800 that is
just under two megabytes apiece, which is the arithmetic `docs/DRAW.md`
section 10 wrote down a milestone before this call existed.

False is no memory. The caller exits, and says so with a number.
*/
windows_init :: proc "contextless" () -> bool #no_bounds_check {
	for i in 0 ..< MAX_WINDOWS {
		base, err := libuser.segalloc(win_w * win_h * 4)
		if err < 0 {
			return false
		}
		windows[i] = Window {
			x      = i * (win_w / 2),
			y      = 0,
			w      = win_w,
			h      = win_h,
			pixels = ([^]u32)(base),
		}
	}
	return true
}

/*
window_free is which window has no session, for `new` to answer with.

Advice rather than an allocation. Nothing is reserved by asking, and the claim
is the `Tlopen` below. A client that loses the race between the two is refused
by name, which is the honest answer and the only one this server could give
without a lease.
*/
window_free :: proc "contextless" () -> int #no_bounds_check {
	for i in 0 ..< MAX_WINDOWS {
		if !windows[i].used {
			return i
		}
	}
	return -1
}

/*
window_open claims window `at` for this fid, or reports that somebody has it.

**The claim is by index now, because the tree is numbered.** A session used to
be handed whichever window was free, and could not be told which. It walks to
one by name and takes it, so a `ctl` line has something to be about.

The store is cleared, and a window owning its rectangle is why it must be. A
run outlives the session it was lent to, so the last client's drawing is still
in it, and every pixel of a window is on the screen. An uncleared slot would
put the last client's work on the glass under the new client's name.

The whole allocation is cleared rather than the current size, because a `size`
line can grow a window back into the part this one never used.

The composite at the end is the window appearing. It walks the stack, so a
window that opens under another shows up occluded rather than on top.
*/
window_open :: proc "contextless" (owner: vectra9.Fid, at: int) -> bool #no_bounds_check {
	if at < 0 || at >= MAX_WINDOWS {
		return false
	}
	win := &windows[at]
	if win.used {
		return win.owner == owner
	}

	win.owner = owner
	win.used = true
	win.w = win_w
	win.h = win_h
	region_clear(&win.dmg)
	for j in 0 ..< win_w * win_h {
		win.pixels[j] = WIN_GROUND
	}
	// New windows arrive on top, which is the only placement rule a client
	// gets without asking.
	stack_add(at)

	repaint_top(win)
	// And the lamp for it. A lamp is opaque over its own square and sits
	// outside every window's rectangle, so the desktop's own repaint over that
	// square is exactly the lamp -- there is no second painter for one.
	lx, ly := lamp_at(at)
	desk_paint(lx, ly, lx + LAMP, ly + LAMP)
	return true
}

/*
window_close gives the slot back, keeps its memory, and repaints what it was
covering.

The composite at the end is the visible half of the backing store. A window
below this one had its pixels the whole time it was hidden, so the glass can
have them back without anything asking its client to redraw. **That is what a
backing store is for**, and it is why this server has no expose event.

**What no remaining window covers becomes desktop again**, which is the half
that needed a desktop to exist.
*/
window_close :: proc "contextless" (owner: vectra9.Fid) #no_bounds_check {
	for i in 0 ..< MAX_WINDOWS {
		win := &windows[i]
		if !win.used || win.owner != owner {
			continue
		}
		x0 := win.x
		y0 := win.y
		x1 := win.x + win.w
		y1 := win.y + win.h

		// The slot first, so the composite below walks the windows that are
		// left rather than the one that is going. Its regions are not cleared
		// here: `used` is the gate every reader passes, and a control found
		// that clearing in two places meant neither place held it.
		win.owner = 0
		win.used = false
		stack_drop(i)

		desk_paint(x0, y0, x1, y1)
		repaint(x0, y0, x1 - x0, y1 - y0)
		lx, ly := lamp_at(i)
		desk_paint(lx, ly, lx + LAMP, ly + LAMP)
	}
}

/*
window_move puts a window somewhere else, and repaints both places.

**This is the first thing in this server that damages two rectangles far
apart**, which is the case `MAX_RECTS` was sized for and nothing reached until
now. The old place and the new one are two entries in one region, and a window
that moves a long way pays for the ground between them exactly once: not at
all.

A window may hang off the edge. `composite` and `desk_paint` both clip, so
partly off-screen is a picture rather than a special case. Entirely off-screen
is refused, because a window nobody can see is a client that has lost its own
output with no verb to get it back.
*/
window_move :: proc "contextless" (win: ^Window, nx: int, ny: int) -> vectra9.Errno {
	if nx + win.w <= 0 || nx >= scr_w || ny + win.h <= 0 || ny >= scr_h {
		return vectra9.EINVAL
	}
	if nx == win.x && ny == win.y {
		return vectra9.Errno(0)
	}
	ox, oy := win.x, win.y
	win.x = nx
	win.y = ny

	/*
	The ground the move actually frees, then every window over both places.

	Only the part of the old rectangle the new one does not cover needs ground
	under it -- the rest is about to be this window again. Painting the whole
	old rectangle would write up to a screen's worth of desktop and then cover
	all of it, which for a one-column move is every pixel but a column.

	The two are the same size, so the difference is at most two bands.
	*/
	desk_band(ox, oy, win.w, win.h, nx, ny)
	region_clear(&scratch)
	region_add(&scratch, ox, oy, win.w, win.h)
	region_add(&scratch, nx, ny, win.w, win.h)
	composite(&scratch)
	return vectra9.Errno(0)
}

/*
window_size changes what a window is, inside the run it was born with.

**A window cannot grow past its allocation, and that is `segbrk`'s absence
speaking.** The store is one `segalloc` run, fixed at the birth size, and
nothing in this kernel grows a run in place. `docs/USER.md` names `segbrk` with
the other two Plan 9 segment calls Vectra does not have. So `size` moves a
window's edges inside the memory it already holds, and asks for no more.

The stride does not move with the width. A pixel a client drew at (x, y) is at
(x, y) afterwards, so shrinking loses the edges and growing brings back
whatever was there before the last shrink. That stale band is cleared to
ground, which is the one thing a resize has to do to the store.

**No event tells the client.** None is needed: the client asked. A `ctl` read
answers the new size for anything that wants to confirm it.
*/
window_size :: proc "contextless" (win: ^Window, nw: int, nh: int) -> vectra9.Errno #no_bounds_check {
	if nw <= 0 || nh <= 0 || nw > win_w || nh > win_h {
		return vectra9.EINVAL
	}
	if nw == win.w && nh == win.h {
		return vectra9.Errno(0)
	}
	ow, oh := win.w, win.h

	// The bands this grows into hold whatever stood there before a shrink.
	for y in 0 ..< nh {
		row := win.pixels[y * win_w:]
		from := y < oh ? ow : 0
		for x in from ..< nw {
			row[x] = WIN_GROUND
		}
	}

	win.w = nw
	win.h = nh
	region_clear(&win.dmg)

	// The ground under what it gave up and nothing else. A window that grew
	// frees none, and the composite below is about to own every pixel of the
	// new rectangle anyway.
	if nw < ow {
		desk_paint(win.x + nw, win.y, win.x + ow, win.y + oh)
	}
	if nh < oh {
		desk_paint(win.x, win.y + nh, win.x + max(ow, nw), win.y + oh)
	}
	repaint(win.x, win.y, max(ow, nw), max(oh, nh))
	return vectra9.Errno(0)
}

/*
window_raise brings one to the front.

The stack is a list and this is a move to its end, so everything under it keeps
its order. Only the window's own rectangle can have changed, so that is all
that is repainted.
*/
window_raise :: proc "contextless" (win: ^Window, at: int) #no_bounds_check {
	if stack_n > 0 && stack[stack_n - 1] == at {
		return
	}
	stack_add(at)
	repaint_top(win)
}

/*
composite paints one screen region out of the windows that own it, back to
front.

Slot order is stacking order, so the last window to write a pixel is the
topmost one that has it. That single sentence is the whole of occlusion, and it
needs no depth test: a covered window paints first and the cover paints over
it.

**A window is opaque over its whole rectangle now, and that is the whole of
what a desktop bought.** The inner loop used to meet the area against a second
region -- the pixels a client had actually drawn -- because a window that
painted its own blank rectangle would have painted over the boot chassis. There
is a desktop under one now, so a window is a rectangle and this is a rectangle
intersection.

The desktop is not painted here. Nothing else writes the glass while this
server holds the screen, so the ground under a window that has not moved is
still there. `desk_paint` runs at start and where a window uncovers, and
nowhere else.

A pixel under two windows is written twice, once per window, and a region that
says a rectangle twice writes it twice again. Both are copies of the same value
to the same address, which is why `Region` may be a bag rather than a
partition. Walking front to back and subtracting would spend each pixel once
and cost a rectangle split, and an opaque window is what would finally make it
correct. It is the trade to revisit at more windows than two.
*/
composite :: proc "contextless" (area: ^Region) #no_bounds_check {
	for si in 0 ..< stack_n {
		paint_window(&windows[stack[si]], area)
	}
}

/*
paint_window puts one window's pixels on the glass, clipped to a region.

`composite`'s body, named, because two callers know they are the top of the
stack and can skip the walk. A window that has just opened or just been raised
is topmost over its own rectangle by construction, so nothing under it could
survive the pass anyway -- painting the whole stack there copies every window
below it to the glass and then covers all of it.

This is the one place that knows where a window sits, which is why `run_fill`
and `run_blit` no longer do.
*/
paint_window :: proc "contextless" (win: ^Window, area: ^Region) #no_bounds_check {
	if !win.used {
		return
	}
	for ai in 0 ..< area.n {
		a := area.rects[ai]
		x0 := max(max(a.x0, win.x), 0)
		y0 := max(max(a.y0, win.y), 0)
		x1 := min(min(a.x1, win.x + win.w), scr_w)
		y1 := min(min(a.y1, win.y + win.h), scr_h)
		if x0 >= x1 || y0 >= y1 {
			continue
		}
		for y in y0 ..< y1 {
			dst := screen_at(y)
			src := win.pixels[(y - win.y) * win_w:]
			for x in x0 ..< x1 {
				dst[x] = src[x - win.x]
			}
		}
	}
}

/*
repaint composites one rectangle out of every window, and `repaint_top` out of
the one window that is standing over it.

The `region_clear` / `region_add` / `composite` trio was written out at five
sites, four of which also converted between the corner pair `desk_paint` takes
and the extent pair `region_add` takes. One helper each, and the conversion
happens once.
*/
repaint :: proc "contextless" (x: int, y: int, w: int, h: int) {
	region_clear(&scratch)
	region_add(&scratch, x, y, w, h)
	composite(&scratch)
}

repaint_top :: proc "contextless" (win: ^Window) {
	region_clear(&scratch)
	region_add(&scratch, win.x, win.y, win.w, win.h)
	paint_window(win, &scratch)
}

/*
window_flush is `flush`'s whole body: what this client drew since it last
asked, walked onto the glass.

The damage is this window's, and the composite is every window's. A client that
flushes while another sits on top of it repaints its own pixels and then the
cover's, in that order, and the glass ends up right. So a client never has to
know it is covered, which is the second half of not knowing where it is.

The translation to screen coordinates happens once, here, into `scratch`. A
region of damage in window coordinates is what the verbs record, because that
is the only frame a client has.
*/
window_flush :: proc "contextless" (win: ^Window) #no_bounds_check {
	if win.dmg.n == 0 {
		return
	}
	region_clear(&scratch)
	for i in 0 ..< win.dmg.n {
		d := win.dmg.rects[i]
		region_add(&scratch, d.x0 + win.x, d.y0 + win.y, d.x1 - d.x0, d.y1 - d.y0)
	}
	composite(&scratch)
	region_clear(&win.dmg)
}

// window_mark records one drawn rectangle, in window coordinates: what the
// next flush owes the glass.
window_mark :: proc "contextless" (win: ^Window, x: int, y: int, w: int, h: int) {
	region_add(&win.dmg, x, y, w, h)
}

// window_of is which window a session draws into. Nil is a fid that opened
// nothing, which cannot reach a draw and is checked anyway.
window_of :: proc "contextless" (owner: vectra9.Fid) -> ^Window #no_bounds_check {
	for i in 0 ..< MAX_WINDOWS {
		if windows[i].used && windows[i].owner == owner {
			return &windows[i]
		}
	}
	return nil
}

// -- The images ---------------------------------------------------------------

image_find :: proc "contextless" (owner: vectra9.Fid, id: u32) -> int #no_bounds_check {
	for i in 0 ..< MAX_IMAGES {
		if images[i].used && images[i].owner == owner && images[i].id == id {
			return i
		}
	}
	return -1
}

// image_alloc takes a pool slot for this fid. A duplicate id, an id of
// zero, and a size past the slot are each the client's error. A full pool
// is the server's, and answers ENOSPC.
image_alloc :: proc "contextless" (owner: vectra9.Fid, id: u32, w: int, h: int) -> vectra9.Errno #no_bounds_check {
	if id == 0 || w <= 0 || h <= 0 || w * h > IMG_PIXELS {
		return vectra9.EINVAL
	}
	if image_find(owner, id) >= 0 {
		return vectra9.EINVAL
	}
	for i in 0 ..< MAX_IMAGES {
		if !images[i].used {
			images[i] = Image{owner = owner, id = id, w = w, h = h, used = true}
			return vectra9.Errno(0)
		}
	}
	return vectra9.ENOSPC
}

// image_free_all is the clunk's half of the session rule: what a fid
// allocated goes when the fid does.
image_free_all :: proc "contextless" (owner: vectra9.Fid) #no_bounds_check {
	for i in 0 ..< MAX_IMAGES {
		if images[i].used && images[i].owner == owner {
			images[i] = Image{}
		}
	}
}

// -- The screen ---------------------------------------------------------------

// screen_at is where row `y` starts in the mapped screen. The caller clipped
// already, so this never has a boundary to check.
screen_at :: proc "contextless" (y: int) -> [^]u32 #no_bounds_check {
	return glass[y * glass_stride:]
}

// clip trims a rectangle to a destination's bounds, moving a source
// origin by the same trim. Reports whether anything is left.
clip :: proc "contextless" (x: ^int, y: ^int, w: ^int, h: ^int, sx: ^int, sy: ^int, bw: int, bh: int) -> bool {
	if x^ < 0 {
		w^ += x^
		sx^ -= x^
		x^ = 0
	}
	if y^ < 0 {
		h^ += y^
		sy^ -= y^
		y^ = 0
	}
	if x^ + w^ > bw {
		w^ = bw - x^
	}
	if y^ + h^ > bh {
		h^ = bh - y^
	}
	return w^ > 0 && h^ > 0
}

// -- The verbs ----------------------------------------------------------------

/*
run_commands walks one write's worth of the stream and executes each
command, `docs/DRAW.md` section 5's rules exactly. A malformed command
fails the whole write, and what stood before it already drew. Fill and
blit clip to their destination. A load must fit its image whole, because
a load is transport rather than drawing.
*/
run_commands :: proc "contextless" (owner: vectra9.Fid, data: []u8) -> vectra9.Errno #no_bounds_check {
	at := 0
	for at < len(data) {
		if len(data) - at < libdraw.HEADER {
			return vectra9.EINVAL
		}
		size := int(libdraw.get_u16(data, at))
		if size < libdraw.HEADER || at + size > len(data) || data[at + 3] != 0 {
			return vectra9.EINVAL
		}
		verb := data[at + 2]
		body := data[at + libdraw.HEADER:at + size]

		err := vectra9.Errno(0)
		switch verb {
		case libdraw.ALLOC:
			err = run_alloc(owner, body)
		case libdraw.LOAD:
			err = run_load(owner, body)
		case libdraw.FILL:
			err = run_fill(owner, body)
		case libdraw.BLIT:
			err = run_blit(owner, body)
		case libdraw.FREE:
			err = run_free(owner, body)
		case libdraw.FLUSH:
			/*
			**Flush is the damage mark now, and this is the milestone in one
			verb.** Every draw above landed in the window's own memory and
			nothing reached the glass. This is what makes it visible, and it
			composites only what the client drew since it last asked.

			`docs/DRAW.md` section 6 promised exactly this and promised nothing
			about how it happened. A client written against v1 needed no edit,
			because a client that already flushed was already correct. One
			that never flushed was always wrong and only now finds out.
			*/
			if len(body) != 0 {
				err = vectra9.EINVAL
				break
			}
			win := window_of(owner)
			if win == nil {
				err = vectra9.EBADF
				break
			}
			window_flush(win)
		case:
			err = vectra9.EINVAL
		}
		if err != vectra9.Errno(0) {
			return err
		}
		at += size
	}
	return vectra9.Errno(0)
}

run_alloc :: proc "contextless" (owner: vectra9.Fid, body: []u8) -> vectra9.Errno #no_bounds_check {
	if len(body) != 12 {
		return vectra9.EINVAL
	}
	id := libdraw.get_u32(body, 0)
	w := int(libdraw.get_u32(body, 4))
	h := int(libdraw.get_u32(body, 8))
	return image_alloc(owner, id, w, h)
}

run_load :: proc "contextless" (owner: vectra9.Fid, body: []u8) -> vectra9.Errno #no_bounds_check {
	if len(body) < 20 {
		return vectra9.EINVAL
	}
	id := libdraw.get_u32(body, 0)
	x := int(libdraw.get_u32(body, 4))
	y := int(libdraw.get_u32(body, 8))
	w := int(libdraw.get_u32(body, 12))
	h := int(libdraw.get_u32(body, 16))
	slot := image_find(owner, id)
	if slot < 0 || w <= 0 || h <= 0 {
		return vectra9.EINVAL
	}
	img := &images[slot]
	if x < 0 || y < 0 || x + w > img.w || y + h > img.h {
		return vectra9.EINVAL
	}
	if len(body) - 20 != w * h * 4 {
		return vectra9.EINVAL
	}
	// The wire and the one build target are both little-endian, so a row
	// of payload is byte-identical to the pixel words. One copy per row,
	// no per-pixel decode.
	for line in 0 ..< h {
		base := (y + line) * img.w + x
		src := 20 + line * w * 4
		dst := ([^]u8)(raw_data(pixels[slot][base:]))
		copy(dst[:w * 4], body[src:src + w * 4])
	}
	return vectra9.Errno(0)
}

run_fill :: proc "contextless" (owner: vectra9.Fid, body: []u8) -> vectra9.Errno #no_bounds_check {
	if len(body) != 24 {
		return vectra9.EINVAL
	}
	id := libdraw.get_u32(body, 0)
	x := int(libdraw.get_u32(body, 4))
	y := int(libdraw.get_u32(body, 8))
	w := int(libdraw.get_u32(body, 12))
	h := int(libdraw.get_u32(body, 16))
	color := libdraw.get_u32(body, 20)

	sx := 0
	sy := 0
	if id == 0 {
		win := window_of(owner)
		if win == nil {
			return vectra9.EBADF
		}
		/*
		The clip is the window's, and the translation is gone.

		It used to be two lines here: clip in window coordinates, then move by
		the window's origin, in that order, because the other order let a
		client past its own edge into the window beside it. The store now lands
		in the window's own memory, where a client's coordinates already mean
		what they say. The origin moved to `composite`, which is the only code
		left that knows where a window sits.
		*/
		if !clip(&x, &y, &w, &h, &sx, &sy, win.w, win.h) {
			return vectra9.Errno(0)
		}
		for line in 0 ..< h {
			dst := win.pixels[(y + line) * win_w:]
			for i in 0 ..< w {
				dst[x + i] = color
			}
		}
		window_mark(win, x, y, w, h)
		return vectra9.Errno(0)
	}

	slot := image_find(owner, id)
	if slot < 0 {
		return vectra9.EINVAL
	}
	img := &images[slot]
	if !clip(&x, &y, &w, &h, &sx, &sy, img.w, img.h) {
		return vectra9.Errno(0)
	}
	for line in 0 ..< h {
		base := (y + line) * img.w + x
		for i in 0 ..< w {
			pixels[slot][base + i] = color
		}
	}
	return vectra9.Errno(0)
}

run_blit :: proc "contextless" (owner: vectra9.Fid, body: []u8) -> vectra9.Errno #no_bounds_check {
	if len(body) != 32 {
		return vectra9.EINVAL
	}
	dst := libdraw.get_u32(body, 0)
	dx := int(libdraw.get_u32(body, 4))
	dy := int(libdraw.get_u32(body, 8))
	src := libdraw.get_u32(body, 12)
	sx := int(libdraw.get_u32(body, 16))
	sy := int(libdraw.get_u32(body, 20))
	sw := int(libdraw.get_u32(body, 24))
	sh := int(libdraw.get_u32(body, 28))

	// A window is a destination, never a source. Reading pixels back is
	// /dev/fb's job, and a client that could read image zero could read
	// whatever a window above it last drew there.
	if src == 0 {
		return vectra9.EINVAL
	}
	sslot := image_find(owner, src)
	if sslot < 0 || sw <= 0 || sh <= 0 {
		return vectra9.EINVAL
	}
	simg := &images[sslot]
	if sx < 0 || sy < 0 || sx + sw > simg.w || sy + sh > simg.h {
		return vectra9.EINVAL
	}

	if dst == 0 {
		win := window_of(owner)
		if win == nil {
			return vectra9.EBADF
		}
		if !clip(&dx, &dy, &sw, &sh, &sx, &sy, win.w, win.h) {
			return vectra9.Errno(0)
		}
		for line in 0 ..< sh {
			base := (sy + line) * simg.w + sx
			out := win.pixels[(dy + line) * win_w:]
			for i in 0 ..< sw {
				out[dx + i] = pixels[sslot][base + i]
			}
		}
		window_mark(win, dx, dy, sw, sh)
		return vectra9.Errno(0)
	}

	dslot := image_find(owner, dst)
	if dslot < 0 {
		return vectra9.EINVAL
	}
	dimg := &images[dslot]
	if !clip(&dx, &dy, &sw, &sh, &sx, &sy, dimg.w, dimg.h) {
		return vectra9.Errno(0)
	}
	for line in 0 ..< sh {
		sbase := (sy + line) * simg.w + sx
		dbase := (dy + line) * dimg.w + dx
		for i in 0 ..< sw {
			pixels[dslot][dbase + i] = pixels[sslot][sbase + i]
		}
	}
	return vectra9.Errno(0)
}

run_free :: proc "contextless" (owner: vectra9.Fid, body: []u8) -> vectra9.Errno #no_bounds_check {
	if len(body) != 4 {
		return vectra9.EINVAL
	}
	slot := image_find(owner, libdraw.get_u32(body, 0))
	if slot < 0 {
		return vectra9.EINVAL
	}
	images[slot] = Image{}
	return vectra9.Errno(0)
}


// fid_release is also the session teardown: a data fid takes its images
// with it, `docs/DRAW.md` section 4's rule.
fid_release :: proc "contextless" (fid: vectra9.Fid) {
	// The images and the window before the slot. A fid on `data` owns both,
	// and the table is what says which fid that was.
	node := libuser.fid_lookup(&fids, fid)
	if node_part(node) == PART_DATA {
		image_free_all(fid)
		window_close(fid)
	}
	if w := node_win(node); w >= 0 && node_part(node) == PART_CTL {
		// The controls are exclusive, so the fid that held them gives them
		// back. A window whose client never opened its `ctl` leaves it for
		// whoever asks, which is what having no users yet costs.
		if windows[w].ctl_held && windows[w].ctl_fid == fid {
			windows[w].ctl_held = false
		}
	}
	libuser.fid_release(&fids, fid)
}

// -- The tree -----------------------------------------------------------------

qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if node == NODE_ROOT || node_part(node) == PART_DIR {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

name_of :: proc "contextless" (node: i32) -> string #no_bounds_check {
	if node == NODE_NEW {
		return "new"
	}
	w := node_win(node)
	if w < 0 {
		return ""
	}
	switch node_part(node) {
	case PART_DIR:
		return libdraw.win_name(w)
	case PART_DATA:
		return "data"
	case PART_CTL:
		return "ctl"
	}
	return ""
}

step :: proc "contextless" (from: i32, name: string) -> i32 #no_bounds_check {
	if name == "." {
		return from
	}
	if name == ".." {
		// A window's files step up to its own directory, and everything else
		// to the root. Two levels is the whole depth.
		if w := node_win(from); w >= 0 && node_part(from) != PART_DIR {
			return node_of(w, PART_DIR)
		}
		return NODE_ROOT
	}

	if from == NODE_ROOT {
		if name == "new" {
			return NODE_NEW
		}
		if len(name) == 1 && name[0] >= '0' && name[0] < '0' + u8(MAX_WINDOWS) {
			return node_of(int(name[0] - '0'), PART_DIR)
		}
		return -1
	}

	w := node_win(from)
	if w < 0 || node_part(from) != PART_DIR {
		return -1
	}
	switch name {
	case "data":
		return node_of(w, PART_DATA)
	case "ctl":
		return node_of(w, PART_CTL)
	}
	return -1
}

// -- The handler --------------------------------------------------------------

handler :: proc "contextless" (
	state: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = state
	_ = s
	_ = tag

	if !libuser.default_reply(request, reply) {
		return
	}

	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply, FRAME)

	case vectra9.Tattach:
		libuser.attach(&fids, m, reply, NODE_ROOT, qid_of)

	case vectra9.Twalk:
		libuser.walk(&fids, m, reply, step, qid_of)

	case vectra9.Tlopen:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		/*
		A session is a fid on a window's `data`, and a session is that window.
		There is nowhere else for the claim to happen: the fid exists from the
		walk, and the first draw may be the next message.

		`ctl` is exclusive the same way. One fid at a time holds a window's
		controls, so two clients cannot both move one window.
		*/
		w := node_win(node)
		switch node_part(node) {
		case PART_DATA:
			if w < 0 || !window_open(m.fid, w) {
				reply^ = vectra9.error_reply(vectra9.ENOSPC)
				return
			}
		case PART_CTL:
			if w < 0 {
				reply^ = vectra9.error_reply(vectra9.ENOSPC)
				return
			}
			if windows[w].ctl_held && windows[w].ctl_fid != m.fid {
				reply^ = vectra9.error_reply(vectra9.ENOSPC)
				return
			}
			windows[w].ctl_held = true
			windows[w].ctl_fid = m.fid
		}
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}

	case vectra9.Tread:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		if node == NODE_ROOT || node_part(node) == PART_DIR {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		if node_part(node) == PART_DATA {
			// The command stream is written, never read. What a session
			// drew is on the glass, and the glass is /dev/fb's to answer.
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}

		/*
		`new` answers which window has no session, and `ctl` answers a
		geometry. Both are built into the reply buffer at the moment they are
		asked, because both are answers about right now.

		The geometry is this window's own size rather than the one every
		window shares. A client that resized itself reads back what it asked
		for, which is the only confirmation a `ctl` line gets.
		*/
		line: [160]u8
		n := 0
		if node == NODE_NEW {
			n = put_number(line[:], 0, window_free())
			n = put_report(line[:], n, "\n")
		} else if w := node_win(node); w >= 0 {
			n = window_report(line[:], &windows[w])
		}
		if m.offset >= u64(n) {
			reply^ = vectra9.Rread{data = nil}
			return
		}
		start_at := int(m.offset)
		end := min(n, start_at + min(len(buf), int(m.count)))
		copy(buf[:end - start_at], line[start_at:end])
		reply^ = vectra9.Rread{data = buf[:end - start_at]}

	case vectra9.Twrite:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		switch node_part(node) {
		case PART_DATA:
			if err := run_commands(m.fid, m.data); err != vectra9.Errno(0) {
				reply^ = vectra9.error_reply(err)
				return
			}
			reply^ = vectra9.Rwrite{count = u32(len(m.data))}
		case PART_CTL:
			if err := run_ctl(node_win(node), m.data); err != vectra9.Errno(0) {
				reply^ = vectra9.error_reply(err)
				return
			}
			reply^ = vectra9.Rwrite{count = u32(len(m.data))}
		case:
			reply^ = vectra9.error_reply(vectra9.EISDIR)
		}

	case vectra9.Treaddir:
		readdir(m, reply, buf)

	case vectra9.Tgetattr:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		dir := node == NODE_ROOT || node_part(node) == PART_DIR
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = dir ? 0o040555 : (node_part(node) == PART_DATA ? 0o100222 : 0o100644),
			nlink   = dir ? 2 : 1,
			size    = 0,
			blksize = 512,
		}

	case vectra9.Tclunk:
		fid_release(m.fid)
		reply^ = vectra9.Rclunk{}

	case vectra9.Tremove:
		fid_release(m.fid)
		reply^ = vectra9.Rremove{}

	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

/*
readdir lists the root or one window's directory, whichever the fid names.

Two levels, so two shapes. The root holds `new` and a directory per window.
A window's directory holds `data` and `ctl`. The cookie is an index into
whichever list this is, which is the position-based listing `docs/SRV.md`
argues against and this tree can afford: nothing here is ever rebound, and the
names are fixed at start.
*/
readdir :: proc "contextless" (m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	node, ok := libuser.node_of(&fids, m.fid, reply)
	if !ok {
		return
	}
	root := node == NODE_ROOT
	w := node_win(node)
	if !root && (w < 0 || node_part(node) != PART_DIR) {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}

	count := root ? 1 + MAX_WINDOWS : 2
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	for i := int(m.offset); i < count; i += 1 {
		child: i32
		kind := vectra9.DT_REG
		if root {
			if i == 0 {
				child = NODE_NEW
			} else {
				child = node_of(i - 1, PART_DIR)
				kind = vectra9.DT_DIR
			}
		} else {
			child = node_of(w, i == 0 ? PART_DATA : PART_CTL)
		}
		if vectra9.remaining(&c) < vectra9.dirent_size(name_of(child)) {
			break
		}
		vectra9.put_dirent(
			&c,
			vectra9.Dirent {
				qid = qid_of(child),
				offset = u64(i + 1),
				type = kind,
				name = name_of(child),
			},
		)
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
