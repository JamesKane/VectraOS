/*
draw -- a laid-out tree becomes a stream of `sys/libdraw` commands.

After `fit` and `lay` give every node a rectangle, `paint` walks the tree and
writes the commands that draw it. A fill sits behind the gadgets. Each raised
control has a face and a bevel, and each label a run of glyph blits. The commands go into a caller's buffer in `docs/DRAW.md`'s wire format,
the same one `cmd/window` pumps down `/srv/draw`. Nothing here opens a file or
touches a pixel, so `tests/mui` reads the stream back and checks it.

The look is the theme's. A button's face is `Theme.face`, its highlight and
shadow the two edges beside it, and its label the ink. A theme file that sets
`face` to copper changes every button's fill, which is the whole of what a
face does. The bevel lights the top and left edges and darkens the bottom and
right, the light fixed at the top-left as the chrome has it.
*/
package libmui

import "vsys:libdraw"
import "vsys:libpal"

/*
paint writes the commands to draw `root` and its descendants onto image `dst`,
starting at offset `at` in buffer `b`. Labels blit from the atlases `f` holds,
so a caller runs `font_prepare` first to bake them. It returns the new offset,
or a negative number if the buffer filled. For the toolkit's own windows one
batch holds a whole tree, so the simple form is one call.
*/
paint :: proc "contextless" (
	b: []u8,
	at: int,
	root: ^Object,
	dst: u32,
	f: ^Fonts,
	t: ^Theme,
) -> int {
	if root == nil {
		return at
	}
	// The window ground, once, behind everything the tree draws on it.
	nat := libdraw.put_fill(
		b,
		at,
		dst,
		u32(root.x),
		u32(root.y),
		u32(root.w),
		u32(root.h),
		libpal.xrgb(t.ground),
	)
	return paint_node(b, nat, root, dst, f, t)
}

// paint_node draws one node and then its children. A group draws only its
// children, so a container leaves no mark of its own.
paint_node :: proc "contextless" (
	b: []u8,
	at: int,
	o: ^Object,
	dst: u32,
	f: ^Fonts,
	t: ^Theme,
) -> int {
	if o == nil || at < 0 {
		return at
	}
	nat := at
	switch o.class {
	case .Space:
	// Glue draws nothing. The ground behind it already reads as blank.
	case .Group:
	// A container draws nothing of its own.
	case .Text:
		// A label draws as written: an underscore in it is a character,
		// not a hotkey mark, which only a button's label carries.
		if a, ok := font_get(f, t.ink, t.ground); ok {
			nat, _, _ = libdraw.put_text(b, nat, a, dst, u32(o.x), u32(o.y), o.label)
		}
	case .Button:
		nat = raised(b, nat, o, dst, t)
		if a, ok := font_get(f, t.ink, t.face); ok {
			nat = label_centered(b, nat, o, dst, a, t)
		}
	case .Checkmark:
		nat = raised(b, nat, o, dst, t)
		if o.on {
			// A lit lamp is the ink shrunk inside the bevel.
			m := t.bevel + 3
			nat = libdraw.put_fill(
				b,
				nat,
				dst,
				u32(o.x + m),
				u32(o.y + m),
				u32(o.w - 2 * m),
				u32(o.h - 2 * m),
				libpal.xrgb(t.ink),
			)
		}
	case .String:
		// A recessed well: the ground, sunk, with a dark edge over a lit one.
		nat = libdraw.put_fill(b, nat, dst, u32(o.x), u32(o.y), u32(o.w), u32(o.h), libpal.xrgb(t.shade))
		nat = libdraw.put_fill(
			b,
			nat,
			dst,
			u32(o.x + t.bevel),
			u32(o.y + t.bevel),
			u32(o.w - 2 * t.bevel),
			u32(o.h - 2 * t.bevel),
			libpal.xrgb(t.ground),
		)
		if a, ok := font_get(f, t.ink, t.ground); ok && o.edit_n > 0 {
			cells := (o.w - 2 * t.well) / FONT_W
			shown := clip_cells(field_text(o), cells)
			nat, _, _ = libdraw.put_text(b, nat, a, dst, u32(o.x + t.well), u32(o.y + t.well), shown)
		}
	case .List:
		nat = list_rows(b, nat, o, dst, f, t)
	case .Icons:
		nat = icon_cells(b, nat, o, dst, f, t)
	}
	for c := o.first; c != nil; c = c.next {
		nat = paint_node(b, nat, c, dst, f, t)
	}
	return nat
}

/*
list_rows draws a list: a well like a string gadget's, then the rows from
`top` down as far as the well holds. Each is clipped to the well's width. The
selected row sits on a bar of the face colour, in the ink baked for that
face, so it reads as the one pressed. A row past the end draws nothing, and
the well behind it already reads as blank.
*/
list_rows :: proc "contextless" (b: []u8, at: int, o: ^Object, dst: u32, f: ^Fonts, t: ^Theme) -> int {
	nat := libdraw.put_fill(b, at, dst, u32(o.x), u32(o.y), u32(o.w), u32(o.h), libpal.xrgb(t.shade))
	nat = libdraw.put_fill(
		b,
		nat,
		dst,
		u32(o.x + t.well),
		u32(o.y + t.well),
		u32(o.w - 2 * t.well),
		u32(o.h - 2 * t.well),
		libpal.xrgb(t.ground),
	)
	plain, pok := font_get(f, t.ink, t.ground)
	lit, lok := font_get(f, t.ink, t.face)
	if !pok {
		return nat
	}
	cells := (o.w - 2 * t.well) / FONT_W
	n := list_visible(o, t)
	x := o.x + t.well
	for k in 0 ..< n {
		row := o.top + k
		if row < 0 || row >= len(o.rows) {
			break
		}
		y := o.y + t.well + k * FONT_H
		atlas := plain
		if row == o.sel && lok {
			nat = libdraw.put_fill(b, nat, dst, u32(x), u32(y), u32(o.w - 2 * t.well), u32(FONT_H), libpal.xrgb(t.face))
			atlas = lit
		}
		shown := clip_cells(o.rows[row], cells)
		next, _, _ := libdraw.put_text(b, nat, atlas, dst, u32(x), u32(y), shown)
		if next < 0 {
			return next
		}
		nat = next
	}
	return nat
}

// clip_cells answers the longest prefix of `s` that draws in `cells` cells,
// counting a multi-byte rune as one.
/*
icon_cells draws an icon grid. First the well, then a cell per name from
the top row down as far as the well holds. Each cell is a picture of its
kind above its name. The selected cell's name sits on a bar of the face,
as a list's selected row does. The pictures are the chassis's vocabulary,
`docs/WORKBENCH.md` section 6. A drawer is a plinth with a bar, a tool a
plinth with a lamp, and a project a well with lines in it.
*/
icon_cells :: proc "contextless" (b: []u8, at: int, o: ^Object, dst: u32, f: ^Fonts, t: ^Theme) -> int {
	nat := libdraw.put_fill(b, at, dst, u32(o.x), u32(o.y), u32(o.w), u32(o.h), libpal.xrgb(t.shade))
	nat = libdraw.put_fill(
		b,
		nat,
		dst,
		u32(o.x + t.well),
		u32(o.y + t.well),
		u32(o.w - 2 * t.well),
		u32(o.h - 2 * t.well),
		libpal.xrgb(t.ground),
	)
	plain, pok := font_get(f, t.ink, t.ground)
	lit, lok := font_get(f, t.ink, t.face)
	if !pok {
		return nat
	}
	cols := icons_cols(o, t)
	rows := icons_visible(o, t)
	name_cells := ICON_W / FONT_W - 1
	for r in 0 ..< rows {
		for c in 0 ..< cols {
			i := (o.top + r) * cols + c
			if i < 0 || i >= len(o.rows) {
				break
			}
			cx := o.x + t.well + c * ICON_W
			cy := o.y + t.well + r * ICON_H
			kind := ICON_PROJECT
			if o.kinds != nil && i < len(o.kinds) {
				kind = o.kinds[i]
			}
			nat = icon_picture(b, nat, dst, cx + (ICON_W - 40) / 2, cy + 6, kind, t)
			shown := clip_cells(o.rows[i], name_cells)
			tw := drawn_len(shown) * FONT_W
			tx := cx + (ICON_W - tw) / 2
			ty := cy + ICON_H - FONT_H - 4
			atlas := plain
			if i == o.sel && lok {
				nat = libdraw.put_fill(b, nat, dst, u32(tx - 2), u32(ty), u32(tw + 4), u32(FONT_H), libpal.xrgb(t.face))
				atlas = lit
			}
			next, _, _ := libdraw.put_text(b, nat, atlas, dst, u32(tx), u32(ty), shown)
			if next < 0 {
				return next
			}
			nat = next
		}
	}
	return nat
}

// icon_picture is one kind's picture, forty by twenty-eight, at a point.
icon_picture :: proc "contextless" (b: []u8, at: int, dst: u32, x: int, y: int, kind: u8, t: ^Theme) -> int {
	W :: 40
	H :: 28
	nat := at
	switch kind {
	case ICON_DRAWER, ICON_TOOL:
		// A plinth: the face with a lit top and left, a shaded bottom and right.
		nat = plinth(b, nat, dst, x, y, W, H, t)
		if kind == ICON_DRAWER {
			// The drawer's bar, copper across the top like a window's.
			nat = libdraw.put_fill(b, nat, dst, u32(x + t.bevel), u32(y + t.bevel), u32(W - 2 * t.bevel), 5, libpal.xrgb(libpal.COPPER))
		} else {
			// The tool's lamp, phosphor in a socket at the corner.
			nat = libdraw.put_fill(b, nat, dst, u32(x + W - 12), u32(y + 4), 8, 8, libpal.xrgb(t.shade))
			nat = libdraw.put_fill(b, nat, dst, u32(x + W - 11), u32(y + 5), 6, 6, libpal.xrgb(libpal.PHOSPHOR))
		}
	case:
		// A project: a well, and three lines of ink in it.
		nat = libdraw.put_fill(b, nat, dst, u32(x + 4), u32(y), u32(W - 8), u32(H), libpal.xrgb(t.shade))
		nat = libdraw.put_fill(b, nat, dst, u32(x + 4 + t.well), u32(y + t.well), u32(W - 8 - 2 * t.well), u32(H - 2 * t.well), libpal.xrgb(t.ground))
		for k in 0 ..< 3 {
			nat = libdraw.put_fill(b, nat, dst, u32(x + 10), u32(y + 6 + k * 7), u32(W - 20), 2, libpal.xrgb(t.ink))
		}
	}
	return nat
}

// plinth is `raised` for a rectangle that is not a node.
plinth :: proc "contextless" (b: []u8, at: int, dst: u32, x: int, y: int, w: int, h: int, t: ^Theme) -> int {
	nat := libdraw.put_fill(b, at, dst, u32(x), u32(y), u32(w), u32(h), libpal.xrgb(t.face))
	edge := t.bevel
	nat = libdraw.put_fill(b, nat, dst, u32(x), u32(y), u32(w), u32(edge), libpal.xrgb(t.lit))
	nat = libdraw.put_fill(b, nat, dst, u32(x), u32(y), u32(edge), u32(h), libpal.xrgb(t.lit))
	nat = libdraw.put_fill(b, nat, dst, u32(x), u32(y + h - edge), u32(w), u32(edge), libpal.xrgb(t.shade))
	nat = libdraw.put_fill(b, nat, dst, u32(x + w - edge), u32(y), u32(edge), u32(h), libpal.xrgb(t.shade))
	return nat
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
// and a dark bottom-right edge. A pressed control swaps the two edges, which a
// caller signals by leaving `on` set on a momentary press.
raised :: proc "contextless" (b: []u8, at: int, o: ^Object, dst: u32, t: ^Theme) -> int {
	nat := libdraw.put_fill(b, at, dst, u32(o.x), u32(o.y), u32(o.w), u32(o.h), libpal.xrgb(t.face))
	edge := t.bevel
	// Top edge and left edge, the highlight.
	nat = libdraw.put_fill(b, nat, dst, u32(o.x), u32(o.y), u32(o.w), u32(edge), libpal.xrgb(t.lit))
	nat = libdraw.put_fill(b, nat, dst, u32(o.x), u32(o.y), u32(edge), u32(o.h), libpal.xrgb(t.lit))
	// Bottom edge and right edge, the shadow.
	nat = libdraw.put_fill(
		b,
		nat,
		dst,
		u32(o.x),
		u32(o.y + o.h - edge),
		u32(o.w),
		u32(edge),
		libpal.xrgb(t.shade),
	)
	nat = libdraw.put_fill(
		b,
		nat,
		dst,
		u32(o.x + o.w - edge),
		u32(o.y),
		u32(edge),
		u32(o.h),
		libpal.xrgb(t.shade),
	)
	return nat
}

// label writes a node's text at (x, y), skipping a hotkey underscore the way
// the layout counted it.
label :: proc "contextless" (
	b: []u8,
	at: int,
	o: ^Object,
	x: int,
	y: int,
	dst: u32,
	atlas: libdraw.Atlas,
	t: ^Theme,
) -> int {
	// The drawn text with a single hotkey underscore removed.
	drawn := strip_hotkey(o.label)
	nat, _, _ := libdraw.put_text(b, at, atlas, dst, u32(x), u32(y), drawn)
	return nat
}

// label_centered writes a button's text centred in its face.
label_centered :: proc "contextless" (
	b: []u8,
	at: int,
	o: ^Object,
	dst: u32,
	atlas: libdraw.Atlas,
	t: ^Theme,
) -> int {
	n := drawn_len(o.label)
	tw := n * FONT_W
	x := o.x + (o.w - tw) / 2
	y := o.y + (o.h - FONT_H) / 2
	return label(b, at, o, x, y, dst, atlas, t)
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
		c := label[i]
		if c == '_' && i + 1 < len(label) {
			d := label[i + 1]
			is_letter := (d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z')
			if is_letter {
				i += 1
				continue
			}
		}
		hotkey_buf[n] = c
		n += 1
		i += 1
	}
	return string(hotkey_buf[:n])
}
