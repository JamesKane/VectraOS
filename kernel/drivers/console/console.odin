/*
Framebuffer text console.

This is the kernel's own output device, not a terminal emulator: no escape
sequences, no scrollback, no reflow. `apps/terminal` will do all of that in
userland against /dev/fb. What lives here is what a panic handler is allowed
to depend on.

Glyphs come from `sys/libfont`, the one table `tools/genfont.py` bakes.
There is no font loading at boot, and ring 3 links the same table. The
aliases below keep this package's names for the callers that size things
by them.
*/
package console

import "kernel:drivers/fb"
import "vsys:libfont"

FONT_WIDTH :: libfont.FONT_WIDTH
FONT_HEIGHT :: libfont.FONT_HEIGHT
FONT_FIRST :: libfont.FONT_FIRST
FONT_LAST :: libfont.FONT_LAST

/*
Text is drawn embossed by default: a dark copy one pixel down-right, then the
lit copy. It costs a second glyph blit. It is also the single cheapest thing
that makes amber-on-slate read as engraved metal rather than a web page.
*/
Style :: enum {
	Flat,
	Embossed,
	Engraved, // Shadow above-left instead: text pressed *into* the surface
}

Console :: struct {
	surface: ^fb.Surface,
	bounds:  fb.Rect, // Region of the surface this console owns

	cols: int,
	rows: int,
	col:  int,
	row:  int,

	fg:    fb.RGB,
	bg:    fb.RGB,
	style: Style,

	// Leading added between rows. The 8x16 cell is tight. One or two extra
	// scanlines is what makes a wall of boot log legible.
	line_gap: int,
}

/*
init lays a console over `bounds`, which must already be filled with `bg`.

The console does not clear its region: callers usually want it inside a bevel
they have just drawn, and clearing would eat the bevel.
*/
init :: proc "contextless" (s: ^fb.Surface, bounds: fb.Rect, fg, bg: fb.RGB, line_gap := 2) -> Console {
	c := Console {
		surface  = s,
		bounds   = bounds,
		fg       = fg,
		bg       = bg,
		style    = .Embossed,
		line_gap = line_gap,
	}
	c.cols = bounds.w / FONT_WIDTH
	c.rows = bounds.h / (FONT_HEIGHT + line_gap)
	return c
}

cell_height :: proc "contextless" (c: ^Console) -> int {
	return FONT_HEIGHT + c.line_gap
}

/*
draw_glyph blits one cell at pixel position (px, py).

Nothing paints the background. Glyphs composite onto whatever is already there,
so a console can sit over a gradient or a brushed panel and punch no rectangles
through it.
*/
/*
The kernel's own font, past ASCII: a `libfont.Loader` filled from `/lib/font`
once a filesystem is up. Before then, and for ASCII always, the baked table
answers; `loader_glyph` reaches the loaded subfonts only for the rest. The
early-boot log and the panic screen are ASCII and want none of it, which is
why nothing waits on the load.
*/
console_font: libfont.Loader

// use_font opens the kernel's runtime font through the caller's reader --
// `kernel/main` gives it one over `vfs`. Called once a filesystem holds the
// `.font`; a console that never calls it draws ASCII and nothing more.
use_font :: proc "contextless" (
	read: proc "contextless" (data: rawptr, path: string, into: []u8) -> int,
	data: rawptr,
) -> bool {
	return libfont.loader_open(&console_font, "/lib/font/default.font", read, data)
}

draw_glyph :: proc "contextless" (s: ^fb.Surface, px, py: int, ch: rune, color: fb.RGB) #no_bounds_check {
	cell: [FONT_HEIGHT]u8
	_, ok := libfont.loader_glyph(&console_font, ch, cell[:])
	if !ok {
		return
	}
	for y in 0 ..< FONT_HEIGHT {
		bits := cell[y]
		if bits == 0 {
			continue
		}
		for x in 0 ..< FONT_WIDTH {
			if bits & (0x80 >> u8(x)) != 0 {
				fb.put_pixel(s, px + x, py + y, color)
			}
		}
	}
}

// decode_rune reads one UTF-8 rune from `b`, answering it and its byte
// length. A byte that starts no valid sequence is one Latin-1-ish rune of
// itself, so a lone high byte still draws something rather than stalling.
decode_rune :: proc "contextless" (b: []u8) -> (r: rune, size: int) #no_bounds_check {
	if len(b) == 0 {
		return 0, 0
	}
	c := b[0]
	if c < 0x80 {
		return rune(c), 1
	}
	n: int
	switch {
	case c & 0xE0 == 0xC0:
		r = rune(c & 0x1F); n = 2
	case c & 0xF0 == 0xE0:
		r = rune(c & 0x0F); n = 3
	case c & 0xF8 == 0xF0:
		r = rune(c & 0x07); n = 4
	case:
		return rune(c), 1
	}
	if len(b) < n {
		return rune(c), 1
	}
	for i in 1 ..< n {
		if b[i] & 0xC0 != 0x80 {
			return rune(c), 1
		}
		r = r << 6 | rune(b[i] & 0x3F)
	}
	return r, n
}

// draw_text_styled renders `text` at a pixel position with the emboss applied.
draw_text_styled :: proc "contextless" (
	s: ^fb.Surface,
	px, py: int,
	text: string,
	color: fb.RGB,
	style: Style,
) {
	shadow := fb.shade(color, -110)
	switch style {
	case .Flat:
	case .Embossed:
		draw_string(s, px + 1, py + 1, text, shadow)
	case .Engraved:
		draw_string(s, px - 1, py - 1, text, shadow)
	}
	draw_string(s, px, py, text, color)
}

@(private)
draw_string :: proc "contextless" (s: ^fb.Surface, px, py: int, text: string, color: fb.RGB) #no_bounds_check {
	x := px
	i := 0
	for i < len(text) {
		r, size := decode_rune(transmute([]u8)text[i:])
		if size == 0 {
			break
		}
		draw_glyph(s, x, py, r, color)
		x += FONT_WIDTH
		i += size
	}
}

// -- Cursor-based output -----------------------------------------------------

newline :: proc "contextless" (c: ^Console) {
	c.col = 0
	c.row += 1
	if c.row >= c.rows {
		scroll(c)
		c.row = c.rows - 1
	}
}

write_byte :: proc "contextless" (c: ^Console, ch: u8) {
	switch ch {
	case '\n':
		newline(c)
		return
	case '\r':
		c.col = 0
		return
	case '\b':
		backspace(c)
		return
	case '\t':
		// Tabs land on 8-column stops, matching the font cell grid.
		next := (c.col + 8) & ~int(7)
		for c.col < next && c.col < c.cols {
			write_byte(c, ' ')
		}
		return
	}

	if c.col >= c.cols {
		newline(c)
	}
	px := c.bounds.x + c.col * FONT_WIDTH
	py := c.bounds.y + c.row * cell_height(c)
	draw_text_styled(c.surface, px, py, string([]u8{ch}), c.fg, c.style)
	c.col += 1
}

/*
backspace moves back one cell and clears it.

**Destructive, which a terminal's backspace is not.** On a serial line the
sequence to erase is `\b \b`: step back, overwrite with a space, step back
again. That does not work here, because nothing in this file paints a
background. A space glyph is blank, so it composites nothing over the character
that is already there and the character stays.

So this fills the cell instead. A caller with both sinks sends `\b \b` to the
wire and calls this for the screen, which is what `devfs.cons_erase` does.

One pixel wider and taller than a cell, because `draw_text_styled` puts the
emboss shadow at +1,+1. A fill of exactly one cell would leave the erased
glyph's shadow along the next cell's left edge.

At column zero this does nothing. A backspace does not unwrap a line: the row
above holds output the caller never asked to take back.
*/
backspace :: proc "contextless" (c: ^Console) {
	if c.col <= 0 {
		return
	}
	c.col -= 1
	px := c.bounds.x + c.col * FONT_WIDTH
	py := c.bounds.y + c.row * cell_height(c)
	fb.fill_rect(c.surface, fb.Rect{px, py, FONT_WIDTH + 1, FONT_HEIGHT + 1}, c.bg)
}

write_string :: proc "contextless" (c: ^Console, text: string) {
	for i in 0 ..< len(text) {
		write_byte(c, text[i])
	}
}

/*
scroll moves the console region up one text row.

This is a straight memmove of the owned sub-rectangle: slow, and correct even
when the console is a window over a busy surface. The compositor will get a
dirty-rect path. The boot log does not need one.
*/
scroll :: proc "contextless" (c: ^Console) #no_bounds_check {
	s := c.surface
	step := cell_height(c)
	area := fb.clip(s, c.bounds) or_else fb.Rect{}
	if area.w == 0 {
		return
	}

	for y in area.y ..< area.y + area.h - step {
		src := (y + step) * s.pitch + area.x * s.bytes_pp
		dst := y * s.pitch + area.x * s.bytes_pp
		span := area.w * s.bytes_pp
		for i in 0 ..< span {
			s.pixels[dst + i] = s.pixels[src + i]
		}
	}

	fb.fill_rect(s, fb.Rect{area.x, area.y + area.h - step, area.w, step}, c.bg)
}
