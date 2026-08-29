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

@(private)
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

put_alloc :: proc "contextless" (b: []u8, at: int, id: u32, w: u32, h: u32) -> int #no_bounds_check {
	body := put_header(b, at, HEADER + 12, ALLOC)
	if body < 0 {
		return -1
	}
	put_u32(b, body, id)
	put_u32(b, body + 4, w)
	put_u32(b, body + 8, h)
	return body + 12
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
) -> int #no_bounds_check {
	body := put_header(b, at, HEADER + 24, FILL)
	if body < 0 {
		return -1
	}
	put_u32(b, body, id)
	put_u32(b, body + 4, x)
	put_u32(b, body + 8, y)
	put_u32(b, body + 12, w)
	put_u32(b, body + 16, h)
	put_u32(b, body + 20, color)
	return body + 24
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
) -> int #no_bounds_check {
	body := put_header(b, at, HEADER + 32, BLIT)
	if body < 0 {
		return -1
	}
	put_u32(b, body, dst)
	put_u32(b, body + 4, dx)
	put_u32(b, body + 8, dy)
	put_u32(b, body + 12, src)
	put_u32(b, body + 16, sx)
	put_u32(b, body + 20, sy)
	put_u32(b, body + 24, sw)
	put_u32(b, body + 28, sh)
	return body + 32
}

put_free :: proc "contextless" (b: []u8, at: int, id: u32) -> int #no_bounds_check {
	body := put_header(b, at, HEADER + 4, FREE)
	if body < 0 {
		return -1
	}
	put_u32(b, body, id)
	return body + 4
}

put_flush :: proc "contextless" (b: []u8, at: int) -> int #no_bounds_check {
	body := put_header(b, at, HEADER, FLUSH)
	if body < 0 {
		return -1
	}
	return body
}
