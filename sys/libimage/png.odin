/*
libimage -- a picture's bytes into pixels, for the reader and the desktop.

`docs/WEB.md` section 5 draws an image on the page or on its own. Odin's
own `core:image` reaches for the host's `core:os` and cannot build for ring
3, so this is the decoder, over the `core:compress/zlib` that already does.
PNG first, since it is what a page and a screenshot are. The whole format
is chunks, one zlib stream, and five row filters. Every colour type and
bit depth decodes to one shape, eight bits of red, green, blue and alpha a
pixel, row by row. That is what a gadget draws and a test compares.

`jpeg.odin` is the baseline JPEG beside it, and `decode` picks by the
file's signature. Not yet: interlaced PNG, which a reader can live without.
*/
package libimage

import "core:bytes"
import "core:compress/zlib"

// A decoded picture: `pix` is `w` by `h` pixels of four bytes, RGBA.
Image :: struct {
	w:   int,
	h:   int,
	pix: []u8,
}

// The most pixels a picture may have. A ring 3 heap is eight megabytes,
// and the decode holds the rows once filtered and once converted.
MAX_PIXELS :: 512 * 1024
MAX_SIDE :: 8192

image_free :: proc(img: ^Image, allocator := context.allocator) {
	delete(img.pix, allocator)
	img^ = Image{}
}

// is_png says whether `data` begins with PNG's signature.
is_png :: proc "contextless" (data: []u8) -> bool {
	return(
		len(data) >= 8 &&
		data[0] == 0x89 &&
		data[1] == 'P' &&
		data[2] == 'N' &&
		data[3] == 'G' &&
		data[4] == 0x0D &&
		data[5] == 0x0A &&
		data[6] == 0x1A &&
		data[7] == 0x0A \
	)
}

/*
decode_png turns a PNG file into an `Image`. False for a file that is not
one, is interlaced, is larger than MAX_PIXELS, or whose stream does not
inflate to its rows. The chunk CRCs are not checked. A file that inflates
and filters to its size is a picture, and one that does not is refused for
that.
*/
decode_png :: proc(data: []u8, allocator := context.allocator) -> (img: Image, ok: bool) {
	context.allocator = allocator
	if !is_png(data) {
		return img, false
	}
	w, h, depth, ctype, interlace := 0, 0, 0, 0, 0
	have_hdr := false
	plte: []u8
	trns: []u8
	idat := make([dynamic]u8, 0, 4096)
	defer delete(idat)

	at := 8
	for at + 8 <= len(data) {
		n := be32(data[at:])
		typ := string(data[at + 4:][:4])
		at += 8
		if n < 0 || at + n + 4 > len(data) {
			return img, false
		}
		body := data[at:][:n]
		switch typ {
		case "IHDR":
			if n < 13 {
				return img, false
			}
			w = be32(body)
			h = be32(body[4:])
			depth = int(body[8])
			ctype = int(body[9])
			interlace = int(body[12])
			have_hdr = true
		case "PLTE":
			plte = body
		case "tRNS":
			trns = body
		case "IDAT":
			append(&idat, ..body)
		case "IEND":
			at = len(data)
			continue
		}
		at += n + 4
	}
	if !have_hdr || w <= 0 || h <= 0 || w > MAX_SIDE || h > MAX_SIDE || w * h > MAX_PIXELS || interlace != 0 {
		return img, false
	}
	channels := 0
	switch ctype {
	case 0:
		channels = 1
	case 2:
		channels = 3
	case 3:
		channels = 1
	case 4:
		channels = 2
	case 6:
		channels = 4
	case:
		return img, false
	}
	switch depth {
	case 1, 2, 4:
		if ctype != 0 && ctype != 3 {
			return img, false
		}
	case 8:
	case 16:
		if ctype == 3 {
			return img, false
		}
	case:
		return img, false
	}
	if ctype == 3 && len(plte) < 3 {
		return img, false
	}
	bits := channels * depth
	stride := (w * bits + 7) / 8
	bpp := max((bits + 7) / 8, 1)

	raw: bytes.Buffer
	defer bytes.buffer_destroy(&raw)
	if zlib.inflate_from_byte_array(idat[:], &raw, expected_output_size = (stride + 1) * h) != nil {
		return img, false
	}
	src := bytes.buffer_to_bytes(&raw)
	if len(src) < (stride + 1) * h {
		return img, false
	}

	// Unfilter each row in place against the row above.
	prev: []u8
	for y in 0 ..< h {
		row := src[y * (stride + 1):][:stride + 1]
		cur := row[1:]
		switch row[0] {
		case 0:
		case 1:
			for i in bpp ..< stride {
				cur[i] += cur[i - bpp]
			}
		case 2:
			if prev != nil {
				for i in 0 ..< stride {
					cur[i] += prev[i]
				}
			}
		case 3:
			for i in 0 ..< stride {
				a := i >= bpp ? int(cur[i - bpp]) : 0
				b := prev != nil ? int(prev[i]) : 0
				cur[i] += u8((a + b) / 2)
			}
		case 4:
			for i in 0 ..< stride {
				a := i >= bpp ? int(cur[i - bpp]) : 0
				b := prev != nil ? int(prev[i]) : 0
				c := prev != nil && i >= bpp ? int(prev[i - bpp]) : 0
				cur[i] += paeth(a, b, c)
			}
		case:
			return img, false
		}
		prev = cur
	}

	// Convert to RGBA, a byte a channel.
	pix := make([]u8, w * h * 4)
	if pix == nil {
		return img, false
	}
	for y in 0 ..< h {
		cur := src[y * (stride + 1) + 1:][:stride]
		for x in 0 ..< w {
			o := (y * w + x) * 4
			switch ctype {
			case 0:
				v := sample(cur, x, depth)
				g := scale(v, depth)
				pix[o], pix[o + 1], pix[o + 2] = g, g, g
				pix[o + 3] = 255
				if len(trns) >= 2 && depth <= 8 && v == int(trns[0]) << 8 | int(trns[1]) {
					pix[o + 3] = 0
				}
			case 2:
				r := sample(cur, x * 3, depth)
				g := sample(cur, x * 3 + 1, depth)
				b := sample(cur, x * 3 + 2, depth)
				pix[o], pix[o + 1], pix[o + 2] = scale(r, depth), scale(g, depth), scale(b, depth)
				pix[o + 3] = 255
				if len(trns) >= 6 && depth == 8 && r == int(trns[1]) && g == int(trns[3]) && b == int(trns[5]) {
					pix[o + 3] = 0
				}
			case 3:
				idx := sample(cur, x, depth)
				if idx * 3 + 2 < len(plte) {
					pix[o], pix[o + 1], pix[o + 2] = plte[idx * 3], plte[idx * 3 + 1], plte[idx * 3 + 2]
				}
				pix[o + 3] = idx < len(trns) ? trns[idx] : 255
			case 4:
				g := scale(sample(cur, x * 2, depth), depth)
				pix[o], pix[o + 1], pix[o + 2] = g, g, g
				pix[o + 3] = scale(sample(cur, x * 2 + 1, depth), depth)
			case 6:
				pix[o] = scale(sample(cur, x * 4, depth), depth)
				pix[o + 1] = scale(sample(cur, x * 4 + 1, depth), depth)
				pix[o + 2] = scale(sample(cur, x * 4 + 2, depth), depth)
				pix[o + 3] = scale(sample(cur, x * 4 + 3, depth), depth)
			}
		}
	}
	return Image{w = w, h = h, pix = pix}, true
}

// sample answers the i'th sample of a row at `depth` bits, as stored: a
// sixteen-bit sample whole, so a transparent colour can be matched.
sample :: proc "contextless" (row: []u8, i: int, depth: int) -> int #no_bounds_check {
	switch depth {
	case 8:
		return int(row[i])
	case 16:
		return int(row[2 * i]) << 8 | int(row[2 * i + 1])
	case:
		bit := i * depth
		shift := 8 - depth - bit % 8
		return int(row[bit / 8] >> uint(shift)) & ((1 << uint(depth)) - 1)
	}
}

// scale brings a sample of `depth` bits to eight.
scale :: proc "contextless" (v: int, depth: int) -> u8 {
	switch depth {
	case 8:
		return u8(v)
	case 16:
		return u8(v >> 8)
	case:
		return u8(v * 255 / ((1 << uint(depth)) - 1))
	}
}

paeth :: proc "contextless" (a, b, c: int) -> u8 {
	p := a + b - c
	pa := abs(p - a)
	pb := abs(p - b)
	pc := abs(p - c)
	if pa <= pb && pa <= pc {
		return u8(a)
	}
	if pb <= pc {
		return u8(b)
	}
	return u8(c)
}

be32 :: proc "contextless" (b: []u8) -> int #no_bounds_check {
	if len(b) < 4 {
		return -1
	}
	v := u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
	if v > 0x7FFF_FFFF {
		return -1
	}
	return int(v)
}
