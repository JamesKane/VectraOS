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

**And a window wears the chassis.** A raised border with a copper bar across
its top, out of `sys/libdraw`'s vocabulary, painted into the window's own run
so the compositor never learns there is one. The client area is inside it, and
a client's (0, 0) is there. The name on the bar comes off a `ctl` line and is
drawn from `sys/libfont` -- the server's own text about a client's window,
which is why it needed no verb.

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
    /ctl     text lines in, the geometry of a client area out

**`ctl` reports the client area rather than the screen**, and that is the
second half of a client not knowing where it is. It learns how much room it
has to draw in, and nothing about the glass, the frame around it, or the
window beside it.

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

import "base:intrinsics"
import "base:runtime"

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libedit"
import "vsys:libfont"
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

// A window's five nodes, in one block apiece after the two fixed ones.
NODE_BASE :: i32(2)
NODE_PER :: i32(5)
PART_DIR :: i32(0)
PART_DATA :: i32(1)
PART_CTL :: i32(2)
PART_CONS :: i32(3)
PART_CONSCTL :: i32(4)

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

A window's own ground is not here. It is the face of the well
`window_frame` sinks the client area into, which is `SLATE` out of the same
table -- a window is a sunken panel in this idiom, and a client that draws
nothing gets one because the frame painted one.
*/
DESK_GROUND :: u32(libpal.SLATE_DEEP[0]) << 16 | u32(libpal.SLATE_DEEP[1]) << 8 | u32(libpal.SLATE_DEEP[2])
DESK_GRID :: u32(libpal.VOID[0]) << 16 | u32(libpal.VOID[1]) << 8 | u32(libpal.VOID[2])
DESK_STEP :: 32

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
/*
How much of the glass a window is born covering, as a percentage of its
height.

`rio` has no equivalent because `rio` has a mouse: a window is the rectangle
somebody swept, and `goodrect` only says which rectangles are allowed --
at least one line of text tall, no more than `BIG` times the screen, and never
big enough to contain the whole screen. This is the same idea where there is
nobody to ask.

Three quarters leaves a quarter of the glass below a window, which is where a
grown one goes and where the desktop shows through.
*/
WIN_FILL :: 75

DESK_EDGE :: 2
LAMP :: 12
LAMP_GAP :: 6
LAMP_INSET :: 20

// `desk_at` used to sit here: the desktop's colour at one screen pixel, ground
// with a grid every `DESK_STEP`. It kept no callers once `desk_paint` hoisted
// that test out of its inner loop and into one per row, and a control found it
// by mutating it and changing nothing. The rule it stated is still the
// desktop's, and `desk_paint` below is where it is written now.

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

	// The face is the ground `desk_paint` already laid, grid and all, so this
	// is `edges` rather than `panel`. The chassis chisels around a brushed
	// plinth for the same reason.
	n := libdraw.edges(
		pieces[:],
		0,
		0,
		scr_w,
		scr_h,
		.Recessed,
		libpal.MAGNESIUM_LIT,
		libpal.VOID,
		DESK_EDGE,
	)
	desk_pieces(pieces[:n], sx0, sy0, sx1, sy1)

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

/*
pieces_into stores a run of chrome into a strided surface, clipped to one box.

**The one place that turns a `Piece` into a pixel on this side of the door.**
`desk_pieces` and `win_pieces` below are this with a destination and a clip
box filled in, and they were the same six lines twice until the two parameters
were lifted out. `fb.paint` is the third painter and cannot be folded in here:
it goes through `fill_rect`, which packs against the channel shifts the
bootloader set rather than against the one depth `/srv/draw` accepts. That
split is what `Piece.color` carrying an `RGB` is for.
*/
pieces_into :: proc "contextless" (
	dst: [^]u32,
	stride: int,
	pieces: []libdraw.Piece,
	bx0: int,
	by0: int,
	bx1: int,
	by1: int,
) #no_bounds_check {
	for p in pieces {
		x0 := max(p.x, bx0)
		y0 := max(p.y, by0)
		x1 := min(p.x + p.w, bx1)
		y1 := min(p.y + p.h, by1)
		word := libpal.xrgb(p.color)
		for y in y0 ..< y1 {
			row := dst[y * stride:]
			for x in x0 ..< x1 {
				row[x] = word
			}
		}
	}
}

// desk_pieces stores a run of chrome onto the glass, each rectangle clipped to
// the region being repainted and to the screen.
desk_pieces :: proc "contextless" (pieces: []libdraw.Piece, sx0: int, sy0: int, sx1: int, sy1: int) {
	pieces_into(glass, glass_stride, pieces, max(sx0, 0), max(sy0, 0), min(sx1, scr_w), min(sy1, scr_h))
}

// -- The window frame --------------------------------------------------------

/*
And what a `frame` makes: a bevel's edges, and two panels.

Written against the three depths a frame is actually made of rather than
against `MAX_DEPTH`, which no part of a frame uses. Raising `FRAME_EDGE` is
what should grow this array, and against `MAX_DEPTH` it would not have.

Its own bound rather than `libdraw.MAX_PIECES`, which is what one panel makes.
*/
MAX_FRAME_PIECES :: 4 * FRAME_EDGE + (1 + 4) + (1 + 4 * FRAME_WELL)

/*
The window frame's three numbers, and the only three a window's chassis has.

`FRAME_EDGE` is the raised border a window stands up out of the desktop with.
`FRAME_TITLE` is the bar across the top of it, inside that border.
`FRAME_WELL` is the recess the client area is sunk into, which is what makes a
window the same object as the chassis: a raised plinth with a sunken screen in
it. Everything else about a frame is arithmetic over those three, and all of it
is below.

**They are this server's alone, and that took a milestone to get right.**
They sat in `sys/libdraw` first, because the kernel's self-test insets its
readbacks by the same amount and could not import `servers/`. That made the
test agree with the code under test: no mutation of a frame's geometry could
fail a check. The test finds a window's client area by scanning the glass for
it now, so these are layout policy in the one process that has any.
*/
FRAME_EDGE :: 3
FRAME_TITLE :: 20
FRAME_WELL :: 2

// `libdraw.edges` and `libdraw.panel` clamp to `MAX_DEPTH`, and a clamped frame
// would leave a band of the window that `window_frame` below does not tile. The
// tiling is what clears a reused slot, so the clamp is a compile error rather
// than a gap.
#assert(FRAME_EDGE <= libdraw.MAX_DEPTH)
#assert(FRAME_WELL <= libdraw.MAX_DEPTH)

// Where the client area begins inside a window, which is the one piece of
// frame arithmetic that does not depend on the window's size. A caller that
// wants only the origin reads these rather than inventing a width to hand
// `frame_client`.
FRAME_INSET_X :: FRAME_EDGE + FRAME_WELL
FRAME_INSET_Y :: FRAME_EDGE + FRAME_TITLE + FRAME_WELL

// What the bar keeps clear around its text. The bar is `FRAME_TITLE` tall and
// a glyph is sixteen, so the vertical half of this is what centres one.
FRAME_PAD :: 4

/*
window_frame decomposes a window's chassis: a raised border, with a copper bar across
the top of it.

**The same three surfaces the boot chassis is made of, one privilege level
out.** `kernel/splash.odin` says its window frames should be recognisably the
same object as the screen the kernel painted, and this is the call that makes
them so: a raised plinth, a copper bar across its top, and a well sunk into
what is left. The plinth is brushed magnesium there and flat here, and the bar
is a copper gradient there and flat here, for the reason the file comment
gives: neither a pattern nor a ramp is a rectangle.

**The well's face is the client area's ground**, so a client that draws nothing
gets the sunken slate field rather than the plinth it is standing on. It is
also the only face a reused slot needs: the border and the bar sit strictly
outside the client area at every size a window can take, so nothing a previous
session drew is ever under them. That is what lets `window_open` clear a slot
by painting a frame on it.

**The plinth has no face, because at `FRAME_EDGE` deep its edges are the whole
of it.** Three nested one-pixel rings tile a three-pixel border exactly, so a
face under them would be written and completely overpainted -- half a megabyte
of stores per window on this screen, for nothing. That is what `edges` exists
apart from `panel` for, and the assertion above is what keeps the two depths
from drifting into a gap.

The three parts tile the window between them: the edges take the border ring,
the bar takes the rows under it, and the well takes the rest.

The name on the bar is not here either. A glyph is not a rectangle, and the
painter that has a font is the one that draws it.

`lit` is whether this window has the focus, which only the bar reads. See
`frame_bar`.

Coordinates are the window's own, so a server painting into a window's store
passes (0, 0). Answers how many pieces it wrote; size the array by
`MAX_FRAME_PIECES`.
*/
window_frame :: proc "contextless" (out: []libdraw.Piece, x: int, y: int, w: int, h: int, lit: bool) -> int #no_bounds_check {
	n := libdraw.edges(out, x, y, w, h, .Raised, libpal.MAGNESIUM_HOT, libpal.MAGNESIUM_DARK, FRAME_EDGE)
	if n == 0 {
		return 0
	}
	n += frame_bar(out[n:], x, y, w, lit)

	// The well starts where the bar ends and is as wide as it, which is one
	// fact rather than three: `frame_bar_at` is where the bar is, and this
	// asks it rather than deriving the same numbers a second time.
	bx, by, bw, bh := frame_bar_at(x, y, w)
	return n + libdraw.well(out[n:], bx, by + bh, bw, h - (by - y) - bh - FRAME_EDGE, FRAME_WELL)
}

/*
frame_bar decomposes the title bar alone: copper trim, out of the same three
names the chassis's own bar is drawn from.

Apart from `window_frame` because a window that is renamed repaints its bar and
nothing else, and the bar is what an old name has to be erased off. A window
that gains or loses the focus repaints the same rectangle for the same reason.

**`lit` is the whole of what focus looks like.** The window in front wears the
chassis's copper. Every other bar is the same trim one step down the same
table: `COPPER_DARK` for its face, with `COPPER` above it and `VOID` below. It
is the lamp's rule again -- a dark version of its own colour rather than a
neutral grey -- and for the lamp's reason: a row of windows with one of them
in front still has to read as several of the same kind of thing. `libpal` has
both faces already, so this is a choice between two names and not a new colour.
*/
frame_bar :: proc "contextless" (out: []libdraw.Piece, x: int, y: int, w: int, lit: bool) -> int {
	bx, by, bw, bh := frame_bar_at(x, y, w)
	if lit {
		return libdraw.panel(out, bx, by, bw, bh, .Raised, libpal.COPPER, libpal.COPPER_LIT, libpal.COPPER_DARK, 1)
	}
	return libdraw.panel(out, bx, by, bw, bh, .Raised, libpal.COPPER_DARK, libpal.COPPER, libpal.VOID, 1)
}

// frame_bar_at is where that bar sits, inside a window at (x, y) that is `w`
// across. The painter that draws the name needs it, and so does whatever
// repaints one bar's worth of glass.
frame_bar_at :: proc "contextless" (x: int, y: int, w: int) -> (int, int, int, int) {
	return x + FRAME_EDGE, y + FRAME_EDGE, w - 2 * FRAME_EDGE, FRAME_TITLE
}

/*
frame_client is where a window's client area is, and how big, inside a window
`w` by `h`.

**This is the whole cost of a frame**, and `docs/DRAW.md` section 12 named it
a milestone before there was one: the client area is no longer the window's
rectangle. A client's (0, 0) is here, and the origin is a constant because a
frame is the same depth whatever size the window is.

It is the well's *interior*, so the recess is chrome the client cannot draw on,
the way the border and the bar are.
*/
frame_client :: proc "contextless" (w: int, h: int) -> (x: int, y: int, cw: int, ch: int) {
	return FRAME_INSET_X, FRAME_INSET_Y, w - 2 * FRAME_INSET_X, h - FRAME_INSET_Y - FRAME_INSET_X
}

// frame_window is the inverse: the window a client area of `cw` by `ch` needs
// around it. A `size` line names a client area, because a `ctl` read answers
// one, and this is what turns that into a window.
frame_window :: proc "contextless" (cw: int, ch: int) -> (w: int, h: int) {
	return cw + 2 * FRAME_INSET_X, ch + FRAME_INSET_Y + FRAME_INSET_X
}

/*
The window frame, and the font the draw server did not have.

**`sys/libdraw`'s `frame` is the vocabulary; this is the painter.** A window's
border and title bar are the same two surfaces the boot chassis is made of,
decomposed into rectangles one privilege level out, and stored into the
window's own run. So a frame is ordinary pixels in the store: `composite`
copies a window's rectangle to the glass and never learns which of those
pixels a client drew.

**A client cannot reach them.** Its coordinates start at the client area,
which `frame_client` puts inside the border and below the bar, and
every store it makes is clipped to that extent first. A frame is the one part
of a window that is the server's, and the clip is what says so.

`MAX_TITLE` is a cap on the name rather than on the bar. A longer name is cut
at the bar's own edge as it is drawn, because a window narrower than its name
is a picture and not an error.
*/
MAX_TITLE :: 24

// The name's colour on the bar: dark on copper, which is the chassis's
// engraved wordmark. It is also the one colour a bar drawn out of the copper
// three cannot otherwise contain, which is what makes it a sensor.
//
// **One ink, focused or not.** An engraved wordmark is engraved whichever
// window the machine is listening to; what changes under it is the metal. So
// focus costs the bar one colour and costs the name none.
TITLE_FG :: u32(libpal.SLATE_DEEP[0]) << 16 | u32(libpal.SLATE_DEEP[1]) << 8 | u32(libpal.SLATE_DEEP[2])

// win_pieces stores a run of chrome into one window's own memory, clipped to
// the window rather than to the screen, because a window's store is the only
// memory it may touch. The stride is the run's birth width and not `win.w`.
win_pieces :: proc "contextless" (win: ^Window, pieces: []libdraw.Piece) {
	pieces_into(win.pixels, win_w, pieces, 0, 0, win.w, win.h)
}

/*
window_chrome paints a window's whole frame into its store: the border, the
bar, and the name on it.

Called when a window opens and when it changes shape, and never per draw. The
frame is memory like everything else in the run, so it survives being covered
the way a client's pixels do.
*/
window_chrome :: proc "contextless" (win: ^Window) {
	pieces: [MAX_FRAME_PIECES]libdraw.Piece
	win_pieces(win, pieces[:window_frame(pieces[:], 0, 0, win.w, win.h, focused(win))])
	title_text(win)
}

/*
title_paint repaints one bar and the name on it, which is what a rename needs,
and what a change of focus needs for the same reason.

`window_chrome` does not call this: `window_frame` already carries the bar,
so a whole-frame repaint lays it down once and goes straight to the letters.
This is the path that has to lay it down itself, and laying it down first is
how a name that grew shorter loses its tail.

The bar it lays down is the one this window's place in the stack calls for.
Both of its reasons to run are reasons the bar's own pixels changed, so neither
caller has to say which.
*/
title_paint :: proc "contextless" (win: ^Window) {
	pieces: [libdraw.MAX_PIECES]libdraw.Piece
	win_pieces(win, pieces[:frame_bar(pieces[:], 0, 0, win.w, focused(win))])
	title_text(win)
}

/*
bar_show repaints one window's bar into its store and sends that rectangle to
the glass, which is the whole of what a rename and a change of focus each do.

Only the bar's own rectangle goes back. `composite` walks the whole stack over
it, so a bar under another window repaints nothing anybody can see.
*/
bar_show :: proc "contextless" (win: ^Window) {
	title_paint(win)
	bx, by, bw, bh := frame_bar_at(win.x, win.y, win.w)
	repaint(bx, by, bw, bh)
}

/*
title_text draws the name across the bar, out of `sys/libfont` -- the one 8x16
table the kernel console and every ring 3 program already link.

**This is the font `docs/DRAW.md` said the server had none of, and it did not
make one a protocol question.** A client still uploads its own glyphs as images
and blits them, which is section 5's answer to a font verb and stays the
answer. A title is the *server's* text about a client's window, drawn into
memory no client can reach, so it needs no verb at all.

It paints no bar of its own, so both callers lay one down exactly once:
`window_chrome` gets it out of `window_frame`, and `title_paint` out of
`frame_bar`.

The clip is per glyph rather than per pixel. A name runs off the bar's right
edge at a whole character, so the first one that will not fit ends the whole
loop, and the column range is settled before the rows are walked. The bar is
taller than a glyph by `FRAME_PAD`, so no row of one can leave it.
*/
title_text :: proc "contextless" (win: ^Window) #no_bounds_check {
	bx, by, bw, bh := frame_bar_at(0, 0, win.w)
	tx := bx + FRAME_PAD
	ty := by + (bh - libfont.FONT_HEIGHT) / 2
	right := bx + bw - FRAME_PAD
	for i in 0 ..< win.title_n {
		gx := tx + i * libfont.FONT_WIDTH
		if gx >= right {
			return
		}
		ch := win.title[i]
		if ch < libfont.FONT_FIRST || ch > libfont.FONT_LAST {
			continue
		}
		rows := &libfont.font_8x16[int(ch) - libfont.FONT_FIRST]
		wide := min(libfont.FONT_WIDTH, right - gx)
		for line in 0 ..< libfont.FONT_HEIGHT {
			bits := rows[line]
			dst := win.pixels[(ty + line) * win_w:]
			for c in 0 ..< wide {
				if bits & (0x80 >> u8(c)) != 0 {
					dst[gx + c] = TITLE_FG
				}
			}
		}
	}
}

/*
window_name is the `name` line: what the bar across a window's top says.

`ctl_rest` has already taken the space and the newline off, so what arrives is
the name. An empty one is legal and clears the bar, which is what makes the
bar's repaint testable in both directions.

`bar_show` is the repaint, and it is the same one a change of focus makes.
*/
window_name :: proc "contextless" (win: ^Window, name: []u8) -> vectra9.Errno #no_bounds_check {
	n := min(len(name), MAX_TITLE)
	for i in 0 ..< n {
		win.title[i] = name[i]
	}
	win.title_n = n

	bar_show(win)
	return vectra9.Errno(0)
}

/*
One window: where it sits, the memory behind it, and the damage it owes.

`pixels` is a run of anonymous memory from `segalloc`, `w * h` words of it,
and **it belongs to the session**. `Tlopen` buys it and the clunk gives it
back with `segdetach`, which is the call this line waited two milestones
for. A slot between sessions holds no memory at all.

`dmg` is what this client drew since its last `flush`, and it is the only
region a window keeps now.

**A window owns its whole rectangle, and part of it is not the client's.** The
border and the title bar live in this same run, painted by `window_chrome`,
and `frame_client` is where the client area begins inside them. Every
store a verb makes is clipped to that and moved into it, so a frame costs the
compositor nothing: a window is still one opaque rectangle backed by one run.

That sentence took three milestones and cost two mechanisms on the way. First a magic pixel value said which pixels a
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

	// The store. Every window's run is `win_w` wide, bought at the birth
	// height when a session opens `data` and detached when it clunks. So
	// `win_w` is the stride and this struct does not carry a second copy of
	// it. `w` and `h` move inside that, and `segbrk` moves `rows`. Nil
	// between sessions, and `used` is the gate every reader passes first.
	pixels: [^]u32,

	// How many rows the run behind `pixels` actually holds. It starts at the
	// birth height and `segbrk` moves it, which is what lets a window grow
	// past the size its slot was born with.
	rows:   int,

	dmg:    Region,
	used:   bool,

	// What the bar across the top says, set by a `name` line and nothing
	// else. A window is born nameless, because a slot outlives the session it
	// was lent to and the last client's name is not this one's.
	title:   [MAX_TITLE]u8,
	title_n: int,

	// The `ctl` file is exclusive the way `data` is. One fid at a time holds
	// a window's controls, so two clients cannot both move one window.
	ctl_fid:  vectra9.Fid,
	ctl_held: bool,

	// And `cons` the same way, for the same reason one step along: two
	// readers of one window's keyboard would each get part of every line.
	cons_fid:  vectra9.Fid,
	cons_held: bool,

	// What this window's `consctl` says. Raw is `there is no line
	// discipline`, the same sentence `kernel/devfs` uses, and it reverts to
	// cooked when the last `consctl` fid closes -- which is `/dev/consctl`'s
	// own rule, kept because a client that dies holding a mode should not
	// leave the next one with it.
	cons_raw:     bool,
	consctl_fid:  vectra9.Fid,
	consctl_held: bool,
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

/*
Which window has the focus, and it is a reading of the stack rather than a
variable beside it.

**The window in front is the one the machine is listening to.** There is no
pointer in this system and no keystroke to route yet, so front is the whole of
what focus can mean, and the stack already says which window is in front.
Nothing here can therefore disagree with the stacking order, and `raise` needs
no second call to move the focus with it.

What it costs is a colour on a title bar and a repaint of two bars per stack
move. See `frame_bar` for the colour and `refocus` for the repaint.
*/
stack_top :: proc "contextless" () -> int {
	return stack_n > 0 ? stack[stack_n - 1] : -1
}

focused :: proc "contextless" (win: ^Window) -> bool #no_bounds_check {
	at := stack_top()
	return at >= 0 && &windows[at] == win
}

/*
refocus repaints the bars that a stack move just changed hands between.

**At most two windows change**, whatever the move was: the one that was in
front and the one that is now. Every other bar is drawn the same either way, so
a screen full of windows costs the same as a screen with two.

`was` is `stack_top()` read before the move. A caller that did not move the
stack has nothing to call this with, which is the shape rather than a rule:
`window_open`, `window_close` and `window_raise` are the three, and they are
the three that touch `stack`.

The old front may be gone -- that is `window_close` -- so it is checked for a
session before its bar is drawn. The new front cannot be: it is in the stack.
*/
refocus :: proc "contextless" (was: int) #no_bounds_check {
	now := stack_top()
	if now == was {
		return
	}
	if was >= 0 && windows[was].used {
		bar_show(&windows[was])
	}
	if now >= 0 {
		bar_show(&windows[now])
	}
}

/*
The keyboard, and which window is listening to it.

**This server does not translate scancodes, and Plan 9's does not either.**
`rio` opens `/dev/cons`, writes `rawon` to `/dev/consctl`, and prefers
`/dev/kbd` when it exists -- and both of those are served by `kbdfs`, one
process further out. `rio` never opens `/dev/scancode`. So the divert this
server does hold is `/dev/fb`'s, and the keyboard arrives already cooked,
through the same file every other program reads.

**A line goes to the window in front, and focus is read when the line
arrives.** That is the honest rule for cooked lines: a line belongs to whoever
had the focus at the moment it completed, because that is the only instant the
whole line existed at once.

**The editing state is this server's, and there is one per window**, which is
what `rio` writes `rawon` for. A character joins the line under construction in
the window that has the focus *now*, and only a completed line reaches a
window's queue. So a line half-typed when the focus moves stays where it was
being typed, and the window that gains the focus starts its own.

One ring per window, because two parked readers must not race for one queue.
The child is the only producer and each window's worker is its only consumer,
which is the discipline `libuser.Ring` is written to.
*/
KBD_RING :: 256
kbd_store: [MAX_WINDOWS][KBD_RING]u8
kbd: [MAX_WINDOWS]libuser.Ring

// The child's own read buffer, in the bss both halves share and touched by
// the child alone.
kbd_chunk: [128]u8

/*
The line under construction, one per window, and the characters that edit it.

**This is `kernel/devfs`'s line discipline, one privilege level out and one per
window**, which is what moving it was for. The kernel's is still there and
still cooks `/dev/cons` for everything that has not diverted it. This server
writes `rawon` and takes the characters, so the editing that used to be shared
by every window belongs to each.

**The rules are `sys/libedit`'s and are not restated here.** That package is
`rio`'s `wbswidth` and `winsert`, worn by this server and by `apps/terminal`,
and one of the two is enough places to write down what `^W` means.

**A cooked window has a cursor and cannot show it.** `^A` and `^E` move it, so
a character goes in where it is rather than at the end. Nothing in this server
echoes -- see `run_consctl` -- so a client that wants a person to *see* the
cursor draws its own, which is what `apps/terminal` takes `rawon` for. The two
control bytes stop reaching a cooked client, which is `rio`'s arrangement
exactly: they are motion there too, and a client that wants them literally asks
for raw.

A newline finishes a line, and nothing else does. `^D` is the kernel's
end-of-transmission and this does not answer it: a partial line delivered with
no newline would break the one-line-per-read rule `ring_drain_line` keeps, and
an empty one has to mean end of file, which is a claim about a window's life
rather than about its keyboard.
*/
EDIT_MAX :: 128
edit_store: [MAX_WINDOWS][EDIT_MAX]u8
edit: [MAX_WINDOWS]libedit.Line

/*
type_at gives one character to a window's line discipline.

**Raw mode is `there is no line discipline`**, which is the sentence
`kernel/devfs` puts on the same distinction. A window in raw mode gets every
character the moment it arrives, editing keys included, because a client that
asked for raw is the one doing the editing.

Cooked mode answers the three erase keys, drops what will not fit, and hands
the whole line over on a newline. A line longer than `EDIT_MAX` loses its tail
rather than the front of it: the beginning of a command is the part somebody
meant.
*/
type_at :: proc "contextless" (w: int, b: u8) #no_bounds_check {
	if windows[w].cons_raw {
		libuser.ring_push(&kbd[w], b)
		return
	}
	if libedit.put(&edit[w], b) != .Done {
		return
	}
	for c in libedit.text(&edit[w]) {
		libuser.ring_push(&kbd[w], u8(c))
	}
	// The newline goes with the line, because it is what a reader stops at
	// and what `/dev/cons` always delivered. `libedit` does not store it,
	// because the other caller draws the line and would have to strip it.
	libuser.ring_push(&kbd[w], '\n')
	libedit.clear(&edit[w])
}

/*
focus_win is `stack_top` as the reader child may read it.

The child runs in its own process against shared memory, and the parent
mutates the stack between two of its instructions whenever a window opens,
closes or is raised. `stack_top` would index with a count it read a moment
ago. This reads each half once and refuses anything that is not a window.

**A torn read costs a line, not a fault.** The worst answer this can give is
the window that had the focus an instant earlier, which is inside the rule the
file comment above states.
*/
focus_win :: proc "contextless" () -> int #no_bounds_check {
	n := int(intrinsics.volatile_load(&stack_n))
	if n <= 0 || n > MAX_WINDOWS {
		return -1
	}
	w := intrinsics.volatile_load(&stack[n - 1])
	if w < 0 || w >= MAX_WINDOWS || !windows[w].used {
		return -1
	}
	return w
}

/*
reader is the child's whole life: read the console, give each line to the
window in front.

A failed read is not a loop to break out of. A noted process's read answers
EINTR, and its next system call is the boundary the note ends it at, so asking
again *is* the teardown protocol. `servers/kbdfs` and `servers/consrv` have
the same shape over different devices.

**A character nobody is listening to is dropped**, which is what no window in
front means. `rio` has nowhere to put one either.

**The focus is read per character, not per read.** A chunk carries whatever
arrived since the last one, and the front can move between two of its bytes.
Reading it once per chunk would put a whole burst in one window, which is the
defect this milestone exists to retire -- one level finer than the one it
started at.
*/
reader :: proc "contextless" (cons: int) -> ! {
	for {
		n := libuser.read(cons, kbd_chunk[:])
		if n <= 0 {
			continue
		}
		for i in 0 ..< int(n) {
			w := focus_win()
			if w < 0 {
				continue
			}
			type_at(w, kbd_chunk[i])
		}
	}
}

// win_h_at is how many rows this window's run holds. `win_h` is the height a
// slot is born with; `segbrk` can move a window's own above it.
win_h_at :: proc "contextless" (win: ^Window) -> int {
	return win.rows
}

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
and this server's stack is a program's.

**Safe as a single variable because one loop draws.** `serve_mux` forks a
worker only for a request `blocks` claims, and `blocks` claims exactly one: a
read of a window's `cons`, which touches that window's key ring and nothing
else. Every message that moves a pixel is still answered inline, in order, by
the one loop that owns this.
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

// The write lock `serve_mux` serialises replies with, and a state lock over
// the consumer end of a window's key ring. `stopping` releases a worker
// parked on an empty one at teardown. See `servers/kbdfs`, which this is the
// shape of, and `sys/libuser/serve.odin`.
wlock: libuser.Spin
state_lock: libuser.Spin
stopping: bool

// One worker per window that may have a read parked on its `cons`, and one
// spare so a client that opens a second window is never the request that
// stalls the loop.
SLOTS :: MAX_WINDOWS + 1
slot_frame: [SLOTS][FRAME]u8
slot_out: [SLOTS][FRAME]u8
slot_payload: [SLOTS][1024]u8
slots: [SLOTS]libuser.Mux_Slot

// One tick between looks at a key ring, for a read parked waiting on a line.
POLL_TICKS :: 1

/*
How many `cons` reads are parked, and the reason this server counts them.

**`serve_mux` answers inline when no slot is free**, which is right for every
message this server has except one. A `cons` read waits for a keystroke, so an
inline one parks the loop that draws -- and `Tremove` is inline too, so a
server wedged that way cannot even be stopped. Three abandoned reads is all it
takes, because a worker whose client died polls a ring nobody will fill.

The count is what makes the inline case identifiable from inside the handler.
`serve_mux` forks at most `SLOTS` workers, so a `cons` read that arrives with
`SLOTS` already parked is the inline one, and it is refused instead of waiting.
The loop that owns the glass therefore never parks, whatever a client does.

`EAGAIN` rather than an empty read, because a short read means end of file to
every client in this tree and a client that should try again is not at one.
*/
cons_parked: u32

/*
_start opens the screen, learns its shape, and serves.

The exits each name their failure. 0x74 is a framebuffer that would not
open, 0x76 a geometry this server cannot draw on -- fewer than four
numbers, a depth other than 32, or a cascade that would not fit -- 0x77 a
screen that would not map, and 0x71 a post that failed. 0x78 was a window
that could not buy its pixels, retired when a run became the session's. The serve loop's three endings are `ramfs`'s,
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

	// And the windows' places. Their memory is bought per session now, at
	// `Tlopen`, so nothing here can fail for want of it.
	windows_init()

	// And the ground everything stands on. From here this server owns every
	// pixel of the screen: `/dev/fb` diverts the console for as long as the
	// descriptor above is open, so nothing else is painting.
	desk_paint(0, 0, scr_w, scr_h)

	/*
	And the keyboard, which is a file like everything else.

	`/dev/cons` rather than `/dev/scancode`, because `rio` reads a cooked
	keyboard and so does this. The translation is `kbdfs`'s and the divert
	behind it is `/dev/scancode`'s, one process further out. What this server
	diverts is the glass.

	The rings are framed before the fork, so both halves hold the same
	structure rather than each initialising its own copy.
	*/
	for i in 0 ..< MAX_WINDOWS {
		kbd[i] = libuser.Ring{buf = kbd_store[i][:]}
		edit[i] = libedit.Line{buf = edit_store[i][:]}
	}
	cons := libuser.open("/dev/cons", abi.O_RDONLY)
	if cons < 0 {
		libuser.exit(0x79)
	}

	/*
	And raw, because the line discipline is this server's now.

	`rio` writes exactly this and for exactly this reason: a window system
	that cooks per window must be given the characters. The kernel's own
	discipline is still there for everything that has not diverted the
	console, and `consctl_close` puts it back when this descriptor goes --
	so it is held for the server's whole life, the way `apps/terminal` holds
	its own.

	Raw mode turns the kernel's echo off with it, which is what `echooff`
	was doing by hand. A window's text is drawn by its client.
	*/
	cons_ctl := libuser.open("/dev/consctl", abi.O_WRONLY)
	if cons_ctl < 0 {
		libuser.exit(0x79)
	}
	raw := "rawon"
	if libuser.write(int(cons_ctl), transmute([]u8)raw) != i64(len(raw)) {
		libuser.exit(0x79)
	}

	pid := libuser.rfork(abi.RFPROC | abi.RFMEM)
	if pid < 0 {
		libuser.exit(0x73)
	}
	if pid == 0 {
		reader(int(cons))
	}

	sfd, perr := libuser.post("/srv/draw")
	if perr < 0 {
		_ = libuser.stop_child(u64(pid))
		libuser.exit(0x71)
	}

	for i in 0 ..< SLOTS {
		slots[i] = libuser.Mux_Slot {
			frame   = slot_frame[i][:],
			out     = slot_out[i][:],
			payload = slot_payload[i][:],
		}
	}
	mux := libuser.Mux {
		fd      = sfd,
		handler = handler,
		blocks  = blocks,
		frame   = frame_in[:],
		out     = frame_out[:],
		payload = payload[:],
		wlock   = &wlock,
		slots   = slots[:],
	}

	_, why := libuser.serve_mux(&mux)

	// The flag first, so a worker parked on an empty ring leaves before the
	// child it was waiting on is noted out of its console read.
	intrinsics.volatile_store(&stopping, true)

	if why != .Removed {
		_ = libuser.stop_child(u64(pid))
		libuser.exit(why == .Hangup ? 0x68 : 0x72)
	}
	libuser.exit(libuser.stop_child(u64(pid)) ? 0 : 0x75)
}

/*
blocks is true for exactly the read that waits on a keystroke: a read of a
window's `cons`.

**Everything that draws is false here**, which is what keeps one loop painting.
A worker answers a `cons` read and touches that window's key ring and the fid
table, and neither the glass nor a window's store nor `scratch` is reachable
from it.
*/
blocks :: proc "contextless" (state: rawptr, request: ^vectra9.Msg) -> bool {
	_ = state
	#partial switch m in request^ {
	case vectra9.Tread:
		return node_part(libuser.fid_lookup(&fids, m.fid)) == PART_CONS
	}
	return false
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

	**A window is born shorter than the glass, and `rio` is why.** `goodrect`
	refuses a rectangle that contains the whole screen -- "must have some
	screen and border visible so we can move it out of the way" -- and `rio`
	invents no rectangle at all: a window's size comes from a sweep or from an
	explicit `wctl` rect. Nothing there is ever born filling the display.

	Vectra has no pointer, so the size is a policy rather than a gesture, and
	`WIN_FILL` is that policy. What it buys beyond looking right is that a
	window can *grow* somewhere the glass can be read: while a window was born
	as tall as the screen, every row `segbrk` added fell below it and
	`composite` clipped it away, so two of that call's controls had nothing to
	watch. See `docs/USER.md`.
	*/
	win_w = scr_w / MAX_WINDOWS
	win_h = scr_h * WIN_FILL / 100
	if win_w <= 0 {
		return false
	}
	// And a window has to have room for a client area inside its frame. A
	// screen too small for one is a geometry this server cannot draw on,
	// which is the refusal it already makes for a depth it cannot pack.
	_, _, cw, ch := frame_client(win_w, win_h)
	if cw <= 0 || ch <= 0 {
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

**It is the client area rather than the window**, which is what a frame did to
this report. A client draws on the inside of the border and below the bar, and
the extent it is told is the extent it may use. It is never told there is a
frame, and no coordinate it sends means anything outside the area reported
here. A `size` line names this same rectangle, so what a client reads back is
in the units it writes.
*/
window_report :: proc "contextless" (out: []u8, win: ^Window) -> int #no_bounds_check {
	_, _, cw, ch := frame_client(win.w, win.h)
	at := 0
	at = put_report(out, at, "size ")
	at = put_number(out, at, cw)
	at = put_report(out, at, " ")
	at = put_number(out, at, ch)
	at = put_report(out, at, " ")
	at = put_number(out, at, cw * 4)
	at = put_report(out, at, " 32\n")
	return at
}

/*
The control lines, and the whole of what a client may say about its window.

    move X Y     put it somewhere else
    size W H     make its client area another shape, inside the run it holds
    raise        bring it to the front, and take the focus with it
    name TEXT    what the bar across its top says

Four lines rather than four verbs, which is the distinction `docs/DRAW.md`
section 5 has guarded since there were six verbs and nothing else. A verb is
about pixels. A window is not a pixel, and neither is its name.

`size` and the report `ctl` answers are both the *client area*, never the
window around it. A client is not told it has a frame and could not act on the
number if it were.

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
	case "name":
		// The one line whose operand is not a number, so `ctl_rest` takes it
		// where the other two ask `ctl_end` whether anything is left.
		return window_name(win, ctl_rest(data, at))
	}
	return vectra9.EINVAL
}

/*
run_consctl is a window's own `consctl`, and it takes the two words
`/dev/consctl` takes for the same two meanings.

    rawon     no line discipline: every character, the moment it arrives
    rawoff    the line discipline above, and whole lines out

**A client asks its own window rather than the machine.** `apps/terminal`
writes `echooff` to `/dev/consctl` before it mounts anything, and that is a
statement about the kernel's console. This is the same idea scoped to a
window, which is what `rio` serves a `consctl` per window for.

Echo is not here, because nothing in this server echoes. The kernel's console
draws typed bytes on the glass it no longer owns, and a window's text is drawn
by its client out of glyphs the client uploaded. There is nothing for an
`echoon` to turn on.

Switching mode drops the line under construction. Half a line edited under one
discipline is not a line under the other, and carrying it across would be a
guess about what the client meant.
*/
run_consctl :: proc "contextless" (win_at: int, data: []u8) -> vectra9.Errno #no_bounds_check {
	if win_at < 0 || win_at >= MAX_WINDOWS {
		return vectra9.EINVAL
	}
	win := &windows[win_at]
	if !win.used {
		return vectra9.EBADF
	}
	verb, at := ctl_word(data, 0)
	if !ctl_end(data, at) {
		return vectra9.EINVAL
	}
	switch verb {
	case "rawon":
		win.cons_raw = true
	case "rawoff":
		win.cons_raw = false
	case:
		return vectra9.EINVAL
	}
	libedit.clear(&edit[win_at])
	return vectra9.Errno(0)
}

// ctl_word takes the next run of non-space bytes, and answers where it ended.
@(private = "file")
ctl_word :: proc "contextless" (data: []u8, from: int) -> (string, int) #no_bounds_check {
	at := from
	for at < len(data) && ctl_space(data[at]) {
		at += 1
	}
	start := at
	for at < len(data) && !ctl_space(data[at]) {
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
		if !ctl_space(data[i]) {
			return false
		}
	}
	return true
}

/*
ctl_rest is everything after the verb, with the space either side of it taken
off. The operand of a line that does not take numbers.

It lives here with `ctl_word` and `ctl_end` because it is the third of one
file's three ideas about where a word begins and ends, and `ctl_space` is now
the only place that says what a space is.

**A `ctl` write is one line**, which `ctl_end` has assumed since there were
three lines and which this makes explicit: everything to the end of the write
belongs to this line, so a second line behind it would be part of the name.
*/
@(private = "file")
ctl_rest :: proc "contextless" (data: []u8, from: int) -> []u8 #no_bounds_check {
	start := from
	for start < len(data) && ctl_space(data[start]) {
		start += 1
	}
	end := len(data)
	for end > start && ctl_space(data[end - 1]) {
		end -= 1
	}
	return data[start:end]
}

@(private = "file")
ctl_space :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
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
windows_init places every window, once, at start. It buys nothing.

**The run used to be bought here rather than at `Tlopen`, and that was what
having no `segdetach` meant.** A slot's memory could not go back, so it could
not be tied to a session that comes and goes. It was bought once, for the
life of the server, and lent to whichever session held the slot. That was
two megabytes apiece at 640 by 800, held whether or not anyone was drawing.

`window_open` buys the run now and `window_close` gives it back. A session
costs memory for as long as it lasts and no longer, which is what a session
is. The one thing that moved the wrong way is where a failure lands. A
machine with no run left refuses the `Tlopen` with `ENOMEM`, which is a
reason the client can at least report.
*/
windows_init :: proc "contextless" () #no_bounds_check {
	for i in 0 ..< MAX_WINDOWS {
		windows[i] = Window {
			x    = i * (win_w / 2),
			y    = 0,
			w    = win_w,
			h    = win_h,
			rows = win_h,
		}
	}
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
window_open claims window `at` for this fid, buys its run, or reports why not.

**The claim is by index now, because the tree is numbered.** A session used to
be handed whichever window was free, and could not be told which. It walks to
one by name and takes it, so a `ctl` line has something to be about.

**The run is the session's, bought here and detached at the clunk.** It
arrives zero from the kernel, and the frame writes every pixel of it anyway.
`window_chrome` paints the plinth's *face* over the window's whole rectangle
before it chisels anything, and the well's face over the whole client area
after, so every pixel a session can see is written by the frame. The window
opens at its birth size, so the whole run is covered. That is what retired a
two megabyte memset when a run still outlived its session. It is still what
puts the frame on the glass.

A run bought after the fork is this process's alone. The reader child was
forked at start and holds none of these. So a `size` line may shrink one as
well as grow it -- see `window_size`.

The composite at the end is the window appearing. It walks the stack, so a
window that opens under another shows up occluded rather than on top.

`ENOSPC` is a window somebody else holds, or no window at all. `ENOMEM` is a
machine with no run left, which is the one refusal a client can report.
*/
window_open :: proc "contextless" (owner: vectra9.Fid, at: int) -> vectra9.Errno #no_bounds_check {
	if at < 0 || at >= MAX_WINDOWS {
		return vectra9.ENOSPC
	}
	win := &windows[at]
	if win.used {
		return win.owner == owner ? vectra9.Errno(0) : vectra9.ENOSPC
	}
	base, err := libuser.segalloc(win_w * win_h * 4)
	if err < 0 {
		return vectra9.ENOMEM
	}

	was := stack_top()
	win.owner = owner
	win.used = true
	win.pixels = ([^]u32)(base)
	win.rows = win_h
	win.w = win_w
	win.h = win_h
	win.title_n = 0
	region_clear(&win.dmg)
	/*
	And the keystrokes, which is the same rule as the pixels one line up.

	**A slot outlives the session it was lent to**, and its key ring is as
	much a part of that slot as its store is. A window nobody was reading
	fills one to its cap, so a new session's first read would answer with what
	the last client was typed and never took. The frame clears the pixels and
	this clears the queue, for the reason `window_open`'s own comment gives.

	Dropping the tail on the head empties it without disturbing the producer's
	end, which is the only end the child owns.
	*/
	intrinsics.volatile_store(&kbd[at].tail, intrinsics.volatile_load(&kbd[at].head))
	// And the exclusive files go back with the slot. `fid_release` gives them
	// up when the fid that held them is clunked, and a session that ends
	// without clunking -- or a fid opened on a window somebody else then
	// claimed -- would otherwise deny a window's own client its own files.
	win.ctl_held = false
	win.cons_held = false
	win.consctl_held = false
	win.cons_raw = false
	libedit.clear(&edit[at])
	// New windows arrive on top, which is the only placement rule a client
	// gets without asking. Before the frame rather than after it, because the
	// frame's bar is drawn lit or dark by where this window stands, and this
	// is the line that puts it in front.
	stack_add(at)
	// The frame, nameless until a `name` line says otherwise. A slot outlives
	// the session it was lent to, so the last client's name goes with the last
	// client's pixels -- and so do the pixels, because this writes every one
	// of them.
	window_chrome(win)
	// And the window it arrived over gives up the focus.
	refocus(was)

	repaint_top(win)
	// And the lamp for it. A lamp is opaque over its own square and sits
	// outside every window's rectangle, so the desktop's own repaint over that
	// square is exactly the lamp -- there is no second painter for one.
	lx, ly := lamp_at(at)
	desk_paint(lx, ly, lx + LAMP, ly + LAMP)
	return vectra9.Errno(0)
}

/*
window_close gives the slot back, gives its memory back, and repaints what it
was covering.

**The run goes back with `segdetach`, after the composite.** The window
below this one had its pixels the whole time it was hidden. `stack_drop`
runs before the repaint, so nothing reads the closing window's pixels once
the slot is free. The detach is last anyway, so that no reader of `pixels`
runs after it. `pixels` is nil after it, so a reader that did would fault by
name rather than read a run the kernel handed on.

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
		was := stack_top()
		win.owner = 0
		win.used = false
		stack_drop(i)
		// And the window under a closing one comes to the front, which is the
		// one case where focus arrives at a window that did nothing to ask.
		refocus(was)

		desk_paint(x0, y0, x1, y1)
		repaint(x0, y0, x1 - x0, y1 - y0)
		lx, ly := lamp_at(i)
		desk_paint(lx, ly, lx + LAMP, ly + LAMP)

		// And the memory, last. A detach that fails leaves the run held
		// until the server exits. That is the leak this server lived with
		// for two milestones, and the honest answer to a kernel that says no.
		if win.pixels != nil && libuser.segdetach(uintptr(win.pixels)) == 0 {
			win.pixels = nil
		}
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
window_size changes what a window is, and grows its run to hold it.

**The numbers are the client area**, the same rectangle `window_report`
answers with, and the frame this server puts around it is what the two differ
by. `frame_window` is that arithmetic, and the bound is checked
against the window it produces rather than against what was asked.

**A window grows its own run now, which is `segbrk`.** The store began as one
`segalloc` and `size` was capped at the birth height because nothing could
change a run. `docs/USER.md` has the call. What is still fixed is the *width*:
the stride is the run's and a window's shape is its rows.

The stride does not move with the width. A pixel a client drew at (x, y) is at
(x, y) afterwards, so shrinking loses the edges and growing keeps whatever this
session drew there before its last shrink.

**And the frame is what takes the stale band, the way it takes a new slot.**
`window_chrome` writes every pixel of the new window rectangle: the plinth's
face over all of it and the well's over the client area. So a window that grew
gets ground under the band it grew into, and the old border that was standing
just outside the old client area is written over rather than cleared first.

**No event tells the client.** None is needed: the client asked. A `ctl` read
answers the new size for anything that wants to confirm it.
*/
window_size :: proc "contextless" (win: ^Window, ncw: int, nch: int) -> vectra9.Errno #no_bounds_check {
	if ncw <= 0 || nch <= 0 {
		return vectra9.EINVAL
	}
	nw, nh := frame_window(ncw, nch)
	/*
	And the run grows to hold it, which is `segbrk`.

	**A window used to be capped at the size it was born**, because a run was
	fixed at its one `segalloc` and nothing in this kernel could grow one. That
	is the sentence `docs/DRAW.md` section 10 wrote as "`segbrk`'s absence
	speaking", and the call exists now.

	The stride is the run's width and stays `win_w`, so a window's shape is its
	rows. What `segbrk` is asked for is exactly the rows this window is about
	to have -- **both ways**. A window that shrinks gives the pages back rather
	than sitting on them, which is the half of `segbrk` that is about memory
	rather than about a cap.
	*/
	if nw > win_w {
		return vectra9.EINVAL
	}
	if nh != win_h_at(win) {
		/*
		**Growing must work and shrinking is best effort.**

		A run shared with another process cannot shrink -- Plan 9 refuses
		that on `s->ref > 1` and `docs/USER.md` says why: the pages about to
		go back may already be somewhere in the sharer's kernel. This server's
		runs were shared with its reader child while they were bought at
		start, before the fork, and every shrink was refused. A run is bought
		at `Tlopen` now, after the fork. It is this process's alone, and a
		shrink gives the pages back.

		The rule stays as written, because it is about the kernel's answer
		rather than about this server's history. A refused shrink is a reason
		to keep the pages, not to refuse the client. A window that gets smaller
		and keeps its run is a window that works; a window that cannot get
		bigger is the cap this call exists to lift.
		*/
		need := uintptr(win_w) * uintptr(nh) * 4
		err := libuser.segbrk(uintptr(win.pixels), uintptr(win.pixels) + need)
		if err < 0 {
			// Only a grow has to work. A refused shrink costs the pages and
			// nothing else.
			if nh > win_h_at(win) {
				return vectra9.ENOSPC
			}
		} else {
			win.rows = nh
		}
	}
	if nw == win.w && nh == win.h {
		return vectra9.Errno(0)
	}
	ow, oh := win.w, win.h

	win.w = nw
	win.h = nh
	window_chrome(win)
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
window_raise brings one to the front, and the front is what has the focus.

The stack is a list and this is a move to its end, so everything under it keeps
its order. Two rectangles can have changed: this window's, and the title bar of
whatever was in front before it. `refocus` is the second, and it is a bar
rather than a window because a bar is all that focus is drawn as.
*/
window_raise :: proc "contextless" (win: ^Window, at: int) #no_bounds_check {
	was := stack_top()
	if was == at {
		return
	}
	stack_add(at)
	// The front is what focus is, so this line moved it. Both bars are
	// repainted before the composite below, which then covers one of them
	// again with the rest of the window it belongs to.
	refocus(was)
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

The translation to screen coordinates happens once, here, into `scratch`. The
damage is in the store's own coordinates, which is what a window's origin
means, so this adds the window's place on the screen and nothing else.
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

// window_mark records one drawn rectangle, in the store's coordinates: what
// the next flush owes the glass. The caller has already moved a client's
// rectangle in by the frame, because the store is where a frame lives too.
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

/*
client_clip trims one of a client's rectangles to its client area and then
moves it into the store, in that order.

**The order is the whole point, and this is why it is one call.** Clipping
against the client area and then adding the inset keeps a client inside its own
rectangle. Adding the inset first and clipping against the window would let a
client past its own edge -- onto its border in this milestone, and into the
window beside it in the one where a client's rectangle used to land on the
glass. `run_fill` and `run_blit` are the two callers and a control once caught
them disagreeing, so neither writes the sequence out any more.

Answers whether anything is left, with `x` and `y` already in the store's
coordinates. `window_mark` takes them as they come back.
*/
client_clip :: proc "contextless" (
	win: ^Window,
	x: ^int,
	y: ^int,
	w: ^int,
	h: ^int,
	sx: ^int,
	sy: ^int,
) -> bool {
	cx, cy, cw, ch := frame_client(win.w, win.h)
	if !clip(x, y, w, h, sx, sy, cw, ch) {
		return false
	}
	x^ += cx
	y^ += cy
	return true
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
		The clip is the client area's, and the translation is back -- one
		level in.

		It used to be two lines here: clip in window coordinates, then move by
		the window's origin onto the glass, in that order, because the other
		order let a client past its own edge into the window beside it. A store
		into the window's own memory retired that, and a frame brings it back
		as the inset the client area sits at. Clip first, then move, for the
		same reason and with a smaller consequence: an unclipped store now
		lands in this window's own border rather than in the window beside it.

		`composite` still owns the other translation, and is still the only
		code that knows where a window sits on the screen.
		*/
		if !client_clip(win, &x, &y, &w, &h, &sx, &sy) {
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
		// The same call `run_fill` makes, which is why a blit and a fill
		// cannot disagree about the client area any more.
		if !client_clip(win, &dx, &dy, &sw, &sh, &sx, &sy) {
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
	if w := node_win(node); w >= 0 {
		// The exclusive files are given back by the fid that held them. A
		// window whose client never opened its `ctl` leaves it for whoever
		// asks, which is what having no users yet costs.
		if node_part(node) == PART_CTL && windows[w].ctl_held && windows[w].ctl_fid == fid {
			windows[w].ctl_held = false
		}
		if node_part(node) == PART_CONS && windows[w].cons_held && windows[w].cons_fid == fid {
			windows[w].cons_held = false
		}
		// And the mode goes back to cooked with the fid that set it, which
		// is `/dev/consctl`'s rule. A client that died in raw mode would
		// otherwise hand the next one a window with no line discipline.
		if node_part(node) == PART_CONSCTL && windows[w].consctl_held && windows[w].consctl_fid == fid {
			windows[w].consctl_held = false
			windows[w].cons_raw = false
			libedit.clear(&edit[w])
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
	case PART_CONS:
		return "cons"
	case PART_CONSCTL:
		return "consctl"
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
	case "cons":
		return node_of(w, PART_CONS)
	case "consctl":
		return node_of(w, PART_CONSCTL)
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
		controls, so two clients cannot both move one window. `cons` is
		exclusive for the reason one step along: two readers of one window's
		keyboard would each get part of every line.
		*/
		w := node_win(node)
		switch node_part(node) {
		case PART_DATA:
			if w < 0 {
				reply^ = vectra9.error_reply(vectra9.ENOSPC)
				return
			}
			if oerr := window_open(m.fid, w); oerr != 0 {
				reply^ = vectra9.error_reply(oerr)
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
		case PART_CONS:
			if w < 0 {
				reply^ = vectra9.error_reply(vectra9.ENOSPC)
				return
			}
			if windows[w].cons_held && windows[w].cons_fid != m.fid {
				reply^ = vectra9.error_reply(vectra9.ENOSPC)
				return
			}
			windows[w].cons_held = true
			windows[w].cons_fid = m.fid
		case PART_CONSCTL:
			if w < 0 {
				reply^ = vectra9.error_reply(vectra9.ENOSPC)
				return
			}
			if windows[w].consctl_held && windows[w].consctl_fid != m.fid {
				reply^ = vectra9.error_reply(vectra9.ENOSPC)
				return
			}
			windows[w].consctl_held = true
			windows[w].consctl_fid = m.fid
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
		A read of a window's `cons` parks until a line is typed at it, off in
		a worker of its own -- `blocks` sent it here, and it is the only
		message in this server that leaves the serve loop.

		The shutdown flag lets a parked read leave at teardown rather than
		wait for a keystroke a torn-down console will never deliver. A zero
		count asks for nothing and gets it.
		*/
		if w := node_win(node); w >= 0 && node_part(node) == PART_CONS {
			room := min(len(buf), int(m.count))
			if room <= 0 {
				reply^ = vectra9.Rread{data = nil}
				return
			}
			// The inline case, refused rather than waited out. See
			// `cons_parked`: this is the read the serve loop would have
			// parked on, and the serve loop is what paints.
			if intrinsics.atomic_load(&cons_parked) >= u32(len(slots)) {
				reply^ = vectra9.error_reply(vectra9.EAGAIN)
				return
			}
			intrinsics.atomic_add(&cons_parked, 1)
			defer intrinsics.atomic_sub(&cons_parked, 1)
			for {
				/*
				One line per read in cooked mode, which is `rio`'s drain rule.

				`rio` copies from a window's output point and breaks at the
				newline, so a program that reads gets one line however many are
				queued behind it. A drain that emptied the ring would hand a
				client two lines in one buffer, and a client that looked only
				at the first would lose the rest silently -- which is what
				`apps/terminal` was doing until this landed.

				Raw mode takes whatever is there. A client that asked for raw
				is the one deciding where a line ends.
				*/
				got := 0
				if windows[w].cons_raw {
					got = libuser.ring_drain(&kbd[w], buf[:room], &state_lock)
				} else {
					got = libuser.ring_drain_line(&kbd[w], buf[:room], '\n', &state_lock)
				}
				if got > 0 {
					reply^ = vectra9.Rread{data = buf[:got]}
					return
				}
				if intrinsics.volatile_load(&stopping) {
					reply^ = vectra9.Rread{data = nil}
					return
				}
				_ = libuser.sleep(POLL_TICKS)
			}
		}

		/*
		`new` answers which window has no session, and `ctl` answers a
		geometry. Both are built into the reply buffer at the moment they are
		asked, because both are answers about right now.

		The geometry is this window's own size rather than the one every
		window shares. A client that resized itself reads back what it asked
		for, which is the only confirmation a `ctl` line gets.
		*/
		if w := node_win(node); w >= 0 && node_part(node) == PART_CONSCTL {
			// The state as the command that would restore it, which is
			// `/dev/consctl`'s convention and `docs/DEVFS.md`'s.
			report := windows[w].cons_raw ? "rawon\n" : "rawoff\n"
			if m.offset >= u64(len(report)) {
				reply^ = vectra9.Rread{data = nil}
				return
			}
			from := int(m.offset)
			upto := min(len(report), from + min(len(buf), int(m.count)))
			copy(buf[:upto - from], transmute([]u8)report[from:upto])
			reply^ = vectra9.Rread{data = buf[:upto - from]}
			return
		}

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
		case PART_CONS:
			// Typed at, never written to. `data`'s read is refused the same
			// way, and neither is a directory.
			reply^ = vectra9.error_reply(vectra9.EPERM)
		case PART_CONSCTL:
			if err := run_consctl(node_win(node), m.data); err != vectra9.Errno(0) {
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
		// `cons` answers how much is waiting, which is what a size means for
		// a file whose contents are a queue. `kbdfs` answers the same way.
		size := u64(0)
		if w := node_win(node); w >= 0 && node_part(node) == PART_CONS {
			size = libuser.ring_available(&kbd[w])
		}
		mode := u32(0o100644)
		switch {
		case dir:
			mode = 0o040555
		case node_part(node) == PART_DATA:
			mode = 0o100222
		case node_part(node) == PART_CONS:
			mode = 0o100444
		}
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = mode,
			nlink   = dir ? 2 : 1,
			size    = size,
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

	count := root ? 1 + MAX_WINDOWS : 4
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
			child = node_of(w, PART_DATA + i32(i))
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
