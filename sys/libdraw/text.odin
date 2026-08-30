/*
text -- the library `docs/DRAW.md` promised instead of a font verb.

A glyph on the screen is a blit out of an atlas. The atlas is a strip
image of cells, uploaded once, blitted per character for ever after. This
file owns the arithmetic from a byte of text to that blit. It knows
nothing about any particular font -- the caller uploaded the strips and
says how they are laid out.

`put_text` diverges from the other puts in one way, and on purpose. It
returns the characters it consumed as well as the new offset, because a
full buffer is a batch boundary rather than an error. A caller with more
text writes the batch and calls again with the rest. That keeps the wire
budget in one pump loop, not baked into every client as a magic count.
*/
package libdraw

/*
Atlas describes strip images already uploaded: `count` glyphs for the
characters from `first_char` on, `per_image` cells per strip, in image
ids from `first_image_id` up. Cell `idx` lives in image `first_image_id +
idx / per_image`, at `x = (idx % per_image) * cell_w`, `y = 0`.
*/
Atlas :: struct {
	first_image_id: u32,
	per_image:      int,
	cell_w:         int,
	cell_h:         int,
	first_char:     u8,
	count:          int,
}

// atlas_cell names the strip and column a glyph lives in. `put_text`
// blits by it, and an uploader walking pixels runs the same Atlas
// fields in reverse. The layout is described once, in the struct both
// read -- cells loaded and blitted from different places is a failure
// only a boot's pixel test would catch.
atlas_cell :: proc "contextless" (a: Atlas, idx: int) -> (image: u32, sx: u32) {
	return a.first_image_id + u32(idx / a.per_image), u32((idx % a.per_image) * a.cell_w)
}

/*
put_text packs one blit per character of `text` at (x, y) on `dst`, until
the buffer refuses the next one. Returns the new offset and how many
characters it consumed. A character the atlas does not carry consumes
with no blit -- the caller's background fill already reads as a space.
A consumed count short of the text is the caller's cue to write the
batch and continue. A negative `at` passes through as (-1, 0).
*/
put_text :: proc "contextless" (
	b: []u8,
	at: int,
	a: Atlas,
	dst: u32,
	x: u32,
	y: u32,
	text: string,
) -> (nat: int, put: int) #no_bounds_check {
	if at < 0 {
		return -1, 0
	}
	nat = at
	for put < len(text) {
		idx := int(text[put]) - int(a.first_char)
		if idx >= 0 && idx < a.count {
			image, sx := atlas_cell(a, idx)
			next := put_blit(
				b,
				nat,
				dst,
				x + u32(put * a.cell_w),
				y,
				image,
				sx,
				0,
				u32(a.cell_w),
				u32(a.cell_h),
			)
			if next < 0 {
				return nat, put
			}
			nat = next
		}
		put += 1
	}
	return nat, put
}
