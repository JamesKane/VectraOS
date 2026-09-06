/*
text -- the library `docs/DRAW.md` promised instead of a font verb.

A glyph on the screen is a blit out of an atlas. The atlas is a set of strip
images of cells, uploaded once, blitted per character for ever after. This
file owns the arithmetic from a rune of text to that blit. It knows nothing
about any particular font -- the caller uploaded the strips and says how they
are laid out.

The atlas is a *set of rune ranges*, which is 9front's `Font`: a handful of
`Cachefont` spans, each a run of runes taken from one subfont. ASCII is one
range; Latin-1, the punctuation and the arrows are more. `sys/libfont` names
the same ranges on the read side, and a client bakes a strip-set per range in
each colour it draws a label in. A rune no range holds blits nothing and still
takes its cell, so a caller's background fill reads as a space under it.

`put_text` diverges from the other puts in one way, and on purpose. It returns
the bytes it consumed and the cells it advanced, as well as the new offset,
because a full buffer is a batch boundary rather than an error. A caller with
more text writes the batch and calls again with the rest, its pixel x moved on
by the cells the last call drew. That keeps the wire budget in one pump loop,
not baked into every client as a magic count.
*/
package libdraw

// MAX_ATLAS_RANGES caps the ranges one atlas describes. ASCII and the three
// `sys/libfont` names past it -- Latin-1, punctuation, arrows -- leave room.
MAX_ATLAS_RANGES :: 8

/*
Atlas_Range is one run of runes `[lo, hi]` packed into the atlas's shared
strip set starting at cell `offset`. Rune `r`'s cell is `offset + (r - lo)`.
It is 9front's `Cachefont`: `offset` is its "position in subfont of the
character at min", here a position in the one packed strip set the whole face
shares, so a font of several ranges spends one run of image ids and not one
run per range.
*/
Atlas_Range :: struct {
	lo, hi: rune,
	offset: int,
}

/*
Atlas describes the strip images already uploaded for one face: `per_image`
cells of `cell_w` by `cell_h` each, in image ids from `first_image_id` up,
packed one range after another. The ranges say which runes are there and at
what cell. A face is one atlas per colour pair, because the draw server's blit
is opaque and carries the background baked in.
*/
Atlas :: struct {
	first_image_id: u32,
	per_image:      int,
	cell_w:         int,
	cell_h:         int,
	n:              int,
	ranges:         [MAX_ATLAS_RANGES]Atlas_Range,
}

// atlas_locate names the strip and column rune `r` lives in, or ok false for
// a rune no range holds. `put_text` blits by it, and an uploader baking the
// strips runs the same fields in reverse -- the layout is described once, in
// the struct both read.
atlas_locate :: proc "contextless" (a: Atlas, r: rune) -> (image: u32, sx: u32, ok: bool) #no_bounds_check {
	for i in 0 ..< a.n {
		rg := a.ranges[i]
		if r >= rg.lo && r <= rg.hi {
			idx := rg.offset + int(r - rg.lo)
			return a.first_image_id + u32(idx / a.per_image), u32((idx % a.per_image) * a.cell_w), true
		}
	}
	return 0, 0, false
}

/*
decode_rune reads one UTF-8 rune from `b`, answering it and its byte length. A
byte that starts no valid sequence is one rune of itself -- 9front's
`chartorune` answering `Runeerror` and moving one byte on -- so a stream this
cannot read makes progress rather than stalling. `libdraw` carries its own
decoder rather than `core:unicode/utf8`, because the kernel links it too.
*/
decode_rune :: proc "contextless" (b: []u8) -> (r: rune, size: int) #no_bounds_check {
	if len(b) == 0 {
		return 0, 0
	}
	c := b[0]
	if c < 0x80 {
		return rune(c), 1
	}
	n: int
	switch {
	case c & 0xE0 == 0xC0:
		r = rune(c & 0x1F); n = 2
	case c & 0xF0 == 0xE0:
		r = rune(c & 0x0F); n = 3
	case c & 0xF8 == 0xF0:
		r = rune(c & 0x07); n = 4
	case:
		return rune(c), 1
	}
	if len(b) < n {
		return rune(c), 1
	}
	for i in 1 ..< n {
		if b[i] & 0xC0 != 0x80 {
			return rune(c), 1
		}
		r = r << 6 | rune(b[i] & 0x3F)
	}
	return r, n
}

// rune_len counts the cells a UTF-8 string draws into -- one per rune, which
// is one per monospace column. A centred label and a line's width are sized
// by it, not by the byte length a multi-byte rune would overstate.
rune_len :: proc "contextless" (text: string) -> int #no_bounds_check {
	cells := 0
	i := 0
	for i < len(text) {
		_, size := decode_rune(transmute([]u8)text[i:])
		if size <= 0 {
			break
		}
		i += size
		cells += 1
	}
	return cells
}

/*
put_runes packs one blit per rune of `runes` at (x, y) on `dst`, a cell apart,
until the buffer refuses the next one. It is `put_text` for a caller that
already holds runes rather than UTF-8 -- a terminal's grid, a cell a rune --
so it needs no decoding. Returns the new offset and how many runes it drew; a
count short of the slice is the cue to write the batch and continue with the
rest, `x` moved on by `put * cell_w`. A rune the atlas does not carry consumes
with no blit. A negative `at` passes through as (-1, 0).
*/
put_runes :: proc "contextless" (
	b: []u8,
	at: int,
	a: Atlas,
	dst: u32,
	x: u32,
	y: u32,
	runes: []rune,
) -> (nat: int, put: int) #no_bounds_check {
	if at < 0 {
		return -1, 0
	}
	nat = at
	for put < len(runes) {
		if image, sx, ok := atlas_locate(a, runes[put]); ok {
			next := put_blit(b, nat, dst, x + u32(put * a.cell_w), y, image, sx, 0, u32(a.cell_w), u32(a.cell_h))
			if next < 0 {
				return nat, put
			}
			nat = next
		}
		put += 1
	}
	return nat, put
}

/*
put_text packs one blit per rune of `text` at (x, y) on `dst`, until the
buffer refuses the next one. Returns the new offset, the bytes it consumed,
and the cells it advanced. A rune the atlas does not carry consumes with no
blit -- the caller's background fill already reads as a space. A byte count
short of the text is the caller's cue to write the batch and continue, its `x`
moved on by `cells * cell_w`. A negative `at` passes through as (-1, 0, 0).
*/
put_text :: proc "contextless" (
	b: []u8,
	at: int,
	a: Atlas,
	dst: u32,
	x: u32,
	y: u32,
	text: string,
) -> (nat: int, put: int, cells: int) #no_bounds_check {
	if at < 0 {
		return -1, 0, 0
	}
	nat = at
	for put < len(text) {
		r, size := decode_rune(transmute([]u8)text[put:])
		if size <= 0 {
			break
		}
		if image, sx, ok := atlas_locate(a, r); ok {
			next := put_blit(
				b,
				nat,
				dst,
				x + u32(cells * a.cell_w),
				y,
				image,
				sx,
				0,
				u32(a.cell_w),
				u32(a.cell_h),
			)
			if next < 0 {
				return nat, put, cells
			}
			nat = next
		}
		put += size
		cells += 1
	}
	return nat, put, cells
}
