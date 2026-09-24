/*
workbench -- the desktop, `docs/WORKBENCH.md` section 6.

What `init` starts after the draw server. It opens a `bar` window across
the top of the screen and a `backdrop` behind every other window, holds
`/srv/draw/hotkey` open for the chords the server does not act on, serves
`/srv/wb` for notices, and draws the desktop. Everything it shows is
`sys/libmui`'s: the bar is a row of labels, the backdrop an icon grid, a
drawer window an icon grid in a well, a menu a popup of buttons.

**The bar** says `Vectra Workbench` on the left, the four menu titles
after it, and the machine's memory on the right, off `/dev/sysstat`. Button
3 on a title opens that title's menu as a popup below it, and the `menu`
chord opens the first. The menus are section 6's four, and `Tools` is every
file under `/lib/wb/tools`, whose first line is the command it runs.

**Icons are kinds, not files.** A directory is a drawer, a file under `/bin`
or with its execute bit is a tool, and anything else is a project. The
backdrop carries `Home`, `System`, `Tools` and one icon per disk under `/n`.
A double click opens a drawer window, runs a tool in a `window`, or opens a
project in the tool `/lib/wb/types` names for its suffix, `view` when none.

**Every action is a line.** A chord's action, a menu item's, a notice's and
`Execute Command...`'s are the same lines, run by `run_action`: the verbs
Workbench knows, `open`, `run`, `execute`, `menu`, `workspace`, `shell`,
`quit`, or a command line, which runs in a `window`. A notice's action is
never a shell string, and the notice's text is never in it.

One proc, many threads. Each window's loop is a thread of its own, a
notice arrives on the served tree's thread, and the memory line is a thread
that wakes every few seconds. Nothing here is locked, because a thread runs
until it waits, which is `sys/libthread`'s promise.
*/
package workbench

import "base:runtime"

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libmui"
import "vsys:libndb"
import "vsys:libthread"
import "vsys:libuser"

BAR_H :: 24
TOOLS_DIR :: "/lib/wb/tools"
TYPES_FILE :: "/lib/wb/types"

// The bar and the backdrop, the two windows the desktop is. On the heap,
// because a window carries a paint buffer and the loader's frame budget
// is a quarter megabyte of image, `kernel/user`'s bound.
bar: ^libmui.Window
back: ^libmui.Window

// The menu at the pointer, and the popup it draws in.
menu: libmui.Menu
menu_win: ^libmui.Window
menu_title: int // Which of the four submenus the choice was in

/*
The main menu, docked at the top left while the desktop is in front,
`docs/CHROME.md` section 8. It is one tree of the four menus the screen bar
carried, `Workbench`, `Window`, `Icons` and `Tools`, each a submenu. The
menu at the pointer is a copy of the same tree. A submenu is filled just
before it opens. The Window menu grows a `Kill` per window asked to close,
and the Tools menu is a directory.
*/
main_menu: libmui.Menu
main_win: ^libmui.Window
top_nodes: [4]libmui.Menu_Node
sub_nodes: [4][libmui.MENU_ITEMS]libmui.Menu_Node

// The room the backdrop keeps clear at its left for the docked main menu.
DOCK_ROOM :: 160

screen_w, screen_h: int

// The heap's context, made once at start and taken up by every procedure
// here that allocates, since a handler the toolkit calls carries none.
wb_ctx: runtime.Context

// The bar's own labels, and the storage the memory line is written into.
mem_label: ^libmui.Object
mem_text: [64]u8
TITLES := [4]string{"Workbench", "Window", "Icons", "Tools"}

// The backdrop's icons: the names, the paths under them, and the kinds.
MAX_BACK :: 16
back_grid: ^libmui.Object
back_names: [MAX_BACK]string
back_paths: [MAX_BACK]string
back_kinds: [MAX_BACK]u8
back_n: int

// The tools under /lib/wb/tools, read once when the menu first opens.
MAX_TOOLS :: 12
tool_names: [MAX_TOOLS]string
tool_n: int
tools_read: bool

// The menu's items, built per title.
MENU_WORKBENCH := [?]string{"About...", "Execute Command...", "Shell", "Snapshot", "Clean Up", "Theme...", "Reload", "Lock", "Quit"}
MENU_WINDOW := [?]string{"New Drawer", "Open Parent", "Close", "Update", "Select All", "Clean Up", "Snapshot"}
MENU_ICONS := [?]string{"Open", "Copy", "Rename...", "Information...", "Delete..."}
menu_items: [MAX_TOOLS]string

// The Workbench menu grows a `Shell on <host>` for every machine `ndb` marks
// `cpu=` -- picking one opens a `cpu` shell on it in a window. `docs/FLEET.md`
// section 7. The names and the labels live here for the life of the desktop,
// because the menu holds slices of them.
WB_SHELL_MAX :: 6
cpu_hosts: [WB_SHELL_MAX]string
cpu_host_n: int
cpu_host_buf: [192]u8
shell_label_buf: [256]u8
wb_menu: [len(MENU_WORKBENCH) + WB_SHELL_MAX]string
wb_menu_n: int

// read_cpu_hosts scans the local database once for the machines a `cpu` shell
// can run on -- those marked `cpu=` -- and builds the Workbench menu from the
// base items and a `Shell on <host>` for each, this machine itself left off.
read_cpu_hosts :: proc "contextless" () {
	context = wb_ctx
	// This machine's own name, so it does not offer a shell on itself.
	selfbuf: [64]u8
	self := ""
	if fd := libuser.open("/net/sysname", abi.O_RDONLY); fd >= 0 {
		n := libuser.read(int(fd), selfbuf[:])
		_ = libuser.close(int(fd))
		if n > 0 {
			self = trim_line(string(selfbuf[:n]))
		}
	}
	data, ok := libuser.read_file("/lib/ndb/local", context.allocator)
	if ok {
		defer delete(data)
		text := string(data)
		at := 0
		hb := 0
		for cpu_host_n < WB_SHELL_MAX {
			rec, next, more := libndb.record_at(text, at)
			if !more {
				break
			}
			at = next
			name, has_sys := libndb.attr_of(rec, "sys")
			if !has_sys {
				continue
			}
			if _, has_cpu := libndb.attr_of(rec, "cpu"); !has_cpu {
				continue
			}
			if name == self || hb + len(name) > len(cpu_host_buf) {
				continue
			}
			m := copy(cpu_host_buf[hb:], name)
			cpu_hosts[cpu_host_n] = string(cpu_host_buf[hb:hb + m])
			hb += m
			cpu_host_n += 1
		}
	}
	build_wb_menu()
}

// build_wb_menu lays the base items down, then a `Shell on <host>` per machine.
build_wb_menu :: proc "contextless" () {
	n := 0
	for it in MENU_WORKBENCH {
		wb_menu[n] = it
		n += 1
	}
	lb := 0
	for i in 0 ..< cpu_host_n {
		start := lb
		lb += copy(shell_label_buf[lb:], "Shell on ")
		lb += copy(shell_label_buf[lb:], cpu_hosts[i])
		wb_menu[n] = string(shell_label_buf[start:lb])
		n += 1
	}
	wb_menu_n = n
}

// trim_line drops a trailing newline or carriage return from a read value.
trim_line :: proc "contextless" (s: string) -> string {
	end := len(s)
	for end > 0 && (s[end - 1] == '\n' || s[end - 1] == '\r') {
		end -= 1
	}
	return s[:end]
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	wb_ctx = libuser.startup()
	context = wb_ctx
	libthread.main(wb_main, nil)
}

wb_main :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = wb_ctx
	screen_size()
	menu_win = new(libmui.Window)
	bar = new(libmui.Window)
	back = new(libmui.Window)
	if menu_win == nil || bar == nil || back == nil {
		libthread.threadexitsall("no memory")
	}
	menu.win = menu_win
	menu.handler = main_chosen
	menu.on_cascade = main_cascade
	main_win = new(libmui.Window)
	if main_win == nil {
		libthread.threadexitsall("no memory")
	}
	main_menu.win = main_win
	main_menu.handler = main_chosen
	main_menu.on_cascade = main_cascade
	fill_menus()

	// The notice service first, posted and served before a window opens,
	// so `init` and the desktop's own mount find a server answering.
	notice_mounted = libthread.chancreate(size_of(u64), 1)
	notice_post()
	_ = libthread.threadcreate(notice_thread, nil)
	_ = libthread.threadcreate(mount_thread, nil)
	libthread.yield()

	// The look, from /lib/theme and $home/lib/theme, before a window opens so
	// each takes it. `docs/WORKBENCH.md` section 5.
	theme_load()

	// The machines a `cpu` shell can run on, from `ndb`, for the menu below.
	read_cpu_hosts()

	if !open_bar() {
		libuser.eprint("workbench: no bar\n")
		libthread.threadexitsall("no bar")
	}
	if !open_backdrop() {
		libuser.eprint("workbench: no backdrop\n")
		libthread.threadexitsall("no backdrop")
	}
	_ = libthread.threadcreate(window_thread, bar)
	_ = libthread.threadcreate(window_thread, back)
	_ = libthread.threadcreate(dock_thread, nil)
	_ = libthread.threadcreate(memory_thread, nil)
	_ = libthread.threadcreate(toast_thread, nil)
	hotkey_loop()
	libthread.threadexitsall("")
}

/*
dock_thread opens the main menu, docked over the backdrop and shown while the
desktop or a drawer is in front, once `/srv/wb` is mounted.

**It waits for the notice service's handshake.** The notice service is a thread
of this proc, and the kernel's handshake with it, for the mount `mount_thread`
asks, has a deadline. A thread that opens a window runs a long while without
yielding. The dock opened in that window of time kept the handshake past its
deadline. The kernel then tears the wire down, the service ends, and
`/srv/wb` never answers a mount again. So the dock opens after the mount.
*/
dock_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = wb_ctx
	if notice_mounted != nil {
		_ = libthread.recvul(notice_mounted)
	}
	_ = libmui.menu_dock(&main_menu, back, "Workbench", top_nodes[:])
	libthread.threadexits("")
}

// window_thread runs one window's loop until the window is done.
window_thread :: proc "contextless" (arg: rawptr) {
	libmui.window_run((^libmui.Window)(arg))
	libthread.threadexits("")
}

// screen_size reads the framebuffer's geometry, the bar's width and the
// backdrop's height.
screen_size :: proc "contextless" () {
	screen_w, screen_h = 640, 480
	fd := libuser.open("/dev/fbctl", abi.O_RDONLY)
	if fd < 0 {
		return
	}
	report: [128]u8
	n := libuser.read(int(fd), report[:])
	_ = libuser.close(int(fd))
	if w, h, _, _, ok := libdraw.parse_geometry(report[:max(int(n), 0)]); ok && w > 0 && h > 0 {
		screen_w, screen_h = w, h
	}
}

// -- The bar --------------------------------------------------------------------

open_bar :: proc "contextless" () -> bool {
	row := libmui.group(true)
	libmui.add(row, libmui.text("Vectra Workbench"))
	libmui.add(row, libmui.space())
	mem_label = libmui.text(memory_line())
	libmui.add(row, mem_label)

	bar.kind = .Bar
	bar.bind_dev = false
	bar.own_exit = false
	bar.set_up = true
	bar.placed = true
	bar.at_x, bar.at_y = 0, 0
	bar.want_w, bar.want_h = screen_w, BAR_H
	bar.on_menu = bar_menu
	bar.handler = bar_press
	return libmui.window_open(bar, "Workbench", row)
}

bar_press :: proc "contextless" (w: ^libmui.Window, id: int) {
	_ = w
	_ = id
}

// bar_menu is button 3 on the bar: the main menu at the pointer. The bar
// carries no menus of its own, `docs/CHROME.md` section 8.
bar_menu :: proc "contextless" (w: ^libmui.Window, x: int, y: int) {
	libmui.window_locate(w)
	open_menu(0, w.sx + x, w.sy + y)
}

/*
The Window menu grows a `Kill` for each window the desktop asked to close
that has not, past the theme's `closegrace`: the server lists them on its
`ctl`, `closing N title`. Choosing one hangs the window up, `kill N`, which
is what the close gadget did before it asked. `docs/WORKBENCH.md` step 5.
*/
KILL_MAX :: 4
kill_ids: [KILL_MAX]int
kill_n: int
kill_labels: [KILL_MAX][64]u8
window_items: [len(MENU_WINDOW) + KILL_MAX]string

window_menu_items :: proc "contextless" () -> []string #no_bounds_check {
	n := copy(window_items[:], MENU_WINDOW[:])
	kill_n = 0
	report: [1024]u8
	fd := libuser.open("/mnt/ctl", abi.O_RDONLY)
	if fd < 0 {
		return window_items[:n]
	}
	got := libuser.read(int(fd), report[:])
	_ = libuser.close(int(fd))
	text := string(report[:max(int(got), 0)])
	for len(text) > 0 && kill_n < KILL_MAX {
		eol := 0
		for eol < len(text) && text[eol] != '\n' {
			eol += 1
		}
		line := text[:eol]
		text = text[min(eol + 1, len(text)):]
		verb, rest := first_word(line)
		if verb != "closing" {
			continue
		}
		num, title := first_word(rest)
		id, ok := libuser.atoi(num)
		if !ok {
			continue
		}
		label := libuser.cat_into(kill_labels[kill_n][:], "Kill ", title == "" ? num : title)
		kill_ids[kill_n] = int(id)
		window_items[n] = label
		n += 1
		kill_n += 1
	}
	return window_items[:n]
}

// open_menu opens a copy of the main menu at a point on the screen, the
// menu at the pointer. `which` is the submenu a caller had in mind, and the
// whole tree opens, as a program's menu at the pointer does.
open_menu :: proc "contextless" (which: int, x: int, y: int) {
	_ = which
	if menu.open {
		return
	}
	fill_menus()
	_ = libmui.menu_open_tree(&menu, "Workbench", top_nodes[:], x, y)
}

// fill_menus lays the four submenus down from what each lists now. They are
// the base Workbench items and a `Shell on` per machine, the Window items and
// a `Kill` per window asked to close, the icon verbs, and the tools.
fill_menus :: proc "contextless" () {
	lists: [4][]string
	lists[0] = wb_menu_n > 0 ? wb_menu[:wb_menu_n] : MENU_WORKBENCH[:]
	lists[1] = window_menu_items()
	lists[2] = MENU_ICONS[:]
	read_tools()
	lists[3] = tool_names[:tool_n]
	if tool_n == 0 {
		menu_items[0] = "(no tools)"
		lists[3] = menu_items[:1]
	}
	for i in 0 ..< 4 {
		n := min(len(lists[i]), libmui.MENU_ITEMS)
		for k in 0 ..< n {
			sub_nodes[i][k] = libmui.Menu_Node{label = lists[i][k]}
		}
		top_nodes[i] = libmui.Menu_Node{label = TITLES[i], sub = sub_nodes[i][:n]}
	}
}

// main_cascade fills the submenus just before one opens.
main_cascade :: proc "contextless" (m: ^libmui.Menu, i: int) {
	_ = m
	_ = i
	fill_menus()
}

// main_chosen hears a choice two deep, on the dock or at the pointer: the
// submenu is the item, and the choice in it is `sub_chosen`.
main_chosen :: proc "contextless" (m: ^libmui.Menu, item: int) {
	if item < 0 || m.sub_chosen < 0 {
		return
	}
	menu_title = item
	menu_chosen(m, m.sub_chosen)
}

// menu_chosen hears the item, and runs what it means.
menu_chosen :: proc "contextless" (m: ^libmui.Menu, item: int) {
	context = wb_ctx
	_ = m
	if item < 0 {
		return
	}
	switch menu_title {
	case 0:
		switch item {
		case 0:
			post_notice("workbench", "Vectra Workbench, September 2026. A desktop of files.", "")
		case 1:
			execute_open()
		case 2:
			run_action("window rc -i")
		case 3: // Snapshot: keep the backdrop's icon positions
			snapshot_save(BACKDROP_KEY, back_grid, back_names[:back_n])
		case 4: // Clean Up: drop them and lay the backdrop's icons in rows again
			libmui.icons_clear(back_grid)
			libmui.window_relayout(back)
		case 5: // Theme...: the picker over /lib/themes
			theme_pick()
		case 6:
			server_ctl("reload")
		case 7: // Lock: the server takes the glass until the passphrase
			server_ctl("lock")
		case 8:
			libthread.threadexitsall("")
		case:
			// A `Shell on <host>` past the base items: open a `cpu` shell on
			// that machine in a window, its three descriptors the window's own.
			h := item - len(MENU_WORKBENCH)
			if h >= 0 && h < cpu_host_n {
				cmd: [64]u8
				spawn_window(libuser.cat_into(cmd[:], "cpu -h ", cpu_hosts[h], " -f"))
			}
		}
	case 1:
		drawer_window_menu(item)
	case 2:
		drawer_icons_menu(item)
	case:
		if item < tool_n {
			run_tool(tool_names[item])
		}
	}
}

// -- The backdrop --------------------------------------------------------------------

open_backdrop :: proc "contextless" () -> bool {
	context = wb_ctx
	back_n = 0
	back_icon("Home", home_path(), libmui.ICON_DRAWER)
	back_icon("System", "/", libmui.ICON_DRAWER)
	back_icon("Tools", "/bin", libmui.ICON_DRAWER)
	if fd := libuser.open("/n", abi.O_RDONLY); fd >= 0 {
		names := libuser.list_dir(int(fd))
		_ = libuser.close(int(fd))
		libuser.sort_strings(names)
		for name in names {
			if back_n < MAX_BACK && dir_has_entries(libuser.join("/n", name)) {
				back_icon(name, libuser.join("/n", name), libmui.ICON_DRAWER)
			}
		}
	}
	back_grid = libmui.icons(3)
	back_grid.rows = back_names[:back_n]
	back_grid.kinds = back_kinds[:back_n]
	back_grid.id = 1
	// The docked main menu's corner kept clear at the left.
	col := libmui.group(true)
	libmui.add(col, libmui.strut(DOCK_ROOM))
	libmui.add(col, back_grid)

	back.kind = .Backdrop
	back.bind_dev = false
	back.own_exit = false
	back.set_up = true
	back.placed = true
	back.at_x, back.at_y = 0, BAR_H
	back.want_w, back.want_h = screen_w, screen_h - BAR_H
	back.handler = back_press
	back.on_menu = back_menu
	back.on_drop = back_drop
	if !libmui.window_open(back, "Workbench", col) {
		return false
	}
	// A saved arrangement, placed onto the laid grid and painted.
	snapshot_load(BACKDROP_KEY, back_grid, back_names[:back_n])
	libmui.window_paint(back)
	return true
}

back_icon :: proc "contextless" (name: string, path: string, kind: u8) {
	if back_n >= MAX_BACK {
		return
	}
	back_names[back_n] = name
	back_paths[back_n] = path
	back_kinds[back_n] = kind
	back_n += 1
}

// back_press: a double click on an icon opens what it is.
back_press :: proc "contextless" (w: ^libmui.Window, id: int) {
	if id == 1 && w.clicks == 2 && w.arg >= 0 && w.arg < back_n {
		open_path(back_paths[w.arg], back_kinds[w.arg])
	}
}

back_menu :: proc "contextless" (w: ^libmui.Window, x: int, y: int) {
	libmui.window_locate(w)
	open_menu(0, w.sx + x, w.sy + y)
}

// back_drop repositions a backdrop icon where it was dropped. The backdrop
// fills the screen below the bar, so a drop is always within it; a desktop
// icon has nowhere else to go. `icon_reposition` and Snapshot are `drawer`'s.
back_drop :: proc "contextless" (w: ^libmui.Window, item: int, x: int, y: int) {
	context = wb_ctx
	icon_reposition(back_grid, item, x, y)
	libmui.window_paint(back)
}

// home_path is `$home`, or the host owner's home when the environment
// does not say.
home_path :: proc "contextless" () -> string {
	if fd := libuser.open("/env/home", abi.O_RDONLY); fd >= 0 {
		n := libuser.read(int(fd), home_buf[:])
		_ = libuser.close(int(fd))
		if n > 0 {
			end := int(n)
			for end > 0 && (home_buf[end - 1] == '\n' || home_buf[end - 1] == 0) {
				end -= 1
			}
			if end > 0 {
				return string(home_buf[:end])
			}
		}
	}
	return "/usr/glenda"
}
home_buf: [128]u8

// dir_has_entries says whether a directory opens and holds anything, which
// is what makes a disk under /n worth an icon.
dir_has_entries :: proc "contextless" (path: string) -> bool {
	context = wb_ctx
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return false
	}
	names := libuser.list_dir(int(fd))
	_ = libuser.close(int(fd))
	return len(names) > 0
}

// -- Memory on the bar ---------------------------------------------------------------

// memory_line reads /dev/sysstat and writes the bar's right-hand text.
memory_line :: proc "contextless" () -> string {
	total, free := u64(0), u64(0)
	if fd := libuser.open("/dev/sysstat", abi.O_RDONLY); fd >= 0 {
		line: [96]u8
		n := libuser.read(int(fd), line[:])
		_ = libuser.close(int(fd))
		at := 0
		if n > 4 {
			at = 4 // past "mem "
			t, tok := libdraw.scan_int(line[:int(n)], &at)
			f, fok := libdraw.scan_int(line[:int(n)], &at)
			if tok && fok {
				total, free = u64(t), u64(f)
			}
		}
	}
	tmp: [24]u8
	at := copy(mem_text[:], libuser.itoa(tmp[:], i64(free / 1024)))
	at += copy(mem_text[at:], "M free of ")
	at += copy(mem_text[at:], libuser.itoa(tmp[:], i64(total / 1024)))
	at += copy(mem_text[at:], "M")
	return string(mem_text[:at])
}

// memory_thread rewrites the memory line every five seconds. The wait goes
// through an io proc, so the desktop's other threads run meanwhile.
memory_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	io := libthread.ioproc()
	if io == nil {
		libthread.threadexits("")
	}
	for !bar.done {
		_ = libthread.iosleep(io, 5000)
		if mem_label != nil {
			mem_label.label = memory_line()
			libmui.window_relayout(bar)
		}
	}
	libthread.threadexits("")
}

// -- Actions ----------------------------------------------------------------------------

/*
hotkey_loop reads `/srv/draw/hotkey`, one action line per read, for as long
as the server serves it, and runs each. The server holds the file's reads
until a chord it does not act on is pressed, so this thread is parked
almost always. The draw server is at /mnt, where `window_open` mounted it.
*/
hotkey_loop :: proc "contextless" () {
	fd := libuser.open("/mnt/hotkey", abi.O_RDONLY)
	if fd < 0 {
		return
	}
	io := libthread.ioproc()
	if io == nil {
		return
	}
	line: [128]u8
	for {
		n := libthread.ioread(io, int(fd), line[:])
		if n <= 0 {
			break
		}
		end := int(n)
		for end > 0 && (line[end - 1] == '\n' || line[end - 1] == ' ') {
			end -= 1
		}
		run_action(string(line[:end]))
	}
}

/*
run_action runs one line. The first word is a verb Workbench knows, or the
line is a command, which runs in a window of its own. This is the one place
an action becomes a program, so a notice's action and a chord's are the same
thing and neither is a shell string.
*/
run_action :: proc "contextless" (line: string) {
	verb, rest := first_word(line)
	switch verb {
	case "":
	case "execute":
		execute_open()
	case "menu":
		open_menu(0, 0, BAR_H)
	case "shell":
		spawn_window("rc -i")
	case "open":
		open_path(rest, path_kind(rest))
	case "run":
		spawn_window(rest)
	case "workspace":
		server_ctl(line)
	case "quit":
		libthread.threadexitsall("")
	case "window":
		spawn_window(rest)
	case:
		spawn_window(line)
	}
}

// spawn_window starts `window` on a command line, so the command has a
// window of its own to run in. The line is split into words for its argv.
spawn_window :: proc "contextless" (cmdline: string) {
	argv: [16]string
	n := 0
	argv[n] = "window"
	n += 1
	rest := cmdline
	for n < len(argv) {
		w, r := first_word(rest)
		if w == "" {
			break
		}
		argv[n] = w
		n += 1
		rest = r
	}
	// Detached: the desktop opens windows and never waits for them, so the
	// kernel reaps each when its window closes. Without this a closed shell
	// or tool would sit in the process table forever, a slot the desktop
	// leaks every time it launches one.
	_ = libuser.spawn("/bin/window", abi.SPAWN_NOWAIT, argv[:n])
}

// run_tool runs one of /lib/wb/tools: the file's first line is its command.
run_tool :: proc "contextless" (name: string) {
	context = wb_ctx
	path := libuser.join(TOOLS_DIR, name)
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return
	}
	line: [128]u8
	n := libuser.read(int(fd), line[:])
	_ = libuser.close(int(fd))
	end := 0
	for end < int(n) && line[end] != '\n' {
		end += 1
	}
	if end > 0 {
		spawn_window(string(line[:end]))
	}
}

// read_tools lists /lib/wb/tools once.
read_tools :: proc "contextless" () {
	context = wb_ctx
	if tools_read {
		return
	}
	tools_read = true
	fd := libuser.open(TOOLS_DIR, abi.O_RDONLY)
	if fd < 0 {
		return
	}
	names := libuser.list_dir(int(fd))
	_ = libuser.close(int(fd))
	libuser.sort_strings(names)
	for name in names {
		if tool_n < MAX_TOOLS {
			tool_names[tool_n] = name
			tool_n += 1
		}
	}
}

// server_ctl writes one line to the draw server's ctl.
server_ctl :: proc "contextless" (line: string) {
	fd := libuser.open("/mnt/ctl", abi.O_WRONLY)
	if fd < 0 {
		return
	}
	_ = libuser.write(int(fd), transmute([]u8)line)
	_ = libuser.close(int(fd))
}

// first_word splits a line at its first space, both sides trimmed.
first_word :: proc "contextless" (s: string) -> (word: string, rest: string) {
	i := 0
	for i < len(s) && s[i] == ' ' {
		i += 1
	}
	j := i
	for j < len(s) && s[j] != ' ' {
		j += 1
	}
	k := j
	for k < len(s) && s[k] == ' ' {
		k += 1
	}
	return s[i:j], s[k:]
}

// ends_with reports whether a name carries a suffix.
ends_with :: proc "contextless" (s: string, suffix: string) -> bool {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}

// base_name is the last element of a path.
base_name :: proc "contextless" (path: string) -> string {
	i := len(path)
	for i > 0 && path[i - 1] == '/' {
		i -= 1
	}
	j := i
	for j > 0 && path[j - 1] != '/' {
		j -= 1
	}
	if i == j {
		return "/"
	}
	return path[j:i]
}

// parent_of is the directory a path is in.
parent_of :: proc "contextless" (path: string) -> string {
	i := len(path)
	for i > 0 && path[i - 1] == '/' {
		i -= 1
	}
	for i > 0 && path[i - 1] != '/' {
		i -= 1
	}
	for i > 1 && path[i - 1] == '/' {
		i -= 1
	}
	if i == 0 {
		return "/"
	}
	return path[:i]
}
