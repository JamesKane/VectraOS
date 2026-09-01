/*
The boot chassis: the first thing Vectra draws and the visual contract for
everything that follows.

Nothing here is decoration for its own sake. The chassis establishes the four
surface roles the whole system reuses. Those are the brushed plinth, the copper
trim, the recessed well, and the indicator lamp.

`intuition`'s window frames are therefore recognisably the same object as the
screen the kernel painted before there was a compositor.

The geometry comes from the framebuffer at runtime. There are no fixed
resolutions.
*/
package kernel

import "kernel:drivers/console"
import "kernel:drivers/fb"
import "vsys:libdraw"

BEZEL      :: 22 // Gap between screen edge and chassis
TITLE_H    :: 30
LAMP       :: 12
PAD        :: 10
CHASSIS_D  :: 2 // Bevel depth of the outer plinth
WELL_D     :: 2 // Bevel depth of the sunken console well

Chassis :: struct {
	frame: fb.Rect, // The plinth
	title: fb.Rect, // Copper bar across its top
	well:  fb.Rect, // Recessed area the console lives in
	strip: fb.Rect, // Indicator row along the bottom
}

/*
draw_chassis paints the full boot screen and returns the sub-rectangles the
caller should render into.

The geometry comes back to the caller, rather than into a global. The panic
path can then draw its own chassis over the top, and disturb none of this one's
state.
*/
draw_chassis :: proc "contextless" (s: ^fb.Surface, title, subtitle: string) -> Chassis {
	// Backdrop: a very dark vertical wash so the plinth reads as lit from above.
	fb.gradient_v(s, fb.Rect{0, 0, s.width, s.height}, fb.SLATE_DEEP, fb.VOID)

	c: Chassis
	c.frame = fb.Rect{BEZEL, BEZEL, s.width - 2 * BEZEL, s.height - 2 * BEZEL}

	// Plinth: brushed face, raised two-pixel bevel, hairline copper keyline.
	fb.brushed(s, c.frame, fb.MAGNESIUM)
	fb.bevel_edges(s, c.frame, .Raised, fb.MAGNESIUM_HOT, fb.MAGNESIUM_DARK, CHASSIS_D)
	fb.outline(s, fb.inset_of(c.frame, CHASSIS_D), fb.COPPER_DARK)

	inner := fb.inset_of(c.frame, CHASSIS_D + 1)

	// -- Title bar: the copper bar ------------------------------------------
	c.title = fb.Rect{inner.x + PAD, inner.y + PAD, inner.w - 2 * PAD, TITLE_H}
	fb.gradient_v(s, c.title, fb.COPPER_LIT, fb.COPPER_DARK)
	fb.bevel_edges(s, c.title, .Raised, fb.mix(fb.COPPER_LIT, fb.AMBER_HOT, 90), fb.COPPER_DARK, 1)

	// Engraved wordmark, letter-spaced the way a silkscreened panel would be.
	ty := c.title.y + (TITLE_H - console.FONT_HEIGHT) / 2
	draw_spaced(s, c.title.x + PAD, ty, title, fb.SLATE_DEEP, 4, .Engraved)

	// Right-aligned build tag, dimmer so it recedes from the wordmark.
	sub_w := len(subtitle) * console.FONT_WIDTH
	console.draw_text_styled(
		s,
		c.title.x + c.title.w - PAD - sub_w,
		ty,
		subtitle,
		fb.mix(fb.COPPER_DARK, fb.VOID, 60),
		.Flat,
	)

	// -- Indicator strip along the bottom -----------------------------------
	c.strip = fb.Rect{inner.x + PAD, inner.y + inner.h - PAD - LAMP, inner.w - 2 * PAD, LAMP}

	// -- Console well: sunken, dark, with an inner shadow line --------------
	//
	// `libdraw.well` is the whole of it, face and edges, and it is the same
	// call `apps/terminal` sinks its field with through a pipe. Three
	// milestones of vocabulary so that this line and that one are one line.
	well_top := c.title.y + c.title.h + PAD
	c.well = fb.Rect{inner.x + PAD, well_top, inner.w - 2 * PAD, c.strip.y - PAD - well_top}
	pieces: [libdraw.MAX_PIECES]fb.Piece
	fb.paint(s, pieces[:libdraw.well(pieces[:], c.well.x, c.well.y, c.well.w, c.well.h, WELL_D)])

	return c
}

/*
draw_spaced renders `text` with `extra` pixels of tracking between glyphs.

The console's fixed 8px advance is right for a log and wrong for a wordmark.
Industrial panels of the era let their lettering breathe.
*/
draw_spaced :: proc "contextless" (
	s: ^fb.Surface,
	px, py: int,
	text: string,
	color: fb.RGB,
	extra: int,
	style: console.Style,
) {
	x := px
	for i in 0 ..< len(text) {
		console.draw_text_styled(s, x, py, string(text[i:i + 1]), color, style)
		x += console.FONT_WIDTH + extra
	}
}

/*
Lamp is one indicator in the bottom strip: a recessed socket with a lit or
unlit jewel in it.

An unlit lamp is a dark version of its own colour, rather than a neutral grey.
A bank of lamps with none of them on therefore still reads as three of the same
kind of thing. That rule is `libdraw.lamp`'s now, and the desktop's lamps obey
it because they are the same call.
*/
draw_lamp :: proc "contextless" (s: ^fb.Surface, x, y: int, color: fb.RGB, lit: bool) {
	pieces: [libdraw.MAX_PIECES]fb.Piece
	fb.paint(s, pieces[:libdraw.lamp(pieces[:], x, y, LAMP, color, lit)])
	if !lit {
		return
	}

	// A lit jewel is the one place the chassis has more than the vocabulary
	// can carry, so it paints the extra over the rectangle rather than instead
	// of it. A gradient is a colour per row and the specular corner is one
	// pixel, and a `Piece` is neither. `intuition`'s lamps are flat for that
	// reason, and are otherwise this lamp exactly.
	jewel := fb.inset_of(fb.Rect{x, y, LAMP, LAMP}, 2)
	fb.gradient_v(s, jewel, fb.mix(color, fb.AMBER_HOT, 70), color)
	// A single lit pixel at the top-left sells it as glass.
	fb.put_pixel(s, jewel.x, jewel.y, fb.AMBER_HOT)
}

// draw_lamp_row lays a labelled bank of lamps along the indicator strip.
draw_lamp_row :: proc "contextless" (s: ^fb.Surface, strip: fb.Rect, labels: []string, colors: []fb.RGB, lit: []bool) {
	x := strip.x
	ty := strip.y + (LAMP - console.FONT_HEIGHT) / 2
	for i in 0 ..< len(labels) {
		draw_lamp(s, x, strip.y, colors[i], lit[i])
		x += LAMP + 5
		console.draw_text_styled(s, x, ty, labels[i], lit[i] ? colors[i] : fb.MAGNESIUM_LIT, .Embossed)
		x += len(labels[i]) * console.FONT_WIDTH + PAD + 6
	}
}
