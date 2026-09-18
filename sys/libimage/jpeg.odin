/*
JPEG, the baseline half: what a camera and a page hand out.

A baseline JPEG is Huffman-coded, quantised DCT blocks, eight by eight,
of a luma plane and two chroma planes usually sampled less often. This
reads the markers that matter, the quantisation and Huffman tables, the
frame, the scan and its restart intervals, decodes each minimum coded
unit, inverts the transform, and turns YCbCr into the RGBA every picture
here becomes. The chroma is brought up to the luma's size by taking the
nearest sample, which is what the reader's shrink to fit hides anyway.

Not here: progressive JPEG, which needs every scan kept and merged,
arithmetic coding, twelve-bit samples, and CMYK. Each is refused, not
misread.
*/
package libimage

// The IDCT's cosines, `c[x*8+u] = cos((2x+1)u*pi/16)`, the `u == 0` column
// already scaled by `1/sqrt(2)`. A table, since the freestanding target has
// no cosine to call.
@(private = "file")
IDCT_COS := [64]f32 {
	0.707106781, 0.980785280, 0.923879533, 0.831469612, 0.707106781, 0.555570233, 0.382683432, 0.195090322,
	0.707106781, 0.831469612, 0.382683432, -0.195090322, -0.707106781, -0.980785280, -0.923879533, -0.555570233,
	0.707106781, 0.555570233, -0.382683432, -0.980785280, -0.707106781, 0.195090322, 0.923879533, 0.831469612,
	0.707106781, 0.195090322, -0.923879533, -0.555570233, 0.707106781, 0.831469612, -0.382683432, -0.980785280,
	0.707106781, -0.195090322, -0.923879533, 0.555570233, 0.707106781, -0.831469612, -0.382683432, 0.980785280,
	0.707106781, -0.555570233, -0.382683432, 0.980785280, -0.707106781, -0.195090322, 0.923879533, -0.831469612,
	0.707106781, -0.831469612, 0.382683432, 0.195090322, -0.707106781, 0.980785280, -0.923879533, 0.555570233,
	0.707106781, -0.980785280, 0.923879533, -0.831469612, 0.707106781, -0.555570233, 0.382683432, -0.195090322,
}

// The zigzag order a block's coefficients are coded in, to the natural.
@(private = "file")
ZIGZAG := [64]u8 {
	0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
	12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
	58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
}

@(private = "file")
Huffman :: struct {
	set:     bool,
	// Canonical codes by length: the first code of each length, how many,
	// and where its symbols start. JPEG's own F.2.2.3.
	mincode: [17]int,
	maxcode: [17]int, // -1 for a length with no codes
	valptr:  [17]int,
	symbols: [256]u8,
}

@(private = "file")
Component :: struct {
	id:     u8,
	h, v:   int, // Sampling factors
	tq:     int, // Quantisation table
	td, ta: int, // Huffman tables, DC and AC
	bw, bh: int, // Blocks across and down, at this component's sampling
	plane:  []u8, // bw*8 by bh*8 samples
	pred:   int, // The DC predictor
}

@(private = "file")
Reader :: struct {
	data: []u8,
	at:   int,
	bits: u32, // The bit buffer, high bits first
	nbit: int,
	hit_marker: bool, // A marker was reached: the bits from here are zeros
}

@(private = "file")
Jpeg :: struct {
	qt:       [4][64]u16,
	dc:       [4]Huffman,
	ac:       [4]Huffman,
	comps:    [3]Component,
	ncomp:    int,
	w, h:     int,
	hmax, vmax: int,
	restart:  int, // MCUs between restart markers, 0 for none
	r:        Reader,
}

// is_jpeg says whether `data` begins with JPEG's start-of-image marker.
is_jpeg :: proc "contextless" (data: []u8) -> bool {
	return len(data) >= 4 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
}

// decode picks the decoder by the file's signature: PNG or JPEG.
decode :: proc(data: []u8, allocator := context.allocator) -> (img: Image, ok: bool) {
	if is_png(data) {
		return decode_png(data, allocator)
	}
	if is_jpeg(data) {
		return decode_jpeg(data, allocator)
	}
	return img, false
}

/*
decode_jpeg turns a baseline JPEG into an `Image`. False for a file that is
not one, is progressive, or whose stream ends before its blocks do. A
picture larger than MAX_PIXELS is refused too, for the heap's sake.
*/
decode_jpeg :: proc(data: []u8, allocator := context.allocator) -> (img: Image, ok: bool) {
	context.allocator = allocator
	if !is_jpeg(data) {
		return img, false
	}
	j := new(Jpeg)
	defer {
		for k in 0 ..< j.ncomp {
			delete(j.comps[k].plane)
		}
		free(j)
	}
	at := 2
	have_frame := false
	for at + 4 <= len(data) {
		if data[at] != 0xFF {
			return img, false
		}
		marker := data[at + 1]
		at += 2
		if marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01 || marker == 0xFF {
			// No segment behind these.
			if marker == 0xFF {
				at -= 1
			}
			continue
		}
		if marker == 0xD9 {
			break
		}
		if at + 2 > len(data) {
			return img, false
		}
		length := int(data[at]) << 8 | int(data[at + 1])
		if length < 2 || at + length > len(data) {
			return img, false
		}
		seg := data[at + 2:][:length - 2]
		switch marker {
		case 0xDB:
			if !read_dqt(j, seg) {
				return img, false
			}
		case 0xC4:
			if !read_dht(j, seg) {
				return img, false
			}
		case 0xC0, 0xC1:
			if !read_sof(j, seg) {
				return img, false
			}
			have_frame = true
		case 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF:
			// Progressive, lossless, hierarchical or arithmetic: not this decoder.
			return img, false
		case 0xDD:
			if len(seg) < 2 {
				return img, false
			}
			j.restart = int(seg[0]) << 8 | int(seg[1])
		case 0xDA:
			if !have_frame || !read_sos(j, seg) {
				return img, false
			}
			// The entropy-coded data follows the header, to the next
			// marker that is not a restart or a stuffed byte.
			j.r = Reader{data = data, at = at + length}
			if !decode_scan(j) {
				return img, false
			}
			return to_rgba(j)
		}
		at += length
	}
	return img, false
}

// -- Tables ---------------------------------------------------------------------

@(private = "file")
read_dqt :: proc(j: ^Jpeg, seg: []u8) -> bool {
	at := 0
	for at < len(seg) {
		pq := int(seg[at] >> 4)
		tq := int(seg[at] & 15)
		at += 1
		if tq > 3 {
			return false
		}
		n := pq == 0 ? 64 : 128
		if at + n > len(seg) {
			return false
		}
		for k in 0 ..< 64 {
			v: u16
			if pq == 0 {
				v = u16(seg[at + k])
			} else {
				v = u16(seg[at + 2 * k]) << 8 | u16(seg[at + 2 * k + 1])
			}
			// Stored in natural order, so dequantising needs no lookup.
			j.qt[tq][ZIGZAG[k]] = v
		}
		at += n
	}
	return true
}

@(private = "file")
read_dht :: proc(j: ^Jpeg, seg: []u8) -> bool {
	at := 0
	for at + 17 <= len(seg) {
		class := int(seg[at] >> 4)
		id := int(seg[at] & 15)
		at += 1
		if id > 3 || class > 1 {
			return false
		}
		counts: [17]int
		total := 0
		for l in 1 ..= 16 {
			counts[l] = int(seg[at + l - 1])
			total += counts[l]
		}
		at += 16
		if total > 256 || at + total > len(seg) {
			return false
		}
		t := class == 0 ? &j.dc[id] : &j.ac[id]
		t.set = true
		copy(t.symbols[:], seg[at:][:total])
		at += total
		code := 0
		k := 0
		for l in 1 ..= 16 {
			t.valptr[l] = k
			t.mincode[l] = code
			if counts[l] == 0 {
				t.maxcode[l] = -1
			} else {
				code += counts[l]
				k += counts[l]
				t.maxcode[l] = code - 1
			}
			code <<= 1
		}
	}
	return true
}

@(private = "file")
read_sof :: proc(j: ^Jpeg, seg: []u8) -> bool {
	if len(seg) < 6 || seg[0] != 8 {
		return false
	}
	j.h = int(seg[1]) << 8 | int(seg[2])
	j.w = int(seg[3]) << 8 | int(seg[4])
	j.ncomp = int(seg[5])
	if j.w <= 0 || j.h <= 0 || j.w > MAX_SIDE || j.h > MAX_SIDE || j.w * j.h > MAX_PIXELS {
		return false
	}
	if (j.ncomp != 1 && j.ncomp != 3) || len(seg) < 6 + 3 * j.ncomp {
		return false
	}
	j.hmax, j.vmax = 1, 1
	for k in 0 ..< j.ncomp {
		c := &j.comps[k]
		c.id = seg[6 + 3 * k]
		c.h = int(seg[7 + 3 * k] >> 4)
		c.v = int(seg[7 + 3 * k] & 15)
		c.tq = int(seg[8 + 3 * k])
		if c.h < 1 || c.h > 4 || c.v < 1 || c.v > 4 || c.tq > 3 {
			return false
		}
		j.hmax = max(j.hmax, c.h)
		j.vmax = max(j.vmax, c.v)
	}
	if j.ncomp == 1 {
		j.comps[0].h, j.comps[0].v = 1, 1
		j.hmax, j.vmax = 1, 1
	}
	// Each plane holds whole MCUs, so a block at the edge has room.
	mcux := (j.w + 8 * j.hmax - 1) / (8 * j.hmax)
	mcuy := (j.h + 8 * j.vmax - 1) / (8 * j.vmax)
	for k in 0 ..< j.ncomp {
		c := &j.comps[k]
		c.bw = mcux * c.h
		c.bh = mcuy * c.v
		c.plane = make([]u8, c.bw * 8 * c.bh * 8)
		if c.plane == nil {
			return false
		}
	}
	return true
}

@(private = "file")
read_sos :: proc(j: ^Jpeg, seg: []u8) -> bool {
	if len(seg) < 1 {
		return false
	}
	n := int(seg[0])
	if n != j.ncomp || len(seg) < 1 + 2 * n {
		return false
	}
	for k in 0 ..< n {
		id := seg[1 + 2 * k]
		found := false
		for m in 0 ..< j.ncomp {
			if j.comps[m].id == id {
				j.comps[m].td = int(seg[2 + 2 * k] >> 4)
				j.comps[m].ta = int(seg[2 + 2 * k] & 15)
				found = j.comps[m].td < 4 && j.comps[m].ta < 4 && j.dc[j.comps[m].td].set && j.ac[j.comps[m].ta].set
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// -- The bit stream ---------------------------------------------------------------

// fill keeps at least `want` bits in the buffer, taking a stuffed `FF 00`
// as one byte and stopping at a marker, past which the bits read as zero.
@(private = "file")
fill :: proc "contextless" (r: ^Reader, want: int) #no_bounds_check {
	for r.nbit < want {
		b: u32 = 0
		if !r.hit_marker && r.at < len(r.data) {
			b = u32(r.data[r.at])
			if b == 0xFF {
				next := r.at + 1 < len(r.data) ? r.data[r.at + 1] : 0xD9
				if next == 0x00 {
					r.at += 2
				} else {
					r.hit_marker = true
					b = 0
				}
			} else {
				r.at += 1
			}
		}
		r.bits |= b << uint(24 - r.nbit)
		r.nbit += 8
	}
}

@(private = "file")
take_bits :: proc "contextless" (r: ^Reader, n: int) -> int {
	if n == 0 {
		return 0
	}
	fill(r, n)
	v := int(r.bits >> uint(32 - n))
	r.bits <<= uint(n)
	r.nbit -= n
	return v
}

@(private = "file")
decode_symbol :: proc "contextless" (r: ^Reader, t: ^Huffman) -> (u8, bool) {
	code := 0
	for l in 1 ..= 16 {
		code = code << 1 | take_bits(r, 1)
		if t.maxcode[l] >= 0 && code <= t.maxcode[l] && code >= t.mincode[l] {
			return t.symbols[t.valptr[l] + code - t.mincode[l]], true
		}
	}
	return 0, false
}

// extend turns `v`, read as `n` bits, into the signed coefficient it codes.
@(private = "file")
extend :: proc "contextless" (v: int, n: int) -> int {
	if n == 0 {
		return 0
	}
	if v < 1 << uint(n - 1) {
		return v - (1 << uint(n)) + 1
	}
	return v
}

// restart aligns to the next restart marker and clears the predictors.
@(private = "file")
restart :: proc "contextless" (j: ^Jpeg) -> bool {
	r := &j.r
	r.bits = 0
	r.nbit = 0
	r.hit_marker = false
	// The marker, past any fill bytes.
	for r.at + 1 < len(r.data) {
		if r.data[r.at] == 0xFF {
			m := r.data[r.at + 1]
			if m >= 0xD0 && m <= 0xD7 {
				r.at += 2
				break
			}
			if m == 0xFF {
				r.at += 1
				continue
			}
			return false
		}
		r.at += 1
	}
	for k in 0 ..< j.ncomp {
		j.comps[k].pred = 0
	}
	return true
}

// -- Blocks ---------------------------------------------------------------------

@(private = "file")
decode_scan :: proc(j: ^Jpeg) -> bool {
	mcux := j.comps[0].bw / j.comps[0].h
	mcuy := j.comps[0].bh / j.comps[0].v
	block: [64]i32
	count := 0
	for my in 0 ..< mcuy {
		for mx in 0 ..< mcux {
			if j.restart > 0 && count > 0 && count % j.restart == 0 {
				if !restart(j) {
					return false
				}
			}
			for k in 0 ..< j.ncomp {
				c := &j.comps[k]
				for by in 0 ..< c.v {
					for bx in 0 ..< c.h {
						if !decode_block(j, c, block[:]) {
							return false
						}
						idct_into(c, mx * c.h + bx, my * c.v + by, block[:])
					}
				}
			}
			count += 1
		}
	}
	return true
}

// decode_block reads one block's coefficients, dequantised, in natural order.
@(private = "file")
decode_block :: proc "contextless" (j: ^Jpeg, c: ^Component, block: []i32) -> bool #no_bounds_check {
	for k in 0 ..< 64 {
		block[k] = 0
	}
	q := &j.qt[c.tq]
	t, ok := decode_symbol(&j.r, &j.dc[c.td])
	if !ok {
		return false
	}
	diff := extend(take_bits(&j.r, int(t)), int(t))
	c.pred += diff
	block[0] = i32(c.pred) * i32(q[0])
	k := 1
	for k < 64 {
		rs, aok := decode_symbol(&j.r, &j.ac[c.ta])
		if !aok {
			return false
		}
		run := int(rs >> 4)
		size := int(rs & 15)
		if size == 0 {
			if run == 15 {
				k += 16
				continue
			}
			break
		}
		k += run
		if k > 63 {
			return false
		}
		nat := int(ZIGZAG[k])
		block[nat] = i32(extend(take_bits(&j.r, size), size)) * i32(q[nat])
		k += 1
	}
	return true
}

// idct_into inverts one block's transform and writes its samples, level
// shifted and clamped, into the component's plane at block (bx, by).
@(private = "file")
idct_into :: proc "contextless" (c: ^Component, bx, by: int, block: []i32) #no_bounds_check {
	tmp: [64]f32
	// Rows: for each row v of coefficients, the spatial row v... the
	// separable form, columns then rows.
	for x in 0 ..< 8 {
		for v in 0 ..< 8 {
			s: f32 = 0
			for u in 0 ..< 8 {
				s += f32(block[v * 8 + u]) * IDCT_COS[x * 8 + u]
			}
			tmp[v * 8 + x] = s
		}
	}
	stride := c.bw * 8
	for y in 0 ..< 8 {
		for x in 0 ..< 8 {
			s: f32 = 0
			for v in 0 ..< 8 {
				s += tmp[v * 8 + x] * IDCT_COS[y * 8 + v]
			}
			val := int(s / 4 + 128.5)
			if val < 0 {
				val = 0
			} else if val > 255 {
				val = 255
			}
			c.plane[(by * 8 + y) * stride + bx * 8 + x] = u8(val)
		}
	}
}

// to_rgba brings the planes together: chroma up to the luma's size by the
// nearest sample, then YCbCr to RGB, alpha opaque.
@(private = "file")
to_rgba :: proc(j: ^Jpeg) -> (img: Image, ok: bool) #no_bounds_check {
	pix := make([]u8, j.w * j.h * 4)
	if pix == nil {
		return img, false
	}
	for y in 0 ..< j.h {
		for x in 0 ..< j.w {
			o := (y * j.w + x) * 4
			if j.ncomp == 1 {
				c := &j.comps[0]
				g := c.plane[y * c.bw * 8 + x]
				pix[o], pix[o + 1], pix[o + 2], pix[o + 3] = g, g, g, 255
				continue
			}
			yy := int(sample_at(j, 0, x, y))
			cb := int(sample_at(j, 1, x, y)) - 128
			cr := int(sample_at(j, 2, x, y)) - 128
			// ITU-R BT.601, in fixed point.
			r := yy + ((91881 * cr) >> 16)
			g := yy - ((22554 * cb + 46802 * cr) >> 16)
			b := yy + ((116130 * cb) >> 16)
			pix[o] = clamp8(r)
			pix[o + 1] = clamp8(g)
			pix[o + 2] = clamp8(b)
			pix[o + 3] = 255
		}
	}
	return Image{w = j.w, h = j.h, pix = pix}, true
}

@(private = "file")
sample_at :: proc "contextless" (j: ^Jpeg, k: int, x, y: int) -> u8 #no_bounds_check {
	c := &j.comps[k]
	sx := x * c.h / j.hmax
	sy := y * c.v / j.vmax
	return c.plane[sy * c.bw * 8 + sx]
}

@(private = "file")
clamp8 :: proc "contextless" (v: int) -> u8 {
	if v < 0 {
		return 0
	}
	if v > 255 {
		return 255
	}
	return u8(v)
}
