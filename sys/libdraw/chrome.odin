/*
The chrome vocabulary: bevels, wells and lamps, as rectangles.

`kernel/splash.odin` paints the boot chassis and says of itself that
`intuition`'s window frames should be recognisably the same object. That could
not happen while the vocabulary was a set of surface painters in ring 0. This
is that vocabulary with the painting taken out of it, and `frame` is the
sentence itself: a window's border and title bar, out of the same names the
chassis's plinth and copper bar come from.

**A piece of chrome is a list of coloured rectangles, and that is the whole
design.** The kernel walks a `[]Piece` through `fb.paint`, straight onto a
surface. The draw server paints into a window's store or onto the glass. A
client sends `fill` commands down a pipe. Those are three different painters,
and the one thing they agree about is a rectangle with a colour in it. So this
decomposes and paints nothing.

**Both privilege levels wear it**, which is what `Piece.color` being an `RGB`
rather than a packed pixel word bought. `fb.paint` packs against the mode the
bootloader actually set, and ring 3 packs with `libpal.xrgb` because
`/srv/draw` accepts one depth. There is no copy of the arithmetic left to
drift.

What the rectangle model does not carry is the chassis's two richest surfaces.
`gradient_v` is a colour per row and `brushed` is a pattern per pixel, and
neither is a rectangle. The chassis keeps both by painting them *over* the
rectangles this file decomposes it into, which is what a lit jewel does. Ring 3
has no verb for either. A client that wants a gradient sends one fill per row.
A gradient verb would be the seventh verb `docs/DRAW.md` section 5 guards
against, and a row of fills is what a client library is for.

The light source is fixed at the top-left, as it was on every machine this look
is quoting, and as `fb.bevel_edges` had it before the walk moved here.
*/
package libdraw

import "vsys:libpal"

/*
One rectangle of chrome, in whatever coordinates the caller is working in.

The colour is an `RGB` rather than a packed pixel word, so a painter packs it
for the mode it is drawing on. Ring 3 packs with `libpal.xrgb`, because
`/srv/draw` accepts one depth. The kernel packs with `fb.pack`, which reads the
channel shifts the bootloader set -- which is the whole reason this type cannot
carry a `u32`.
*/
Piece :: struct {
	x:     int,
	y:     int,
	w:     int,
	h:     int,
	color: libpal.RGB,
}

Bevel :: enum {
	Raised, // A control that stands up: light on top and left
	Recessed, // A well sunk into the face: light on the bottom and right
}

// The most rectangles any one *panel* call below produces: a face and four
// edges per level of depth, and one jewel. A caller sizes its array by this
// and never counts. Written against `MAX_DEPTH` so the two cannot drift.
MAX_DEPTH :: 4
MAX_PIECES :: 1 + 4 * MAX_DEPTH + 1

/*
And what a `frame` makes, which is three panels: the border, the bar on it,
and the well the client area is sunk into.

Its own bound rather than a larger `MAX_PIECES`, because a caller that draws
no frames should keep the smaller array. `fb.bevel_edges` puts one on a kernel
stack that a panic walks.
*/
MAX_FRAME_PIECES :: 3 * (1 + 4 * MAX_DEPTH)

/*
The window frame's three numbers, and the only three a window's chassis has.

`FRAME_EDGE` is the raised border a window stands up out of the desktop with.
`FRAME_TITLE` is the bar across the top of it, inside that border.
`FRAME_WELL` is the recess the client area is sunk into, which is what makes a
window the same object as the chassis: a raised plinth with a sunken screen in
it. Everything else about a frame is arithmetic over those three, and all of it
is below.

**They are here rather than in the draw server because a frame moves the
client area, and more than the server has to know where it went.** The server
insets every client store by it. `kernel/user/verify.odin` reads back pixels a
client drew and has to know where on the glass they landed. Two places
computing one inset by hand is the drift this file exists to stop.
*/
FRAME_EDGE :: 3
FRAME_TITLE :: 20
FRAME_WELL :: 2

// What the bar keeps clear around its text. The bar is `FRAME_TITLE` tall and
// a glyph is sixteen, so the vertical half of this is what centres one.
FRAME_PAD :: 4

/*
edges decomposes a bevelled border into its four sides, per level of depth,
from the outside in.

**The face is not here**, because what a border gets chiselled around is often
not a rectangle. The chassis's plinth is `brushed` and its copper bar is
`gradient_v`. The desktop is ground with a grid engraved in it. `fb.bevel_edges`
and `intuition`'s `desk_chrome` are the two callers, and `panel` below is this
with a face put in front of it.

`depth` is clamped to `MAX_DEPTH`. A bevel deeper than the box it is on is
arithmetic nobody wants to debug at a call site. Returns how many pieces it
wrote, and stops early rather than overrunning the array it was given.
*/
edges :: proc "contextless" (
	out: []Piece,
	x: int,
	y: int,
	w: int,
	h: int,
	style: Bevel,
	light: libpal.RGB,
	dark: libpal.RGB,
	depth: int,
) -> int #no_bounds_check {
	if w <= 0 || h <= 0 {
		return 0
	}
	d := clamp(depth, 0, MAX_DEPTH)

	tl := style == .Raised ? light : dark
	br := style == .Raised ? dark : light

	n := 0
	for i in 0 ..< d {
		ix := x + i
		iy := y + i
		iw := w - 2 * i
		ih := h - 2 * i
		if iw <= 0 || ih <= 0 || n + 4 > len(out) {
			break
		}
		out[n] = Piece{ix, iy, iw, 1, tl}
		out[n + 1] = Piece{ix, iy, 1, ih, tl}
		out[n + 2] = Piece{ix, iy + ih - 1, iw, 1, br}
		out[n + 3] = Piece{ix + iw - 1, iy, 1, ih, br}
		n += 4
	}
	return n
}

/*
panel decomposes a bevelled box into its face and its edges.

The face first, then `edges`. A painter that walks the list in order draws
exactly what a painter that nests them would. Returns how many pieces it wrote,
and writes nothing at all for a box too small to have an interior.

`.Raised` is what the chassis's plinth and its copper bar are, and what a
window's border and title bar are. `.Recessed` is every well. The wrapper
naming a face and its two shades belongs with a caller rather than ahead of
one, which is what `frame` and `well` below are.
*/
panel :: proc "contextless" (
	out: []Piece,
	x: int,
	y: int,
	w: int,
	h: int,
	style: Bevel,
	face: libpal.RGB,
	light: libpal.RGB,
	dark: libpal.RGB,
	depth: int,
) -> int #no_bounds_check {
	if w <= 0 || h <= 0 || len(out) < 1 {
		return 0
	}
	out[0] = Piece{x, y, w, h, face}
	return 1 + edges(out[1:], x, y, w, h, style, light, dark, depth)
}

/*
well is the sunken panel every recessed thing in this system is: a slate face
with a magnesium highlight below and the void above.

The chassis's console well, the terminal's field, and whatever a program sinks
into its own window are one call apart.
*/
well :: proc "contextless" (out: []Piece, x: int, y: int, w: int, h: int, depth := 2) -> int {
	return panel(out, x, y, w, h, .Recessed, libpal.SLATE, libpal.MAGNESIUM_LIT, libpal.VOID, depth)
}

/*
frame decomposes a window's chassis: a raised border, with a copper bar across
the top of it.

**The same three surfaces the boot chassis is made of, one privilege level
out.** `kernel/splash.odin` says its window frames should be recognisably the
same object as the screen the kernel painted, and this is the call that makes
them so: a raised plinth, a copper bar across its top, and a well sunk into
what is left. The plinth is brushed magnesium there and flat here, and the bar
is a copper gradient there and flat here, for the reason the file comment
gives: neither a pattern nor a ramp is a rectangle.

**The well's face is the client area's ground**, so a client that draws nothing
gets the sunken slate field rather than the plinth it is standing on. A window
covers its whole rectangle either way; this is the difference between covering
it correctly and covering it.

The name on the bar is not here either. A glyph is not a rectangle, and the
painter that has a font is the one that draws it.

Coordinates are the window's own, so a server painting into a window's store
passes (0, 0). Answers how many pieces it wrote; size the array by
`MAX_FRAME_PIECES`.
*/
frame :: proc "contextless" (out: []Piece, x: int, y: int, w: int, h: int) -> int #no_bounds_check {
	n := panel(
		out,
		x,
		y,
		w,
		h,
		.Raised,
		libpal.MAGNESIUM,
		libpal.MAGNESIUM_HOT,
		libpal.MAGNESIUM_DARK,
		FRAME_EDGE,
	)
	if n == 0 {
		return 0
	}
	n += frame_bar(out[n:], x, y, w)
	return n + well(
		out[n:],
		x + FRAME_EDGE,
		y + FRAME_EDGE + FRAME_TITLE,
		w - 2 * FRAME_EDGE,
		h - 2 * FRAME_EDGE - FRAME_TITLE,
		FRAME_WELL,
	)
}

/*
frame_bar decomposes the title bar alone: copper trim, out of the same three
names the chassis's own bar is drawn from.

Apart from `frame` because a window that is renamed repaints its bar and
nothing else, and the bar is what an old name has to be erased off.
*/
frame_bar :: proc "contextless" (out: []Piece, x: int, y: int, w: int) -> int {
	bx, by, bw, bh := frame_bar_at(x, y, w)
	return panel(out, bx, by, bw, bh, .Raised, libpal.COPPER, libpal.COPPER_LIT, libpal.COPPER_DARK, 1)
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
	in_x := FRAME_EDGE + FRAME_WELL
	in_y := FRAME_EDGE + FRAME_TITLE + FRAME_WELL
	return in_x, in_y, w - 2 * in_x, h - in_y - FRAME_EDGE - FRAME_WELL
}

// frame_window is the inverse: the window a client area of `cw` by `ch` needs
// around it. A `size` line names a client area, because a `ctl` read answers
// one, and this is what turns that into a window.
frame_window :: proc "contextless" (cw: int, ch: int) -> (w: int, h: int) {
	return cw + 2 * (FRAME_EDGE + FRAME_WELL), ch + 2 * (FRAME_EDGE + FRAME_WELL) + FRAME_TITLE
}

/*
lamp is one indicator: a recessed socket with a jewel in it.

**An unlit lamp is a dark version of its own colour, rather than a neutral
grey.** That sentence is `kernel/splash.odin`'s and so is the reason. A bank of
lamps with none of them on still reads as several of the same kind of thing.
*/
lamp :: proc "contextless" (out: []Piece, x: int, y: int, size: int, color: libpal.RGB, lit: bool) -> int #no_bounds_check {
	n := panel(out, x, y, size, size, .Recessed, libpal.MAGNESIUM_DARK, libpal.MAGNESIUM_LIT, libpal.VOID, 1)
	if n == 0 || n >= len(out) {
		return n
	}
	// A lit jewel is flat here, and the chassis paints a gradient and a
	// specular corner over it. Those are a colour per row and one pixel, and
	// neither is a rectangle. See the file comment. An unlit one is the whole
	// rule, which is why it is the state with a check on it.
	jewel := lit ? color : libpal.mix(color, libpal.VOID, 200)
	out[n] = Piece{x + 2, y + 2, size - 4, size - 4, jewel}
	return n + 1
}

/*
put_pieces encodes a run of chrome as `fill` commands into a client's batch.

The one place in this file that knows there is a protocol. A server painting
its own memory walks the same list and stores instead. That is why `panel`
answers with rectangles rather than with a command stream.

Answers where the batch now ends, or the offset it was given if the whole run
does not fit. A caller that gets its own offset back sends what it has and
calls again, which is the rule `put_text` already set.
*/
put_pieces :: proc "contextless" (buf: []u8, at: int, id: u32, pieces: []Piece) -> int #no_bounds_check {
	n := at
	for p in pieces {
		if p.w <= 0 || p.h <= 0 {
			continue
		}
		next := put_fill(buf, n, id, u32(p.x), u32(p.y), u32(p.w), u32(p.h), libpal.xrgb(p.color))
		if next == n {
			return at
		}
		n = next
	}
	return n
}
