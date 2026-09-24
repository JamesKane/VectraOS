/*
draw -- a laid-out tree becomes pixels.

After `fit` and `lay` give every node a rectangle, `paint` walks the tree and
paints it into a `sys/libraster` canvas. The canvas is the window's store, which
the draw server composites straight from, `docs/CHROME.md` brick 3. A fill sits behind
the gadgets. Each raised control has a face and a bevel, and each label is its
glyphs laid in the ink over whatever is under them. Nothing here opens a file,
so `tests/mui` paints into a canvas of its own and reads the pixels back.

**The labels need no atlas.** The draw server's `blit` is opaque, so the toolkit
once baked its glyphs per ink and background and blitted them. A label on a
gradient had no one background to bake. A glyph laid into the store is a set of
pixels over what is already there, which any ground takes. That is the per-face
atlas gone, and the image pool with it.

The look is the theme's. A button's face is `Theme.face`, its highlight and
shadow the two edges beside it, and its label the ink. A theme file that sets
`face` to copper changes every button's fill, which is the whole of what a face
does. The bevel lights the top and left edges and darkens the bottom and right. The
light is at the top left, as the chrome has it.
*/
package libmui

import "vsys:libdraw"
import "vsys:libfont"
import "vsys:libpal"
import "vsys:libraster"

// px is a palette colour as a pixel word.
@(private = "file")
px :: proc "contextless" (c: libpal.RGB) -> u32 {
	return libraster.rgb(c)
}

/*
paint draws `root` and its descendants into `c`, whose (0, 0) is the client
area's corner. The window's ground goes down once, behind everything the tree
draws on it.
*/
paint :: proc "contextless" (c: ^libraster.Canvas, root: ^Object, t: ^Theme) {
	if root == nil {
		return
	}
	libraster.fill(c, root.x, root.y, root.w, root.h, px(t.ground))
	paint_node(c, root, t)
}

// paint_node draws one node and then its children. A group draws only its
// children, so a container leaves no mark of its own.
paint_node :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, t: ^Theme) {
	if o == nil {
		return
	}
	switch o.class {
	case .Space:
	// Glue draws nothing. The ground behind it already reads as blank.
	case .Group:
	// A container draws nothing of its own.
	case .Text:
		// A label draws as written: an underscore in it is a character,
		// not a hotkey mark, which only a button's label carries.
		face_text(c, t, .Interface, o.x, o.y, o.label, px(t.ink))
	case .Button:
		raised(c, o, t)
		label_centered(c, o, t)
	case .Checkmark:
		raised(c, o, t)
		if o.on {
			// A lit lamp is the ink shrunk inside the bevel.
			m := t.bevel + 3
			libraster.fill(c, o.x + m, o.y + m, o.w - 2 * m, o.h - 2 * m, px(t.ink))
		}
	case .String:
		// A recessed well: the ground, sunk, with a dark edge round it.
		libraster.fill(c, o.x, o.y, o.w, o.h, px(t.shade))
		libraster.fill(c, o.x + t.bevel, o.y + t.bevel, o.w - 2 * t.bevel, o.h - 2 * t.bevel, px(t.ground))
		if o.edit_n > 0 {
			cells := (o.w - 2 * t.well) / FONT_W
			glyphs(c, o.x + t.well, o.y + t.well, clip_cells(field_text(o), cells), px(t.ink))
		}
	case .List:
		list_rows(c, o, t)
	case .Icons:
		icon_cells(c, o, t)
	case .Picture:
		well(c, o.x, o.y, o.w, o.h, t)
		picture(c, o, t)
	case .Item:
		menu_item(c, o, t)
	case .Title:
		menu_title(c, o, t)
	}
	for k := o.first; k != nil; k = k.next {
		paint_node(c, k, t)
	}
}

// well is a sunk field: the shade as its edge, the ground inside.
@(private = "file")
well :: proc "contextless" (c: ^libraster.Canvas, x: int, y: int, w: int, h: int, t: ^Theme) {
	libraster.fill(c, x, y, w, h, px(t.shade))
	libraster.fill(c, x + t.well, y + t.well, w - 2 * t.well, h - 2 * t.well, px(t.ground))
}

/*
list_rows draws a list: a well like a string gadget's, then the rows from
`top` down as far as the well holds. Each is clipped to the well's width. The
selected row sits on a bar of the face colour, so it reads as the one pressed.
A row past the end draws nothing, and the well behind it already reads as
blank. The pictures standing on rows go down last, cut at the well's edge.
*/
list_rows :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, t: ^Theme) {
	well(c, o.x, o.y, o.w, o.h, t)
	cells := (o.w - 2 * t.well) / FONT_W
	n := list_visible(o, t)
	x := o.x + t.well
	for k in 0 ..< n {
		row := o.top + k
		if row < 0 || row >= len(o.rows) {
			break
		}
		y := o.y + t.well + k * FONT_H
		style := row_style(o, row)
		ink := t.ink
		switch style {
		case STYLE_HEADING, STYLE_BUTTON:
			ink = t.hot
		case STYLE_LINK:
			ink = t.link
		case STYLE_QUOTE:
			ink = t.dim
		case STYLE_FIELD:
			// A recessed bar, the way a string gadget's well reads.
			libraster.fill(c, x, y, o.w - 2 * t.well, FONT_H, px(t.shade))
		}
		if row == o.sel {
			libraster.fill(c, x, y, o.w - 2 * t.well, FONT_H, px(t.face))
			ink = t.ink
		}
		if style == STYLE_RULE {
			// A line across the well, at the row's middle.
			libraster.fill(c, x + FONT_W, y + FONT_H / 2, max(o.w - 2 * t.well - 2 * FONT_W, 1), 1, px(t.face))
			continue
		}
		if style == STYLE_PICTURE {
			// The picture lands below. The row is its stand.
			continue
		}
		glyphs(c, x, y, clip_cells(o.rows[row], cells), px(ink))
	}
	if o.pics != nil {
		list_pictures(c, o, t)
	}
}

/*
list_pictures lays the pictures standing on a list's rows. Each sits under its
caption row, a cell in from the well's left, shrunk to the well's width if
wider. A picture half scrolled off is cut at the well's edge, the way its rows
are. It paints through a canvas no taller than the rows shown.
*/
@(private = "file")
list_pictures :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, t: ^Theme) {
	n := list_visible(o, t)
	top_y := o.y + t.well
	avail := o.w - 2 * t.well - 2 * FONT_W
	if avail <= 0 || n <= 0 || top_y < 0 || top_y >= c.h {
		return
	}
	shown := sub_canvas(c, 0, top_y, c.w, min(n * FONT_H, c.h - top_y))
	for &p in o.pics {
		if p.pix == nil || p.pw <= 0 || p.ph <= 0 || len(p.pix) < p.pw * p.ph * 4 {
			continue
		}
		if p.row + p.tall <= o.top || p.row >= o.top + n {
			continue
		}
		dw := min(p.pw, avail)
		dh := max(p.ph * dw / p.pw, 1)
		dx := o.x + t.well + FONT_W
		dy := (p.row - o.top) * FONT_H
		libraster.copy_scaled(&shown, p.pix, p.pw, p.ph, dx, dy, dw, dh)
	}
}

/*
picture lays a picture gadget's pixels in its well. A picture larger than the
well is shrunk to fit it, its shape kept, by taking one source pixel per
destination pixel. A smaller one is drawn as it is, centred. Alpha is blended
over the well's ground.
*/
@(private = "file")
picture :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, t: ^Theme) {
	if o.pix == nil || o.pw <= 0 || o.ph <= 0 || len(o.pix) < o.pw * o.ph * 4 {
		return
	}
	ax, ay := o.x + t.well, o.y + t.well
	aw, ah := o.w - 2 * t.well, o.h - 2 * t.well
	if aw <= 0 || ah <= 0 {
		return
	}
	dw, dh := o.pw, o.ph
	if dw > aw || dh > ah {
		if dw * ah > dh * aw {
			dh = max(o.ph * aw / o.pw, 1)
			dw = aw
		} else {
			dw = max(o.pw * ah / o.ph, 1)
			dh = ah
		}
	}
	libraster.copy_scaled(c, o.pix, o.pw, o.ph, ax + (aw - dw) / 2, ay + (ah - dh) / 2, dw, dh)
}

/*
menu_item draws a menu's key, `docs/CHROME.md` section 8. It is a raised face
with the label at the left in the interface face. At the right is the shortcut
in the namespace face in `dim`, or an arrow for a submenu.
*/
@(private = "file")
menu_item :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, t: ^Theme) {
	raised(c, o, t)
	lh := text_height(t, .Interface)
	face_text(c, t, .Interface, o.x + t.bevel + t.hpad, o.y + (o.h - lh) / 2, o.label, px(t.ink))
	right := o.x + o.w - t.bevel - t.hpad
	if o.has_sub {
		// A right-pointing triangle, eight wide, centred on the key.
		S :: libraster.SUB
		cy := o.y + o.h / 2
		tri := [3]libraster.Point{{(right - ITEM_ARROW) * S, (cy - 4) * S}, {right * S, cy * S}, {(right - ITEM_ARROW) * S, (cy + 4) * S}}
		ends := [1]int{3}
		if c.w <= len(arrow_scratch) {
			libraster.path(c, tri[:], ends[:], px(t.ink), arrow_scratch[:])
		}
	} else if o.shortcut != "" {
		sw := text_width(t, .Namespace, o.shortcut)
		sh := text_height(t, .Namespace)
		face_text(c, t, .Namespace, right - sw, o.y + (o.h - sh) / 2, o.shortcut, px(t.dim))
	}
}

// The arrow's row of coverage, one word a pixel across the widest canvas. Not
// on the stack: a menu paints on a `libthread` thread, whose stack is small,
// and eight kilobytes there ran it over. A program paints one window at a
// time, so one row serves.
@(private = "file")
arrow_scratch: [2048]u32

/*
menu_title draws a menu's title. It is a strip of the frame's metal, `bar` down
to `bar.shade` with two hairline patterns, with the name in the chrome face.
*/
@(private = "file")
menu_title :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, t: ^Theme) {
	libraster.vgrad(c, o.x, o.y, o.w, o.h, px(t.metal_hi), px(t.metal_lo))
	libraster.hairline(c, o.x, o.y, o.w, o.h, 3, 0xFFFFFF, 9, true)
	libraster.hairline(c, o.x + 1, o.y, o.w, o.h, 7, 0x000000, 15, true)
	th := text_height(t, .Chrome)
	face_text(c, t, .Chrome, o.x + t.hpad, o.y + (o.h - th) / 2, o.label, px(t.ink))
	// The tear-off gadget: a small raised key at the right with a pin on it,
	// OPEN LOOK's, a head and a shaft.
	gs := TEAR_W
	gx := o.x + o.w - t.hpad / 2 - gs
	gy := o.y + (o.h - gs) / 2
	libraster.fill(c, gx, gy, gs, gs, px(t.face))
	libraster.bevel(c, gx, gy, gs, gs, 1, px(t.lit), px(t.shade))
	libraster.fill(c, gx + gs / 2 - 2, gy + 3, 4, 4, px(t.ink))
	libraster.fill(c, gx + gs / 2 - 1, gy + 7, 1, gs - 10, px(t.ink))
}

// sub_canvas is the part of `c` at (x, y), `w` by `h`, as a canvas of its own.
// What paints through it is cut at its edges.
@(private = "file")
sub_canvas :: proc "contextless" (c: ^libraster.Canvas, x: int, y: int, w: int, h: int) -> libraster.Canvas #no_bounds_check {
	return libraster.canvas(c.pix[y * c.stride + x:], c.stride, max(w, 0), max(h, 0))
}

/*
icon_cells draws an icon grid. First the well, then a cell per name from
the top row down as far as the well holds. Each cell is a picture of its
kind above its name. The selected cell's name sits on a bar of the face,
as a list's selected row does. The pictures are the chassis's vocabulary,
`docs/WORKBENCH.md` section 6. A drawer is a plinth with a bar, a tool a
plinth with a lamp, and a project a well with lines in it.
*/
icon_cells :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, t: ^Theme) {
	well(c, o.x, o.y, o.w, o.h, t)
	// Free placement, for Snapshot: each cell at its own point in the well,
	// rather than the grid. A cell that would fall outside the well is
	// skipped, so a placement near an edge clips rather than spills.
	if o.place != nil {
		n := min(len(o.rows), len(o.place))
		for i in 0 ..< n {
			cx, cy := icons_place_xy(o, i, t)
			if cx < o.x + t.well || cy < o.y + t.well || cx + ICON_W > o.x + o.w - t.well || cy + ICON_H > o.y + o.h - t.well {
				continue
			}
			icon_one(c, o, i, cx, cy, t)
		}
		return
	}
	cols := icons_cols(o, t)
	rows := icons_visible(o, t)
	for r in 0 ..< rows {
		for k in 0 ..< cols {
			i := (o.top + r) * cols + k
			if i < 0 || i >= len(o.rows) {
				break
			}
			icon_one(c, o, i, o.x + t.well + k * ICON_W, o.y + t.well + r * ICON_H, t)
		}
	}
}

// icon_one draws one cell of an icon grid at `(cx, cy)`. The picture of its
// kind is above, and its name under it, on a bar of the face when selected. Both the grid and free placement draw a cell this way.
icon_one :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, i: int, cx: int, cy: int, t: ^Theme) #no_bounds_check {
	kind := ICON_PROJECT
	if o.kinds != nil && i < len(o.kinds) {
		kind = o.kinds[i]
	}
	// With a theme that names icons, the cell's own icon, else its kind's.
	// Else the chassis's picture.
	ix, iy := cx + (ICON_W - ICON_PICTURE) / 2, cy + 4
	own := o.pictures != nil && i < len(o.pictures) && icon_named(c, o.pictures[i], ix, iy, ICON_PICTURE, t)
	if !own && !icon_named(c, icon_kind_name(kind), ix, iy, ICON_PICTURE, t) {
		icon_picture(c, cx + (ICON_W - 40) / 2, cy + 6, kind, t)
	}
	shown := clip_cells(o.rows[i], NAME_CELLS)
	tw := drawn_len(shown) * FONT_W
	tx := cx + (ICON_W - tw) / 2
	ty := cy + ICON_H - FONT_H - 4
	if i == o.sel {
		libraster.fill(c, tx - 2, ty, tw + 4, FONT_H, px(t.face))
	}
	glyphs(c, tx, ty, shown, px(t.ink))
}

// icon_picture is one kind's picture, forty by twenty-eight, at a point.
icon_picture :: proc "contextless" (c: ^libraster.Canvas, x: int, y: int, kind: u8, t: ^Theme) {
	W :: 40
	H :: 28
	switch kind {
	case ICON_DRAWER, ICON_TOOL:
		// A plinth: the face with a lit top and left, a shaded bottom and right.
		plinth(c, x, y, W, H, t)
		if kind == ICON_DRAWER {
			// The drawer's bar, copper across the top like a window's.
			libraster.fill(c, x + t.bevel, y + t.bevel, W - 2 * t.bevel, 5, px(libpal.COPPER))
		} else {
			// The tool's lamp, phosphor in a socket at the corner.
			libraster.fill(c, x + W - 12, y + 4, 8, 8, px(t.shade))
			libraster.fill(c, x + W - 11, y + 5, 6, 6, px(libpal.PHOSPHOR))
		}
	case:
		// A project: a well, and three lines of ink in it.
		libraster.fill(c, x + 4, y, W - 8, H, px(t.shade))
		libraster.fill(c, x + 4 + t.well, y + t.well, W - 8 - 2 * t.well, H - 2 * t.well, px(t.ground))
		for k in 0 ..< 3 {
			libraster.fill(c, x + 10, y + 6 + k * 7, W - 20, 2, px(t.ink))
		}
	}
}

// plinth is `raised` for a rectangle that is not a node.
plinth :: proc "contextless" (c: ^libraster.Canvas, x: int, y: int, w: int, h: int, t: ^Theme) {
	libraster.fill(c, x, y, w, h, px(t.face))
	libraster.bevel(c, x, y, w, h, t.bevel, px(t.lit), px(t.shade))
}

clip_cells :: proc "contextless" (s: string, cells: int) -> string {
	n := 0
	i := 0
	for i < len(s) && n < cells {
		_, size := libdraw.decode_rune(transmute([]u8)s[i:])
		if size <= 0 {
			break
		}
		i += size
		n += 1
	}
	return s[:i]
}

// raised draws a control's face with a bevel: the face, a lit top-left edge,
// and a dark bottom-right edge.
raised :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, t: ^Theme) {
	plinth(c, o.x, o.y, o.w, o.h, t)
}

/*
glyphs lays a string's glyphs at (x, y) in one ink, a cell each, over whatever
is there. A rune past ASCII comes from the font `window_open` loads. A rune no
range holds takes its cell and draws nothing, as a title does.
*/
glyphs :: proc "contextless" (c: ^libraster.Canvas, x: int, y: int, s: string, ink: u32) #no_bounds_check {
	cell: [libfont.FONT_HEIGHT]u8
	col := 0
	i := 0
	for i < len(s) {
		r, size := libdraw.decode_rune(transmute([]u8)s[i:])
		if size <= 0 {
			break
		}
		i += size
		if _, ok := libfont.loader_glyph(&text_font, r, cell[:]); ok {
			libraster.bits(c, x + col * FONT_W, y, cell[:], ink)
		}
		col += 1
	}
}

// label_centered writes a button's text centred in its face, in the chrome
// face, a hotkey underscore skipped the way the layout counted it.
label_centered :: proc "contextless" (c: ^libraster.Canvas, o: ^Object, t: ^Theme) {
	shown := strip_hotkey(o.label)
	tw := text_width(t, .Chrome, shown)
	th := text_height(t, .Chrome)
	face_text(c, t, .Chrome, o.x + (o.w - tw) / 2, o.y + (o.h - th) / 2, shown, px(t.ink))
}

/*
face_text lays a string in a role's face with its line's top at (x, y). Each
glyph's mask is blended in the ink over what is there, so the edges are smooth
on any ground. The role's capitals and tracking are applied here and in
`text_width` alike, so what is measured is what is drawn. A role with no face
draws in the cells.
*/
face_text :: proc "contextless" (c: ^libraster.Canvas, t: ^Theme, role: Face_Role, x: int, y: int, s: string, ink: u32) {
	f := face_of(t, role)
	if f == nil {
		glyphs(c, x, y, s, ink)
		return
	}
	spec := &t.faces[role]
	space, _ := libfont.face_glyph(f, ' ')
	pen := x
	base := y + f.ascent
	for r in s {
		ch := spec.caps ? libfont.upper(r) : r
		g, ok := libfont.face_glyph(f, ch)
		if !ok {
			pen += space.advance + spec.track
			continue
		}
		if g.w > 0 {
			libraster.coverage(c, pen + g.left, base - g.top, g.mask, g.w, g.h, ink)
		}
		pen += g.advance + spec.track
	}
}

// strip_hotkey returns a label with one `_` before a letter removed, into a
// small static buffer. A label longer than the buffer is passed through whole.
hotkey_buf: [128]u8

strip_hotkey :: proc "contextless" (label: string) -> string #no_bounds_check {
	// Fast path: no underscore means no work.
	has := false
	for i in 0 ..< len(label) {
		if label[i] == '_' {
			has = true
			break
		}
	}
	if !has || len(label) > len(hotkey_buf) {
		return label
	}
	n := 0
	i := 0
	for i < len(label) {
		ch := label[i]
		if ch == '_' && i + 1 < len(label) {
			d := label[i + 1]
			is_letter := (d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z')
			if is_letter {
				i += 1
				continue
			}
		}
		hotkey_buf[n] = ch
		n += 1
		i += 1
	}
	return string(hotkey_buf[:n])
}
