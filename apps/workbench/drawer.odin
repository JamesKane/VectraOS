/*
drawer -- a directory as a window of icons, `docs/WORKBENCH.md` section 6.

A drawer window is a `libmui` window whose root is an icon grid in a well.
Each entry of the directory is an icon of its kind: a directory a drawer, a
program a tool, anything else a project. A single click selects, a double
click opens, and the `Icons` menu acts on the selection. `Window` menu
items act on the drawer in front, which is the last one a click landed in.

A drawer is heap memory, because a window carries a paint buffer, and it
is given back when its window closes.
*/
package workbench

import "vsys:abi"
import "vsys:libmui"
import "vsys:libthread"
import "vsys:libuser"

MAX_DRAWERS :: 8
MAX_ENTRIES :: 256

Drawer :: struct {
	win:   libmui.Window,
	used:  bool,
	path:  string,
	names: []string,
	paths: []string,
	kinds: []u8,
	pics:  []string,
	grid:  ^libmui.Object,
	title: ^libmui.Object,
	// The column view, `columns.odin`, once the drawer is turned to it, and
	// the icon tree it set aside.
	cols:       ^Col_View,
	icons_root: ^libmui.Object,
	cols_shown: bool,
}

drawers: [MAX_DRAWERS]^Drawer
front: ^Drawer // The drawer a click last landed in, which the menus act on

// open_path opens what a path is: a drawer as a window, a tool in a
// window, a project in the tool its suffix names.
open_path :: proc "contextless" (path: string, kind: u8) {
	switch kind {
	case libmui.ICON_DRAWER:
		open_drawer(path)
	case libmui.ICON_TOOL:
		spawn_window(path)
	case:
		open_project(path)
	}
}

// path_kind asks a stat what a path is.
path_kind :: proc "contextless" (path: string) -> u8 {
	st: abi.Stat
	if libuser.stat(path, &st) < 0 {
		return libmui.ICON_PROJECT
	}
	return kind_of(path, &st)
}

// kind_of is section 6's rule: a directory is a drawer, a file under /bin
// or with its execute bit is a tool, anything else is a project.
kind_of :: proc "contextless" (path: string, st: ^abi.Stat) -> u8 {
	if st.mode & abi.DMDIR != 0 || st.qid_kind & abi.QTDIR != 0 {
		return libmui.ICON_DRAWER
	}
	if len(path) > 5 && path[:5] == "/bin/" {
		return libmui.ICON_TOOL
	}
	if st.mode & 0o111 != 0 {
		return libmui.ICON_TOOL
	}
	return libmui.ICON_PROJECT
}

// open_project runs the tool /lib/wb/types names for the path's suffix, in
// a window, or `view` when no line names it.
open_project :: proc "contextless" (path: string) {
	context = wb_ctx
	tool := "view"
	if fd := libuser.open(TYPES_FILE, abi.O_RDONLY); fd >= 0 {
		text: [1024]u8
		n := libuser.read(int(fd), text[:])
		_ = libuser.close(int(fd))
		rest := string(text[:max(int(n), 0)])
		for len(rest) > 0 {
			line := rest
			if nl := index_byte(rest, '\n'); nl >= 0 {
				line = rest[:nl]
				rest = rest[nl + 1:]
			} else {
				rest = ""
			}
			suffix, cmd := first_word(line)
			if suffix != "" && suffix[0] != '#' && cmd != "" && ends_with(path, suffix) {
				tool = cmd
				break
			}
		}
	}
	line: [512]u8
	at := copy(line[:], tool)
	at += copy(line[at:], " ")
	at += copy(line[at:], path)
	spawn_window(string(line[:at]))
}

index_byte :: proc "contextless" (s: string, c: u8) -> int {
	for i in 0 ..< len(s) {
		if s[i] == c {
			return i
		}
	}
	return -1
}

// open_drawer opens a directory as a window of icons, in a thread of its own.
open_drawer :: proc "contextless" (path: string) {
	context = wb_ctx
	slot := -1
	for i in 0 ..< MAX_DRAWERS {
		if drawers[i] == nil {
			drawers[i] = new(Drawer)
		}
		if drawers[i] != nil && !drawers[i].used {
			slot = i
			break
		}
	}
	if slot < 0 {
		post_notice("workbench", "Too many drawers open", "")
		return
	}
	d := drawers[slot]
	d.used = true
	d.path = clone_string(path)
	if !drawer_read(d) {
		d.used = false
		post_notice("workbench", "Cannot open that drawer", "")
		return
	}
	d.grid = libmui.icons(3)
	d.grid.rows = d.names
	d.grid.kinds = d.kinds
	d.grid.pictures = d.pics
	d.grid.id = 1
	d.title = libmui.text(d.path)
	col := libmui.group(false)
	libmui.add(col, d.title)
	libmui.add(col, d.grid)

	w := &d.win
	w.kind = .Normal
	w.bind_dev = false
	w.own_exit = false
	w.set_up = true
	w.want_w, w.want_h = 4 * libmui.ICON_W + 24, 3 * libmui.ICON_H + 60
	w.handler = drawer_press
	w.on_menu = drawer_menu
	w.on_drop = drawer_drop
	w.user = rawptr(d)
	if !libmui.window_open(w, base_name(d.path), col) {
		d.used = false
		return
	}
	// The grid is laid now, so a saved arrangement can be placed onto it and
	// painted before the window's own thread takes over.
	if snapshot_load(d.path, d.grid, d.names) {
		columns_on(d)
	}
	libmui.window_paint(w)
	front = d
	_ = libthread.threadcreate(drawer_thread, d)
}

// drawer_read lists the drawer's directory into its names, paths and kinds.
drawer_read :: proc "contextless" (d: ^Drawer) -> bool {
	context = wb_ctx
	fd := libuser.open(d.path, abi.O_RDONLY)
	if fd < 0 {
		return false
	}
	names := libuser.list_dir(int(fd))
	_ = libuser.close(int(fd))
	libuser.sort_strings(names)
	n := min(len(names), MAX_ENTRIES)
	d.names = make([]string, n)
	d.paths = make([]string, n)
	d.kinds = make([]u8, n)
	d.pics = make([]string, n)
	ns_read()
	for i in 0 ..< n {
		d.names[i] = names[i]
		d.paths[i] = libuser.join(d.path, names[i])
		st: abi.Stat
		d.kinds[i] = libmui.ICON_PROJECT
		if libuser.stat(d.paths[i], &st) == 0 {
			d.kinds[i] = kind_of(d.paths[i], &st)
		}
		d.pics[i] = picture_of(d.paths[i], d.names[i], d.kinds[i])
	}
	return true
}

// drawer_thread runs the window until it closes, then frees the drawer.
drawer_thread :: proc "contextless" (arg: rawptr) {
	context = wb_ctx
	d := (^Drawer)(arg)
	libmui.window_run(&d.win)
	if front == d {
		front = nil
	}
	delete(d.names)
	delete(d.paths)
	delete(d.kinds)
	delete(d.pics)
	d.used = false
	libthread.threadexits("")
}

// drawer_press: a click in the window makes it the front drawer, and a
// double click on an icon opens it.
drawer_press :: proc "contextless" (w: ^libmui.Window, id: int) {
	d := (^Drawer)(w.user)
	front = d
	if id == -1 {
		w.done = true
		return
	}
	if d.cols_shown && id >= ID_SCROLL {
		columns_press(d, id, w.arg, w.clicks)
		return
	}
	if id == 1 && w.clicks == 2 && w.arg >= 0 && w.arg < len(d.paths) {
		open_path(d.paths[w.arg], d.kinds[w.arg])
	}
}

drawer_menu :: proc "contextless" (w: ^libmui.Window, x: int, y: int) {
	front = (^Drawer)(w.user)
	libmui.window_locate(w)
	open_menu(2, w.sx + x, w.sy + y)
}

// drawer_window_menu is the Window menu, on the drawer in front.
drawer_window_menu :: proc "contextless" (item: int) {
	context = wb_ctx
	d := front
	switch item {
	case 0: // New Drawer
		if d != nil {
			path := libuser.join(d.path, "New Drawer")
			if libuser.mkdir(path) == 0 {
				drawer_update(d)
			} else {
				post_notice("workbench", "Cannot make a drawer there", "")
			}
		}
	case 1: // Open Parent
		if d != nil {
			open_drawer(parent_of(d.path))
		}
	case 2: // Close
		if d != nil {
			libmui.window_end(&d.win)
		}
	case 3: // Update
		if d != nil {
			drawer_update(d)
		}
	case 4: // Select All: the grid holds one selection, so the first
		if d != nil && d.grid != nil && len(d.names) > 0 {
			d.grid.sel = 0
			libmui.window_paint(&d.win)
		}
	case 5: // Clean Up: drop any free placement and lay the icons in rows again
		if d != nil {
			libmui.icons_clear(d.grid)
			libmui.window_relayout(&d.win)
		}
	case 6: // Snapshot: keep this drawer's icon positions, and its view, across sessions
		if d != nil {
			snapshot_save(d.path, d.grid, d.names, d.cols_shown)
		}
	case 7: // Columns: the drawer as a browser, or back to its icons
		if d != nil {
			if d.cols_shown {
				columns_off(d)
			} else {
				columns_on(d)
			}
		}
	case:
		// A `Kill` the menu grew for a window that would not close.
		k := item - len(MENU_WINDOW)
		if k >= 0 && k < kill_n {
			line: [32]u8
			nb: [16]u8
			server_ctl(libuser.cat_into(line[:], "kill ", libuser.itoa(nb[:], i64(kill_ids[k]))))
		}
	}
}

// drawer_update reads the directory again and repaints.
drawer_update :: proc "contextless" (d: ^Drawer) {
	context = wb_ctx
	delete(d.names)
	delete(d.paths)
	delete(d.kinds)
	delete(d.pics)
	if drawer_read(d) {
		d.grid.rows = d.names
		d.grid.kinds = d.kinds
		d.grid.pictures = d.pics
		if d.grid.sel >= len(d.names) {
			d.grid.sel = -1
		}
		libmui.window_relayout(&d.win)
	}
}

/*
drawer_drop is a file dragged out of a drawer and released. `w` is the drawer
the drag began in, `item` the icon it began on, or the row of a column, and
`(x, y)` the release in `w`'s own coordinates -- which the server's grab may
carry outside `w` and onto another drawer. Moving a file from one drawer to
another is a `cp` and an `rm`, `docs/WORKBENCH.md` section 6; a drawer (a
directory) is left where it is, since a move of one is a recursion this cut
does not do. Anything dropped on a column view's shelf is kept there instead,
`columns.odin`.

It runs on the source window's mouse thread and touches both drawers, but
every step between here and the repaints is a synchronous call that `libthread`
does not yield on, so no other window's thread runs in the middle of it.
*/
drawer_drop :: proc "contextless" (w: ^libmui.Window, item: int, x: int, y: int) {
	context = wb_ctx
	src := (^Drawer)(w.user)
	if src == nil {
		return
	}
	path, name, kind := "", "", u8(0)
	if src.cols_shown {
		path, kind = columns_dragged(src, w, item)
		name = base_name(path)
	} else if item >= 0 && item < len(src.paths) {
		path, name, kind = src.paths[item], src.names[item], src.kinds[item]
	}
	if path == "" {
		return
	}
	// Released inside the same window: onto its shelf, or, for icons, a
	// reposition, free placement for Snapshot, not a move between drawers.
	if x >= 0 && x < w.cw && y >= 0 && y < w.ch {
		if on_shelf(src, x, y) {
			shelf_drop(path)
		} else if !src.cols_shown {
			icon_reposition(src.grid, item, x, y)
			libmui.window_paint(&src.win)
		}
		return
	}
	// The screen point the drop landed on, from the source's client origin.
	libmui.window_locate(w)
	dst := drawer_at(w.sx + x, w.sy + y)
	if dst == nil || dst == src {
		return // released on nothing, or back on its own drawer
	}
	if on_shelf(dst, w.sx + x - dst.win.sx, w.sy + y - dst.win.sy) {
		shelf_drop(path)
		return
	}
	if kind == libmui.ICON_DRAWER {
		post_notice("workbench", "Drag a file, not a drawer", "")
		return
	}
	target := libuser.join(dst.path, name)
	if !move_file(path, target) {
		post_notice("workbench", "Cannot move that", "")
		return
	}
	drawer_refresh(src)
	drawer_refresh(dst)
}

// shelf_drop keeps a dropped path on the shelf, or says why not.
shelf_drop :: proc "contextless" (path: string) {
	if !shelf_add(path) {
		post_notice("workbench", "The shelf is full", "")
	}
}

// drawer_refresh reads a drawer again as it is seen: its icons, and its
// columns when it is turned to them.
drawer_refresh :: proc "contextless" (d: ^Drawer) {
	drawer_update(d)
	if d.cols_shown && d.cols != nil {
		for k in 0 ..< d.cols.n {
			_ = col_read(&d.cols.cols[k], d.cols.cols[k].path)
		}
		columns_show(d)
	}
}

// icon_reposition gives an icon a free place under the point it was dropped,
// centred on the cursor, for Snapshot. The point is in the window's client
// coordinates; the grid sits inside the client and its well inside that, so
// the cell's place is the point less the grid's origin, the well, and half a
// cell. `libmui.icons_set` clamps it into the well and repaints follows.
icon_reposition :: proc(grid: ^libmui.Object, item: int, cx: int, cy: int) {
	if grid == nil {
		return
	}
	t := libmui.default_theme
	wx := cx - grid.x - t.well - libmui.ICON_W / 2
	wy := cy - grid.y - t.well - libmui.ICON_H / 2
	libmui.icons_set(grid, item, wx, wy, &t)
}

// drawer_at is the open drawer whose client area holds a screen point, or nil.
drawer_at :: proc "contextless" (sx: int, sy: int) -> ^Drawer #no_bounds_check {
	for i in 0 ..< MAX_DRAWERS {
		d := drawers[i]
		if d == nil || !d.used {
			continue
		}
		libmui.window_locate(&d.win)
		if sx >= d.win.sx && sx < d.win.sx + d.win.cw && sy >= d.win.sy && sy < d.win.sy + d.win.ch {
			return d
		}
	}
	return nil
}

// move_file copies a file's bytes to a new path and removes the original: the
// `cp` and the `rm` section 6's move is. False if the source will not open,
// the destination will not be made, or a read or write fails -- and then the
// original is left, so a failed move loses nothing.
move_file :: proc "contextless" (src: string, dst: string) -> bool #no_bounds_check {
	sfd := libuser.open(src, abi.O_RDONLY)
	if sfd < 0 {
		return false
	}
	dfd := libuser.create(dst, abi.O_WRONLY, 0o644)
	if dfd < 0 {
		libuser.close(int(sfd))
		return false
	}
	buf: [2048]u8
	ok := true
	for {
		n := libuser.read(int(sfd), buf[:])
		if n < 0 {
			ok = false
			break
		}
		if n == 0 {
			break
		}
		if !libuser.write_full(int(dfd), buf[:n]) {
			ok = false
			break
		}
	}
	libuser.close(int(sfd))
	libuser.close(int(dfd))
	if ok {
		_ = libuser.remove(src)
	}
	return ok
}

// drawer_icons_menu is the Icons menu, on the selection in the drawer in
// front, or on the backdrop's selection when no drawer is.
drawer_icons_menu :: proc "contextless" (item: int) {
	path := ""
	kind := libmui.ICON_PROJECT
	d := front
	if d != nil && d.grid != nil && d.grid.sel >= 0 && d.grid.sel < len(d.paths) {
		path = d.paths[d.grid.sel]
		kind = d.kinds[d.grid.sel]
	} else if back_grid != nil && back_grid.sel >= 0 && back_grid.sel < back_n {
		path = back_paths[back_grid.sel]
		kind = back_kinds[back_grid.sel]
		d = nil
	}
	if path == "" {
		post_notice("workbench", "Select an icon first", "")
		return
	}
	switch item {
	case 0: // Open
		open_path(path, kind)
	case 1: // Copy
		post_notice("workbench", "Copy waits for drag and drop", "")
	case 2: // Rename...
		post_notice("workbench", "Rename waits for a requester", "")
	case 3: // Information...
		information(path)
	case 4: // Delete...: to the Recycler, or out of it
		if d == nil {
			post_notice("workbench", "The backdrop's icons stay", "")
		} else if recycle(path, kind) {
			drawer_update(d)
			recycler_update(d)
		} else {
			post_notice("workbench", "Cannot delete that", "")
		}
	}
}

// recycler_update reads an open Recycler drawer again, other than `skip`,
// so a delete or an emptying shows in it.
recycler_update :: proc "contextless" (skip: ^Drawer) {
	for i in 0 ..< MAX_DRAWERS {
		r := drawers[i]
		if r != nil && r.used && r != skip && r.path == recycler_path() {
			drawer_update(r)
		}
	}
}

// information posts a notice with the file's stat: its kind and its size.
information :: proc "contextless" (path: string) {
	st: abi.Stat
	if libuser.stat(path, &st) < 0 {
		post_notice("workbench", "No such file", "")
		return
	}
	text: [200]u8
	tmp: [24]u8
	at := copy(text[:], base_name(path))
	switch kind_of(path, &st) {
	case libmui.ICON_DRAWER:
		at += copy(text[at:], ": a drawer")
	case libmui.ICON_TOOL:
		at += copy(text[at:], ": a tool, ")
		at += copy(text[at:], libuser.itoa(tmp[:], i64(st.length)))
		at += copy(text[at:], " bytes")
	case:
		at += copy(text[at:], ": a project, ")
		at += copy(text[at:], libuser.itoa(tmp[:], i64(st.length)))
		at += copy(text[at:], " bytes")
	}
	post_notice("workbench", string(text[:at]), "")
}

// clone_string copies a string onto the heap, for a path that outlives the
// buffer it arrived in.
clone_string :: proc "contextless" (s: string) -> string {
	context = wb_ctx
	b := make([]u8, len(s))
	copy(b, s)
	return string(b)
}
