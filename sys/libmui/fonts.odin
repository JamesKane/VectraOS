/*
fonts -- one small glyph atlas per colour a label is drawn in.

The draw server's blit is opaque, so a glyph carries the background baked into
it, as `cmd/window` never noticed while it drew on one colour. A toolkit draws
a label on a button's face and another on the window's ground, so it needs a
glyph atlas per pair of colours. This bakes one on demand. The first
time a label wants ink on a background, six strips of the font upload in that
ink over that background. Every later label of the same two colours blits from
them. It is the "Amiga look", coloured controls with their labels on
them, bought against the six-verb draw protocol `docs/DRAW.md` holds to.

An atlas is six images of sixteen cells, the layout `sys/libdraw`'s `Atlas`
describes and `cmd/window` uploads. The pixels go out in bands that fit one
wire slot, the same split `cmd/window` makes. The image ids count up from the
first this `Fonts` was given, six to an atlas, out of the server's shared pool.
*/
package libmui

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libfont"
import "vsys:libpal"
import "vsys:libuser"

PER_STRIP :: 16
GLYPHS :: libfont.FONT_LAST - libfont.FONT_FIRST + 1
STRIP_W :: PER_STRIP * libfont.FONT_WIDTH

// The strips ASCII alone needs -- what a face bakes when the past-ASCII font
// is not loaded, which is every face until `window_open` opens it.
STRIPS :: (GLYPHS + PER_STRIP - 1) / PER_STRIP

// The strip set of one face holds ASCII and the ranges `sys/libfont` names
// past it, packed one after another. Sixteen strips is room for the whole of
// `default.font` -- ASCII, Latin-1, punctuation and arrows come to fourteen.
// The server's pool is sixty-four across all windows, so a face is not free:
// `font_for` degrades to the label it cannot draw when the pool fills.
STRIPS_MAX :: 16
MAX_CELLS :: STRIPS_MAX * PER_STRIP

// How many distinct (ink, background) pairs one window may bake. A full-font
// face is up to fourteen ids, so a window with several colours can exhaust
// the pool; the demo uses two.
MAX_FACES :: 8

// text_font is the font past ASCII, shared across every `Fonts` a program
// makes. `window_open` fills it once from `/lib/font`; until then, and if the
// load fails, `loader_glyph` still answers ASCII from the baked table, so a
// face bakes ASCII alone rather than nothing. A `tests/mui` that never opens
// a window leaves it closed and bakes ASCII, which is what it always did.
text_font: libfont.Loader

// glyph_cells holds one baked strip set's cells, `FONT_HEIGHT` 1bpp rows each,
// filled once per face before the pixels go out. It is a scratch buffer, not
// state a caller keeps.
glyph_cells: [MAX_CELLS][libfont.FONT_HEIGHT]u8

// text_read is the font loader's I/O: the whole of `path` into `into`, or
// zero. `window_open` gives the loader this reader.
text_read :: proc "contextless" (data: rawptr, path: string, into: []u8) -> int {
	_ = data
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return 0
	}
	at := 0
	for at < len(into) {
		n := libuser.read(int(fd), into[at:])
		if n <= 0 {
			break
		}
		at += int(n)
	}
	_ = libuser.close(int(fd))
	return at
}

// font_load opens the shared past-ASCII font once. A failure is not fatal: a
// face still bakes ASCII from the baked table. `window_open` calls it before
// it bakes; a caller that bakes without a window (a test) skips it.
font_load :: proc "contextless" () {
	if !text_font.ready {
		_ = libfont.loader_open(&text_font, "/lib/font/default.font", text_read, nil)
	}
}

/*
A Sink is where a baked atlas batch goes. A live window points it at its `data`
stream. A test points it at a buffer it reads back. The atlas baker writes one
wire slot at a time through it, so neither caller needs to know the other.
*/
Sink :: struct {
	write: proc "contextless" (user: rawptr, data: []u8) -> bool,
	user:  rawptr,
}

Face_Atlas :: struct {
	ink:   libpal.RGB,
	bg:    libpal.RGB,
	atlas: libdraw.Atlas,
}

/*
Fonts holds the atlases a window baked, and the next free image id. A
program makes one per window and hands it to `font_prepare` before it paints,
and to `paint` while it does.
*/
Fonts :: struct {
	faces:   [MAX_FACES]Face_Atlas,
	n:       int,
	next_id: u32,
}

// The pixels of one band, built here and copied into a load command. Sized for
// a whole strip, so any band a wire slot allows fits.
band_pixels: [STRIP_W * libfont.FONT_HEIGHT * 4]u8

// font_init resets a Fonts and sets the first image id it hands out. A window
// that shares the pool with the frame's own images starts past them.
font_init :: proc "contextless" (f: ^Fonts, first_id: u32 = 1) {
	f^ = {}
	f.next_id = first_id
}

// font_get returns the atlas already baked for (ink, bg), or false. `paint`
// uses it, because a paint never uploads.
font_get :: proc "contextless" (f: ^Fonts, ink: libpal.RGB, bg: libpal.RGB) -> (libdraw.Atlas, bool) {
	for i in 0 ..< f.n {
		if f.faces[i].ink == ink && f.faces[i].bg == bg {
			return f.faces[i].atlas, true
		}
	}
	return {}, false
}

/*
font_for returns the atlas for (ink, bg), baking and uploading it through
`sink` if this is the first time the pair is asked for. `scratch` is one wire
slot the batches are built in. It returns false when the pool is full or a
write failed, which a caller treats as a label it cannot draw yet.
*/
font_for :: proc "contextless" (
	f: ^Fonts,
	ink: libpal.RGB,
	bg: libpal.RGB,
	scratch: []u8,
	sink: Sink,
) -> (libdraw.Atlas, bool) #no_bounds_check {
	if a, ok := font_get(f, ink, bg); ok {
		return a, true
	}
	if f.n >= MAX_FACES {
		return {}, false
	}
	base := f.next_id

	// The ranges this face carries -- ASCII, and the font's own past it -- and
	// the cells they pack into. Then the strips those cells need.
	ranges: [libdraw.MAX_ATLAS_RANGES]libdraw.Atlas_Range
	nr, total := plan_ranges(ranges[:])
	strips := (total + PER_STRIP - 1) / PER_STRIP

	// Each cell's 1bpp bits, once, from the baked table for ASCII and a loaded
	// subfont for the rest. A rune a range names but no subfont holds bakes
	// blank, which reads as a space.
	for g in 0 ..< total {
		libfont.loader_glyph(&text_font, cell_rune(ranges[:nr], g), glyph_cells[g][:])
	}

	// The strip images, allocated in one batch.
	at := 0
	for s in 0 ..< strips {
		at = libdraw.put_alloc(scratch, at, base + u32(s), STRIP_W, u32(libfont.FONT_HEIGHT))
	}
	if at < 0 || !sink.write(sink.user, scratch[:at]) {
		return {}, false
	}

	// The pixels, in bands that fit one slot: ink where a glyph bit is set,
	// the background everywhere else.
	band := (len(scratch) - libdraw.HEADER - 20) / (libfont.FONT_HEIGHT * 4)
	if band <= 0 {
		return {}, false
	}
	fg := libpal.xrgb(ink)
	bw_color := libpal.xrgb(bg)
	for s in 0 ..< strips {
		bx := 0
		for bx < STRIP_W {
			w := min(band, STRIP_W - bx)
			for y in 0 ..< libfont.FONT_HEIGHT {
				for i in 0 ..< w {
					px := bx + i
					g := s * PER_STRIP + px / libfont.FONT_WIDTH
					v := bw_color
					if g < total {
						bits := glyph_cells[g][y]
						if bits & (0x80 >> u8(px % libfont.FONT_WIDTH)) != 0 {
							v = fg
						}
					}
					libdraw.put_u32(band_pixels[:], (y * w + i) * 4, v)
				}
			}
			end := libdraw.put_load(
				scratch,
				0,
				base + u32(s),
				u32(bx),
				0,
				u32(w),
				u32(libfont.FONT_HEIGHT),
				band_pixels[:w * libfont.FONT_HEIGHT * 4],
			)
			if end < 0 || !sink.write(sink.user, scratch[:end]) {
				return {}, false
			}
			bx += w
		}
	}

	a := libdraw.Atlas {
		first_image_id = base,
		per_image      = PER_STRIP,
		cell_w         = libfont.FONT_WIDTH,
		cell_h         = libfont.FONT_HEIGHT,
		n              = nr,
		ranges         = ranges,
	}
	f.faces[f.n] = Face_Atlas {
		ink   = ink,
		bg    = bg,
		atlas = a,
	}
	f.n += 1
	f.next_id += u32(strips)
	return a, true
}

// plan_ranges fills `out` with the ranges a face carries: ASCII first, then
// the ones `text_font` names, each packed after the last. Answers how many
// ranges and how many cells in all. A range that would run past `MAX_CELLS`
// is dropped whole rather than split across the buffer's end.
plan_ranges :: proc "contextless" (out: []libdraw.Atlas_Range) -> (n: int, total: int) #no_bounds_check {
	out[0] = {lo = libfont.FONT_FIRST, hi = libfont.FONT_LAST, offset = 0}
	n = 1
	total = int(libfont.FONT_LAST - libfont.FONT_FIRST) + 1
	if text_font.ready {
		for i in 0 ..< text_font.idx.n {
			if n >= len(out) {
				break
			}
			rg := text_font.idx.ranges[i]
			cnt := int(rg.hi - rg.lo) + 1
			if total + cnt > MAX_CELLS {
				break
			}
			out[n] = {lo = rg.lo, hi = rg.hi, offset = total}
			total += cnt
			n += 1
		}
	}
	return
}

// cell_rune answers the rune baked into cell `g`, or zero for a cell no range
// covers -- which the bake loop draws blank.
cell_rune :: proc "contextless" (ranges: []libdraw.Atlas_Range, g: int) -> rune #no_bounds_check {
	for rg in ranges {
		cnt := int(rg.hi - rg.lo) + 1
		if g >= rg.offset && g < rg.offset + cnt {
			return rg.lo + rune(g - rg.offset)
		}
	}
	return 0
}

/*
font_prepare bakes every atlas the tree's labels need, so a later `paint` finds
them all in the cache. A Text wants ink on the ground, a Button ink on the
face. It walks the tree once and asks `font_for` for each, which uploads only
the pairs it has not seen. A false return says the pool filled before the tree
was covered.
*/
font_prepare :: proc "contextless" (
	root: ^Object,
	f: ^Fonts,
	scratch: []u8,
	sink: Sink,
	t: ^Theme,
) -> bool {
	if root == nil {
		return true
	}
	#partial switch root.class {
	case .Text:
		if _, ok := font_for(f, t.ink, t.ground, scratch, sink); !ok {
			return false
		}
	case .Button:
		if _, ok := font_for(f, t.ink, t.face, scratch, sink); !ok {
			return false
		}
	}
	for c := root.first; c != nil; c = c.next {
		if !font_prepare(c, f, scratch, sink, t) {
			return false
		}
	}
	return true
}
