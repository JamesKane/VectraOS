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
			dst[tx + x] = DESK_GROUND
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

/*
overview_click is a press while the picture is up: the tile it landed in
becomes the current workspace, and the picture closes. A press in no tile
closes it and stays.
*/
overview_click :: proc "contextless" (x: int, y: int) #no_bounds_check {
	for ws in 1 ..= WORKSPACES {
		tx, ty, tw, th := tile_rect(ws)
		if x >= tx && x < tx + tw && y >= ty && y < ty + th {
			overview_on = false
			current_ws = 0 // Force the switch to repaint.
			workspace_switch(ws)
			return
		}
	}
	overview_close()
}
