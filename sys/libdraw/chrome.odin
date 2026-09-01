/*
The chrome vocabulary: bevels, wells and lamps, as rectangles.

`kernel/splash.odin` paints the boot chassis and says of itself that
`intuition`'s window frames should be recognisably the same object. That could
not happen while the vocabulary was a set of surface painters in ring 0. This
is the same vocabulary one privilege level out.

**Ring 0 has not been moved onto it, and until it is there are two copies.**
`fb.bevel_edges` and `splash.draw_lamp` still paint the chassis. What that
costs is drift, so the arithmetic here is deliberately the kernel's own. The
edge walk is `fb.bevel_edges`'s inset-per-depth loop, and an unlit jewel is
`mix(colour, VOID, 200)` because that is what `splash.draw_lamp` makes.

The move is one surface painter away: `fb` walking a `[]Piece` through
`fill_rect`. `Piece.color` carries an `RGB` rather than a packed word so that
painter can pack against the mode the bootloader actually set.

**A piece of chrome is a list of coloured rectangles, and that is the whole
design.** The kernel paints its chassis straight onto a surface. The draw
server paints into a window's store or onto the glass. A client sends `fill`
commands down a pipe. Those are three different painters, and the one thing
they agree about is a rectangle with a colour in it. So this decomposes and
paints nothing.

What the rectangle model does not carry is the chassis's two richest surfaces.
`gradient_v` is a colour per row and `brushed` is a pattern per pixel, and
neither is a rectangle. A client that wants a gradient sends one fill per row
today. A gradient verb would be the seventh verb `docs/DRAW.md` section 5
guards against, and a row of fills is what a client library is for.

The light source is fixed at the top-left, as it was on every machine this look
is quoting, and as `fb.bevel_edges` already had it.
*/
package libdraw

import "vsys:libpal"

/*
One rectangle of chrome, in whatever coordinates the caller is working in.

The colour is an `RGB` rather than a packed pixel word, so a painter packs it
for the mode it is drawing on. Ring 3 packs with `libpal.xrgb`, because
`/srv/draw` accepts one depth. The kernel would pack with `fb.pack`, which
reads the channel shifts the bootloader set -- which is the whole reason this
type cannot carry a `u32`.
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

// The most rectangles any one call below produces: a face and four edges per
// level of depth, and one jewel. A caller sizes its array by this and never
// counts. Written against `MAX_DEPTH` so the two cannot drift.
MAX_DEPTH :: 4
MAX_PIECES :: 1 + 4 * MAX_DEPTH + 1

/*
panel decomposes a bevelled box into its face and its edges.

The face first, then the edges from the outside in. A painter that walks the
list in order draws exactly what a painter that nests them would. Returns how
many pieces it wrote, and writes nothing at all for a box too small to have an
interior.

`depth` is clamped to `MAX_DEPTH`. A bevel deeper than the box it is on is
arithmetic nobody wants to debug at a call site.

**Nothing passes `.Raised` yet.** Nothing in this system stands up off the
ground. The desktop is a well, a lamp socket is a well, and a window has no
frame. The frame is what will exercise it. The wrapper naming a face and its
two shades belongs with that caller rather than ahead of it.
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
	d := clamp(depth, 0, MAX_DEPTH)

	n := 0
	out[0] = Piece{x, y, w, h, face}
	n = 1

	tl := style == .Raised ? light : dark
	br := style == .Raised ? dark : light

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
well is the sunken panel every recessed thing in this system is: a slate face
with a magnesium highlight below and the void above.

The chassis's console well, the terminal's field, and whatever a program sinks
into its own window are one call apart.
*/
well :: proc "contextless" (out: []Piece, x: int, y: int, w: int, h: int, depth := 2) -> int {
	return panel(out, x, y, w, h, .Recessed, libpal.SLATE, libpal.MAGNESIUM_LIT, libpal.VOID, depth)
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
	// The same arithmetic `splash.draw_lamp` uses, so the two lamps make the
	// same pixels for as long as there are two of them. A lit jewel there also
	// carries a gradient and a specular corner. Those are a colour per row and
	// one pixel, and neither is a rectangle. See the file comment.
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
