/*
mui -- `sys/libmui`'s layout, exercised from ring 3.

The kernel's self-test spawns this program and reads the word it exits with.
The word is `ok` when every step held, or the name of the first that did not.
Each step builds a tree, lays it out, and checks the rectangles the library
computed against the same weighting rule worked here by hand. No pixel is
drawn. The claim under test is the one `docs/WORKBENCH.md` makes for the
toolkit. Weight places every gadget, never a number.

Three buttons share a column's height by their weights. A rigid label keeps its
width while the glue beside it soaks the slack. A nested group is laid inside
its parent's inset, which is what proves the walk recurses.
*/
package muitest

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libfont"
import "vsys:libmui"
import "vsys:libpal"
import "vsys:libuser"

fail :: proc "contextless" (what: string) -> ! {
	libuser.exits(what)
}

// eq reports whether two numbers match, and names the step when they do not.
main_check :: proc "contextless" (a: int, b: int, what: string) {
	if a != b {
		fail(what)
	}
}

want :: proc "contextless" (cond: bool, what: string) {
	if !cond {
		fail(what)
	}
}

// The buffer paint writes its command stream into, and the atlas paint blits
// labels from. The atlas is `cmd/window`'s, six strips of the 8x16 font.
paint_buf: [4096]u8

ATLAS :: libdraw.Atlas {
	first_image_id = 1,
	per_image      = 16,
	cell_w         = libfont.FONT_WIDTH,
	cell_h         = libfont.FONT_HEIGHT,
	first_char     = libfont.FONT_FIRST,
	count          = libfont.FONT_LAST - libfont.FONT_FIRST + 1,
}

// has_fill reports whether the command stream in `b[:end]` holds a fill with
// this colour. A fill's fields are id, x, y, w, h, colour, so the colour is
// the sixth word after the header.
has_fill :: proc "contextless" (b: []u8, end: int, color: u32) -> bool #no_bounds_check {
	at := 0
	for at + libdraw.HEADER <= end {
		size := int(libdraw.get_u16(b, at))
		if size < libdraw.HEADER {
			break
		}
		verb := b[at + 2]
		if verb == libdraw.FILL {
			c := libdraw.get_u32(b, at + libdraw.HEADER + 20)
			if c == color {
				return true
			}
		}
		at += size
	}
	return false
}

// count_verb counts commands of one kind in the stream.
count_verb :: proc "contextless" (b: []u8, end: int, verb: u8) -> int #no_bounds_check {
	n := 0
	at := 0
	for at + libdraw.HEADER <= end {
		size := int(libdraw.get_u16(b, at))
		if size < libdraw.HEADER {
			break
		}
		if b[at + 2] == verb {
			n += 1
		}
		at += size
	}
	return n
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = libuser.startup()

	t := libmui.default_theme

	// -- Three weighted buttons share a column --------------------------------
	//
	// Heights of 1:2:1 over 400 pixels of slack come out 100:200:100 on top of
	// each button's own smallest height. The y of each follows with a gap.
	{
		col := libmui.group(false)
		b1 := libmui.weigh(libmui.button("One"), 1)
		b2 := libmui.weigh(libmui.button("Two"), 2)
		b3 := libmui.weigh(libmui.button("Six"), 1)
		libmui.add(col, b1)
		libmui.add(col, b2)
		libmui.add(col, b3)
		libmui.fit(col, &t)
		libmui.lay(col, 0, 0, 200, 500, &t)

		// The smallest height of a three-letter button under the default theme.
		minh := libmui.FONT_H + 2 * t.vpad + 2 * t.bevel // 16 + 8 + 4 = 28
		main_check(minh, 28, "the button's own smallest height")

		// inner height 492, minus two gaps of 4, is 484 of room. The three
		// smallest heights are 84, so 400 is slack, shared 100:200:100.
		main_check(b1.h, 28 + 100, "the first button's height by weight")
		main_check(b2.h, 28 + 200, "the second button's height by weight")
		main_check(b3.h, 28 + 100, "the third button's height by weight")

		// The column sums back to the inner height with the gaps in place.
		main_check(b1.h + b2.h + b3.h + 2 * t.gap, 500 - 2 * t.pad, "the heights fill the column")

		// Each y sits below the last, a gap on.
		main_check(b1.y, t.pad, "the first button's top at the inset")
		main_check(b2.y, b1.y + b1.h + t.gap, "the second button below the first")
		main_check(b3.y, b2.y + b2.h + t.gap, "the third button below the second")
		main_check(b3.y + b3.h, 500 - t.pad, "the last button reaches the far inset")
	}

	// -- A rigid label keeps its width, the glue takes the slack --------------
	{
		row := libmui.group(true)
		name := libmui.text("Name") // rigid, four cells wide
		glue := libmui.space() // stretchy
		go := libmui.button("Go") // stretchy
		libmui.add(row, name)
		libmui.add(row, glue)
		libmui.add(row, go)
		libmui.fit(row, &t)
		libmui.lay(row, 0, 0, 300, 40, &t)

		// The label is exactly its text and never grows.
		main_check(name.w, 4 * libmui.FONT_W, "the rigid label keeps its width")
		main_check(name.weight, 0, "the rigid label carries no weight")

		// The button's own smallest width, two cells and the insets.
		gomin := 2 * libmui.FONT_W + 2 * t.hpad + 2 * t.bevel // 16 + 16 + 4 = 36
		main_check(gomin, 36, "the button's own smallest width")

		// inner width 292, minus two gaps, is 284 of room. The label and button
		// take 32 and 36 at rest. The 216 of slack splits evenly, 108 each.
		main_check(glue.w, 108, "the glue took its half of the slack")
		main_check(go.w, 36 + 108, "the button took its half of the slack")
		main_check(name.w + glue.w + go.w + 2 * t.gap, 300 - 2 * t.pad, "the row fills its width")
	}

	// -- A nested group is laid inside its parent's inset ---------------------
	{
		outer := libmui.group(false)
		inner := libmui.group(true)
		libmui.add(inner, libmui.text("A"))
		libmui.add(inner, libmui.text("B"))
		libmui.add(outer, inner)
		libmui.add(outer, libmui.text("tail"))
		libmui.fit(outer, &t)
		libmui.lay(outer, 0, 0, 200, 120, &t)

		// The inner group's own first child sits one further inset in on both
		// axes, which only happens if lay recursed into the group.
		main_check(inner.first.x, inner.x + t.pad, "the nested child is inset in x")
		main_check(inner.first.y, inner.y + t.pad, "the nested child is inset in y")
	}

	// -- The painter draws the tree it laid out, in the theme's colours -------
	//
	// A painted button leaves a ground fill behind it, a face fill on it, and
	// a blit for each letter of its label.
	{
		t2 := libmui.default_theme
		col := libmui.group(false)
		go := libmui.button("Go")
		libmui.add(col, go)
		libmui.fit(col, &t2)
		libmui.lay(col, 0, 0, 120, 60, &t2)

		end := libmui.paint(paint_buf[:], 0, col, 1, ATLAS, &t2)
		want(end > 0, "the paint fit the buffer")
		want(has_fill(paint_buf[:], end, libpal.xrgb(t2.ground)), "the window ground was filled")
		want(has_fill(paint_buf[:], end, libpal.xrgb(t2.face)), "the button face was filled")
		want(count_verb(paint_buf[:], end, libdraw.BLIT) >= 2, "the label was blitted")
	}

	// -- A theme's face line changes every button's fill ----------------------
	//
	// Set the face to copper and the same tree paints a copper button, with no
	// magnesium face left in the stream. This is the whole of what a face does.
	{
		t3 := libmui.default_theme
		t3.face = libpal.COPPER
		col := libmui.group(false)
		go := libmui.button("Go")
		libmui.add(col, go)
		libmui.fit(col, &t3)
		libmui.lay(col, 0, 0, 120, 60, &t3)

		end := libmui.paint(paint_buf[:], 0, col, 1, ATLAS, &t3)
		want(has_fill(paint_buf[:], end, libpal.xrgb(libpal.COPPER)), "the copper face was filled")
		want(!has_fill(paint_buf[:], end, libpal.xrgb(libpal.MAGNESIUM)), "no magnesium face was left")
	}

	// -- A click finds the gadget under it, through labels and groups ---------
	{
		row := libmui.group(true)
		name := libmui.text("File")
		go := libmui.button("Go")
		go.id = 7
		libmui.add(row, name)
		libmui.add(row, go)
		libmui.fit(row, &t)
		libmui.lay(row, 0, 0, 300, 40, &t)

		// The centre of the button is a hit. The centre of the label is not.
		bx := go.x + go.w / 2
		by := go.y + go.h / 2
		want(libmui.hit(row, bx, by) == go, "a click on the button found it")
		nx := name.x + name.w / 2
		ny := name.y + name.h / 2
		want(libmui.hit(row, nx, ny) == nil, "a click on a label found nothing")
		want(libmui.hit(row, -1, -1) == nil, "a click outside found nothing")
	}

	// -- Return, Escape, and a click each dismiss a requester ----------------
	{
		req := libmui.requester("Really?", "OK", "Cancel")
		libmui.fit(req.root, &t)
		libmui.lay(req.root, 0, 0, 240, 100, &t)

		// Return chooses the default, id 1. Escape chooses the cancel, id 2.
		done, id := libmui.req_handle(&req, libmui.Event{kind = .Key, key = '\r'})
		want(done && id == 1, "Return chose the default button")
		done, id = libmui.req_handle(&req, libmui.Event{kind = .Key, key = 0x1b})
		want(done && id == 2, "Escape chose the cancel button")

		// A release over the OK button chooses it. One in blank space does not.
		ok := req.def
		ox := ok.x + ok.w / 2
		oy := ok.y + ok.h / 2
		done, id = libmui.req_handle(&req, libmui.Event{kind = .Release, x = ox, y = oy})
		want(done && id == 1, "a click on OK dismissed the requester")
		done, _ = libmui.req_handle(&req, libmui.Event{kind = .Release, x = ok.x + ok.w + 100, y = oy})
		want(!done, "a click in blank space left it standing")

		// The message text takes no click.
		want(libmui.hit(req.root, req.root.first.x + 2, req.root.first.y + 2) == nil, "the message text takes no click")
	}

	libuser.exits("ok")
}
