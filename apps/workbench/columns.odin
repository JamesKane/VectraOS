/*
columns -- a drawer seen as columns, `docs/CHROME.md` section 11's G.

A second way to look at a drawer, NeXT's browser: each directory a column,
the choice in one opening the next to its right. `Columns` on the Window
menu turns a drawer to it and back.

    the icon path   the deepest column's path as a row of keys, one per
                    element, each a place to go back to
    the columns     a list each, the last few that fit
    a union's tag   under a column for a union directory: its members, in
                    bind order, which is the order its entries are in
    the status      the server behind the deepest folder, off the mount
                    table: `/srv/kfs`, `#c`, or `import one`

The mount table, `/proc/N/ns`, is the witness for the last two. A union's
entries keep the order the kernel lists them in, which is bind order. Any
other column is sorted.

The shelf across the top, and the scroller, are the study's too, and wait.
*/
package workbench

import "vsys:abi"
import "vsys:libmui"
import "vsys:libuser"

MAX_COLS :: 8
// How many columns the window shows, the deepest ones.
SHOW_COLS :: 3
ID_COLUMN :: 100
ID_ELEMENT :: 200
MAX_ELEMENTS :: 16

Column :: struct {
	path:    string,
	names:   []string,
	dirs:    []bool,
	union_n: int,
	tag:     [192]u8,
	tag_n:   int,
}

Col_View :: struct {
	cols:     [MAX_COLS]Column,
	n:        int,
	root:     ^libmui.Object,
	elements: [MAX_ELEMENTS]string,
	status:   [192]u8,
	status_n: int,
}

// col_read lists one directory into a column: its names, which are
// directories, and its union's members when it is one.
col_read :: proc "contextless" (c: ^Column, path: string) -> bool {
	context = wb_ctx
	delete(c.names)
	delete(c.dirs)
	c.names, c.dirs = nil, nil
	c.path = clone_string(path)
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return false
	}
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
	c.dirs = make([]bool, len(names))
	for name, i in names {
		st: abi.Stat
		full := libuser.join(path, name)
		if libuser.stat(full, &st) == 0 {
			c.dirs[i] = st.mode & abi.DMDIR != 0 || st.qid_kind & abi.QTDIR != 0
		}
		delete(full)
	}
	return true
}

// columns_on turns a drawer to columns, the drawer's own directory first.
columns_on :: proc "contextless" (d: ^Drawer) {
	context = wb_ctx
	if d.cols == nil {
		d.cols = new(Col_View)
		if d.cols == nil {
			return
		}
	}
	ns_read()
	d.cols.n = 0
	if col_read(&d.cols.cols[0], d.path) {
		d.cols.n = 1
	}
	d.icons_root = d.win.root
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

/*
columns_show builds the column view's tree from its state and puts it in the
window. The tree is the icon path, the last columns that fit, each with its
union's tag, and the status.
*/
columns_show :: proc "contextless" (d: ^Drawer) {
	context = wb_ctx
	v := d.cols
	if v.n == 0 {
		return
	}
	deep := v.cols[v.n - 1].path
	path_row := libmui.group(true)
	libmui.add(path_row, element_key("/", 0))
	ne := 1
	at := 1
	for at < len(deep) && ne < MAX_ELEMENTS {
		e := at
		for e < len(deep) && deep[e] != '/' {
			e += 1
		}
		if e > at {
			libmui.add(path_row, element_key(deep[at:e], ne))
			v.elements[ne] = deep[:e]
			ne += 1
		}
		at = e + 1
	}
	v.elements[0] = "/"
	libmui.add(path_row, libmui.space())

	cols_row := libmui.group(true)
	for k in max(v.n - SHOW_COLS, 0) ..< v.n {
		c := &v.cols[k]
		col := libmui.group(false)
		list := libmui.list(4)
		list.rows = c.names
		list.id = ID_COLUMN + k
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
		libmui.add(col, list)
		if c.union_n > 1 {
			libmui.add(col, libmui.text(string(c.tag[:c.tag_n])))
		}
		libmui.add(cols_row, col)
	}
	sn := copy(v.status[:], "on ")
	sn += copy(v.status[sn:], server_of(deep))
	v.status_n = sn
	root := libmui.group(false)
	libmui.add(root, path_row)
	libmui.add(root, cols_row)
	libmui.add(root, libmui.text(string(v.status[:sn])))
	v.root = root
	d.win.root = root
	d.win.focus, d.win.pressed = nil, nil
	d.cols_shown = true
	libmui.window_relayout(&d.win)
}

// element_key is one key of the icon path.
element_key :: proc "contextless" (name: string, i: int) -> ^libmui.Object {
	k := libmui.button(name)
	if k != nil {
		k.id = ID_ELEMENT + i
	}
	return k
}

/*
columns_press is a click in the column view. A row of a column chooses that
entry. A directory opens as the next column, and the ones right of it go. A
file opens on a double click. A key of the icon path makes that directory
the first column.
*/
columns_press :: proc "contextless" (d: ^Drawer, id: int, row: int, clicks: int) {
	context = wb_ctx
	v := d.cols
	switch {
	case id >= ID_COLUMN && id < ID_COLUMN + v.n:
		k := id - ID_COLUMN
		c := &v.cols[k]
		if row < 0 || row >= len(c.names) {
			return
		}
		full := libuser.join(c.path, c.names[row])
		if c.dirs[row] {
			if k + 1 < MAX_COLS && col_read(&v.cols[k + 1], full) {
				v.n = k + 2
				columns_show(d)
			}
		} else if clicks == 2 {
			open_path(full, path_kind(full))
		}
	case id >= ID_ELEMENT && id < ID_ELEMENT + MAX_ELEMENTS:
		path := v.elements[id - ID_ELEMENT]
		if path != "" && col_read(&v.cols[0], path) {
			v.n = 1
			columns_show(d)
		}
	}
}

/*
view_report is what Workbench's `view` file says: the drawer in front and how
it is seen. For columns, a `column PATH` line each, with `union` and its
members for a union, then its entries, then the status line. A script, or a
check, reads the browser's state here rather than off the glass.
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
	n += copy(out[n:], "columns\n")
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
