/*
The overview: every workspace at once, Mission Control's picture.

`docs/WORKBENCH.md` section 4. A chord opens it, and the server paints
the glass with a tile per workspace, three by three, over a dimmed
ground. Each tile is that workspace's windows scaled down from their own
stores, frames and titles and all. No program takes part, and none is
asked to redraw. A click on a tile switches to it, and a click on a
window inside a tile switches to that workspace and raises the window.
The chord again, or a click on nothing, returns.

Scaling
is by an integer, `OVERVIEW_SCALE`: a row and a column skipped rather
than a filter. That is what lets the compositor do it out of the stores
it already holds. A smoother picture is a day's work the
day someone minds.
*/
package intuition

import "vsys:libpal"

OVERVIEW_SCALE :: 3
OVERVIEW_GRID :: 3 // Three by three tiles, for nine workspaces

overview_on: bool

DIM :: u32(libpal.VOID[0]) << 16 | u32(libpal.VOID[1]) << 8 | u32(libpal.VOID[2])

// overview_toggle opens the picture or closes it back to the current
// workspace.
overview_toggle :: proc "contextless" () {
	if overview_on {
		overview_close()
	} else {
		overview_open()
	}
}

overview_open :: proc "contextless" () #no_bounds_check {
	overview_on = true
	ov_win = -1
	ov_from = -1
	// A dimmed ground under the tiles, so the picture reads as apart from
	// the desktop.
	for y in 0 ..< scr_h {
		dst := screen_at(y)
		for x in 0 ..< scr_w {
			dst[x] = DIM
		}
	}
	for ws in 1 ..= WORKSPACES {
		overview_tile(ws)
	}
}

overview_close :: proc "contextless" () {
	overview_on = false
	desk_paint(0, 0, scr_w, scr_h)
	repaint(0, 0, scr_w, scr_h)
}

// tile_rect is where workspace `ws`'s tile sits on the glass: its cell in
// the grid, scaled from the screen.
tile_rect :: proc "contextless" (ws: int) -> (x: int, y: int, w: int, h: int) {
	col := (ws - 1) % OVERVIEW_GRID
	row := (ws - 1) / OVERVIEW_GRID
	tw := scr_w / OVERVIEW_SCALE
	th := scr_h / OVERVIEW_SCALE
	gap := tw / 16
	cw := (scr_w - (OVERVIEW_GRID + 1) * gap) / OVERVIEW_GRID
	ch := (scr_h - (OVERVIEW_GRID + 1) * gap) / OVERVIEW_GRID
	_ = tw
	_ = th
	return gap + col * (cw + gap), gap + row * (ch + gap), cw, ch
}

/*
overview_tile paints one workspace's windows into its cell, scaled down.

The cell is a third of the screen, so a window scaled by three lands at a
third of its screen place inside it. The current workspace's cell wears
the copper edge, so the picture says which one you are on.
*/
overview_tile :: proc "contextless" (ws: int) #no_bounds_check {
	tx, ty, tw, th := tile_rect(ws)
	// The cell's own ground, so an empty workspace is a panel rather than a
	// hole in the dim.
	for y in 0 ..< th {
		dst := screen_at(ty + y)
		for x in 0 ..< tw {
			dst[tx + x] = desk_ground
		}
	}
	// Every window on this workspace, back to front, scaled into the cell.
	for si in 0 ..< stack_n {
		win := &windows[stack[si]]
		if !win.used || win.workspace != ws || win.hidden {
			continue
		}
		overview_window(win, tx, ty, tw, th)
	}
	// The current workspace's cell is lit at its edge.
	edge := ws == current_ws ? libpal.COPPER : libpal.MAGNESIUM_DARK
	word := libpal.xrgb(edge)
	for x in 0 ..< tw {
		screen_at(ty)[tx + x] = word
		screen_at(ty + th - 1)[tx + x] = word
	}
	for y in 0 ..< th {
		screen_at(ty + y)[tx] = word
		screen_at(ty + y)[tx + tw - 1] = word
	}
}

// overview_window scales one window's store into a cell. The window's
// screen place divided by the scale is where it goes, and every third
// pixel is the one kept.
overview_window :: proc "contextless" (win: ^Window, tx: int, ty: int, tw: int, th: int) #no_bounds_check {
	dx0 := win.x / OVERVIEW_SCALE
	dy0 := win.y / OVERVIEW_SCALE
	dw := win.w / OVERVIEW_SCALE
	dh := win.h / OVERVIEW_SCALE
	for row in 0 ..< dh {
		sy := row * OVERVIEW_SCALE
		gy := ty + dy0 + row
		if gy < ty || gy >= ty + th {
			continue
		}
		dst := screen_at(gy)
		src := win.pixels[sy * win.stride:]
		for col in 0 ..< dw {
			gx := tx + dx0 + col
			if gx < tx || gx >= tx + tw {
				continue
			}
			dst[gx] = src[col * OVERVIEW_SCALE]
		}
	}
}

// A drag in the picture: the window a press landed on, and the workspace whose
// tile it was in. A release on another tile moves the window there. Reset when
// the picture opens and after each release, so a release never reads a stale
// window slot.
ov_win: int
ov_from: int

// overview_press begins a press in the picture: which tile it is in, and which
// window inside it, if any.
overview_press :: proc "contextless" (x: int, y: int) {
	ov_from = overview_tile_at(x, y)
	ov_win = ov_from >= 1 ? overview_window_at(ov_from, x, y) : -1
}

/*
overview_release ends the press, `docs/WORKBENCH.md`'s two gestures in one.

A window dragged onto another tile moves to that workspace, and the picture
stays up so the move is seen -- the drag between workspaces. A press and
release in one tile is a click: that workspace comes to the front, the window
under the press raised if there was one. A release on no tile closes the
picture.
*/
overview_release :: proc "contextless" (x: int, y: int) #no_bounds_check {
	to := overview_tile_at(x, y)
	win := ov_win
	from := ov_from
	ov_win = -1
	ov_from = -1
	if win >= 0 {
		if to >= 1 && to != from {
			// The move is the workspace field and two tiles repainted; the
			// focus and the lamps settle when the picture closes and the whole
			// glass is laid out again. No desktop repaint, which would paint
			// the real windows over the picture.
			windows[win].workspace = to
			overview_tile(from)
			overview_tile(to)
			return
		}
		if to == from {
			window_raise(&windows[win], win)
			overview_on = false
			current_ws = 0
			workspace_switch(to)
			return
		}
		return // a window dragged onto nothing: cancelled, the picture stays
	}
	if to >= 1 {
		overview_on = false
		current_ws = 0 // Force the switch to repaint.
		workspace_switch(to)
		return
	}
	overview_close()
}

// overview_tile_at is the workspace whose tile holds a screen point, or -1.
overview_tile_at :: proc "contextless" (x: int, y: int) -> int #no_bounds_check {
	for ws in 1 ..= WORKSPACES {
		tx, ty, tw, th := tile_rect(ws)
		if x >= tx && x < tx + tw && y >= ty && y < ty + th {
			return ws
		}
	}
	return -1
}

// overview_window_at maps a point in workspace `ws`'s tile back to the window
// under it -- the point times the scale is where it is in the workspace -- the
// topmost on that workspace, or -1. A bar or a backdrop is not dragged between
// workspaces; a window is.
overview_window_at :: proc "contextless" (ws: int, x: int, y: int) -> int #no_bounds_check {
	tx, ty, _, _ := tile_rect(ws)
	wx := (x - tx) * OVERVIEW_SCALE
	wy := (y - ty) * OVERVIEW_SCALE
	for si := stack_n - 1; si >= 0; si -= 1 {
		w := stack[si]
		win := &windows[w]
		if !win.used || win.workspace != ws || win.hidden || win.kind != .Normal {
			continue
		}
		if wx >= win.x && wx < win.x + win.w && wy >= win.y && wy < win.y + win.h {
			return w
		}
	}
	return -1
}
