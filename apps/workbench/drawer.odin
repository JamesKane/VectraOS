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
	grid:  ^libmui.Object,
	title: ^libmui.Object,
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
	w.user = rawptr(d)
	if !libmui.window_open(w, base_name(d.path), col) {
		d.used = false
		return
	}
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
	for i in 0 ..< n {
		d.names[i] = names[i]
		d.paths[i] = libuser.join(d.path, names[i])
		st: abi.Stat
		d.kinds[i] = libmui.ICON_PROJECT
		if libuser.stat(d.paths[i], &st) == 0 {
			d.kinds[i] = kind_of(d.paths[i], &st)
		}
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
	if id == 1 && w.clicks == 2 && w.arg >= 0 && w.arg < len(d.paths) {
		open_path(d.paths[w.arg], d.kinds[w.arg])
	}
}

drawer_menu :: proc "contextless" (w: ^libmui.Window, x: int, y: int) {
	front = (^Drawer)(w.user)
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
	case 5: // Clean Up: the grid is always in rows, so this is a relayout
		if d != nil {
			libmui.window_relayout(&d.win)
		}
	}
}

// drawer_update reads the directory again and repaints.
drawer_update :: proc "contextless" (d: ^Drawer) {
	context = wb_ctx
	delete(d.names)
	delete(d.paths)
	delete(d.kinds)
	if drawer_read(d) {
		d.grid.rows = d.names
		d.grid.kinds = d.kinds
		if d.grid.sel >= len(d.names) {
			d.grid.sel = -1
		}
		libmui.window_relayout(&d.win)
	}
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
	case 4: // Delete...
		if d == nil {
			post_notice("workbench", "The backdrop's icons stay", "")
		} else if libuser.remove(path) == 0 {
			drawer_update(d)
		} else {
			post_notice("workbench", "Cannot delete that", "")
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
