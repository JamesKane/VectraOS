/*
bake -- one atlas of the font, in one colour pair, uploaded once.

`text.odin` blits from an atlas and knows nothing about a font. This is the
other half: given `sys/libfont` -- the baked ASCII table and a `Loader` for
the ranges past it -- it plans an `Atlas`'s ranges and uploads the strips that
back it, in an ink over a background, through a writer the caller gives. The
draw server's blit is opaque, so the background is baked into every cell and a
face is one atlas per colour pair.

Every client that draws text used to carry this: `cmd/window`, `apps/terminal`
and `sys/libmui` each had the same loop over the same font bits. It lives here
now, the one place that owns both the `Atlas` and the `put_*` commands, so a
font that grows a range grows it for all of them at once. `libdraw` links
`sys/libfont`, which is pure data and has no import of its own, so the kernel
that links `libdraw` for its chassis pulls nothing new.
*/
package libdraw

import "vsys:libfont"

// The strip a face packs its cells into: sixteen to a strip, a strip the
// width of sixteen cells. Sixteen strips is room for the whole of a font --
// ASCII and the ranges `default.font` names come to fourteen. One strip is
// `BAKE_PER_STRIP * FONT_WIDTH * FONT_HEIGHT` = 2048 pixels, one server image.
BAKE_PER_STRIP :: 16
BAKE_STRIP_W :: BAKE_PER_STRIP * libfont.FONT_WIDTH
BAKE_MAX_STRIPS :: 16
BAKE_MAX_CELLS :: BAKE_MAX_STRIPS * BAKE_PER_STRIP

// One baked strip set's cells, filled once per atlas before the pixels go
// out. Scratch, not state: a bake finishes before another begins.
@(private = "file")
bake_cells: [BAKE_MAX_CELLS][libfont.FONT_HEIGHT]u8

// A Bake_Sink is where the upload's wire slots go -- a window's `data` stream,
// or a test's buffer. It is `sys/libmui`'s `Sink.write` unchanged, so a caller
// with one hands its fields straight in.
Bake_Sink :: proc "contextless" (user: rawptr, data: []u8) -> bool

/*
atlas_plan fills `a`'s ranges from ASCII and, when `loader` is ready, the
ranges it names -- each packed after the last -- and answers the total cells.
It sets `a`'s cell size, `per_image` and `first_image_id`; the caller need
only have given `first_id`. A range that would run past `BAKE_MAX_CELLS` is
dropped whole. A nil or unopened loader plans ASCII alone, which the baked
table draws with no file.
*/
atlas_plan :: proc "contextless" (a: ^Atlas, first_id: u32, loader: ^libfont.Loader) -> (total: int) #no_bounds_check {
	a.first_image_id = first_id
	a.per_image = BAKE_PER_STRIP
	a.cell_w = libfont.FONT_WIDTH
	a.cell_h = libfont.FONT_HEIGHT
	a.ranges[0] = {lo = libfont.FONT_FIRST, hi = libfont.FONT_LAST, offset = 0}
	a.n = 1
	total = int(libfont.FONT_LAST - libfont.FONT_FIRST) + 1
	if loader != nil && loader.ready {
		for i in 0 ..< loader.idx.n {
			if a.n >= MAX_ATLAS_RANGES {
				break
			}
			rg := loader.idx.ranges[i]
			cnt := int(rg.hi - rg.lo) + 1
			if total + cnt > BAKE_MAX_CELLS {
				break
			}
			a.ranges[a.n] = {lo = rg.lo, hi = rg.hi, offset = total}
			total += cnt
			a.n += 1
		}
	}
	return
}

// bake_cell_rune answers the rune baked into cell `g`, or zero for a cell no
// range covers -- the reverse of `atlas_locate`, for the uploader.
@(private = "file")
bake_cell_rune :: proc "contextless" (a: ^Atlas, g: int) -> rune #no_bounds_check {
	for i in 0 ..< a.n {
		rg := a.ranges[i]
		cnt := int(rg.hi - rg.lo) + 1
		if g >= rg.offset && g < rg.offset + cnt {
			return rg.lo + rune(g - rg.offset)
		}
	}
	return 0
}

/*
bake_atlas plans `a`'s ranges, then uploads the strips that back it in `fg`
over `bg` (both packed pixel words) through `write`. `scratch` is one wire
slot the commands build in; `band_pixels` holds one band's pixels, at least
`band * FONT_HEIGHT * 4` bytes where a band is a strip's width or less.
Answers the strips it allocated and false on a write failure -- which a caller
treats as a label or a font it cannot draw yet, the server's pool being full.
*/
bake_atlas :: proc "contextless" (
	a: ^Atlas,
	first_id: u32,
	loader: ^libfont.Loader,
	fg: u32,
	bg: u32,
	scratch: []u8,
	band_pixels: []u8,
	write: Bake_Sink,
	user: rawptr,
) -> (strips: int, ok: bool) #no_bounds_check {
	total := atlas_plan(a, first_id, loader)
	strips = (total + BAKE_PER_STRIP - 1) / BAKE_PER_STRIP

	// Each cell's 1bpp bits, once: the baked table for ASCII, a subfont for
	// the rest. A rune a range names but no subfont holds bakes blank.
	for g in 0 ..< total {
		libfont.loader_glyph(loader, bake_cell_rune(a, g), bake_cells[g][:])
	}

	// The strip images, allocated in one batch.
	at := 0
	for s in 0 ..< strips {
		at = put_alloc(scratch, at, first_id + u32(s), BAKE_STRIP_W, u32(libfont.FONT_HEIGHT))
	}
	if at < 0 || !write(user, scratch[:at]) {
		return strips, false
	}

	// The pixels, in bands that fit one slot: ink where a glyph bit is set,
	// the background everywhere else.
	band := (len(scratch) - HEADER - 20) / (libfont.FONT_HEIGHT * 4)
	if band <= 0 {
		return strips, false
	}
	for s in 0 ..< strips {
		bx := 0
		for bx < BAKE_STRIP_W {
			w := min(band, BAKE_STRIP_W - bx)
			for y in 0 ..< libfont.FONT_HEIGHT {
				for i in 0 ..< w {
					px := bx + i
					g := s * BAKE_PER_STRIP + px / libfont.FONT_WIDTH
					v := bg
					if g < total {
						bits := bake_cells[g][y]
						if bits & (0x80 >> u8(px % libfont.FONT_WIDTH)) != 0 {
							v = fg
						}
					}
					put_u32(band_pixels, (y * w + i) * 4, v)
				}
			}
			end := put_load(
				scratch,
				0,
				first_id + u32(s),
				u32(bx),
				0,
				u32(w),
				u32(libfont.FONT_HEIGHT),
				band_pixels[:w * libfont.FONT_HEIGHT * 4],
			)
			if end < 0 || !write(user, scratch[:end]) {
				return strips, false
			}
			bx += w
		}
	}
	return strips, true
}
