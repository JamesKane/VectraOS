/*
The boot chassis: the first thing Vectra draws and the visual contract for
everything that follows.

Nothing here is decoration for its own sake. The chassis establishes the four
surface roles the whole system reuses -- brushed plinth, copper trim, recessed
well, indicator lamp -- so that `intuition`'s window frames are recognisably
the same object as the screen the kernel painted before there was a compositor.

Geometry is derived from the framebuffer at runtime; there are no fixed
resolutions.
*/
package kernel

import "kernel:drivers/console"
import "kernel:drivers/fb"

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

Returning the geometry rather than stashing it globally keeps the panic path
able to draw its own chassis over the top without disturbing this one's state.
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
	well_top := c.title.y + c.title.h + PAD
	c.well = fb.Rect{inner.x + PAD, well_top, inner.w - 2 * PAD, c.strip.y - PAD - well_top}
	fb.fill_rect(s, c.well, fb.SLATE)
	fb.bevel_edges(s, c.well, .Recessed, fb.MAGNESIUM_LIT, fb.VOID, WELL_D)

	return c
}

/*
draw_spaced renders `text` with `extra` pixels of tracking between glyphs.

The console's fixed 8px advance is right for a log and wrong for a wordmark;
industrial panels of the era let their lettering breathe.
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

Unlit lamps are drawn as a dark version of their own colour rather than as a
neutral grey, so a bank of lamps still reads as "these three are the same kind
of thing" when none of them are on.
*/
draw_lamp :: proc "contextless" (s: ^fb.Surface, x, y: int, color: fb.RGB, lit: bool) {
	socket := fb.Rect{x, y, LAMP, LAMP}
	fb.fill_rect(s, socket, fb.MAGNESIUM_DARK)
	fb.bevel_edges(s, socket, .Recessed, fb.MAGNESIUM_LIT, fb.VOID, 1)

	jewel := fb.inset_of(socket, 2)
	if lit {
		fb.gradient_v(s, jewel, fb.mix(color, fb.AMBER_HOT, 70), color)
		// A single lit pixel at the top-left sells it as glass.
		fb.put_pixel(s, jewel.x, jewel.y, fb.AMBER_HOT)
	} else {
		fb.fill_rect(s, jewel, fb.mix(color, fb.VOID, 200))
	}
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
