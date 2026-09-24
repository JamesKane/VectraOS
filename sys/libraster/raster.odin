/*
libraster -- the look's materials, painted into a buffer of pixels.

`docs/CHROME.md` section 4. The chrome study builds each surface from
gradients and noise: an anodized panel, brushed metal, an LCD, an LED, a knob.
This is the painter for them, in ring 3, over a window's store. Section 2 of
that document is the rule it rests on. Every effect inside a window is the
client's, painted in the client's own memory. So the draw protocol keeps its
six verbs and learns nothing about a gradient.

A `Canvas` is a rectangle of `0x00RRGGBB` words with a stride, the layout
`/dev/fbctl` reports and a window's store holds. Every operation clips to it,
so a caller may pass a rectangle that runs off an edge. Nothing here allocates
or opens a file, so `tests/raster` checks each operation against pixels it
works out by hand.

The blend is 8-bit alpha over an opaque buffer, which is all a client needs.
It paints into its own store, which is opaque, so the result is opaque too.
*/
package libraster

import "vsys:libpal"

Canvas :: struct {
	pix:    [^]u32,
	stride: int,
	w:      int,
	h:      int,
}

// canvas makes a canvas over `pix`, `w` by `h`, `stride` words a row.
canvas :: proc "contextless" (pix: [^]u32, stride: int, w: int, h: int) -> Canvas {
	return Canvas{pix = pix, stride = stride, w = w, h = h}
}

// rgb is a palette colour as a pixel word.
rgb :: proc "contextless" (c: libpal.RGB) -> u32 {
	return u32(c[0]) << 16 | u32(c[1]) << 8 | u32(c[2])
}

// get reads one pixel, or zero off the canvas.
get :: proc "contextless" (c: ^Canvas, x: int, y: int) -> u32 #no_bounds_check {
	if x < 0 || y < 0 || x >= c.w || y >= c.h {
		return 0
	}
	return c.pix[y * c.stride + x]
}

// put writes one pixel, and nothing off the canvas.
put :: proc "contextless" (c: ^Canvas, x: int, y: int, v: u32) #no_bounds_check {
	if x < 0 || y < 0 || x >= c.w || y >= c.h {
		return
	}
	c.pix[y * c.stride + x] = v
}

// blend lays `src` over `dst` at alpha `a`, 0 for none of it and 255 for all.
blend :: proc "contextless" (dst: u32, src: u32, a: u32) -> u32 {
	if a >= 255 {
		return src
	}
	if a == 0 {
		return dst
	}
	na := 255 - a
	r := ((src >> 16 & 0xFF) * a + (dst >> 16 & 0xFF) * na + 127) / 255
	g := ((src >> 8 & 0xFF) * a + (dst >> 8 & 0xFF) * na + 127) / 255
	b := ((src & 0xFF) * a + (dst & 0xFF) * na + 127) / 255
	return r << 16 | g << 8 | b
}

// mix is the colour `t` of the way from `a` to `b`, `t` out of 255.
mix :: proc "contextless" (a: u32, b: u32, t: u32) -> u32 {
	return blend(a, b, t)
}

// clip cuts a rectangle to the canvas. False when nothing is left.
@(private)
clip :: proc "contextless" (c: ^Canvas, x: int, y: int, w: int, h: int) -> (x0: int, y0: int, x1: int, y1: int, ok: bool) {
	x0, y0 = max(x, 0), max(y, 0)
	x1, y1 = min(x + w, c.w), min(y + h, c.h)
	return x0, y0, x1, y1, x0 < x1 && y0 < y1
}

// fill paints a rectangle one colour.
fill :: proc "contextless" (c: ^Canvas, x: int, y: int, w: int, h: int, color: u32) #no_bounds_check {
	x0, y0, x1, y1, ok := clip(c, x, y, w, h)
	if !ok {
		return
	}
	for row in y0 ..< y1 {
		line := c.pix[row * c.stride:]
		for col in x0 ..< x1 {
			line[col] = color
		}
	}
}

// tint lays one colour over a rectangle at alpha `a`: a shade, a glow's
// wash, a selection's veil.
tint :: proc "contextless" (c: ^Canvas, x: int, y: int, w: int, h: int, color: u32, a: u32) #no_bounds_check {
	x0, y0, x1, y1, ok := clip(c, x, y, w, h)
	if !ok {
		return
	}
	for row in y0 ..< y1 {
		line := c.pix[row * c.stride:]
		for col in x0 ..< x1 {
			line[col] = blend(line[col], color, a)
		}
	}
}

/*
vgrad paints a rectangle a colour per row, `top` on its first row and
`bottom` on its last, the steps between even. A title bar's metal and a
panel's light are this.
*/
vgrad :: proc "contextless" (c: ^Canvas, x: int, y: int, w: int, h: int, top: u32, bottom: u32) #no_bounds_check {
	x0, y0, x1, y1, ok := clip(c, x, y, w, h)
	if !ok {
		return
	}
	span := max(h - 1, 1)
	for row in y0 ..< y1 {
		v := mix(top, bottom, u32((row - y) * 255 / span))
		line := c.pix[row * c.stride:]
		for col in x0 ..< x1 {
			line[col] = v
		}
	}
}

/*
radial paints a disc of radius `r` round (`cx`, `cy`), `inner` at the centre
and `outer` at the rim. Its edge pixel is blended over what is there, so the
rim is smooth. An LED is this, and a knob's face.

No square root is taken. A pixel's squared distance picks its colour, and
the rim pixel's alpha is how far inside the circle its centre falls.
*/
radial :: proc "contextless" (c: ^Canvas, cx: int, cy: int, r: int, inner: u32, outer: u32) #no_bounds_check {
	if r <= 0 {
		return
	}
	x0, y0, x1, y1, ok := clip(c, cx - r, cy - r, 2 * r + 1, 2 * r + 1)
	if !ok {
		return
	}
	r2 := r * r
	ro2 := (r + 1) * (r + 1)
	for row in y0 ..< y1 {
		dy := row - cy
		line := c.pix[row * c.stride:]
		for col in x0 ..< x1 {
			dx := col - cx
			d2 := dx * dx + dy * dy
			if d2 >= ro2 {
				continue
			}
			v := mix(inner, outer, u32(min(d2 * 255 / max(r2, 1), 255)))
			if d2 <= r2 {
				line[col] = v
			} else {
				// The rim: the fraction of the step from r to r + 1.
				a := u32((ro2 - d2) * 255 / (ro2 - r2))
				line[col] = blend(line[col], v, a)
			}
		}
	}
}

/*
hash is a position's noise, the same number for the same pixel every time.
So a tile of noise is the same whenever it is made. Two rounds of a
multiply-xorshift, which is enough that a 64-pixel tile shows no pattern.
*/
hash :: proc "contextless" (x: int, y: int, seed: u32) -> u32 {
	h := u32(x) * 0x9E3779B1 ~ u32(y) * 0x85EBCA77 ~ seed
	h ~= h >> 15
	h *= 0x2C1B3C6D
	h ~= h >> 12
	h *= 0x297A2D39
	h ~= h >> 15
	return h
}

/*
noise lays hashed grain over a rectangle. Each pixel goes lighter or darker by
up to `strength`, the same in all three channels, so the grain has no colour.
An anodized panel is noise over a gradient. The hash is of the pixel's place
in the rectangle, so a panel's grain moves with the panel.
*/
noise :: proc "contextless" (c: ^Canvas, x: int, y: int, w: int, h: int, strength: int, seed: u32) #no_bounds_check {
	x0, y0, x1, y1, ok := clip(c, x, y, w, h)
	if !ok || strength <= 0 {
		return
	}
	span := 2 * strength + 1
	for row in y0 ..< y1 {
		line := c.pix[row * c.stride:]
		for col in x0 ..< x1 {
			d := int(hash(col - x, row - y, seed) % u32(span)) - strength
			line[col] = shift(line[col], d)
		}
	}
}

// shift moves every channel of a pixel by `d`, held to 0..255.
shift :: proc "contextless" (v: u32, d: int) -> u32 {
	r := clamp(int(v >> 16 & 0xFF) + d, 0, 255)
	g := clamp(int(v >> 8 & 0xFF) + d, 0, 255)
	b := clamp(int(v & 0xFF) + d, 0, 255)
	return u32(r) << 16 | u32(g) << 8 | u32(b)
}

/*
hairline lays a line of `color` at alpha `a` every `step` pixels across a
rectangle: columns when `vertical`, rows when not. Brushed metal is two of
these at different steps over a gradient, the study's two interleaved
patterns.
*/
hairline :: proc "contextless" (c: ^Canvas, x: int, y: int, w: int, h: int, step: int, color: u32, a: u32, vertical: bool) #no_bounds_check {
	x0, y0, x1, y1, ok := clip(c, x, y, w, h)
	if !ok || step <= 0 {
		return
	}
	for row in y0 ..< y1 {
		line := c.pix[row * c.stride:]
		for col in x0 ..< x1 {
			k := vertical ? col - x : row - y
			if k % step == 0 {
				line[col] = blend(line[col], color, a)
			}
		}
	}
}

/*
bevel paints the lit and shadowed edges of a rectangle, `width` deep. `lit`
goes along the top and left and `shade` along the bottom and right, the light
at the top left as the chrome has it. The face is the caller's, painted first.
*/
bevel :: proc "contextless" (c: ^Canvas, x: int, y: int, w: int, h: int, width: int, lit: u32, shade: u32) {
	if width <= 0 {
		return
	}
	d := min(width, w / 2, h / 2)
	fill(c, x, y, w, d, lit)
	fill(c, x, y, d, h, lit)
	fill(c, x, y + h - d, w, d, shade)
	fill(c, x + w - d, y, d, h, shade)
}

/*
inset lays an inner shadow: the edges of a rectangle darkened in a ramp
`depth` deep, darkest at the edge, by `a` at most. A sunk field and an LCD's
glass read as sunk by it. The top and left fall darker than the bottom and
right, since the light is at the top left.
*/
inset :: proc "contextless" (c: ^Canvas, x: int, y: int, w: int, h: int, depth: int, a: u32) #no_bounds_check {
	x0, y0, x1, y1, ok := clip(c, x, y, w, h)
	if !ok || depth <= 0 {
		return
	}
	for row in y0 ..< y1 {
		line := c.pix[row * c.stride:]
		for col in x0 ..< x1 {
			top := row - y
			left := col - x
			bottom := y + h - 1 - row
			right := x + w - 1 - col
			near := min(top, left)
			far := min(bottom, right)
			k: u32 = 0
			if near < depth {
				k = a * u32(depth - near) / u32(depth)
			}
			if far < depth {
				k = max(k, a / 2 * u32(depth - far) / u32(depth))
			}
			if k > 0 {
				line[col] = blend(line[col], 0, k)
			}
		}
	}
}

/*
blur softens a rectangle in place with three box passes each way, which is
near a Gaussian of the same radius. `scratch` holds one row or column: a
caller hands it at least `max(w, h)` words. Bloom and glass are this.
*/
blur :: proc "contextless" (c: ^Canvas, x: int, y: int, w: int, h: int, radius: int, scratch: []u32) #no_bounds_check {
	x0, y0, x1, y1, ok := clip(c, x, y, w, h)
	if !ok || radius <= 0 || len(scratch) < max(x1 - x0, y1 - y0) {
		return
	}
	for _ in 0 ..< 3 {
		for row in y0 ..< y1 {
			box(c.pix[row * c.stride + x0:], 1, x1 - x0, radius, scratch)
		}
		for col in x0 ..< x1 {
			box(c.pix[y0 * c.stride + col:], c.stride, y1 - y0, radius, scratch)
		}
	}
}

// box is one pass of a box filter along `n` pixels `step` apart. It keeps a
// running sum of each channel over `2*radius + 1` pixels, the ends held.
@(private)
box :: proc "contextless" (p: [^]u32, step: int, n: int, radius: int, scratch: []u32) #no_bounds_check {
	for i in 0 ..< n {
		scratch[i] = p[i * step]
	}
	span := u32(2 * radius + 1)
	sr, sg, sb: u32
	at :: proc "contextless" (s: []u32, i: int, n: int) -> u32 #no_bounds_check {
		return s[clamp(i, 0, n - 1)]
	}
	for k in -radius ..= radius {
		v := at(scratch, k, n)
		sr += v >> 16 & 0xFF
		sg += v >> 8 & 0xFF
		sb += v & 0xFF
	}
	for i in 0 ..< n {
		p[i * step] = (sr / span) << 16 | (sg / span) << 8 | (sb / span)
		out := at(scratch, i - radius, n)
		in_ := at(scratch, i + radius + 1, n)
		sr += (in_ >> 16 & 0xFF) - (out >> 16 & 0xFF)
		sg += (in_ >> 8 & 0xFF) - (out >> 8 & 0xFF)
		sb += (in_ & 0xFF) - (out & 0xFF)
	}
}

/*
coverage lays an 8-bit mask in one colour: each byte is how much of that
pixel the shape covers, 0 none and 255 all. A glyph of an antialiased face
is this, and so is an icon's shape and a glow's ramp. `mask` is `mw` bytes a
row.
*/
coverage :: proc "contextless" (c: ^Canvas, x: int, y: int, mask: []u8, mw: int, mh: int, color: u32) #no_bounds_check {
	x0, y0, x1, y1, ok := clip(c, x, y, mw, mh)
	if !ok || len(mask) < mw * mh {
		return
	}
	for row in y0 ..< y1 {
		line := c.pix[row * c.stride:]
		m := mask[(row - y) * mw:]
		for col in x0 ..< x1 {
			a := u32(m[col - x])
			if a != 0 {
				line[col] = blend(line[col], color, a)
			}
		}
	}
}

/*
bits lays a 1-bit glyph: `rows` bytes, one a row, eight pixels wide with the
leftmost the high bit, `sys/libfont`'s cell. A set bit is `color`, and a
clear one leaves what is there, so a label reads on any ground.
*/
bits :: proc "contextless" (c: ^Canvas, x: int, y: int, rows: []u8, color: u32) #no_bounds_check {
	for r in 0 ..< len(rows) {
		b := rows[r]
		if b == 0 {
			continue
		}
		for k in 0 ..< 8 {
			if b & (0x80 >> u8(k)) != 0 {
				put(c, x + k, y + r, color)
			}
		}
	}
}

/*
copy_scaled lays `pw` by `ph` RGBA pixels, four bytes each, into a rectangle
`dw` by `dh` at (`dx`, `dy`). It takes one source pixel for each destination
pixel, alpha blended over what is there. A picture in a well, shrunk to fit, is this.
*/
copy_scaled :: proc "contextless" (c: ^Canvas, pix: []u8, pw: int, ph: int, dx: int, dy: int, dw: int, dh: int) #no_bounds_check {
	x0, y0, x1, y1, ok := clip(c, dx, dy, dw, dh)
	if !ok || pw <= 0 || ph <= 0 || len(pix) < pw * ph * 4 {
		return
	}
	for row in y0 ..< y1 {
		sy := (row - dy) * ph / dh
		line := c.pix[row * c.stride:]
		for col in x0 ..< x1 {
			sx := (col - dx) * pw / dw
			p := pix[(sy * pw + sx) * 4:]
			v := u32(p[0]) << 16 | u32(p[1]) << 8 | u32(p[2])
			line[col] = blend(line[col], v, u32(p[3]))
		}
	}
}

// -- Outlines -----------------------------------------------------------------

/*
A Point is in sixteenths of a pixel, so an outline's corners fall between
pixels and its edges come out smooth. `SUB` is the one.
*/
SUB :: 16

Point :: struct {
	x, y: int,
}

/*
path fills an outline: `pts` holds its contours back to back, and `ends`
says where each stops, a contour closing itself. The rule is nonzero
winding, so a contour inside another in the same direction adds to it and
one the other way cuts a hole. It is `docs/CHROME.md` section 6's icon
filler.

Each pixel row is sampled on four lines. On each line the spans between
crossings count their length in sixteenths of a pixel into `scratch`, one
word a pixel across the canvas. A pixel's alpha is its count
over the most it could hold. So an edge at any angle is smooth, and nothing
here takes a float.
*/
PATH_ROWS :: 4
MAX_CROSS :: 64

path :: proc "contextless" (c: ^Canvas, pts: []Point, ends: []int, color: u32, scratch: []u32) {
	p := Paint{kind = .Solid, color = color, alpha = 255}
	path_paint(c, pts, ends, &p, scratch)
}

/*
A Paint is what an outline is filled with. It is one colour, or a gradient
along a line or out from a point, with an alpha over the whole. A gradient's
stops are at 0 to 255 along it, in order, each with a colour. `a` and `b` are
the line's two ends in sixteenths of a pixel. A radial paint is centred on `a`,
with its radius in `r`, in sixteenths too.

A pixel past either end takes the end stop. `docs/CHROME.md` section 6's icons are filled with these.
*/
Paint_Kind :: enum u8 {
	Solid,
	Linear,
	Radial,
}

MAX_STOPS :: 4

Stop :: struct {
	at:    u32,
	color: u32,
}

Paint :: struct {
	kind:  Paint_Kind,
	color: u32,
	alpha: u32,
	a, b:  Point,
	r:     int,
	stops: [MAX_STOPS]Stop,
	n:     int,
}

// path_paint is `path` with a paint in place of a colour.
path_paint :: proc "contextless" (c: ^Canvas, pts: []Point, ends: []int, paint: ^Paint, scratch: []u32) #no_bounds_check {
	if len(pts) < 3 || len(scratch) < c.w || paint.alpha == 0 {
		return
	}
	// The outline's rows.
	top, bottom := max(int), min(int)
	for p in pts {
		top = min(top, p.y)
		bottom = max(bottom, p.y)
	}
	y0 := max(top / SUB, 0)
	y1 := min((bottom + SUB - 1) / SUB, c.h)
	full := u32(PATH_ROWS * SUB)
	for row in y0 ..< y1 {
		for i in 0 ..< c.w {
			scratch[i] = 0
		}
		lo, hi := c.w, 0
		for s in 0 ..< PATH_ROWS {
			// The sample line, in sixteenths: the middle of its quarter.
			sy := row * SUB + (2 * s + 1) * SUB / (2 * PATH_ROWS)
			xs: [MAX_CROSS]int
			ws: [MAX_CROSS]int
			n := 0
			start := 0
			for e in ends {
				if e > len(pts) || e - start < 2 {
					start = e
					continue
				}
				for k in start ..< e {
					a := pts[k]
					b := pts[k + 1 < e ? k + 1 : start]
					if a.y == b.y {
						continue
					}
					dir := 1
					if a.y > b.y {
						a, b = b, a
						dir = -1
					}
					if sy < a.y || sy >= b.y || n >= MAX_CROSS {
						continue
					}
					xs[n] = a.x + (sy - a.y) * (b.x - a.x) / (b.y - a.y)
					ws[n] = dir
					n += 1
				}
				start = e
			}
			// The crossings left to right, their windings with them.
			for i in 1 ..< n {
				for j := i; j > 0 && xs[j - 1] > xs[j]; j -= 1 {
					xs[j - 1], xs[j] = xs[j], xs[j - 1]
					ws[j - 1], ws[j] = ws[j], ws[j - 1]
				}
			}
			wind := 0
			for i in 0 ..< n - 1 {
				wind += ws[i]
				if wind == 0 {
					continue
				}
				span(scratch, xs[i], xs[i + 1], c.w, &lo, &hi)
			}
		}
		line := c.pix[row * c.stride:]
		for col in lo ..< hi {
			v := scratch[col]
			if v == 0 {
				continue
			}
			color := paint.color
			if paint.kind != .Solid {
				color = paint_at(paint, col * SUB + SUB / 2, row * SUB + SUB / 2)
			}
			line[col] = blend(line[col], color, min(v * 255 / full, 255) * paint.alpha / 255)
		}
	}
}

// paint_at is a gradient's colour at a point in sixteenths of a pixel.
@(private)
paint_at :: proc "contextless" (p: ^Paint, x: int, y: int) -> u32 #no_bounds_check {
	if p.n == 0 {
		return p.color
	}
	t := 0
	switch p.kind {
	case .Solid:
		return p.color
	case .Linear:
		dx, dy := p.b.x - p.a.x, p.b.y - p.a.y
		l2 := dx * dx + dy * dy
		if l2 > 0 {
			t = ((x - p.a.x) * dx + (y - p.a.y) * dy) * 255 / l2
		}
	case .Radial:
		if p.r > 0 {
			t = isqrt((x - p.a.x) * (x - p.a.x) + (y - p.a.y) * (y - p.a.y)) * 255 / p.r
		}
	}
	at := u32(clamp(t, 0, 255))
	if at <= p.stops[0].at {
		return p.stops[0].color
	}
	for i in 1 ..< p.n {
		lo, hi := p.stops[i - 1], p.stops[i]
		if at <= hi.at {
			if hi.at == lo.at {
				return hi.color
			}
			return mix(lo.color, hi.color, (at - lo.at) * 255 / (hi.at - lo.at))
		}
	}
	return p.stops[p.n - 1].color
}

// isqrt is the whole square root of `v`, by Newton's steps.
@(private)
isqrt :: proc "contextless" (v: int) -> int {
	if v <= 0 {
		return 0
	}
	x := v
	y := (x + 1) / 2
	for y < x {
		x = y
		y = (x + v / x) / 2
	}
	return x
}

// span adds the part of each pixel that `xa..xb`, in sixteenths, covers.
@(private)
span :: proc "contextless" (acc: []u32, xa: int, xb: int, w: int, lo: ^int, hi: ^int) #no_bounds_check {
	a := max(xa, 0)
	b := min(xb, w * SUB)
	if a >= b {
		return
	}
	pa, pb := a / SUB, (b - 1) / SUB
	lo^ = min(lo^, pa)
	hi^ = max(hi^, pb + 1)
	if pa == pb {
		acc[pa] += u32(b - a)
		return
	}
	acc[pa] += u32((pa + 1) * SUB - a)
	for p in pa + 1 ..< pb {
		acc[p] += SUB
	}
	acc[pb] += u32(b - pb * SUB)
}

/*
cubic flattens a Bézier curve from `p0` through `p1` and `p2` to `p3` into
`out`, starting after `p0`, and answers how many points it wrote. Sixteen
steps is smooth at 128 pixels, the largest an icon is drawn. An icon's path
is lines and these.
*/
CUBIC_STEPS :: 16

cubic :: proc "contextless" (out: []Point, p0: Point, p1: Point, p2: Point, p3: Point) -> int #no_bounds_check {
	n := 0
	for i in 1 ..= CUBIC_STEPS {
		if n >= len(out) {
			break
		}
		t := i
		u := CUBIC_STEPS - t
		// In steps cubed, so the arithmetic stays whole.
		d := CUBIC_STEPS * CUBIC_STEPS * CUBIC_STEPS
		x := (u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x) / d
		y := (u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y) / d
		out[n] = Point{x, y}
		n += 1
	}
	return n
}
