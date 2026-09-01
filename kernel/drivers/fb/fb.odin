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
import "vsys:libdraw"

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

// `mix` and `shade` used to sit here. They are the palette's own arithmetic
// rather than the surface's, so they moved to `sys/libpal` with the table.
// `palette.odin` aliases them back under these names. `pack` stayed, because
// packing is the one part that depends on the mode the bootloader set.

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

/*
get_raw reads one pixel back, in the surface's native word.

The only thing that says a fill happened. Nothing else in this package reads the
framebuffer, and a self-test that checks a cursor position rather than a pixel
is checking bookkeeping. `kernel/devfs/verify.odin` uses this to prove that an
erased character came off the screen, and `docs/TESTING.md` says why that
distinction keeps mattering.

Off-surface reads answer zero rather than fault. A caller comparing against
`pack` gets a mismatch, which is the honest answer for a pixel that is not
there.
*/
get_raw :: proc "contextless" (s: ^Surface, x, y: int) -> u32 #no_bounds_check {
	if x < 0 || y < 0 || x >= s.width || y >= s.height {
		return 0
	}
	offset := y * s.pitch + x * s.bytes_pp
	switch s.bytes_pp {
	case 4:
		return (cast(^u32)&s.pixels[offset])^
	case 3:
		return u32(s.pixels[offset]) | u32(s.pixels[offset + 1]) << 8 | u32(s.pixels[offset + 2]) << 16
	case 2:
		return u32((cast(^u16)&s.pixels[offset])^)
	}
	return 0
}

/*
span is `count` pixels of row `y`, as bytes, or nothing at all when any of the
run would be off the surface.

`get_raw` bounds one pixel. This bounds a run of them, which is what a caller
that saves and restores a rectangle of the glass is really doing -- and it does
it today with a raw slice of `pixels`, which Odin does not check at all. A row
derived from a geometry that some server *reported* can leave the screen, and a
walk past the framebuffer is a fault rather than a failed check.

An off-surface run answers empty, so a save and its restore copy the same
nothing and the pair stays balanced. `kernel/user/verify.odin` is the caller,
and `docs/TESTING.md` argues why a self-test's own sensors should not be the
thing that ends the boot.
*/
span :: proc "contextless" (s: ^Surface, x, y, count: int) -> []u8 #no_bounds_check {
	if count <= 0 || x < 0 || y < 0 || y >= s.height || x + count > s.width {
		return nil
	}
	at := y * s.pitch + x * s.bytes_pp
	return s.pixels[at:at + count * s.bytes_pp]
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

// -- Chrome ------------------------------------------------------------------
//
// The bevel walk used to live here, as a pair of surface painters. It is
// `sys/libdraw`'s now, one privilege level out, decomposed into rectangles that
// paint nothing. `paint` is the kernel's half of that split, and the reason
// `libdraw.Piece` carries an `RGB` rather than a packed pixel word: this
// painter packs against whatever mode the bootloader set, and ring 3's packs
// against the one depth `/srv/draw` accepts.
//
// So a bevel drawn at boot and a bevel drawn on a window by a program that
// cannot touch this memory are one list of rectangles, walked twice.

Piece :: libdraw.Piece
Bevel :: libdraw.Bevel

/*
paint walks a run of chrome onto a surface.

The kernel's painter for `sys/libdraw`'s vocabulary, and the whole of what ring
0 had to grow to wear it. Every piece goes through `fill_rect`, so each one
clips and packs against the mode the bootloader set.
*/
paint :: proc "contextless" (s: ^Surface, pieces: []Piece) {
	for p in pieces {
		fill_rect(s, Rect{p.x, p.y, p.w, p.h}, p.color)
	}
}

/*
bevel_edges draws a `depth`-pixel chiselled border inside `r`, without touching
the face.

The light source is fixed at the top-left, as it was on every machine this
look is quoting. Nesting a Recessed edge inside a Raised one at depth 2 is the
canonical Vectra control: a raised plinth with a sunken screen in it.

A face is what the chassis's richest surfaces are -- `brushed` for the plinth,
`gradient_v` for the copper bar -- and neither is a rectangle. That is why
`libdraw.edges` exists apart from `libdraw.panel`, and this is its caller.
*/
bevel_edges :: proc "contextless" (s: ^Surface, r: Rect, style: Bevel, light, dark: RGB, depth := 1) {
	pieces: [libdraw.MAX_PIECES]Piece
	n := libdraw.edges(pieces[:], r.x, r.y, r.w, r.h, style, light, dark, depth)
	paint(s, pieces[:n])
}

// `bevel_box` used to sit here: a face and its two shades, which is
// `libdraw.panel` with the shading done for the caller. Nothing in the kernel
// ever called it, and a procedure with no caller is a procedure no control can
// reach. `libdraw.panel` through `paint` is the two lines anything that wants
// one would write.

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
