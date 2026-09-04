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
		if a, ok := font_get(f, t.ink, t.ground); ok {
			nat = label(b, nat, o, o.x, o.y, dst, a, t)
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
	}
	for c := o.first; c != nil; c = c.next {
		nat = paint_node(b, nat, c, dst, f, t)
	}
	return nat
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
	nat, _ := libdraw.put_text(b, at, atlas, dst, u32(x), u32(y), drawn)
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
