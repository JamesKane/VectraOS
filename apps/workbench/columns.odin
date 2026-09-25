/*
columns -- a drawer seen as columns, `docs/CHROME.md` section 11's G.

A second way to look at a drawer, NeXT's browser: each directory a column,
the choice in one opening the next to its right. `Columns` on the Window
menu turns a drawer to it and back, and `Snapshot` keeps the choice.

    the shelf       paths a person keeps, a key each, across the top: a
                    click opens one, and an icon or a row dropped on the
                    shelf is kept there. `$home/lib/wb/shelf`, a path a line,
                    one shelf for every drawer.
    the icon path   the deepest column's path as a row of keys, one per
                    element, each a place to go back to
    the columns     a list each, a row its kind's picture and its name. The
                    window shows three, and a scroller under them moves
                    along when there are more.
    a union's tag   under a column for a union directory: its members, in
                    bind order, which is the order its entries are in
    the status      the server behind the deepest folder, off the mount
                    table: `/srv/kfs`, `#c`, or `import one`

The mount table, `/proc/N/ns`, is the witness for the last two. A union's
entries keep the order the kernel lists them in, which is bind order. Any
other column is sorted.

The view's objects are made once, when a drawer first turns to columns, and
linked again on each change. A scroller being dragged is the object the
toolkit holds as pressed, so it must outlive every change it causes.
*/
package workbench

import "vsys:abi"
import "vsys:libmui"
import "vsys:libuser"

MAX_COLS :: 8
// How many columns the window shows at once.
SHOW_COLS :: 3
ID_SCROLL :: 99
ID_COLUMN :: 100
ID_ELEMENT :: 200
ID_SHELF :: 300
MAX_ELEMENTS :: 16
MAX_SHELF :: 12

Column :: struct {
	path:    string,
	names:   []string,
	kinds:   []u8,
	pics:    []string,
	union_n: int,
	tag:     [192]u8,
	tag_n:   int,
}

Col_View :: struct {
	cols:     [MAX_COLS]Column,
	n:        int,
	// The first column shown, which the scroller moves.
	first:    int,
	elements: [MAX_ELEMENTS]string,
	status:   [192]u8,
	status_n: int,

	// The tree, made once by `columns_make`.
	root:       ^libmui.Object,
	shelf_row:  ^libmui.Object,
	shelf_keys: [MAX_SHELF]^libmui.Object,
	shelf_hint: ^libmui.Object,
	path_row:   ^libmui.Object,
	path_keys:  [MAX_ELEMENTS]^libmui.Object,
	path_space: ^libmui.Object,
	shelf_space: ^libmui.Object,
	cols_row:   ^libmui.Object,
	col_boxes:  [SHOW_COLS]^libmui.Object,
	col_lists:  [SHOW_COLS]^libmui.Object,
	col_tags:   [SHOW_COLS]^libmui.Object,
	scroll:     ^libmui.Object,
	status_txt: ^libmui.Object,
}

// col_read lists one directory into a column: its names, the kind of each
// and its picture, and its union's members when it is one.
col_read :: proc "contextless" (c: ^Column, path: string) -> bool {
	context = wb_ctx
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return false
	}
	delete(c.names)
	delete(c.kinds)
	delete(c.pics)
	c.names, c.kinds, c.pics = nil, nil, nil
	c.path = clone_string(path)
	names := libuser.list_dir(int(fd))
	_ = libuser.close(int(fd))
	c.union_n = 0
	c.tag_n = 0
	if p := ns_find(path); p != nil && p.members > 1 {
		c.union_n = p.members
		c.tag_n = copy(c.tag[:], "union:")
		for k in 0 ..< min(p.members, len(p.sources)) {
			c.tag_n += copy(c.tag[c.tag_n:], " ")
			c.tag_n += copy(c.tag[c.tag_n:], p.sources[k])
		}
	} else {
		// Not a union: sorted. A union keeps the kernel's order, which is
		// bind order.
		libuser.sort_strings(names)
	}
	c.names = names
	c.kinds = make([]u8, len(names))
	c.pics = make([]string, len(names))
	for name, i in names {
		st: abi.Stat
		full := libuser.join(path, name)
		c.kinds[i] = libmui.ICON_PROJECT
		if libuser.stat(full, &st) == 0 {
			c.kinds[i] = kind_of(full, &st)
		}
		c.pics[i] = picture_of(full, name, c.kinds[i])
		delete(full)
	}
	return true
}

// columns_on turns a drawer to columns, the drawer's own directory first.
// A drawer already in columns goes back to its own directory.
columns_on :: proc "contextless" (d: ^Drawer) {
	context = wb_ctx
	if d.cols == nil {
		d.cols = new(Col_View)
		if d.cols == nil {
			return
		}
		columns_make(d.cols)
	}
	ns_read()
	d.cols.n = 0
	d.cols.first = 0
	if col_read(&d.cols.cols[0], d.path) {
		d.cols.n = 1
	}
	if !d.cols_shown {
		d.icons_root = d.win.root
	}
	columns_show(d)
}

// columns_off turns a drawer back to its icons.
columns_off :: proc "contextless" (d: ^Drawer) {
	if d.icons_root == nil {
		return
	}
	d.win.root = d.icons_root
	d.win.focus, d.win.pressed = nil, nil
	d.cols_shown = false
	libmui.window_relayout(&d.win)
}

// columns_make makes the view's objects, every one it will ever show.
columns_make :: proc "contextless" (v: ^Col_View) {
	v.shelf_row = libmui.group(true)
	for i in 0 ..< MAX_SHELF {
		v.shelf_keys[i] = libmui.button("")
		v.shelf_keys[i].id = ID_SHELF + i
	}
	v.shelf_hint = libmui.text("Shelf: drop an icon here to keep it")
	v.shelf_space = libmui.space()
	v.path_row = libmui.group(true)
	for i in 0 ..< MAX_ELEMENTS {
		v.path_keys[i] = libmui.button("")
		v.path_keys[i].id = ID_ELEMENT + i
	}
	v.path_space = libmui.space()
	v.cols_row = libmui.group(true)
	for k in 0 ..< SHOW_COLS {
		v.col_boxes[k] = libmui.group(false)
		v.col_lists[k] = libmui.list(4)
		v.col_lists[k].id = ID_COLUMN + k
		v.col_tags[k] = libmui.text("")
	}
	v.scroll = libmui.scroller(1, 1, 0)
	v.scroll.id = ID_SCROLL
	v.status_txt = libmui.text("")
	v.root = libmui.group(false)
}

// relink empties a group, so its children can be added again in a new set.
relink :: proc "contextless" (o: ^libmui.Object) {
	o.first = nil
}

/*
columns_show puts the view's state into its tree and the tree in the window.
The tree is the shelf, the icon path, and the columns from `first`, each with
its union's tag. Then come the scroller, when there are more than fit, and
the status.
*/
columns_show :: proc "contextless" (d: ^Drawer) {
	context = wb_ctx
	v := d.cols
	if v.n == 0 {
		return
	}
	v.first = clamp(v.first, 0, max(v.n - SHOW_COLS, 0))

	relink(v.shelf_row)
	shelf_load()
	for i in 0 ..< min(shelf_n, MAX_SHELF) {
		v.shelf_keys[i].label = base_name(shelf[i])
		libmui.add(v.shelf_row, v.shelf_keys[i])
	}
	if shelf_n == 0 {
		libmui.add(v.shelf_row, v.shelf_hint)
	}
	libmui.add(v.shelf_row, v.shelf_space)

	relink(v.path_row)
	deep := v.cols[v.n - 1].path
	v.elements[0] = "/"
	v.path_keys[0].label = "/"
	libmui.add(v.path_row, v.path_keys[0])
	ne := 1
	at := 1
	for at < len(deep) && ne < MAX_ELEMENTS {
		e := at
		for e < len(deep) && deep[e] != '/' {
			e += 1
		}
		if e > at {
			v.path_keys[ne].label = deep[at:e]
			v.elements[ne] = deep[:e]
			libmui.add(v.path_row, v.path_keys[ne])
			ne += 1
		}
		at = e + 1
	}
	libmui.add(v.path_row, v.path_space)

	relink(v.cols_row)
	for slot in 0 ..< SHOW_COLS {
		k := v.first + slot
		if k >= v.n {
			break
		}
		c := &v.cols[k]
		box := v.col_boxes[slot]
		relink(box)
		list := v.col_lists[slot]
		list.rows = c.names
		list.kinds = c.kinds
		list.pictures = c.pics
		list.top = 0
		list.sel = -1
		if k + 1 < v.n {
			// The entry the next column is.
			next := base_name(v.cols[k + 1].path)
			for name, i in c.names {
				if name == next {
					list.sel = i
				}
			}
		}
		libmui.add(box, list)
		if c.union_n > 1 {
			v.col_tags[slot].label = string(c.tag[:c.tag_n])
			libmui.add(box, v.col_tags[slot])
		}
		libmui.add(v.cols_row, box)
	}

	sn := copy(v.status[:], "on ")
	sn += copy(v.status[sn:], server_of(deep))
	v.status_n = sn
	v.status_txt.label = string(v.status[:sn])

	relink(v.root)
	libmui.add(v.root, v.shelf_row)
	libmui.add(v.root, v.path_row)
	// The columns take the height, and the rows of keys keep theirs.
	libmui.add(v.root, libmui.weigh(v.cols_row, 1000))
	if v.n > SHOW_COLS {
		libmui.scroller_set(v.scroll, v.n, SHOW_COLS, v.first)
		libmui.add(v.root, v.scroll)
	}
	libmui.add(v.root, v.status_txt)
	if d.win.root != v.root {
		d.win.root = v.root
		d.win.focus, d.win.pressed = nil, nil
	}
	d.cols_shown = true
	libmui.window_relayout(&d.win)
	// A list scrolled to show its choice, once it has a height to show it in.
	for slot in 0 ..< SHOW_COLS {
		if l := v.col_lists[slot]; l.sel >= 0 {
			libmui.list_show(l, l.sel, &d.win.theme)
		}
	}
	libmui.window_paint(&d.win)
}

/*
columns_press is a click in the column view. A row of a column chooses that
entry. A directory opens as the next column, and the ones right of it go. A
file opens on a double click. A key of the icon path makes that directory
the first column. A shelf key opens what it keeps, and the scroller moves
along the columns.
*/
columns_press :: proc "contextless" (d: ^Drawer, id: int, row: int, clicks: int) {
	context = wb_ctx
	v := d.cols
	switch {
	case id == ID_SCROLL:
		if row != v.first {
			v.first = row
			columns_show(d)
		}
	case id >= ID_COLUMN && id < ID_COLUMN + SHOW_COLS:
		columns_choose(d, v.first + id - ID_COLUMN, row, clicks)
	case id >= ID_ELEMENT && id < ID_ELEMENT + MAX_ELEMENTS:
		columns_root(d, v.elements[id - ID_ELEMENT])
	case id >= ID_SHELF && id < ID_SHELF + MAX_SHELF:
		if i := id - ID_SHELF; i < shelf_n {
			open_path(shelf[i], path_kind(shelf[i]))
		}
	}
}

// columns_root makes `path` the view's first and only column.
columns_root :: proc "contextless" (d: ^Drawer, path: string) {
	v := d.cols
	if path != "" && col_read(&v.cols[0], path) {
		v.n = 1
		v.first = 0
		columns_show(d)
	}
}

// columns_choose chooses row `row` of column `k`: a directory opens as the
// next column, and the window moves along to show it. A file opens on a
// double click.
columns_choose :: proc "contextless" (d: ^Drawer, k: int, row: int, clicks: int) {
	context = wb_ctx
	v := d.cols
	if k < 0 || k >= v.n {
		return
	}
	c := &v.cols[k]
	if row < 0 || row >= len(c.names) {
		return
	}
	full := libuser.join(c.path, c.names[row])
	if c.kinds[row] == libmui.ICON_DRAWER {
		if k + 1 < MAX_COLS && col_read(&v.cols[k + 1], full) {
			v.n = k + 2
			v.first = v.n - SHOW_COLS
			columns_show(d)
		}
	} else if clicks == 2 {
		open_path(full, c.kinds[row])
	}
}

// columns_choose_name chooses the entry `name` in the deepest column, as a
// click on its row would: `column NAME` on the ctl.
columns_choose_name :: proc "contextless" (d: ^Drawer, name: string) {
	if d == nil || !d.cols_shown || d.cols == nil || d.cols.n == 0 {
		return
	}
	c := &d.cols.cols[d.cols.n - 1]
	for n, i in c.names {
		if n == name {
			columns_choose(d, d.cols.n - 1, i, 1)
			return
		}
	}
}

// columns_scroll moves the columns shown to start at `first`, as the
// scroller does: `scroll N` on the ctl.
columns_scroll :: proc "contextless" (d: ^Drawer, first: int) {
	if d == nil || !d.cols_shown || d.cols == nil {
		return
	}
	d.cols.first = first
	columns_show(d)
}

// columns_dragged is the path a drag from the column view began on: the
// row of the list the press landed on, or "".
columns_dragged :: proc "contextless" (d: ^Drawer, w: ^libmui.Window, row: int) -> (path: string, kind: u8) {
	context = wb_ctx
	if !d.cols_shown || w.pressed == nil || w.pressed.class != .List {
		return "", 0
	}
	k := d.cols.first + w.pressed.id - ID_COLUMN
	if k < 0 || k >= d.cols.n || row < 0 || row >= len(d.cols.cols[k].names) {
		return "", 0
	}
	c := &d.cols.cols[k]
	return libuser.join(c.path, c.names[row]), c.kinds[row]
}

// on_shelf reports whether a point in a drawer's window is on its shelf.
on_shelf :: proc "contextless" (d: ^Drawer, x: int, y: int) -> bool {
	if d == nil || !d.cols_shown || d.cols == nil {
		return false
	}
	s := d.cols.shelf_row
	return x >= s.x && x < s.x + s.w && y >= s.y && y < s.y + s.h
}

// -- The shelf -----------------------------------------------------------------

shelf: [MAX_SHELF]string
shelf_n: int
@(private = "file") shelf_text: [MAX_SHELF * 128]u8
@(private = "file") shelf_path_buf: [256]u8

// shelf_path is `$home/lib/wb/shelf`.
shelf_path :: proc "contextless" () -> string {
	return libuser.cat_into(shelf_path_buf[:], home_path(), "/lib/wb/shelf")
}

// shelf_load reads the shelf file, a path a line. A missing file is an
// empty shelf.
shelf_load :: proc "contextless" () #no_bounds_check {
	shelf_n = 0
	n := 0
	if fd := libuser.open(shelf_path(), abi.O_RDONLY); fd >= 0 {
		n = int(max(libuser.read(int(fd), shelf_text[:]), 0))
		_ = libuser.close(int(fd))
	}
	i := 0
	for i < n && shelf_n < MAX_SHELF {
		e := i
		for e < n && shelf_text[e] != '\n' {
			e += 1
		}
		if e > i && shelf_text[i] == '/' {
			shelf[shelf_n] = string(shelf_text[i:e])
			shelf_n += 1
		}
		i = e + 1
	}
}

// shelf_write writes the shelf file from `paths` and shows it again in every
// drawer seen as columns.
@(private = "file")
shelf_write :: proc "contextless" (paths: []string) #no_bounds_check {
	out: [MAX_SHELF * 128]u8
	w := 0
	for p in paths {
		if w + len(p) + 1 > len(out) {
			break
		}
		w += copy(out[w:], p)
		out[w] = '\n'
		w += 1
	}
	wb_mkdirs()
	_ = libuser.remove(shelf_path())
	if fd := libuser.create(shelf_path(), abi.O_WRONLY, 0o644); fd >= 0 {
		_ = libuser.write(int(fd), out[:w])
		_ = libuser.close(int(fd))
	}
	for i in 0 ..< MAX_DRAWERS {
		if d := drawers[i]; d != nil && d.used && d.cols_shown {
			columns_show(d)
		}
	}
}

// shelf_add keeps a path on the shelf, at its end. One already there stays
// where it is, and a full shelf takes no more.
shelf_add :: proc "contextless" (path: string) -> bool {
	shelf_load()
	for i in 0 ..< shelf_n {
		if shelf[i] == path {
			return true
		}
	}
	if shelf_n >= MAX_SHELF || len(path) == 0 || path[0] != '/' || index_byte(path, '\n') >= 0 {
		return false
	}
	paths: [MAX_SHELF]string
	copy(paths[:], shelf[:shelf_n])
	paths[shelf_n] = path
	shelf_write(paths[:shelf_n + 1])
	return true
}

// shelf_remove takes a path off the shelf.
shelf_remove :: proc "contextless" (path: string) {
	shelf_load()
	paths: [MAX_SHELF]string
	n := 0
	for i in 0 ..< shelf_n {
		if shelf[i] != path {
			paths[n] = shelf[i]
			n += 1
		}
	}
	shelf_write(paths[:n])
}

/*
view_report is what Workbench's `view` file says: the drawer in front and how
it is seen. For columns, it is a `shelf PATH` line for each path the shelf
keeps. Then a `shown FIRST COUNT of N` line, with `scroller` when one shows.
Then a `column PATH` line each, with `union` and its members for a union, and
its entries. The status line is last. A script, or a check, reads the browser's state here
rather than off the glass.
*/
view_report :: proc "contextless" (out: []u8) -> int {
	d := front
	n := 0
	if d == nil || !d.used {
		return copy(out, "none\n")
	}
	if !d.cols_shown || d.cols == nil {
		n += copy(out[n:], "icons ")
		n += copy(out[n:], d.path)
		n += copy(out[n:], "\n")
		return n
	}
	v := d.cols
	tmp: [16]u8
	n += copy(out[n:], "columns\n")
	for i in 0 ..< shelf_n {
		n += copy(out[n:], "shelf ")
		n += copy(out[n:], shelf[i])
		n += copy(out[n:], "\n")
	}
	// The columns shown: the first, and how many of the whole.
	n += copy(out[n:], "shown ")
	n += copy(out[n:], libuser.itoa(tmp[:], i64(v.first)))
	n += copy(out[n:], " ")
	n += copy(out[n:], libuser.itoa(tmp[:], i64(min(SHOW_COLS, v.n - v.first))))
	n += copy(out[n:], " of ")
	n += copy(out[n:], libuser.itoa(tmp[:], i64(v.n)))
	n += copy(out[n:], v.n > SHOW_COLS ? " scroller\n" : "\n")
	for k in 0 ..< v.n {
		c := &v.cols[k]
		n += copy(out[n:], "column ")
		n += copy(out[n:], c.path)
		if c.union_n > 1 {
			n += copy(out[n:], " ")
			n += copy(out[n:], string(c.tag[:c.tag_n]))
		}
		n += copy(out[n:], "\n")
		for name in c.names {
			if n + len(name) + 3 >= len(out) {
				break
			}
			n += copy(out[n:], "\t")
			n += copy(out[n:], name)
			n += copy(out[n:], "\n")
		}
	}
	n += copy(out[n:], "status ")
	n += copy(out[n:], string(v.status[:v.status_n]))
	n += copy(out[n:], "\n")
	return n
}
