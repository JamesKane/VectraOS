/*
The font past ASCII, as data read at run time.

The baked table in `font_data.odin` is ASCII, 0x20-0x7E, and the kernel draws
its early-boot log from it before any filesystem is up. Everything past ASCII
is a file: Plan 9's shape, a `.font` naming rune ranges and the subfont file
each is in, and a subfont holding the same 1bpp cells the baked table uses.

Nothing here does I/O, so the kernel and a ring 3 program both compile it. A
`Loader` holds the parsed index and a small cache of subfonts, and reads
through a callback the caller gives -- `libuser` on one side, `kernel:vfs` on
the other. `loader_glyph` answers a rune's cell from the baked table when it
is ASCII, and from a subfont it loads on demand and keeps by recency
otherwise. `docs/DRAW.md` has the format; `tools/gensubfont.py` writes it.
*/
package libfont

// The `.font` index: a height and ascent, then a rune range per line naming
// the subfont file it is in. Ranges do not overlap and are small in number.
MAX_RANGES :: 16

Range :: struct {
	lo, hi: rune,
	file:   [24]u8,
	flen:   int,
}

Font_Index :: struct {
	height: int,
	ascent: int,
	n:      int,
	ranges: [MAX_RANGES]Range,
}

// The subfont file: a header, then the range's cells, height bytes each,
// one byte a scanline with the leftmost pixel in the high bit -- the baked
// table's layout, for the runes past it.
SUBF_MAGIC :: u32(0x46425553) // 'S','U','B','F'
SUBF_HDR :: 16
SUBF_MAX :: 8192 // A subfont file at most: (8192-16)/16 = 510 cells

// The loader's cache: how many subfonts it keeps at once. Four holds a
// handful of ranges without eviction; the struct is `LOADER_WAYS * SUBF_MAX`
// bytes, so a `Loader` is not a thing to put on a stack -- a consumer keeps
// one as a global or on the heap.
LOADER_WAYS :: 4

Subfont_Slot :: struct {
	used:   bool,
	lo, hi: rune,
	height: int,
	width:  int,
	age:    u32,
	len:    int,
	bytes:  [SUBF_MAX]u8,
}

/*
A loader over one `.font`. `read` is given the full path of a subfont file
and a buffer, and answers how many bytes it read, or zero; `data` is its to
use. `dir` is where the subfonts sit, the directory the `.font` was in.
*/
Loader :: struct {
	idx:   Font_Index,
	ready: bool,
	dir:   [64]u8,
	dlen:  int,
	read:  proc "contextless" (data: rawptr, path: string, into: []u8) -> int,
	data:  rawptr,
	cache: [LOADER_WAYS]Subfont_Slot,
	clock: u32,
}

// -- Parsing the index -------------------------------------------------------

@(private = "file")
is_space :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\r'
}

// hex reads a hex number from `s` at `at`, answering the value and where it
// stopped. A number with no digits answers `at` unmoved.
@(private = "file")
hex :: proc "contextless" (s: string, at: int) -> (v: rune, next: int) #no_bounds_check {
	i := at
	for i < len(s) {
		c := s[i]
		d: rune
		switch {
		case c >= '0' && c <= '9':
			d = rune(c - '0')
		case c >= 'a' && c <= 'f':
			d = rune(c - 'a' + 10)
		case c >= 'A' && c <= 'F':
			d = rune(c - 'A' + 10)
		case:
			return v, i
		}
		v = v * 16 + d
		i += 1
	}
	return v, i
}

/*
parse_index fills `idx` from a `.font` file's text: the first line that is
not blank or a `#` comment is `height ascent`, and every line after it is
`lo hi file`, all hex but the file. False when the first line is missing or
a range names no file, so a broken index is a font with no ranges rather
than a crash.
*/
parse_index :: proc "contextless" (text: string, idx: ^Font_Index) -> bool #no_bounds_check {
	idx^ = {}
	pos := 0
	head := false
	for pos < len(text) {
		// One line.
		end := pos
		for end < len(text) && text[end] != '\n' {end += 1}
		line := text[pos:end]
		pos = end + 1

		// Skip leading space, then blanks and comments.
		at := 0
		for at < len(line) && is_space(line[at]) {at += 1}
		if at >= len(line) || line[at] == '#' {
			continue
		}

		if !head {
			h, a2 := hex(line, at)
			for a2 < len(line) && is_space(line[a2]) {a2 += 1}
			asc, _ := hex(line, a2)
			idx.height = int(h)
			idx.ascent = int(asc)
			head = true
			continue
		}

		if idx.n >= MAX_RANGES {
			break
		}
		lo, a1 := hex(line, at)
		for a1 < len(line) && is_space(line[a1]) {a1 += 1}
		hi, a2 := hex(line, a1)
		for a2 < len(line) && is_space(line[a2]) {a2 += 1}
		// The rest of the line, trimmed, is the file.
		fend := len(line)
		for fend > a2 && is_space(line[fend - 1]) {fend -= 1}
		name := line[a2:fend]
		if len(name) == 0 || len(name) > len(idx.ranges[0].file) {
			return false
		}
		r := &idx.ranges[idx.n]
		r.lo = lo
		r.hi = hi
		r.flen = copy(r.file[:], name)
		idx.n += 1
	}
	return head
}

// -- Reading a rune's cell ---------------------------------------------------

/*
glyph_baked copies the ASCII cell for `r` into `into` -- `height` bytes, the
first `FONT_HEIGHT` of the buffer -- and answers its width, or ok false for a
rune the baked table does not hold. A blank cell for a printable hole so a
caller need not special-case one.
*/
glyph_baked :: proc "contextless" (r: rune, into: []u8) -> (width: int, ok: bool) #no_bounds_check {
	if r < FONT_FIRST || r > FONT_LAST || len(into) < FONT_HEIGHT {
		return 0, false
	}
	rows := &font_8x16[int(r) - FONT_FIRST]
	for y in 0 ..< FONT_HEIGHT {
		into[y] = rows[y]
	}
	return FONT_WIDTH, true
}

// subfont_glyph copies rune `r`'s cell out of a subfont's bytes into `into`,
// answering its width. False when the bytes are not a subfont, `r` is out of
// its range, or the buffer is short.
subfont_glyph :: proc "contextless" (b: []u8, r: rune, into: []u8) -> (width: int, ok: bool) #no_bounds_check {
	if len(b) < SUBF_HDR {
		return 0, false
	}
	magic := u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
	lo := rune(u32(b[4]) | u32(b[5]) << 8 | u32(b[6]) << 16 | u32(b[7]) << 24)
	hi := rune(u32(b[8]) | u32(b[9]) << 8 | u32(b[10]) << 16 | u32(b[11]) << 24)
	w := int(b[12])
	h := int(b[13])
	if magic != SUBF_MAGIC || r < lo || r > hi || h <= 0 || len(into) < h {
		return 0, false
	}
	off := SUBF_HDR + (int(r) - int(lo)) * h
	if off + h > len(b) {
		return 0, false
	}
	for y in 0 ..< h {
		into[y] = b[off + y]
	}
	return w, true
}

// -- The loader --------------------------------------------------------------

/*
loader_open parses the `.font` at `path` through `read` and remembers where
its subfonts sit, so `loader_glyph` can load them. `read` and `data` are the
caller's I/O. False when the index will not read or parse.
*/
loader_open :: proc "contextless" (
	l: ^Loader,
	path: string,
	read: proc "contextless" (data: rawptr, path: string, into: []u8) -> int,
	data: rawptr,
) -> bool #no_bounds_check {
	l^ = {}
	l.read = read
	l.data = data
	// The directory the .font is in: everything up to its last slash.
	cut := len(path)
	for cut > 0 && path[cut - 1] != '/' {cut -= 1}
	l.dlen = copy(l.dir[:], path[:cut]) // includes the trailing slash, or empty

	buf: [SUBF_MAX]u8
	n := read(data, path, buf[:])
	if n <= 0 {
		return false
	}
	if !parse_index(string(buf[:n]), &l.idx) {
		return false
	}
	l.ready = true
	return true
}

@(private = "file")
range_of :: proc "contextless" (l: ^Loader, r: rune) -> int #no_bounds_check {
	for i in 0 ..< l.idx.n {
		if r >= l.idx.ranges[i].lo && r <= l.idx.ranges[i].hi {
			return i
		}
	}
	return -1
}

// slot_for answers the cache slot holding the subfont for range `ri`, loading
// it if absent -- reusing the least recently used slot -- or -1 on a read or
// format failure.
@(private = "file")
slot_for :: proc "contextless" (l: ^Loader, ri: int) -> int #no_bounds_check {
	rg := &l.idx.ranges[ri]
	l.clock += 1
	// Already cached?
	for i in 0 ..< LOADER_WAYS {
		s := &l.cache[i]
		if s.used && s.lo == rg.lo && s.hi == rg.hi {
			s.age = l.clock
			return i
		}
	}
	// The victim: an empty slot, else the least recently used.
	victim := 0
	for i in 0 ..< LOADER_WAYS {
		s := &l.cache[i]
		if !s.used {
			victim = i
			break
		}
		if s.age < l.cache[victim].age {
			victim = i
		}
	}
	// The subfont's path: the .font's directory and the range's file.
	path: [96]u8
	p := copy(path[:], l.dir[:l.dlen])
	p += copy(path[p:], rg.file[:rg.flen])

	s := &l.cache[victim]
	n := l.read(l.data, string(path[:p]), s.bytes[:])
	if n < SUBF_HDR || !subfont_valid(s.bytes[:n]) {
		s.used = false
		return -1
	}
	s.used = true
	s.lo = rg.lo
	s.hi = rg.hi
	s.len = n
	s.age = l.clock
	return victim
}

@(private = "file")
subfont_valid :: proc "contextless" (b: []u8) -> bool #no_bounds_check {
	if len(b) < SUBF_HDR {
		return false
	}
	magic := u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
	return magic == SUBF_MAGIC
}

/*
loader_glyph answers rune `r`'s cell in `into` and its width: from the baked
table when `r` is ASCII, and from the subfont its range names otherwise,
loaded on demand. False for a rune no range holds, which a caller draws as a
blank or a box of its own choosing.
*/
loader_glyph :: proc "contextless" (l: ^Loader, r: rune, into: []u8) -> (width: int, ok: bool) #no_bounds_check {
	if r >= FONT_FIRST && r <= FONT_LAST {
		return glyph_baked(r, into)
	}
	if !l.ready {
		return 0, false
	}
	ri := range_of(l, r)
	if ri < 0 {
		return 0, false
	}
	si := slot_for(l, ri)
	if si < 0 {
		return 0, false
	}
	s := &l.cache[si]
	return subfont_glyph(s.bytes[:s.len], r, into)
}
