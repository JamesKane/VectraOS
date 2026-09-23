/*
face -- a proportional face, baked to coverage, `docs/CHROME.md` section 5.

The 8x16 table and its subfonts are one bit a pixel in a fixed cell, which is
what a terminal and the console want. The look's four faces are not: each glyph
has its own width and an 8-bit mask, so a letter's edge is smooth over any
ground. `tools/genface.py` bakes them on the host from OFL TrueType files, and
this reads the result, a `.face` file, over a buffer the caller holds. Nothing
here opens a file or allocates, which is the rule this package keeps.

The file's layout is `tools/genface.py`'s comment, and the two must agree by
hand. That script writes it and this reads it, and neither can import the
other.
*/
package libfont

import "core:unicode/utf8"

FACE_MAGIC :: u32(0x45434146) // 'F','A','C','E'
FACE_VERSION :: 1
FACE_MAX_RANGES :: 8
FACE_HDR :: 12
FACE_RANGE :: 12
FACE_RECORD :: 16

Face :: struct {
	data:    []u8,
	height:  int, // The line: ascent and descent
	ascent:  int, // The baseline, down from the line's top
	nranges: int,
	lo:      [FACE_MAX_RANGES]rune,
	hi:      [FACE_MAX_RANGES]rune,
	first:   [FACE_MAX_RANGES]int,
	records: int, // Where the glyph records start in `data`
	masks:   int, // Where the masks start
	count:   int, // Glyphs in all
	ready:   bool,
}

// One glyph: how far the pen moves after it, and its mask's place from the
// pen and the baseline. `top` is the mask's first row above the baseline.
Glyph :: struct {
	advance: int,
	left:    int,
	top:     int,
	w:       int,
	h:       int,
	mask:    []u8,
}

@(private = "file")
le16 :: proc "contextless" (b: []u8, at: int) -> int #no_bounds_check {
	return int(u16(b[at]) | u16(b[at + 1]) << 8)
}

@(private = "file")
les16 :: proc "contextless" (b: []u8, at: int) -> int #no_bounds_check {
	return int(i16(u16(b[at]) | u16(b[at + 1]) << 8))
}

@(private = "file")
le32 :: proc "contextless" (b: []u8, at: int) -> int #no_bounds_check {
	return int(u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24)
}

/*
face_open reads a `.face` file's header over `data`, which the caller keeps
for as long as it uses the face. False for a file that is not one, or whose
tables run past its end, so a glyph read later never reads out of bounds.
*/
face_open :: proc "contextless" (f: ^Face, data: []u8) -> bool #no_bounds_check {
	f^ = {}
	if len(data) < FACE_HDR || u32(le32(data, 0)) != FACE_MAGIC || le16(data, 4) != FACE_VERSION {
		return false
	}
	n := le16(data, 6)
	if n < 1 || n > FACE_MAX_RANGES {
		return false
	}
	f.height = le16(data, 8)
	f.ascent = le16(data, 10)
	at := FACE_HDR
	if at + n * FACE_RANGE > len(data) {
		return false
	}
	for i in 0 ..< n {
		f.lo[i] = rune(le32(data, at))
		f.hi[i] = rune(le32(data, at + 4))
		f.first[i] = le32(data, at + 8)
		if f.hi[i] < f.lo[i] {
			return false
		}
		f.count = max(f.count, f.first[i] + int(f.hi[i] - f.lo[i]) + 1)
		at += FACE_RANGE
	}
	f.nranges = n
	f.records = at
	f.masks = at + f.count * FACE_RECORD
	if f.masks > len(data) {
		return false
	}
	f.data = data
	f.ready = true
	return true
}

/*
face_glyph answers a rune's glyph, or false for a rune no range holds. A mask
that would run past the file is answered empty. A damaged file then draws a
space and reads no memory it does not own.
*/
face_glyph :: proc "contextless" (f: ^Face, r: rune) -> (g: Glyph, ok: bool) #no_bounds_check {
	if !f.ready {
		return {}, false
	}
	for i in 0 ..< f.nranges {
		if r < f.lo[i] || r > f.hi[i] {
			continue
		}
		at := f.records + (f.first[i] + int(r - f.lo[i])) * FACE_RECORD
		g.advance = les16(f.data, at)
		g.left = les16(f.data, at + 2)
		g.top = les16(f.data, at + 4)
		g.w = le16(f.data, at + 6)
		g.h = le16(f.data, at + 8)
		off := f.masks + le32(f.data, at + 12)
		if g.w > 0 && g.h > 0 && off + g.w * g.h <= len(f.data) {
			g.mask = f.data[off:off + g.w * g.h]
		} else {
			g.w, g.h = 0, 0
		}
		return g, true
	}
	return {}, false
}

// upper is a rune in capitals, for a face the theme sets in upper case. In
// ASCII and Latin-1 a small letter is its capital plus a step.
upper :: proc "contextless" (r: rune) -> rune {
	switch {
	case r >= 'a' && r <= 'z':
		return r - 32
	case r >= 0xE0 && r <= 0xFE && r != 0xF7:
		return r - 32
	}
	return r
}

/*
face_width is how far a string moves the pen. It adds each glyph's advance,
and `track` pixels after every glyph but the last. The runes are in capitals
when `caps` says so. A rune no range holds takes the advance of a space.
*/
face_width :: proc "contextless" (f: ^Face, s: string, track: int = 0, caps: bool = false) -> int #no_bounds_check {
	space, _ := face_glyph(f, ' ')
	w := 0
	n := 0
	for r in s {
		c := caps ? upper(r) : r
		g, ok := face_glyph(f, c)
		w += ok ? g.advance : space.advance
		n += 1
	}
	if n > 1 {
		w += (n - 1) * track
	}
	return w
}

// decode is one rune off the front of a string, for a caller that walks one
// by hand, as `face_width`'s loop does.
decode :: proc "contextless" (s: string) -> (rune, int) {
	return utf8.decode_rune_in_string(s)
}
