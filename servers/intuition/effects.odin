/*
effects -- the frame's look past the chassis, and the chrome outside a window.

Two halves, `docs/CHROME.md` section 7 and `docs/DRAW.md` section 19.

**Inside the frame, a metal bar.** With `frame.style metal` every title bar is
brushed metal, `bar` at its top to `bar.shade` at its foot, with two hairline
patterns over it. The front window's bar has a line of `focus` along its
bottom. Its title is in `text` with a faint `focus` glow behind the letters. Every other title is `dim`.

So the active window says so with light, not with a colour of bar. These are pixels in the window's own store, painted
with `sys/libraster` the way a client paints.

**Outside every window, a halo and a shadow.** The halo is `focus` round the
front window, as strong as the theme's `glow`. The shadow is a dark ramp under
every framed window, `shadow` pixels wide, set down and to the right. Neither
is in any window's store. They are blended onto the glass when a composite
reaches them, which is why only the compositor may draw them.

**A composite that reaches a margin is laid from the ground up.** A blend onto
a pixel already blended would brighten it each time, and the glass keeps what
it is given. So an area that touches a window's margin gets the desktop laid
first. Every window goes over it in order, each one's effects just before its
pixels. An area that touches no margin keeps the fast path: windows only, over
the ground already there.
*/
package intuition

import "vsys:libdraw"
import "vsys:libfont"
import "vsys:libpal"
import "vsys:libraster"

// The halo's reach at full `glow`, and the shadow's greatest width.
HALO_R :: 16
SHADOW_MAX :: 12
// How far down and right the shadow falls.
SHADOW_OFF :: 3

// Alpha by squared distance from the window's edge, made once per theme.
@(private = "file") halo_ramp: [HALO_R * HALO_R + 1]u8
@(private = "file") shadow_ramp: [SHADOW_MAX * SHADOW_MAX + 1]u8

// effects_prepare makes the two ramps for the theme just read. Each falls off
// as the square of the distance, so the edge of a glow is soft.
effects_prepare :: proc "contextless" () #no_bounds_check {
	for d2 in 0 ..= HALO_R * HALO_R {
		d := isqrt(d2)
		f := max(HALO_R - d, 0)
		halo_ramp[d2] = u8(th_glow * 150 / 100 * f * f / (HALO_R * HALO_R))
	}
	s := max(th_shadow, 1)
	for d2 in 0 ..= SHADOW_MAX * SHADOW_MAX {
		d := isqrt(d2)
		f := max(s - d, 0)
		shadow_ramp[d2] = th_shadow > 0 ? u8(110 * f * f / (s * s)) : 0
	}
}

@(private = "file")
isqrt :: proc "contextless" (v: int) -> int {
	r := 0
	for (r + 1) * (r + 1) <= v {
		r += 1
	}
	return r
}

// effect_margin is how far past a framed window its effects reach.
effect_margin :: proc "contextless" () -> int {
	m := 0
	if th_glow > 0 {
		m = HALO_R
	}
	if th_shadow > 0 {
		m = max(m, th_shadow + SHADOW_OFF)
	}
	return m
}

// effects_on is whether a composite may have margins to lay.
effects_on :: proc "contextless" () -> bool {
	return (th_glow > 0 || th_shadow > 0) && !locked
}

// shown is a framed window on the glass now: the only kind with effects.
@(private = "file")
shown :: proc "contextless" (win: ^Window) -> bool {
	return win.used && framed(win) && win.workspace == current_ws && !win.hidden
}

/*
margins_touch says whether a composite's area reaches any window's margin: a
part of the area inside some window's extent and not wholly inside the window.
Only then is the area laid from the ground up.
*/
margins_touch :: proc "contextless" (area: ^Region) -> bool #no_bounds_check {
	m := effect_margin()
	for si in 0 ..< stack_n {
		win := &windows[stack[si]]
		if !shown(win) {
			continue
		}
		for ai in 0 ..< area.n {
			a := area.rects[ai]
			if a.x1 <= win.x - m || a.x0 >= win.x + win.w + m || a.y1 <= win.y - m || a.y0 >= win.y + win.h + m {
				continue
			}
			inside := a.x0 >= win.x && a.x1 <= win.x + win.w && a.y0 >= win.y && a.y1 <= win.y + win.h
			if !inside {
				return true
			}
		}
	}
	return false
}

/*
paint_effects blends one window's shadow onto the glass inside `area`, and its
halo when it is in front. It paints nothing inside the window itself, which is
the window's to paint next. The distance from the window's edge is a square
and a table, per pixel of the margin only.
*/
paint_effects :: proc "contextless" (win: ^Window, area: ^Region) #no_bounds_check {
	if !shown(win) {
		return
	}
	halo := th_glow > 0 && focused(win)
	shade := th_shadow > 0
	if !halo && !shade {
		return
	}
	m := effect_margin()
	focus := pack_rgb(th_focus)
	for ai in 0 ..< area.n {
		a := area.rects[ai]
		x0 := max(max(a.x0, win.x - m), 0)
		y0 := max(max(a.y0, win.y - m), 0)
		x1 := min(min(a.x1, win.x + win.w + m), scr_w)
		y1 := min(min(a.y1, win.y + win.h + m), scr_h)
		for y in y0 ..< y1 {
			dst := screen_at(y)
			in_rows := y >= win.y && y < win.y + win.h
			for x in x0 ..< x1 {
				if in_rows && x >= win.x && x < win.x + win.w {
					continue
				}
				v := dst[x]
				if shade {
					sx, sy := win.x + SHADOW_OFF, win.y + SHADOW_OFF
					dx := max(sx - x, 0, x - (sx + win.w - 1))
					dy := max(sy - y, 0, y - (sy + win.h - 1))
					if d2 := dx * dx + dy * dy; d2 <= th_shadow * th_shadow {
						v = libraster.blend(v, 0, u32(shadow_ramp[d2]))
					}
				}
				if halo {
					dx := max(win.x - x, 0, x - (win.x + win.w - 1))
					dy := max(win.y - y, 0, y - (win.y + win.h - 1))
					if d2 := dx * dx + dy * dy; d2 <= HALO_R * HALO_R {
						v = libraster.blend(v, focus, u32(halo_ramp[d2]))
					}
				}
				dst[x] = v
			}
		}
	}
}

// repaint_window repaints a window's rectangle and, with effects on, its
// margin: what a move, a resize, a close and a change of focus all touch.
repaint_window :: proc "contextless" (x: int, y: int, w: int, h: int) {
	m := effects_on() ? effect_margin() : 0
	// The ground under the whole extent first. A window that closed or moved
	// off leaves no margin to set the ground-up pass going, and its old halo
	// would stand on the glass.
	if m > 0 {
		desk_paint(x - m, y - m, x + w + m, y + h + m)
	}
	repaint(x - m, y - m, w + 2 * m, h + 2 * m)
}

@(private = "file")
pack_rgb :: proc "contextless" (c: libpal.RGB) -> u32 {
	return u32(c[0]) << 16 | u32(c[1]) << 8 | u32(c[2])
}

// -- The metal bar --------------------------------------------------------------

/*
bar_dress finishes a bar the frame's pieces laid down. The chassis's bar gets
its name in the 8x16 cells. With `frame.style metal` it gets the whole metal
bar, its gadgets over it, the focus line, and the title in the chrome face. `window_chrome` and
`title_paint` both end here, so an open, a rename and a change of focus dress
the bar the same way.
*/
bar_dress :: proc "contextless" (win: ^Window) #no_bounds_check {
	if !th_frame_metal || !framed(win) {
		title_text(win)
		return
	}
	bx, by, bw, bh := frame_bar_at(0, 0, win.w)
	c := libraster.canvas(win.pixels, win.stride, win.w, win.h)
	libraster.vgrad(&c, bx, by, bw, bh, pack_rgb(th_bar), pack_rgb(th_bar_shade))
	libraster.hairline(&c, bx, by, bw, bh, 3, 0xFFFFFF, 9, true)
	libraster.hairline(&c, bx + 1, by, bw, bh, 7, 0x000000, 15, true)

	// The gadgets over the metal, the study's keys, and the state lamp.
	probe := Window{w = win.w, h = win.h}
	for g in libdraw.Gadget {
		if g == .Size || !has_gadget(win.kind, g) {
			continue
		}
		gx, gy, gs := gadget_at(&probe, g)
		metal_gadget(&c, gx, gy, gs, g)
	}
	pieces: [MAX_FRAME_PIECES]libdraw.Piece
	n := state_lamp(pieces[:], win)
	win_pieces(win, pieces[:n])

	front := focused(win)
	if front {
		libraster.fill(&c, bx, by + bh - 1, bw, 1, pack_rgb(th_focus))
	}
	title_face(win, &c, front)
}

/*
metal_gadget draws one of a metal bar's gadgets as the study draws it. It is a
raised key, the scheme's `raised` a little lit at the top and graded down to
itself, with a one-pixel bevel. A twelve-pixel glyph in `text` sits on it.

The glyphs keep Intuition's meanings. Close is a square with a dot in it. Zoom is a
square with a small one in its corner. Depth is two squares, the front one
solid over the back one's corner.
*/
@(private = "file")
metal_gadget :: proc "contextless" (c: ^libraster.Canvas, x: int, y: int, size: int, g: libdraw.Gadget) {
	raised := pack_rgb(th_raised)
	libraster.vgrad(c, x, y, size, size, libraster.mix(raised, 0xFFFFFF, 36), raised)
	libraster.bevel(c, x, y, size, size, 1, pack_rgb(th_plinth_lit), pack_rgb(th_plinth_shade))
	ink := pack_rgb(th_text)
	gx := x + (size - 12) / 2
	gy := y + (size - 12) / 2
	switch g {
	case .Close:
		outline(c, gx, gy, 12, 12, ink, 191)
		libraster.fill(c, gx + 4, gy + 4, 4, 4, ink)
	case .Zoom:
		outline(c, gx, gy, 12, 12, ink, 191)
		outline(c, gx + 2, gy + 2, 6, 6, ink, 255)
	case .Depth:
		outline(c, gx, gy, 8, 8, ink, 191)
		libraster.fill(c, gx + 4, gy + 4, 8, 8, 0)
		libraster.fill(c, gx + 5, gy + 5, 6, 6, ink)
	case .Size:
	}
}

// outline is a rectangle's one-pixel border in a colour at alpha `a`.
@(private = "file")
outline :: proc "contextless" (c: ^libraster.Canvas, x: int, y: int, w: int, h: int, color: u32, a: u32) {
	libraster.tint(c, x, y, w, 1, color, a)
	libraster.tint(c, x, y + h - 1, w, 1, color, a)
	libraster.tint(c, x, y + 1, 1, h - 2, color, a)
	libraster.tint(c, x + w - 1, y + 1, 1, h - 2, color, a)
}

/*
title_face draws the name in the chrome face across a metal bar. It runs from
the close gadget to the two at the right, centred on the bar's height. The front
window's title is `text` over a faint `focus` glow, four copies of the name a
pixel out. Every other title is `dim` with none. With no chrome face the
name is in the 8x16 cells.
*/
@(private = "file")
title_face :: proc "contextless" (win: ^Window, c: ^libraster.Canvas, front: bool) #no_bounds_check {
	bx, by, bw, bh := frame_bar_at(0, 0, win.w)
	tx := bx + FRAME_PAD + gadget_size() + 2
	if win.state != .Idle {
		tx += STATE_LAMP_GAP
	}
	right := bx + bw - FRAME_PAD - 2 * gadget_size() - 4
	ink := pack_rgb(front ? th_text : th_dim)
	if !th_chrome.ready {
		title_text(win, ink)
		return
	}
	// A canvas that ends at `right`, so a long name is cut there.
	clip := libraster.canvas(c.pix, c.stride, max(right, 0), c.h)
	base := by + (bh - th_chrome.height) / 2 + th_chrome.ascent
	name := string(win.title[:win.title_n])
	if front && th_glow > 0 {
		glow := pack_rgb(th_focus)
		offs := [4][2]int{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}
		for o in offs {
			chrome_line(&clip, tx + o[0], base + o[1], name, glow, 60)
		}
	}
	chrome_line(&clip, tx, base, name, ink, 255)
}

// chrome_line lays a string in the chrome face on a baseline, each glyph's
// coverage scaled by `alpha`, with the theme's capitals and tracking.
@(private = "file")
chrome_line :: proc "contextless" (c: ^libraster.Canvas, x: int, base: int, s: string, ink: u32, alpha: int) #no_bounds_check {
	space, _ := libfont.face_glyph(&th_chrome, ' ')
	pen := x
	scaled: [64 * 32]u8
	for r in s {
		ch := th_chrome_caps ? libfont.upper(r) : r
		g, ok := libfont.face_glyph(&th_chrome, ch)
		if !ok {
			pen += space.advance + th_chrome_track
			continue
		}
		if g.w > 0 && g.w * g.h <= len(scaled) {
			mask := g.mask
			if alpha < 255 {
				for i in 0 ..< g.w * g.h {
					scaled[i] = u8(int(g.mask[i]) * alpha / 255)
				}
				mask = scaled[:g.w * g.h]
			}
			libraster.coverage(c, pen + g.left, base - g.top, mask, g.w, g.h, ink)
		}
		pen += g.advance + th_chrome_track
	}
}
