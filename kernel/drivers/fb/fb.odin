/*
Linear framebuffer surface and the skeuomorphic drawing primitives the rest of
Vectra is built on.

A `Surface` is deliberately just memory plus geometry. The boot splash, the
panic screen, and later the `intuition` compositor all render through this same
type.

The compositor's off-screen window buffers are Surfaces too. A bevel drawn at
boot and a bevel drawn on a window titlebar are therefore the same code.

Every primitive clips to the surface. Nothing here allocates.
*/
package fb

import "kernel:boot/limine"

Surface :: struct {
	pixels:   [^]u8,
	width:    int,
	height:   int,
	pitch:    int, // Bytes per scanline; not necessarily width * bytes_per_pixel
	bytes_pp: int,

	// Channel layout, taken from the mode the bootloader actually set rather
	// than assumed to be XRGB8888.
	red_shift:   u8,
	green_shift: u8,
	blue_shift:  u8,
	red_size:    u8,
	green_size:  u8,
	blue_size:   u8,
}

Rect :: struct {
	x, y, w, h: int,
}

// from_limine adapts a bootloader framebuffer description into a Surface.
from_limine :: proc "contextless" (f: ^limine.Framebuffer) -> Surface {
	return Surface {
		pixels      = cast([^]u8)f.address,
		width       = int(f.width),
		height      = int(f.height),
		pitch       = int(f.pitch),
		bytes_pp    = int(f.bpp) / 8,
		red_shift   = f.red_mask_shift,
		green_shift = f.green_mask_shift,
		blue_shift  = f.blue_mask_shift,
		red_size    = f.red_mask_size,
		green_size  = f.green_mask_size,
		blue_size   = f.blue_mask_size,
	}
}

/*
pack converts an 8-bit-per-channel colour into the surface's native pixel word.

A channel below 8 bits drops its low bits, which is what a 15bpp or 16bpp mode
wants. No mode Limine hands over produces a channel above 8.
*/
pack :: proc "contextless" (s: ^Surface, c: RGB) -> u32 {
	r := u32(c[0]) >> (8 - s.red_size)
	g := u32(c[1]) >> (8 - s.green_size)
	b := u32(c[2]) >> (8 - s.blue_size)
	return r << s.red_shift | g << s.green_shift | b << s.blue_shift
}

/*
mix blends `a` toward `b` by `t` in 1/256ths.

Used for gradients, and to derive bevel edges from a face colour. A control
tinted at runtime therefore still bevels correctly, and needs no three
hand-picked palette entries.
*/
mix :: proc "contextless" (a, b: RGB, t: u8) -> RGB {
	blend :: proc "contextless" (x, y, t: u8) -> u8 {
		return u8((u32(x) * u32(255 - t) + u32(y) * u32(t)) / 255)
	}
	return RGB{blend(a[0], b[0], t), blend(a[1], b[1], t), blend(a[2], b[2], t)}
}

// shade lightens (positive) or darkens (negative) a colour by 1/256ths.
shade :: proc "contextless" (c: RGB, amount: i16) -> RGB {
	adjust :: proc "contextless" (v: u8, amount: i16) -> u8 {
		x := i16(v) + amount
		return u8(clamp(x, 0, 255))
	}
	return RGB{adjust(c[0], amount), adjust(c[1], amount), adjust(c[2], amount)}
}

// -- Pixel access ------------------------------------------------------------

@(private)
put_raw :: proc "contextless" (s: ^Surface, x, y: int, value: u32) #no_bounds_check {
	offset := y * s.pitch + x * s.bytes_pp
	switch s.bytes_pp {
	case 4:
		(cast(^u32)&s.pixels[offset])^ = value
	case 3:
		s.pixels[offset + 0] = u8(value)
		s.pixels[offset + 1] = u8(value >> 8)
		s.pixels[offset + 2] = u8(value >> 16)
	case 2:
		(cast(^u16)&s.pixels[offset])^ = u16(value)
	}
}

put_pixel :: proc "contextless" (s: ^Surface, x, y: int, c: RGB) {
	if x < 0 || y < 0 || x >= s.width || y >= s.height {
		return
	}
	put_raw(s, x, y, pack(s, c))
}

// -- Rectangles --------------------------------------------------------------

/*
clip intersects `r` with the surface bounds.

Returns ok=false for a fully off-surface or empty rect, so a caller can stop
before it computes a span. Every primitive below goes through this, which is
why none of them need bounds checks of their own.
*/
clip :: proc "contextless" (s: ^Surface, r: Rect) -> (out: Rect, ok: bool) {
	x0 := max(r.x, 0)
	y0 := max(r.y, 0)
	x1 := min(r.x + r.w, s.width)
	y1 := min(r.y + r.h, s.height)
	if x1 <= x0 || y1 <= y0 {
		return {}, false
	}
	return Rect{x0, y0, x1 - x0, y1 - y0}, true
}

fill_rect :: proc "contextless" (s: ^Surface, r: Rect, c: RGB) #no_bounds_check {
	area := clip(s, r) or_else Rect{}
	if area.w == 0 {
		return
	}
	value := pack(s, c)
	for y in area.y ..< area.y + area.h {
		for x in area.x ..< area.x + area.w {
			put_raw(s, x, y, value)
		}
	}
}

clear :: proc "contextless" (s: ^Surface, c: RGB) {
	fill_rect(s, Rect{0, 0, s.width, s.height}, c)
}

hline :: proc "contextless" (s: ^Surface, x, y, w: int, c: RGB) {
	fill_rect(s, Rect{x, y, w, 1}, c)
}

vline :: proc "contextless" (s: ^Surface, x, y, h: int, c: RGB) {
	fill_rect(s, Rect{x, y, 1, h}, c)
}

// outline draws a one-pixel border just inside `r`.
outline :: proc "contextless" (s: ^Surface, r: Rect, c: RGB) {
	hline(s, r.x, r.y, r.w, c)
	hline(s, r.x, r.y + r.h - 1, r.w, c)
	vline(s, r.x, r.y, r.h, c)
	vline(s, r.x + r.w - 1, r.y, r.h, c)
}

// -- Gradients ---------------------------------------------------------------

/*
gradient_v fills `r` with a vertical ramp from `top` to `bottom`.

This is the copper-bar workhorse: titlebars, meter backgrounds, and the boot
splash header are all one of these with a bevel on top.
*/
gradient_v :: proc "contextless" (s: ^Surface, r: Rect, top, bottom: RGB) {
	if r.h <= 0 {
		return
	}
	for row in 0 ..< r.h {
		t := r.h == 1 ? u8(0) : u8(row * 255 / (r.h - 1))
		hline(s, r.x, r.y + row, r.w, mix(top, bottom, t))
	}
}

gradient_h :: proc "contextless" (s: ^Surface, r: Rect, left, right: RGB) {
	if r.w <= 0 {
		return
	}
	for col in 0 ..< r.w {
		t := r.w == 1 ? u8(0) : u8(col * 255 / (r.w - 1))
		vline(s, r.x + col, r.y, r.h, mix(left, right, t))
	}
}

// -- Bevels ------------------------------------------------------------------

Bevel :: enum {
	Raised,   // A button or panel standing proud of its background
	Recessed, // A well: text fields, screens, sunken separators
}

/*
bevel_edges draws a `depth`-pixel chiselled border inside `r`, without touching
the face.

The light source is fixed at the top-left, as it was on every machine this
look is quoting. Nesting a Recessed edge inside a Raised one at depth 2 is the
canonical Vectra control: a raised plinth with a sunken screen in it.
*/
bevel_edges :: proc "contextless" (s: ^Surface, r: Rect, style: Bevel, light, dark: RGB, depth := 1) {
	tl := style == .Raised ? light : dark
	br := style == .Raised ? dark : light

	for i in 0 ..< depth {
		inset := Rect{r.x + i, r.y + i, r.w - 2 * i, r.h - 2 * i}
		if inset.w <= 0 || inset.h <= 0 {
			return
		}
		hline(s, inset.x, inset.y, inset.w, tl)
		vline(s, inset.x, inset.y, inset.h, tl)
		hline(s, inset.x, inset.y + inset.h - 1, inset.w, br)
		vline(s, inset.x + inset.w - 1, inset.y, inset.h, br)
	}
}

// bevel_box fills `r` with `face` and then chisels its edges.
bevel_box :: proc "contextless" (s: ^Surface, r: Rect, style: Bevel, face: RGB, depth := 1) {
	fill_rect(s, r, face)
	bevel_edges(s, r, style, shade(face, +48), shade(face, -34), depth)
}

// inset_of returns the usable interior of a `depth`-beveled box.
inset_of :: proc "contextless" (r: Rect, depth := 1) -> Rect {
	return Rect{r.x + depth, r.y + depth, r.w - 2 * depth, r.h - 2 * depth}
}

/*
brushed fills `r` with a subtly striated face to suggest brushed magnesium.

The striation is a fixed two-row pattern rather than noise. It has to survive a
draw of one dirty rectangle at a time, and still line up with the rows the
compositor drew last frame.
*/
brushed :: proc "contextless" (s: ^Surface, r: Rect, face: RGB) {
	area := clip(s, r) or_else Rect{}
	if area.w == 0 {
		return
	}
	lit := pack(s, shade(face, +6))
	base := pack(s, face)
	for y in area.y ..< area.y + area.h {
		value := (y & 3) == 0 ? lit : base
		for x in area.x ..< area.x + area.w {
			put_raw(s, x, y, value)
		}
	}
}
