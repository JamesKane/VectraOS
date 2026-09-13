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
	n              = 1,
	ranges         = {0 = {lo = libfont.FONT_FIRST, hi = libfont.FONT_LAST, offset = 0}},
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

// A sink that records the atlas batches into a buffer the test reads back.
rec_buf: [140000]u8
rec_len: int
scratch: [1000]u8

rec_write :: proc "contextless" (user: rawptr, data: []u8) -> bool #no_bounds_check {
	n := copy(rec_buf[rec_len:], data)
	rec_len += n
	return n == len(data)
}

rec_sink :: proc "contextless" () -> libmui.Sink {
	rec_len = 0
	return libmui.Sink{write = rec_write, user = nil}
}

drop_write :: proc "contextless" (user: rawptr, data: []u8) -> bool {
	_, _ = user, data
	return true
}

// drop_sink takes every batch and keeps none, for a bake whose stream
// the check does not read.
drop_sink :: proc "contextless" () -> libmui.Sink {
	return libmui.Sink{write = drop_write, user = nil}
}

// blit_from_range reports whether any blit in the stream reads its source from
// an image id in [lo, hi]. A blit's fields are dst, dx, dy, src, so src is the
// fourth word after the header.
blit_from_range :: proc "contextless" (b: []u8, end: int, lo: u32, hi: u32) -> bool #no_bounds_check {
	at := 0
	for at + libdraw.HEADER <= end {
		size := int(libdraw.get_u16(b, at))
		if size < libdraw.HEADER {
			break
		}
		if b[at + 2] == libdraw.BLIT {
			src := libdraw.get_u32(b, at + libdraw.HEADER + 12)
			if src >= lo && src <= hi {
				return true
			}
		}
		at += size
	}
	return false
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

		f2: libmui.Fonts
		libmui.font_init(&f2, 1)
		want(libmui.font_prepare(col, &f2, scratch[:], rec_sink(), &t2), "the atlases baked")
		end := libmui.paint(paint_buf[:], 0, col, 1, &f2, &t2)
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

		f3: libmui.Fonts
		libmui.font_init(&f3, 1)
		want(libmui.font_prepare(col, &f3, scratch[:], rec_sink(), &t3), "the copper atlas baked")
		end := libmui.paint(paint_buf[:], 0, col, 1, &f3, &t3)
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

	// -- One atlas per colour a label is drawn in, baked once ----------------
	//
	// A text label wants ink on the ground and a button label ink on the face,
	// two colours, so two atlases are baked. A second button of the same face
	// reuses the first, so the count stays two. The button's label then blits
	// from the face atlas, ids seven through twelve, not the ground's one to
	// six.
	{
		tf := libmui.default_theme
		col := libmui.group(false)
		libmui.add(col, libmui.text("File"))
		libmui.add(col, libmui.button("Open"))
		libmui.add(col, libmui.button("Save"))
		libmui.fit(col, &tf)
		libmui.lay(col, 0, 0, 200, 120, &tf)

		fonts: libmui.Fonts
		libmui.font_init(&fonts, 1)
		sink := rec_sink()
		want(libmui.font_prepare(col, &fonts, scratch[:], sink, &tf), "the atlases baked")
		want(fonts.n == 2, "two colours made two atlases")
		want(count_verb(rec_buf[:], rec_len, libdraw.ALLOC) == 2 * libmui.STRIPS, "each atlas allocated its strips")

		end := libmui.paint(paint_buf[:], 0, col, 1, &fonts, &tf)
		want(end > 0, "the paint fit the buffer")
		// The ground atlas took ids 1..6, the face atlas 7..12.
		want(blit_from_range(paint_buf[:], end, 1, 6), "a label blit from the ground atlas")
		want(blit_from_range(paint_buf[:], end, 7, 12), "a button label blit from the face atlas")
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

	// -- A baked face carries the font past ASCII -----------------------------
	//
	// Every test above baked with the past-ASCII font unopened, which is the
	// ASCII-only path a `Fonts` took before this milestone. This opens
	// `/lib/font` the way `window_open` does and bakes one face: it names more
	// than the one ASCII range, locates a Latin-1 letter and refuses a rune no
	// range holds, and allocates more strips than ASCII alone would -- the
	// subfonts uploaded in this ink over this background.
	{
		libmui.font_load()
		want(libmui.text_font.ready, "the past-ASCII font opens from /lib/font")

		fonts: libmui.Fonts
		libmui.font_init(&fonts, 1)
		sink := rec_sink()
		a, ok := libmui.font_for(&fonts, libpal.AMBER, libpal.SLATE, scratch[:], sink)
		want(ok, "a face bakes with the font loaded")
		want(a.n >= 2, "the atlas names ASCII and at least one range past it")

		_, _, e_ok := libdraw.atlas_locate(a, 'é')
		want(e_ok, "a Latin-1 letter is in the atlas")
		_, _, cjk := libdraw.atlas_locate(a, rune(0x4E00))
		want(!cjk, "a rune no range holds is not")

		want(count_verb(rec_buf[:], rec_len, libdraw.ALLOC) > libmui.STRIPS, "it allocated more strips than ASCII alone")
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

		// Two full-font faces are more strips than `rec_buf` holds, and the
		// stream is not read here, so the strips go to a sink that drops them.
		fl: libmui.Fonts
		libmui.font_init(&fl, 1)
		want(libmui.font_prepare(col, &fl, scratch[:], drop_sink(), &tl), "the list's two atlases baked")
		end := libmui.paint(paint_buf[:], 0, col, 1, &fl, &tl)
		want(end > 0, "the list's paint fit the buffer")
		want(has_fill(paint_buf[:], end, libpal.xrgb(tl.face)), "the selected row sits on a bar of the face")
		// "two", "three", "four", "five" drawn: sixteen glyphs.
		main_check(count_verb(paint_buf[:], end, libdraw.BLIT), 16, "the four drawn rows are blitted, glyph by glyph")
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
		fi: libmui.Fonts
		libmui.font_init(&fi, 1)
		want(libmui.font_prepare(col, &fi, scratch[:], drop_sink(), &ti), "the grid's two atlases baked")
		end := libmui.paint(paint_buf[:], 0, col, 1, &fi, &ti)
		want(end > 0, "the grid's paint fit the buffer")
		want(has_fill(paint_buf[:], end, libpal.xrgb(libpal.COPPER)), "a drawer wears a copper bar")
		want(has_fill(paint_buf[:], end, libpal.xrgb(libpal.PHOSPHOR)), "a tool wears a phosphor lamp")
		want(has_fill(paint_buf[:], end, libpal.xrgb(ti.face)), "and the selected name sits on a bar of the face")
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
		items := [?]string{"About...", "Execute Command...", "Shell", "Quit"}
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

	libuser.exits("ok")
}
