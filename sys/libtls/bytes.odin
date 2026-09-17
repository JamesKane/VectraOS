/*
The byte reader and writer the TLS messages are built from.

TLS wire structures are nested length-prefixed vectors -- a vector's body is
itself vectors -- so encoding wants a length written before a body whose size
is not yet known, and decoding wants a bound that shrinks as it descends. The
`Writer` answers the first with `open`/`close`: `open` reserves a length and
returns a mark, `close` back-patches the mark with the bytes written since. The
`Reader` answers the second with `vec`: it reads a length prefix and returns
exactly that many bytes as a subslice, so a body is parsed against its own
bound and a nested field cannot read past its parent.

Both latch an error rather than fault. A short read returns zero and a nil
slice and sets `err`; every later read is a no-op; a caller checks `err` once
where it matters. A decoder that walks a hostile message therefore never
indexes out of range, whatever the lengths on the wire claim.
*/
package libtls

// -- Reader ------------------------------------------------------------------

Reader :: struct {
	buf: []u8,
	pos: int,
	err: bool,
}

reader :: proc(buf: []u8) -> Reader {
	return Reader{buf = buf}
}

r_remaining :: proc(r: ^Reader) -> int {
	return len(r.buf) - r.pos
}

r_u8 :: proc(r: ^Reader) -> u8 #no_bounds_check {
	if r.err || r.pos + 1 > len(r.buf) {
		r.err = true
		return 0
	}
	v := r.buf[r.pos]
	r.pos += 1
	return v
}

r_u16 :: proc(r: ^Reader) -> u16 {
	hi := r_u8(r)
	lo := r_u8(r)
	return u16(hi) << 8 | u16(lo)
}

r_u24 :: proc(r: ^Reader) -> int {
	a := r_u8(r)
	b := r_u8(r)
	c := r_u8(r)
	return int(a) << 16 | int(b) << 8 | int(c)
}

// r_bytes returns the next n bytes as a subslice of the buffer, no copy.
r_bytes :: proc(r: ^Reader, n: int) -> []u8 #no_bounds_check {
	if r.err || n < 0 || r.pos + n > len(r.buf) {
		r.err = true
		return nil
	}
	v := r.buf[r.pos:][:n]
	r.pos += n
	return v
}

// r_vec8/16/24 read a length-prefixed vector and return its body as a subslice.
r_vec8 :: proc(r: ^Reader) -> []u8 {
	return r_bytes(r, int(r_u8(r)))
}

r_vec16 :: proc(r: ^Reader) -> []u8 {
	return r_bytes(r, int(r_u16(r)))
}

r_vec24 :: proc(r: ^Reader) -> []u8 {
	return r_bytes(r, r_u24(r))
}

// -- Writer ------------------------------------------------------------------

Writer :: struct {
	buf: []u8,
	pos: int,
	err: bool,
}

writer :: proc(buf: []u8) -> Writer {
	return Writer{buf = buf}
}

w_u8 :: proc(w: ^Writer, v: u8) #no_bounds_check {
	if w.err || w.pos + 1 > len(w.buf) {
		w.err = true
		return
	}
	w.buf[w.pos] = v
	w.pos += 1
}

w_u16 :: proc(w: ^Writer, v: u16) {
	w_u8(w, u8(v >> 8))
	w_u8(w, u8(v))
}

w_u24 :: proc(w: ^Writer, v: int) {
	w_u8(w, u8(v >> 16))
	w_u8(w, u8(v >> 8))
	w_u8(w, u8(v))
}

w_bytes :: proc(w: ^Writer, b: []u8) #no_bounds_check {
	if w.err || w.pos + len(b) > len(w.buf) {
		w.err = true
		return
	}
	w.pos += copy(w.buf[w.pos:], b)
}

// open8/16/24 reserve a length of that width and return the mark to close at;
// close back-patches the mark with the number of bytes written since. A nested
// vector is `open`ed and `close`d inside its parent's open/close pair.
w_open8 :: proc(w: ^Writer) -> int {
	m := w.pos
	w_u8(w, 0)
	return m
}

w_close8 :: proc(w: ^Writer, mark: int) #no_bounds_check {
	if w.err {return}
	n := w.pos - mark - 1
	w.buf[mark] = u8(n)
}

w_open16 :: proc(w: ^Writer) -> int {
	m := w.pos
	w_u16(w, 0)
	return m
}

w_close16 :: proc(w: ^Writer, mark: int) #no_bounds_check {
	if w.err {return}
	n := w.pos - mark - 2
	w.buf[mark] = u8(n >> 8)
	w.buf[mark + 1] = u8(n)
}

w_open24 :: proc(w: ^Writer) -> int {
	m := w.pos
	w_u24(w, 0)
	return m
}

w_close24 :: proc(w: ^Writer, mark: int) #no_bounds_check {
	if w.err {return}
	n := w.pos - mark - 3
	w.buf[mark] = u8(n >> 16)
	w.buf[mark + 1] = u8(n >> 8)
	w.buf[mark + 2] = u8(n)
}
