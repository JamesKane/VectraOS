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

import "vsys:libdraw"
import "vsys:libfont"
import "vsys:libpal"

STRIPS :: 6
PER_STRIP :: 16
GLYPHS :: libfont.FONT_LAST - libfont.FONT_FIRST + 1
STRIP_W :: PER_STRIP * libfont.FONT_WIDTH

// How many distinct (ink, background) pairs one window may bake. Six ids each,
// out of the server's pool of sixty-four across all windows.
MAX_FACES :: 8

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

	// The six images, allocated in one batch.
	at := 0
	for s in 0 ..< STRIPS {
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
	for s in 0 ..< STRIPS {
		bx := 0
		for bx < STRIP_W {
			w := min(band, STRIP_W - bx)
			for y in 0 ..< libfont.FONT_HEIGHT {
				for i in 0 ..< w {
					px := bx + i
					g := s * PER_STRIP + px / libfont.FONT_WIDTH
					v := bw_color
					if g < GLYPHS {
						bits := libfont.font_8x16[g][y]
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
		first_char     = libfont.FONT_FIRST,
		count          = GLYPHS,
	}
	f.faces[f.n] = Face_Atlas {
		ink   = ink,
		bg    = bg,
		atlas = a,
	}
	f.n += 1
	f.next_id += STRIPS
	return a, true
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
