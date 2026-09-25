/*
widgets -- the classes the preferences draw, `docs/CHROME.md` section 9.

    Cycle      a key with the arrow segment on its left: a click takes the
               next of its choices, `rows`, and `sel` is the one shown
    Knob       a disc turned by a vertical drag: `sel` is the value, from
               `lo` to `hi`
    PageList   a list of pages on its left, `rows`. The page `sel` names
               is laid out and drawn at its right. Its children are the
               pages, one for each row.
    Scroller   a track across with a thumb, for a row of more than fits:
               `hi` things, `cells` of them shown, `sel` the first shown.
               A drag moves the thumb, and a press off it jumps there.
    titled     a Group with a `label`. A frame line runs round it. Its
               title is set into the top of the frame in the chrome face,
               as a `fieldset`'s legend is.

Each is a class the layout knows. A program builds a page of them as it builds
any tree. It hears a change through its handler with the gadget's `id`, as
for a button. A scroller is heard as it moves, not only at the release.
*/
package libmui

import "vsys:libraster"

CYCLE_SEG :: 18
KNOB_SIZE :: 36
// How many pixels of drag move a knob one step.
KNOB_STEP :: 4
// A titled group's frame: the space inside the line at the sides and foot.
FRAME_SIDE :: 6
// A scroller's height, and the shortest its thumb gets.
SCROLL_H :: 14
SCROLL_THUMB_MIN :: 12

// cycle is a key that steps through `choices`, the first shown.
cycle :: proc "contextless" (choices: []string) -> ^Object {
	o := obj(.Cycle)
	if o != nil {
		o.rows = choices
		o.sel = 0
	}
	return o
}

// knob is a disc for a value from `lo` to `hi`, at `value`.
knob :: proc "contextless" (lo: int, hi: int, value: int) -> ^Object {
	o := obj(.Knob)
	if o != nil {
		o.lo, o.hi = lo, hi
		o.sel = clamp(value, lo, hi)
	}
	return o
}

// page_list is a list of pages, `names`, one for each child the caller adds.
page_list :: proc "contextless" (names: []string) -> ^Object {
	o := obj(.PageList)
	if o != nil {
		o.rows = names
		o.sel = 0
	}
	return o
}

// scroller is a track for `total` things, `shown` of them at once, from `first`.
scroller :: proc "contextless" (total: int, shown: int, first: int) -> ^Object {
	o := obj(.Scroller)
	if o != nil {
		scroller_set(o, total, shown, first)
	}
	return o
}

// scroller_set gives a scroller new numbers, the first kept in range.
scroller_set :: proc "contextless" (o: ^Object, total: int, shown: int, first: int) {
	o.hi = max(total, 1)
	o.cells = clamp(shown, 1, o.hi)
	o.sel = clamp(first, 0, o.hi - o.cells)
}

// titled is a group of children with a frame line and `title` set into it.
titled :: proc "contextless" (title: string, horiz: bool) -> ^Object {
	o := group(horiz)
	if o != nil {
		o.label = title
	}
	return o
}

// -- Sizes ------------------------------------------------------------------------

// widget_fit is `fit` for the classes here. False for a class it does not know.
widget_fit :: proc "contextless" (o: ^Object, t: ^Theme) -> bool {
	#partial switch o.class {
	case .Cycle:
		w := 0
		for c in o.rows {
			w = max(w, text_width(t, .Interface, c))
		}
		o.minw = w + CYCLE_SEG + 2 * t.hpad + 2 * t.bevel
		o.minh = max(text_height(t, .Interface), FONT_H) + 2 * t.vpad + 2 * t.bevel
		o.maxw, o.maxh = o.minw, o.minh
		return true
	case .Knob:
		o.minw, o.maxw = KNOB_SIZE, KNOB_SIZE
		o.minh, o.maxh = KNOB_SIZE, KNOB_SIZE
		return true
	case .PageList:
		lw := page_list_width(o, t)
		pw, ph := 0, len(o.rows) * page_row(t) + 2 * t.well
		for c := o.first; c != nil; c = c.next {
			fit(c, t)
			pw = max(pw, c.minw)
			ph = max(ph, c.minh)
		}
		o.minw, o.minh = lw + t.gap + pw, ph
		o.maxw, o.maxh = BIG, BIG
		return true
	case .Scroller:
		o.minw, o.maxw = 4 * SCROLL_THUMB_MIN, BIG
		o.minh, o.maxh = SCROLL_H, SCROLL_H
		return true
	}
	return false
}

/*
scroller_thumb is where a laid scroller's thumb is: its left and width, in a
track that is the well's inside. The thumb is as wide as the part shown is of
the whole, and no narrower than a finger's worth.
*/
scroller_thumb :: proc "contextless" (o: ^Object, t: ^Theme) -> (x: int, w: int) {
	track := max(o.w - 2 * t.well, 1)
	w = clamp(track * o.cells / max(o.hi, 1), min(SCROLL_THUMB_MIN, track), track)
	span := o.hi - o.cells
	x = o.x + t.well
	if span > 0 {
		x += (track - w) * o.sel / span
	}
	return
}

// scroller_step is how many things a move of `dx` pixels of the thumb is.
scroller_step :: proc "contextless" (o: ^Object, dx: int, t: ^Theme) -> int {
	_, w := scroller_thumb(o, t)
	free := max(o.w - 2 * t.well - w, 1)
	span := o.hi - o.cells
	d := abs(dx) * span + free / 2
	return dx < 0 ? -(d / free) : d / free
}

// legend_top is the room a titled group keeps above its children, for its
// title. It is zero for a group with none.
legend_top :: proc "contextless" (o: ^Object, t: ^Theme) -> int {
	if o.label == "" {
		return 0
	}
	return text_height(t, .Chrome) + 2
}

// legend_side is the room a titled group keeps at its sides and foot.
legend_side :: proc "contextless" (o: ^Object) -> int {
	return o.label == "" ? 0 : FRAME_SIDE
}

page_row :: proc "contextless" (t: ^Theme) -> int {
	return max(text_height(t, .Interface), FONT_H) + 6
}

page_list_width :: proc "contextless" (o: ^Object, t: ^Theme) -> int {
	w := 0
	for r in o.rows {
		w = max(w, text_width(t, .Interface, r))
	}
	return w + 2 * t.hpad + 2 * t.well
}

// page_list_lay lays the page `sel` names at the list's right and gives the
// others no room, so nothing hits or draws them.
page_list_lay :: proc "contextless" (o: ^Object, t: ^Theme) {
	lw := page_list_width(o, t)
	i := 0
	for c := o.first; c != nil; c = c.next {
		if i == o.sel {
			lay(c, o.x + lw + t.gap, o.y, max(o.w - lw - t.gap, 0), o.h, t)
		} else {
			lay(c, 0, 0, 0, 0, t)
		}
		i += 1
	}
}

// page_list_row is the row under a point, or -1 off the list.
page_list_row :: proc "contextless" (o: ^Object, x: int, y: int, t: ^Theme) -> int {
	if x < o.x || x >= o.x + page_list_width(o, t) {
		return -1
	}
	row := (y - o.y - t.well) / page_row(t)
	if y < o.y + t.well || row < 0 || row >= len(o.rows) {
		return -1
	}
	return row
}

// -- Drawing ------------------------------------------------------------------------

// widget_paint is `paint_node` for the classes here.
widget_paint :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, t: ^Theme) {
	#partial switch o.class {
	case .Cycle:
		cycle_paint(c, o, t)
	case .Knob:
		knob_paint(c, o, t)
	case .PageList:
		page_list_paint(c, o, t)
	case .Scroller:
		scroller_paint(c, o, t)
	case .Group:
		if o.label != "" {
			legend_paint(c, o, t)
		}
	}
}

/*
cycle_paint draws a cycle. It is a raised key, with its left segment cut off
by a groove and a small arrow in it. The choice shows in the rest.
*/
cycle_paint :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, t: ^Theme) {
	raised(c, o, t)
	sx := o.x + t.bevel + CYCLE_SEG
	libraster.fill(c, sx, o.y + t.bevel, 1, o.h - 2 * t.bevel, px(t.shade))
	libraster.fill(c, sx + 1, o.y + t.bevel, 1, o.h - 2 * t.bevel, px(t.lit))
	// The arrow: a small triangle pointing down, the choice rolling under.
	S :: libraster.SUB
	ax, ay := o.x + t.bevel + CYCLE_SEG / 2, o.y + o.h / 2
	tri := [3]libraster.Point{{(ax - 4) * S, (ay - 2) * S}, {(ax + 4) * S, (ay - 2) * S}, {ax * S, (ay + 3) * S}}
	ends := [1]int{3}
	@(static) scratch: [2048]u32
	if c.w <= len(scratch) {
		libraster.path(c, tri[:], ends[:], px(t.ink), scratch[:])
	}
	if o.sel >= 0 && o.sel < len(o.rows) {
		label := o.rows[o.sel]
		lw := text_width(t, .Interface, label)
		lx := sx + 2 + (o.x + o.w - t.bevel - sx - 2 - lw) / 2
		ly := o.y + (o.h - text_height(t, .Interface)) / 2
		face_text(c, t, .Interface, lx, ly, label, px(t.ink))
	}
}

/*
knob_paint draws a knob: a disc lit from the top left, a groove round it, and
a mark from its centre toward its value. The mark sweeps three quarters of a
turn, from the bottom left at `lo` to the bottom right at `hi`.
*/
knob_paint :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, t: ^Theme) {
	r := min(o.w, o.h) / 2
	cx, cy := o.x + o.w / 2, o.y + o.h / 2
	libraster.radial(c, cx, cy, r, px(t.shade), px(t.shade))
	libraster.radial(c, cx - 1, cy - 1, r - 2, px(t.lit), px(t.face))
	if !knob_dirs_ready {
		knob_dirs_fill()
	}
	span := max(o.hi - o.lo, 1)
	// A step of the sweep's 270 degrees, ten degrees each.
	step := clamp((o.sel - o.lo) * 27 / span, 0, 27)
	dx, dy := knob_dirs[step][0], knob_dirs[step][1]
	for k in 3 ..< r - 3 {
		libraster.fill(c, cx + dx * k / 1000, cy + dy * k / 1000, 2, 2, px(t.focus))
	}
}

// The knob's mark: 28 directions, ten degrees apart. They start at 225
// degrees, the bottom left, and turn clockwise through the top. Each is x
// and y in thousandths, with y down. Filled at the first paint, by `knob_dirs_fill`.
@(private = "file")
knob_dirs: [28][2]int
@(private = "file")
knob_dirs_ready: bool

// knob_dirs_fill rotates one vector by ten degrees at a time, in millionths:
// no table of sines to get wrong, and nothing that needs a float.
@(private = "file")
knob_dirs_fill :: proc "contextless" () {
	C :: 984808 // cos 10 degrees
	S :: 173648 // sin 10 degrees
	x, y := -707107, 707107 // bottom left, y down
	for i in 0 ..< 28 {
		knob_dirs[i] = {x / 1000, y / 1000}
		// With y down, this turn is clockwise on the glass.
		x, y = (x * C - y * S) / 1000000, (x * S + y * C) / 1000000
	}
	knob_dirs_ready = true
}

// page_list_paint draws a page list: a well of the page names, the chosen on
// a bar of the face. The page itself is a child, drawn after.
page_list_paint :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, t: ^Theme) {
	lw := page_list_width(o, t)
	well(c, o.x, o.y, lw, o.h, t)
	row := page_row(t)
	for name, i in o.rows {
		y := o.y + t.well + i * row
		if y + row > o.y + o.h - t.well {
			break
		}
		if i == o.sel {
			libraster.fill(c, o.x + t.well, y, lw - 2 * t.well, row, px(t.face))
		}
		face_text(c, t, .Interface, o.x + t.well + t.hpad, y + (row - text_height(t, .Interface)) / 2, name, px(i == o.sel ? t.hot : t.ink))
	}
}

// scroller_paint draws a scroller: a well, and the thumb a raised key in it.
scroller_paint :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, t: ^Theme) {
	well(c, o.x, o.y, o.w, o.h, t)
	tx, tw := scroller_thumb(o, t)
	th := o.h - 2 * t.well
	libraster.fill(c, tx, o.y + t.well, tw, th, px(t.face))
	libraster.fill(c, tx, o.y + t.well, tw, 1, px(t.lit))
	libraster.fill(c, tx, o.y + t.well, 1, th, px(t.lit))
	libraster.fill(c, tx, o.y + t.well + th - 1, tw, 1, px(t.shade))
	libraster.fill(c, tx + tw - 1, o.y + t.well, 1, th, px(t.shade))
	// A grip at the thumb's middle, three grooves, so it reads as a thing to move.
	mx := tx + tw / 2
	for k in -1 ..= 1 {
		libraster.fill(c, mx + 3 * k, o.y + t.well + 3, 1, max(th - 6, 1), px(t.shade))
	}
}

/*
legend_paint draws a titled group's frame. A groove runs round it, a shade
line and a lit one, from half way down the title. The title is in the chrome
face in `dim`, centred, on the ground it clears in the line.
*/
legend_paint :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, t: ^Theme) {
	th := text_height(t, .Chrome)
	top := o.y + th / 2
	x0, x1 := o.x + 1, o.x + o.w - 2
	y1 := o.y + o.h - 2
	groove :: proc "contextless" (c: ^libraster.Canvas, x0: int, y0: int, x1: int, y1: int, dark: u32, light: u32) {
		libraster.fill(c, x0, y0, x1 - x0, 1, dark)
		libraster.fill(c, x0, y1, x1 - x0 + 1, 1, dark)
		libraster.fill(c, x0, y0, 1, y1 - y0, dark)
		libraster.fill(c, x1, y0, 1, y1 - y0 + 1, dark)
		libraster.fill(c, x0 + 1, y0 + 1, x1 - x0 - 1, 1, light)
		libraster.fill(c, x0 + 1, y1 + 1, x1 - x0 + 1, 1, light)
		libraster.fill(c, x0 + 1, y0 + 1, 1, y1 - y0 - 1, light)
		libraster.fill(c, x1 + 1, y0, 1, y1 - y0 + 2, light)
	}
	groove(c, x0, top, x1, y1, px(t.shade), px(t.lit))
	tw := text_width(t, .Chrome, o.label)
	tx := o.x + (o.w - tw) / 2
	libraster.fill(c, tx - 4, o.y, tw + 8, th + 1, px(t.ground))
	face_text(c, t, .Chrome, tx, o.y, o.label, px(t.dim))
}

// -- Events -------------------------------------------------------------------------

// widget_press is a press on one of the classes here, before the release.
// A page list's row is chosen at once. A press on a scroller off its thumb
// takes the thumb there. True when the press changed the gadget.
widget_press :: proc "contextless" (win: ^Window, o: ^Object, x: int, y: int) -> bool {
	#partial switch o.class {
	case .Scroller:
		was := o.sel
		tx, tw := scroller_thumb(o, &win.theme)
		if x < tx || x >= tx + tw {
			o.sel = clamp(o.sel + scroller_step(o, x - (tx + tw / 2), &win.theme), 0, o.hi - o.cells)
		}
		win.press_value = o.sel
		win.press_x = x
		return o.sel != was
	case .PageList:
		if row := page_list_row(o, x, y, &win.theme); row >= 0 && row != o.sel {
			o.sel = row
			page_list_lay(o, &win.theme)
		}
	case .Knob:
		win.press_value = o.sel
	}
	return false
}

// widget_drag is the pointer moving with the button down over a press. A
// knob turns toward `hi` as it goes up, a step every `KNOB_STEP` pixels. A
// scroller's thumb follows the pointer across.
widget_drag :: proc "contextless" (win: ^Window, o: ^Object, x: int, y: int) -> bool {
	v := o.sel
	#partial switch o.class {
	case .Knob:
		v = clamp(win.press_value + (win.press_y - y) / KNOB_STEP, o.lo, o.hi)
	case .Scroller:
		v = clamp(win.press_value + scroller_step(o, x - win.press_x, &win.theme), 0, o.hi - o.cells)
	case:
		return false
	}
	if v == o.sel {
		return false
	}
	o.sel = v
	return true
}

// widget_activate is a release on one of the classes here: a cycle takes its
// next choice.
widget_activate :: proc "contextless" (o: ^Object) {
	if o.class == .Cycle && len(o.rows) > 0 {
		o.sel = (o.sel + 1) % len(o.rows)
	}
}
