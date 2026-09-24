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
import "vsys:libfont"
import "vsys:libmui"
import "vsys:libpal"
import "vsys:libraster"
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

// The canvas a paint goes into: the tree's pixels, read back by the checks.
CW :: 320
CH :: 200
cpix: [CW * CH]u32

// paint_tree paints a laid-out tree into a fresh canvas, cleared to a colour
// no theme uses, so every pixel the checks count was the painter's.
paint_tree :: proc "contextless" (root: ^libmui.Object, t: ^libmui.Theme) -> libraster.Canvas {
	for i in 0 ..< len(cpix) {
		cpix[i] = 0x123456
	}
	c := libraster.canvas(raw_data(cpix[:]), CW, CW, CH)
	libmui.paint(&c, root, t)
	return c
}

// count_in counts the pixels of one colour in a rectangle of the canvas.
count_in :: proc "contextless" (c: ^libraster.Canvas, x: int, y: int, w: int, h: int, color: u32) -> int {
	n := 0
	for row in max(y, 0) ..< min(y + h, c.h) {
		for col in max(x, 0) ..< min(x + w, c.w) {
			if libraster.get(c, col, row) == color {
				n += 1
			}
		}
	}
	return n
}

// blends reports whether every channel of `v` lies between the same channel
// of `a` and `b`: a pixel an edge blended from the two.
blends :: proc "contextless" (v: u32, a: u32, b: u32) -> bool {
	for shift in ([3]uint{16, 8, 0}) {
		x, lo, hi := int(v >> shift & 0xFF), int(a >> shift & 0xFF), int(b >> shift & 0xFF)
		if x < min(lo, hi) || x > max(lo, hi) {
			return false
		}
	}
	return true
}

// has_colour reports whether one colour is anywhere on the canvas.
has_colour :: proc "contextless" (c: ^libraster.Canvas, color: u32) -> bool {
	return count_in(c, 0, 0, c.w, c.h, color) > 0
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
	// A painted button leaves the ground behind it, a face on it, and its
	// label's letters in the ink on the face.
	{
		t2 := libmui.default_theme
		col := libmui.group(false)
		go := libmui.button("Go")
		libmui.add(col, go)
		libmui.fit(col, &t2)
		libmui.lay(col, 0, 0, 120, 60, &t2)

		c := paint_tree(col, &t2)
		want(has_colour(&c, libpal.xrgb(t2.ground)), "the window ground was painted")
		want(count_in(&c, go.x, go.y, go.w, go.h, libpal.xrgb(t2.face)) > 0, "the button face was painted")
		want(count_in(&c, go.x, go.y, go.w, go.h, libpal.xrgb(t2.ink)) > 0, "the label's letters are on the face, in the ink")
		want(count_in(&c, 120, 0, CW - 120, CH, 0x123456) == (CW - 120) * CH, "and nothing past the window's area")
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

		c := paint_tree(col, &t3)
		want(has_colour(&c, libpal.xrgb(libpal.COPPER)), "the copper face was painted")
		want(!has_colour(&c, libpal.xrgb(libpal.MAGNESIUM)), "no magnesium face was left")
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

	// -- A label draws on any ground, with no atlas ---------------------------
	//
	// A text label's letters lie on the ground and a button's on its face, in
	// the one ink, with no glyphs baked per colour pair: a label is its bits
	// laid over whatever is under it. A face of any colour takes one.
	{
		tf := libmui.default_theme
		tf.face = libpal.RGB{0x2a, 0x21, 0x50}
		col := libmui.group(false)
		file := libmui.text("File")
		open := libmui.button("Open")
		libmui.add(col, file)
		libmui.add(col, open)
		libmui.fit(col, &tf)
		libmui.lay(col, 0, 0, 200, 120, &tf)

		c := paint_tree(col, &tf)
		ink := libpal.xrgb(tf.ink)
		want(count_in(&c, file.x, file.y, file.w, file.h, ink) > 0, "a text label's letters are on the ground")
		want(count_in(&c, open.x, open.y, open.w, open.h, ink) > 0, "and a button's on a face of any colour")
		want(count_in(&c, open.x, open.y, open.w, open.h, libpal.xrgb(tf.face)) > 0, "with the face round them")
	}

	// -- The theme is read from a file, a role at a time ----------------------
	//
	// A file that names a face, a bevel and a hex ground changes those three
	// and leaves every other role at the chassis default.
	{
		src := "# a theme\nface        copper\nbevel       3\nground      0e131a\nnonsense    xyz\n"
		th: libmui.Theme
		libmui.parse_theme(&th, src)
		want(th.face == libpal.COPPER, "the face line set copper")
		want(th.bevel == 3, "the bevel line set three")
		want(th.ground == libpal.RGB{0x0e, 0x13, 0x1a}, "the hex ground was read")
		want(th.pad == libmui.default_theme.pad, "an unnamed role kept the default")
		want(th.ink == libmui.default_theme.ink, "an unknown role changed nothing")
	}

	// An empty file is the chassis, every role at its default.
	{
		th: libmui.Theme
		libmui.parse_theme(&th, "")
		want(th.face == libmui.default_theme.face, "an empty file is the chassis")
	}

	// -- A label carries the font past ASCII ---------------------------------
	//
	// Every test above drew with the past-ASCII font unopened, the ASCII-only
	// path. This opens `/lib/font` the way `window_open` does: a Latin-1
	// letter now has a glyph and draws, and a rune no range holds does not.
	{
		libmui.font_load()
		want(libmui.text_font.ready, "the past-ASCII font opens from /lib/font")
		cell: [libfont.FONT_HEIGHT]u8
		_, e_ok := libfont.loader_glyph(&libmui.text_font, 'é', cell[:])
		want(e_ok, "a Latin-1 letter has a glyph")
		_, cjk := libfont.loader_glyph(&libmui.text_font, rune(0x4E00), cell[:])
		want(!cjk, "a rune no range holds does not")

		tl := libmui.default_theme
		col := libmui.group(false)
		word := libmui.text("é")
		libmui.add(col, word)
		libmui.fit(col, &tl)
		libmui.lay(col, 0, 0, 100, 40, &tl)
		c := paint_tree(col, &tl)
		want(count_in(&c, word.x, word.y, libmui.FONT_W, libmui.FONT_H, libpal.xrgb(tl.ink)) > 0, "and a label of it draws its letter")
	}

	// -- The look's faces: proportional, and smooth at the edge ---------------
	//
	// `docs/CHROME.md` brick 4. A theme names a baked face per role, and a
	// label in it is measured by its glyphs' advances and drawn as coverage:
	// an edge pixel is a blend of the ink and the ground, which the 8x16
	// cells, one bit a pixel, can never make.
	{
		tf := libmui.default_theme
		libmui.parse_theme(&tf, "font.interface /lib/font/interface/13.face\nfont.chrome /lib/font/chrome/11.face track 1 caps\n")
		want(libmui.face_of(&tf, .Interface) != nil, "the interface face opens from /lib/font")
		want(libmui.face_of(&tf, .Chrome) != nil, "and the chrome face")
		want(libmui.text_width(&tf, .Interface, "iiii") < libmui.text_width(&tf, .Interface, "MMMM"), "the face is proportional: four i are narrower than four M")
		want(libmui.text_width(&tf, .Chrome, "ok") == libmui.text_width(&tf, .Chrome, "OK"), "a role in capitals measures its small letters as capitals")
		plain := libmui.default_theme
		libmui.parse_theme(&plain, "font.chrome /lib/font/chrome/11.face caps\n")
		want(libmui.text_width(&tf, .Chrome, "OK") == libmui.text_width(&plain, .Chrome, "OK") + 1, "and its tracking adds a pixel between two letters")

		col := libmui.group(false)
		word := libmui.text("Workbench")
		libmui.add(col, word)
		libmui.fit(col, &tf)
		main_check(word.minw, libmui.text_width(&tf, .Interface, "Workbench"), "a label is as wide as its face measures it")
		libmui.lay(col, 0, 0, 200, 40, &tf)
		c := paint_tree(col, &tf)
		ink, ground := libpal.xrgb(tf.ink), libpal.xrgb(tf.ground)
		want(count_in(&c, word.x, word.y, word.w, word.h, ink) > 0, "the label's letters are in the ink")
		between := 0
		for y in word.y ..< word.y + word.h {
			for x in word.x ..< word.x + word.w {
				v := libraster.get(&c, x, y)
				if v != ink && v != ground && blends(v, ink, ground) {
					between += 1
				}
			}
		}
		want(between > 0, "and its edges are smooth: pixels between the ink and the ground")
	}

	// -- A list is rows in a well, one on a bar of the face ------------------
	//
	// Ten rows, room for four: the list asks for four rows plus the well,
	// stretches past that, and shows the four from its top. Showing row
	// eight scrolls, and the selected row's bar is a face-coloured fill of
	// one row's height. A click on the third drawn row selects the row it
	// shows, not the third row of the data.
	{
		tl := libmui.default_theme
		rows := [10]string{"zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"}
		l := libmui.list(4)
		l.rows = rows[:]
		col := libmui.group(false)
		libmui.add(col, l)
		libmui.fit(col, &tl)
		main_check(l.minh, 4 * libmui.FONT_H + 2 * tl.well, "a list asks room for its rows and the well")
		want(l.maxh >= libmui.BIG, "and stretches past them")
		libmui.lay(col, 0, 0, 200, 4 * libmui.FONT_H + 2 * tl.well + 2 * tl.pad, &tl)
		main_check(libmui.list_visible(l, &tl), 4, "four rows fit the height it was given")

		libmui.list_show(l, 8, &tl)
		want(l.top > 0 && 8 >= l.top && 8 < l.top + 4, "showing row eight scrolls the list to hold it")
		l.top = 2
		l.sel = 4
		main_check(libmui.list_row_at(l, l.y + tl.well + 2 * libmui.FONT_H + 3, &tl), 4, "the third drawn row is row four")
		main_check(libmui.list_row_at(l, l.y + l.h - 1, &tl), -1, "past the last drawn row is no row")

		c := paint_tree(col, &tl)
		sel_y := l.y + tl.well + 2 * libmui.FONT_H
		want(count_in(&c, l.x + tl.well, sel_y, l.w - 2 * tl.well, libmui.FONT_H, libpal.xrgb(tl.face)) > 0, "the selected row sits on a bar of the face")
		// "two", "three", "four", "five" drawn: ink on each of the four rows.
		for k in 0 ..< 4 {
			want(count_in(&c, l.x + tl.well, l.y + tl.well + k * libmui.FONT_H, l.w - 2 * tl.well, libmui.FONT_H, libpal.xrgb(tl.ink)) > 0, "each of the four drawn rows has its letters")
		}
		want(libmui.hit(col, l.x + 10, l.y + 10) == l, "a click in the well lands on the list")
	}

	// -- An icon grid: cells in a well, a picture and a name each -------------
	{
		ti := libmui.default_theme
		names := [?]string{"Home", "System", "Tools", "notes", "pong", "draft.txt", "kfs"}
		kinds := [?]u8{libmui.ICON_DRAWER, libmui.ICON_DRAWER, libmui.ICON_DRAWER, libmui.ICON_PROJECT, libmui.ICON_TOOL, libmui.ICON_PROJECT, libmui.ICON_DRAWER}
		g := libmui.icons(2)
		want(g != nil, "an icon grid is made")
		g.rows = names[:]
		g.kinds = kinds[:]
		col := libmui.group(false)
		libmui.add(col, g)
		libmui.fit(col, &ti)
		main_check(g.minh, 2 * libmui.ICON_H + 2 * ti.well, "a grid asks room for its rows of cells and the well")
		main_check(g.minw, 2 * libmui.ICON_W + 2 * ti.well, "and two cells across")
		libmui.lay(col, 0, 0, 3 * libmui.ICON_W + 2 * ti.well + 2 * ti.pad, 2 * libmui.ICON_H + 2 * ti.well + 2 * ti.pad, &ti)
		main_check(libmui.icons_cols(g, &ti), 3, "three cells fit the width it was given")
		main_check(libmui.icons_visible(g, &ti), 2, "and two rows the height")
		main_check(libmui.icons_cell_at(g, g.x + ti.well + 2 * libmui.ICON_W + 5, g.y + ti.well + 5, &ti), 2, "the third cell of the first row is icon two")
		main_check(libmui.icons_cell_at(g, g.x + ti.well + 5, g.y + ti.well + libmui.ICON_H + 5, &ti), 3, "the first cell of the second row is icon three")
		main_check(libmui.icons_cell_at(g, g.x + ti.well + libmui.ICON_W + 5, g.y + ti.well + libmui.ICON_H + 5, &ti), 4, "and the next is four")
		g.top = 1
		main_check(libmui.icons_cell_at(g, g.x + ti.well + 5, g.y + ti.well + 5, &ti), 3, "scrolled a row, the first cell is icon three")
		main_check(libmui.icons_cell_at(g, g.x + ti.well + libmui.ICON_W + 5, g.y + ti.well + libmui.ICON_H + 5, &ti), -1, "and a cell past the last icon is no icon")
		g.top = 0
		g.sel = 4
		c := paint_tree(col, &ti)
		want(has_colour(&c, libpal.xrgb(libpal.COPPER)), "a drawer wears a copper bar")
		want(has_colour(&c, libpal.xrgb(libpal.PHOSPHOR)), "a tool wears a phosphor lamp")
		want(has_colour(&c, libpal.xrgb(ti.face)), "and the selected name sits on a bar of the face")
		want(libmui.hit(col, g.x + 10, g.y + 10) == g, "a click in the well lands on the grid")
	}

	// -- A string gadget takes typing -------------------------------------------
	{
		f := libmui.field()
		want(f != nil, "a field is made")
		store: [8]u8
		want(!libmui.string_key(f, 'a'), "a field with no storage takes nothing")
		f.edit = store[:]
		want(libmui.string_key(f, 'r') && libmui.string_key(f, 'c'), "typed letters land in it")
		want(libmui.field_text(f) == "rc", "and read back as typed")
		want(libmui.string_key(f, 0x08) && libmui.field_text(f) == "r", "a backspace takes the last one off")
		want(!libmui.string_key(f, '\n'), "a Return is not the field's to take")
		for i in 0 ..< 10 {
			_ = libmui.string_key(f, u8('0' + i))
		}
		main_check(f.edit_n, 8, "and the text stops at the storage's end")
	}

	// -- A menu: a column of buttons as wide as the longest --------------------
	{
		tm := libmui.default_theme
		m: libmui.Menu
		items := [?]libmui.Menu_Node{{label = "About..."}, {label = "Execute Command..."}, {label = "Shell"}, {label = "Quit"}}
		root := libmui.menu_build(&m, items[:], &tm)
		want(root != nil, "a menu builds its column")
		n := 0
		widest := 0
		for c := root.first; c != nil; c = c.next {
			n += 1
			if c.minw > widest {
				widest = c.minw
			}
		}
		main_check(n, 4, "with a button per item")
		main_check(m.buttons[1].id, 2, "each tagged by its place")
		want(root.minw >= widest, "and the column as wide as the longest label")
		main_check(root.minw, m.buttons[1].minw + 2 * tm.pad, "which is Execute Command's")
	}

	// -- A menu is a tree: a title, a shortcut, a submenu's arrow ----------------
	//
	// `docs/CHROME.md` section 8. A titled menu puts its name on a strip of
	// the frame's metal over the keys. An item with a shortcut is wider by it,
	// and an item with a submenu says so, which draws its arrow.
	{
		tm := libmui.default_theme
		m: libmui.Menu
		m.title = "Demo"
		sub := [?]libmui.Menu_Node{{label = "Snap left"}, {label = "Snap right"}}
		items := [?]libmui.Menu_Node{{label = "New", shortcut = "alt-n"}, {label = "Window", sub = sub[:]}, {label = "New"}}
		root := libmui.menu_build(&m, items[:], &tm)
		want(root != nil && root.first != nil && root.first.class == .Title, "a titled menu puts its title first")
		want(m.buttons[1].has_sub && !m.buttons[0].has_sub, "and an item with a submenu says so")
		want(m.buttons[0].minw > m.buttons[2].minw, "and an item with a shortcut is wider by it")
		libmui.lay(root, 0, 0, root.minw, root.minh, &tm)
		c := paint_tree(root, &tm)
		t := root.first
		want(libraster.get(&c, t.x + 2, t.y) != libraster.get(&c, t.x + 2, t.y + t.h - 1), "the title is a strip of graded metal")
		key := m.buttons[1]
		ink := libpal.xrgb(tm.ink)
		want(count_in(&c, key.x + key.w - tm.hpad - libmui.ITEM_ARROW - 4, key.y, libmui.ITEM_ARROW + 4, key.h, ink) > 0, "and the submenu's key has its arrow at the right, in the ink")
	}

	// -- An icon grid's free placement, for Snapshot --------------------------
	//
	// Laid out, a grid hits by rows and columns. A cell given a free place is
	// then found there, the others where the grid left them, and Clean Up
	// drops it all back to the grid. The places are the well's own offsets, so
	// a hit is the well's origin plus the place plus a little.
	{
		tg := libmui.default_theme
		names := [?]string{"one", "two", "three", "four"}
		kinds := [?]u8{libmui.ICON_PROJECT, libmui.ICON_PROJECT, libmui.ICON_PROJECT, libmui.ICON_PROJECT}
		g := libmui.icons(2)
		g.rows = names[:]
		g.kinds = kinds[:]
		libmui.fit(g, &tg)
		libmui.lay(g, 0, 0, 3 * libmui.ICON_W, 3 * libmui.ICON_H, &tg)

		// Under the grid, cell zero is at the top-left of the well.
		main_check(libmui.icons_cell_at(g, g.x + tg.well + 4, g.y + tg.well + 4, &tg), 0, "the grid hits its first cell at the well's corner")

		// Place cell two well to the right of every grid column, so its square
		// holds the query point alone; it is found there now, and cell zero
		// stays at its grid corner.
		libmui.icons_set(g, 2, 220, 20, &tg)
		want(g.place != nil, "a placement allocates the grid's places")
		main_check(libmui.icons_cell_at(g, g.x + tg.well + 224, g.y + tg.well + 24, &tg), 2, "a placed cell is found where it was put")
		main_check(libmui.icons_cell_at(g, g.x + tg.well + 4, g.y + tg.well + 4, &tg), 0, "and the others keep their grid places")

		// Clean Up drops free placement back to the grid.
		libmui.icons_clear(g)
		want(g.place == nil, "Clean Up drops the placement")
		main_check(libmui.icons_cell_at(g, g.x + tg.well + 4, g.y + tg.well + 4, &tg), 0, "and the grid lays them out again")
	}

	// -- A theme merges, the later line for a role winning --------------------
	//
	// The switcher hands the base file and the personal one to the parser as
	// one text, base first, so the later line wins. A role named nowhere keeps
	// the chassis, and a metric reads as a number.
	{
		tt: libmui.Theme
		libmui.parse_theme(&tt, "face copper\ntext phosphor\ntext cyan\ngap 9")
		main_check(int(tt.face.r), int(libpal.COPPER.r), "a colour role reads a palette name")
		main_check(int(tt.ink.r), int(libpal.CYAN.r), "the later line for a role wins")
		main_check(tt.gap, 9, "a metric role reads a number")
		main_check(int(tt.ground.r), int(libpal.SLATE_DEEP.r), "a role named nowhere keeps the chassis")
	}

	// -- An icon is drawn from its outlines, `docs/CHROME.md` section 6 -------
	//
	// The chassis names no icons, so a grid keeps its pictures. A scheme
	// names the directory, and the icon comes from its file: a folder is warm
	// through its body, and a union's emblem is cyan in its corner.
	{
		for i in 0 ..< len(cpix) {
			cpix[i] = 0x123456
		}
		c := libraster.canvas(raw_data(cpix[:]), CW, CW, CH)
		chassis := libmui.default_theme
		want(!libmui.icon_named(&c, "folder", 0, 0, 36, &chassis), "the chassis draws no icon of its own")
		ti: libmui.Theme
		libmui.parse_theme(&ti, "icons /lib/icons\ncolour cyan 00e5ff\ncolour amber ffb000")
		want(libmui.icon_named(&c, "folder", 0, 0, 36, &ti), "a scheme's icon is read from its file")
		warm := 0
		for y in 10 ..< 28 {
			for x in 8 ..< 28 {
				v := libraster.get(&c, x, y)
				if v >> 16 & 0xFF > 170 && v & 0xFF < 100 {
					warm += 1
				}
			}
		}
		want(warm > 150, "a folder icon is warm through its body")
		want(libmui.icon_named(&c, "union", 40, 0, 36, &ti), "a union's icon is read too")
		cyan := 0
		for y in 21 ..< 34 {
			for x in 40 + 22 ..< 40 + 35 {
				v := libraster.get(&c, x, y)
				if v >> 16 & 0xFF < 120 && v >> 8 & 0xFF > 150 && v & 0xFF > 180 {
					cyan += 1
				}
			}
		}
		want(cyan > 20, "and its emblem is cyan in its corner")
		want(!libmui.icon_named(&c, "nothing", 80, 0, 36, &ti), "an icon with no file is none")
	}

	libuser.exits("ok")
}
