/*
libdraw -- the six verbs, encoded once.

`docs/DRAW.md` fixes the command stream a draw client writes: binary,
little-endian, length-prefixed per command. This package is the encoding's
one owner. The server decodes with the `get` half, a client encodes with
the `put` half, and the kernel's self-test links the same package. A
disagreement about a byte is then a build error somewhere, never a
protocol drift between two hand-rolled copies.

A command is a four-byte header and a body:

    size[2]  the whole command, header included
    verb[1]  one of the six below
    zero[1]  reserved, and refused when set

Bodies are u32 fields in order, and `load` carries its pixels after them,
row by row, four bytes per pixel in the format `/dev/fbctl` reports.

The `put` half returns the new offset, or -1 when the command does not
fit. A client that batches keeps the running offset and writes the buffer
once -- one 9P write carries dozens of commands, which is the point.
*/
package libdraw

// The six verbs, `docs/DRAW.md` section 5's table in order.
ALLOC :: u8(1) // id, width, height
LOAD :: u8(2) // id, x, y, w, h, then w*h*4 bytes of pixels
FILL :: u8(3) // id, x, y, w, h, color
BLIT :: u8(4) // dst id, dx, dy, src id, sx, sy, sw, sh
FREE :: u8(5) // id
FLUSH :: u8(6) // nothing

HEADER :: 4

// -- The get half, for the decoder --------------------------------------------

get_u16 :: proc "contextless" (b: []u8, at: int) -> u16 #no_bounds_check {
	return u16(b[at]) | u16(b[at + 1]) << 8
}

get_u32 :: proc "contextless" (b: []u8, at: int) -> u32 #no_bounds_check {
	return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
}

// -- The put half, for an encoder ---------------------------------------------

@(private)
put_u16 :: proc "contextless" (b: []u8, at: int, v: u16) #no_bounds_check {
	b[at] = u8(v)
	b[at + 1] = u8(v >> 8)
}

// put_u32 stores one little-endian word, the protocol's byte order. It is
// public because a pixel is the same word. Whoever expands a bitmap into
// `load` payload bytes writes this exact layout, best written in one place.
put_u32 :: proc "contextless" (b: []u8, at: int, v: u32) #no_bounds_check {
	b[at] = u8(v)
	b[at + 1] = u8(v >> 8)
	b[at + 2] = u8(v >> 16)
	b[at + 3] = u8(v >> 24)
}

// put_header writes the four command bytes and reports where the body goes.
// A negative `at` passes through as the refusal it already is, so a caller
// may chain puts and check the offset once at the end.
@(private)
put_header :: proc "contextless" (b: []u8, at: int, size: int, verb: u8) -> int #no_bounds_check {
	if at < 0 || size > int(max(u16)) || at + size > len(b) {
		return -1
	}
	put_u16(b, at, u16(size))
	b[at + 2] = verb
	b[at + 3] = 0
	return at + HEADER
}

// put_cmd is the one body every fixed-field verb shares: a header, the
// fields in order, and the offset after them. The size and offset
// arithmetic lives here alone, so a new verb cannot miscount it.
@(private)
put_cmd :: proc "contextless" (b: []u8, at: int, verb: u8, fields: ..u32) -> int #no_bounds_check {
	body := put_header(b, at, HEADER + len(fields) * 4, verb)
	if body < 0 {
		return -1
	}
	for f, i in fields {
		put_u32(b, body + i * 4, f)
	}
	return body + len(fields) * 4
}

put_alloc :: proc "contextless" (b: []u8, at: int, id: u32, w: u32, h: u32) -> int {
	return put_cmd(b, at, ALLOC, id, w, h)
}

put_load :: proc "contextless" (
	b: []u8,
	at: int,
	id: u32,
	x: u32,
	y: u32,
	w: u32,
	h: u32,
	pixels: []u8,
) -> int #no_bounds_check {
	body := put_header(b, at, HEADER + 20 + len(pixels), LOAD)
	if body < 0 {
		return -1
	}
	put_u32(b, body, id)
	put_u32(b, body + 4, x)
	put_u32(b, body + 8, y)
	put_u32(b, body + 12, w)
	put_u32(b, body + 16, h)
	copy(b[body + 20:], pixels)
	return body + 20 + len(pixels)
}

put_fill :: proc "contextless" (
	b: []u8,
	at: int,
	id: u32,
	x: u32,
	y: u32,
	w: u32,
	h: u32,
	color: u32,
) -> int {
	return put_cmd(b, at, FILL, id, x, y, w, h, color)
}

put_blit :: proc "contextless" (
	b: []u8,
	at: int,
	dst: u32,
	dx: u32,
	dy: u32,
	src: u32,
	sx: u32,
	sy: u32,
	sw: u32,
	sh: u32,
) -> int {
	return put_cmd(b, at, BLIT, dst, dx, dy, src, sx, sy, sw, sh)
}

put_free :: proc "contextless" (b: []u8, at: int, id: u32) -> int {
	return put_cmd(b, at, FREE, id)
}

put_flush :: proc "contextless" (b: []u8, at: int) -> int {
	return put_cmd(b, at, FLUSH)
}

// -- The ctl report -----------------------------------------------------------

/*
parse_geometry reads the numbers a draw server's `ctl` file answers with,
which are `/dev/fbctl`'s: width, height, pitch, and depth, in that order.

One decoder for the report both sides of the protocol handle. The server
reads it from the device and serves it on, and a client reads it back.
Two hand-rolled scanners of one format fail differently when a field
moves.
*/
parse_geometry :: proc "contextless" (report: []u8) -> (w: int, h: int, pitch: int, depth: int, ok: bool) #no_bounds_check {
	nums: [4]int
	found := 0
	at := 0
	for at < len(report) && found < 4 {
		if report[at] < '0' || report[at] > '9' {
			at += 1
			continue
		}
		v, got := scan_int(report, &at)
		if !got {
			break
		}
		nums[found] = v
		found += 1
	}
	if found < 4 {
		return 0, 0, 0, 0, false
	}
	return nums[0], nums[1], nums[2], nums[3], true
}

// -- The tree, and the one scanner that reads it -----------------------------

/*
scan_int takes the next decimal from a report, and says whether there was one.

**One scanner for one convention.** `parse_geometry` above had the digit loop
inline. `servers/intuition` grew a second for its `ctl` lines, and
`apps/terminal` a third for `new`'s answer. Three scanners of one text format
is the failure `parse_geometry`'s own comment names, and this is that loop
once.

Leading space is skipped and a leading `-` is taken. A window may sit off the
left edge, and a client says so with a minus. The cap keeps a long run of
digits from wrapping into a number nobody meant. A caller that cares about
range checks its own.
*/
// scan_int_str is `scan_int` over a whole word: the number it holds, and
// whether it held one and nothing else.
scan_int_str :: proc "contextless" (word: []u8) -> (int, bool) {
	at := 0
	v, ok := scan_int(word, &at)
	return v, ok && at == len(word)
}

scan_int :: proc "contextless" (data: []u8, at: ^int) -> (int, bool) #no_bounds_check {
	i := at^
	for i < len(data) && (data[i] == ' ' || data[i] == '\t') {
		i += 1
	}
	neg := false
	if i < len(data) && data[i] == '-' {
		neg = true
		i += 1
	}
	start := i
	value := 0
	for i < len(data) && data[i] >= '0' && data[i] <= '9' {
		value = value * 10 + int(data[i] - '0')
		if value > 1 << 24 {
			return 0, false
		}
		i += 1
	}
	at^ = i
	if i == start {
		return 0, false
	}
	return neg ? -value : value, true
}

/*
The draw server's tree, named once for both sides of it.

    /new       read it, and it answers which window has no session
    /N/data    the command stream, and the claim on window N
    /N/ctl     window N's geometry out, and its control lines in

The server walks these names and a client builds them, so the layout was in two
places the moment the tree grew. A digit table in `servers/intuition`, and a
path builder in `apps/terminal` that a second app would copy. `libdraw` already
owns both directions of this wire, which makes it where the shape belongs.
*/
// Every window's directory name, written out, because a program with no
// allocator cannot format one and a name is a slice of something that
// stays. `MAX_WINDOW_NAMES` is the bound the server's `MAX_WINDOWS`
// stays inside, by an assert at the one place that raises it.
@(private = "file")
WIN_NAMES := [?]string {
	"0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
	"10", "11", "12", "13", "14", "15", "16", "17", "18", "19",
	"20", "21", "22", "23", "24", "25", "26", "27", "28", "29",
	"30", "31",
}

MAX_WINDOW_NAMES :: len(WIN_NAMES)

// win_name is window `n`'s directory name, or empty for one there is no
// name for.
win_name :: proc "contextless" (n: int) -> string #no_bounds_check {
	if n < 0 || n >= len(WIN_NAMES) {
		return ""
	}
	return WIN_NAMES[n]
}

// win_index is the other direction: which window a directory name names,
// or -1 for a name that is not one.
win_index :: proc "contextless" (name: string) -> int #no_bounds_check {
	if len(name) == 0 || len(name) > 2 {
		return -1
	}
	n := 0
	for i in 0 ..< len(name) {
		if name[i] < '0' || name[i] > '9' {
			return -1
		}
		n = n * 10 + int(name[i] - '0')
	}
	if len(name) == 2 && name[0] == '0' {
		return -1
	}
	return n < len(WIN_NAMES) ? n : -1
}

/*
win_dir builds `<mnt>/N` into the caller's buffer: a window's own directory,
with no file named inside it.

What a client binds over `/dev` to make its window's `cons` the console it
reads. `win_path` with an empty leaf would leave a trailing slash, and a
directory is a name rather than a prefix.
*/
win_dir :: proc "contextless" (buf: []u8, mnt: string, n: int) -> string #no_bounds_check {
	name := win_name(n)
	need := len(mnt) + 1 + len(name)
	if name == "" || need > len(buf) {
		return ""
	}
	at := copy(buf, mnt)
	buf[at] = '/'
	at += 1
	at += copy(buf[at:], name)
	return string(buf[:at])
}

/*
win_path builds `<mnt>/N/<leaf>` into the caller's buffer.

The caller's buffer rather than a static one. A program with no allocator that
needs two paths at once should not have to know this one keeps state. Answers
the empty string for a buffer too small, which a caller treats the way it
treats a failed open.
*/
win_path :: proc "contextless" (buf: []u8, mnt: string, n: int, leaf: string) -> string #no_bounds_check {
	name := win_name(n)
	need := len(mnt) + 1 + len(name) + 1 + len(leaf)
	if name == "" || need > len(buf) {
		return ""
	}
	at := copy(buf, mnt)
	buf[at] = '/'
	at += 1
	at += copy(buf[at:], name)
	buf[at] = '/'
	at += 1
	at += copy(buf[at:], leaf)
	return string(buf[:at])
}
