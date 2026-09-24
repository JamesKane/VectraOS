/*
window -- a `/srv/draw` window a gadget tree lives in, and the loop that runs it.

This is the toolkit made live. `window_open` claims a window, lays the tree out,
attaches the window's store, and paints it once. `window_run` is the event loop the plan
calls `rio`'s. A thread per file that parks reads the mouse and the keys through
a `sys/libthread` io proc, one proc, no lock. A click is hit-tested down the
tree, and a key goes to the focus. Tab moves it, Return presses the default, and
Escape the cancel, so a requester needs no mouse.

A paint goes into the window's store, the shared buffer the draw server
composites from, `docs/DEVTOOLS.md` step 1, and a write to `store` shows it.
A program a `cpu` runs cannot map the terminal's store, so it paints a copy of
its own and sends the rows that changed as `load` commands, `docs/FLEET.md`
section 7. When a gadget is pressed the window's `handler` hears its id. So a program on the toolkit learns a button was hit
without knowing a pixel.
*/
package libmui

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libraster"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

// One wire slot's worth of body, the most a write to `/srv/draw` may carry.
SLOT :: vectra9.WIRE_SLOT - vectra9.IOHDRSZ

/*
A live window: the files it holds, the client area it was given, the tree it
draws, and the focus a key goes to. A program makes one, fills `root` and
`handler`, opens it, and runs it.
*/
Window :: struct {
	id:        int,
	data_fd:   int,
	cons_fd:   int,
	consctl_fd: int, // Held open, which is what keeps the window's keys raw
	mouse_fd:  int,
	cw:        int,
	ch:        int,
	sx:        int, // Where the client area is on the screen, for a popup
	sy:        int, // opened at a point in it
	theme:     Theme,
	root:      ^Object,
	focus:     ^Object,
	pressed:   ^Object, // The gadget a mouse press landed on, awaiting release
	done:      bool,
	handler:   proc "contextless" (win: ^Window, id: int),

	/*
	What a program says before `window_open`, and what a desktop needs of
	it. `kind` is the `wctl` word the window is opened as, `docs/WORKBENCH.md`
	section 4: a bar, a backdrop or a popup wears no frame. `want_w` and
	`want_h` ask a client area, and `placed` puts the window at `at_x`,
	`at_y` on the screen, both before the first paint. `bind_dev` binds the
	window's directory over `/dev`, which a program of one window wants
	and a program of several cannot have twice. `own_exit` is whether the
	loop's end takes the whole program down, which a program of one window
	wants and a menu does not. `window_defaults` sets the two a program
	of one window wants, and `window_open` calls it for a Window nobody
	set up.
	*/
	kind:      Kind,
	want_w:    int,
	want_h:    int,
	placed:    bool,
	at_x:      int,
	at_y:      int,
	bind_dev:  bool,
	own_exit:  bool,
	set_up:    bool,

	// What an event says beyond the gadget's id. The row or cell a list or
	// grid selected, and whether the press was the second of a double
	// click. The point a button 3 press landed on is `on_menu`'s.
	arg:       int,
	clicks:    int,
	on_menu:   proc "contextless" (win: ^Window, x: int, y: int),
	// A key the program wants first, before the focus and the hotkeys see
	// it: a reader's scrolling, a game's controls. True means it was taken,
	// and the window is painted again.
	on_key:    proc "contextless" (win: ^Window, k: u8) -> bool,
	// A press on an icon that releases somewhere other than where it began is
	// a drag, not a click: `on_drop` hears the cell it began on and the point
	// it released, in the window's own coordinates, which the grab may carry
	// outside the window. The program maps that to a drop. See
	// `docs/WORKBENCH.md` section 6 and `window_open`'s comment on the grab.
	on_drop:   proc "contextless" (win: ^Window, item: int, x: int, y: int),
	// The desktop asked this window to close, the close gadget or alt-w. A
	// program with work to keep keeps it here and answers true to end now,
	// or false to stay open, to ask the person something first. Unset, the
	// window ends at once. `docs/WORKBENCH.md` step 5.
	on_close:  proc "contextless" (win: ^Window) -> bool,
	// The window that opened this one, for a requester: it is written as
	// `parent` on `wctl`, so the server keeps it above that window and moves
	// and hides it with it.
	parent:    ^Window,
	press_x:   int, // where the last press landed, for the drag threshold
	press_y:   int,
	user:      rawptr,
	last_press: ^Object,
	last_ms:   int,
	last_buttons: u8,

	// The io procs the loop reads through. A window that reopens reads
	// through the same two, so they are made once and kept for a window
	// whose end is the program's. A window given back for good -- a popup,
	// a drawer, a notice -- closes them. `window_run` waits on `mouse_done`
	// first, so the mouse reader is off its io proc before it goes back.
	// See `window_close` and `mouse_thread`.
	key_io:    ^libthread.Ioproc,
	mouse_io:  ^libthread.Ioproc,
	mouse_done: ^libthread.Chan,

	/*
	The store: the shared run the server composites from, mapped here by
	the id its `store` file names, with `stride` words a row and the client
	area at (`cx`, `cy`) in it. A remote window paints `local` instead, the
	client area packed tight, and keeps `sent`, the frame the terminal has,
	so a paint sends only the rows that changed.
	*/
	store_fd:  int,
	store:     [^]u32,
	store_id:  u64,
	stride:    int,
	cx:        int,
	cy:        int,
	remote:    bool,
	local:     [^]u32,
	sent:      [^]u32,
	local_n:   int, // the words `local` and `sent` each hold

	scratch:   [SLOT]u8, // One slot, for a remote paint's `load` commands
	geo:       [160]u8,
	path:      [64]u8,
	keys:      [64]u8,
	line:      [64]u8,

	// Where the draw server's files sit. `/mnt` for a local program, which
	// mounts `/srv/draw` there; `$wsys` for a program a `cpu` runs, where the
	// terminal's window system is a tree the export already carries and no
	// mount reaches. `window_open` sets it, and every file below opens under it.
	// See `docs/FLEET.md` section 7.
	base:      string,
	base_buf:  [64]u8,
}

// The kinds a window is opened as, the server's `wctl` words. A normal
// window wears a frame. The other three are their client's whole rectangle.
Kind :: enum u8 {
	Normal,
	Backdrop,
	Bar,
	Popup,
}

// Two presses on one gadget within this many milliseconds are a double click.
DOUBLE_MS :: 400

// window_defaults is what a Window says before a program says otherwise.
// A normal window, one that binds its directory over /dev, and one whose
// end is the program's. A program of several windows sets the last two off.
window_defaults :: proc "contextless" (win: ^Window) {
	win.kind = .Normal
	win.bind_dev = true
	win.own_exit = true
	win.set_up = true
}

/*
window_bounds tells the server what the tree allows: its least size as
`minsize`, and its most as `maxsize` when the tree has one, so a person
cannot size a toolkit window past its layout. And `parent`, when the program
named the window that opened this one. A normal window only: a bar, a
backdrop and a popup are sized by their program alone.
*/
window_bounds :: proc "contextless" (win: ^Window, mine: int) #no_bounds_check {
	if win.kind != .Normal || win.root == nil {
		return
	}
	wctl := libuser.open(libdraw.win_path(win.path[:], win.base, mine, "wctl"), abi.O_WRONLY)
	if wctl < 0 {
		return
	}
	line: [48]u8
	a, b: [16]u8
	_ = libuser.write(int(wctl), transmute([]u8)libuser.cat_into(line[:], "minsize ", libuser.itoa(a[:], i64(win.root.minw)), " ", libuser.itoa(b[:], i64(win.root.minh))))
	if win.root.maxw < BIG && win.root.maxh < BIG {
		_ = libuser.write(int(wctl), transmute([]u8)libuser.cat_into(line[:], "maxsize ", libuser.itoa(a[:], i64(win.root.maxw)), " ", libuser.itoa(b[:], i64(win.root.maxh))))
	}
	// The program, for the server's rules: `app` on `wctl`, as `cmd/window`
	// writes it for the programs it runs.
	if app := app_name(); app != "" {
		_ = libuser.write(int(wctl), transmute([]u8)libuser.cat_into(line[:], "app ", app))
	}
	if win.parent != nil && win.parent.id != mine && !win.parent.done {
		_ = libuser.write(int(wctl), transmute([]u8)libuser.cat_into(line[:], "parent ", libuser.itoa(a[:], i64(win.parent.id))))
	}
	_ = libuser.close(int(wctl))
}

/*
app_name is this program's name, the first word of its `/proc/N/status`,
which is the process's name, read once. `args` would be emptier: a program
the kernel starts has none. The server's rules match a window on it.
*/
@(private = "file") app_buf: [48]u8
@(private = "file") app_len: int = -1

// set_app_name names the program as another would see it: `cmd/style`
// explains a theme for a program it is not.
set_app_name :: proc "contextless" (name: string) {
	app_len = copy(app_buf[:], name)
}

app_name :: proc "contextless" () -> string #no_bounds_check {
	if app_len >= 0 {
		return string(app_buf[:app_len])
	}
	app_len = 0
	pb: [48]u8
	nb: [24]u8
	fd := libuser.open(libuser.cat_into(pb[:], "/proc/", libuser.itoa(nb[:], i64(libuser.getpid())), "/status"), abi.O_RDONLY)
	if fd < 0 {
		return ""
	}
	buf: [128]u8
	n := libuser.read(int(fd), buf[:])
	_ = libuser.close(int(fd))
	end := 0
	for end < max(int(n), 0) && buf[end] != ' ' && buf[end] != '\n' && buf[end] != 0 {
		end += 1
	}
	first := string(buf[:end])
	app_len = copy(app_buf[:], libuser.basename(first))
	return string(app_buf[:app_len])
}

/*
window_open claims a window, lays `root` out in the client area, attaches its
store, and paints it once. It returns false at the first step that fails,
each of which is a window a program cannot have. It runs inside `libthread`,
because the loop that follows does.
*/
window_open :: proc "contextless" (win: ^Window, title: string, root: ^Object) -> bool #no_bounds_check {
	win.root = root
	// The person's theme, read the first time a window opens. A window that
	// takes the shared theme follows it when it changes; one whose program
	// set its own keeps that.
	if !theme_loaded {
		theme_load()
	}
	follows := false
	if win.theme.pad == 0 && win.theme.gap == 0 {
		win.theme = ui_theme
		follows = true
	}
	if !win.set_up {
		window_defaults(win)
	}
	// The font past ASCII, so a label with an accent in it draws. Not
	// fatal: a label falls back to the baked ASCII table.
	font_load()
	win.data_fd, win.cons_fd, win.consctl_fd, win.mouse_fd = -1, -1, -1, -1
	win.store_fd = -1
	win.store = nil
	win.local = nil
	win.sent = nil
	win.local_n = 0

	// The draw server's files. A program a `cpu` runs finds its terminal's
	// window system already in its namespace, named by `$wsys`, and opens the
	// files there -- the verbs cross the wire to the terminal's screen. A local
	// program has `$wsys` unset and mounts `/srv/draw` at `/mnt` once, the way it
	// always did. Either way the files below open under `win.base`. docs/FLEET.md
	// section 7.
	if wsys := libuser.getenv("wsys", win.base_buf[:]); wsys != "" {
		win.base = wsys
	} else {
		win.base = "/mnt"
		probe := libuser.open("/mnt/new", abi.O_RDONLY)
		if probe < 0 {
			if libuser.mount("/srv/draw", "/mnt", abi.ORDER_BEFORE) < 0 {
				return refused("no draw server at /srv/draw")
			}
		} else {
			_ = libuser.close(int(probe))
		}
	}
	nfd := libuser.open(libuser.cat_into(win.path[:], win.base, "/new"), abi.O_RDONLY)
	if nfd < 0 {
		return refused("the server has no window to give")
	}
	nn := libuser.read(int(nfd), win.geo[:])
	_ = libuser.close(int(nfd))
	scan := 0
	mine, mok := libdraw.scan_int(win.geo[:max(int(nn), 0)], &scan)
	if !mok {
		return refused("the new window has no number")
	}
	win.id = mine

	fd := libuser.open(libdraw.win_path(win.path[:], win.base, mine, "data"), abi.O_WRONLY)
	if fd < 0 {
		return refused("the window's data file will not open")
	}
	win.data_fd = int(fd)

	ctl := libuser.open(libdraw.win_path(win.path[:], win.base, mine, "ctl"), abi.O_RDWR)
	if ctl < 0 {
		return unopened(win, "the window's ctl will not open")
	}
	n := libuser.read(int(ctl), win.geo[:])
	w, h, _, _, gok := libdraw.parse_geometry(win.geo[:max(int(n), 0)])
	if !gok {
		_ = libuser.close(int(ctl))
		return unopened(win, "the window's ctl reports no geometry")
	}
	win.cw, win.ch = w, h
	// The bar's name.
	name_at := copy(win.line[:], "name ")
	name_at += copy(win.line[name_at:], title)
	_ = libuser.write(int(ctl), win.line[:name_at])
	// The kind, the size and the place a program asked for, each a line the
	// server takes before the first paint. The geometry is read again
	// after, because a kind or a size changes it.
	if win.kind != .Normal {
		wctl := libuser.open(libdraw.win_path(win.path[:], win.base, mine, "wctl"), abi.O_WRONLY)
		if wctl >= 0 {
			word := "backdrop"
			#partial switch win.kind {
			case .Bar:
				word = "bar"
			case .Popup:
				word = "popup"
			}
			_ = libuser.write(int(wctl), transmute([]u8)word)
			_ = libuser.close(int(wctl))
		}
	}
	if win.want_w > 0 && win.want_h > 0 {
		at := copy(win.line[:], "size ")
		at += len(libuser.itoa(win.line[at:], i64(win.want_w)))
		at += copy(win.line[at:], " ")
		at += len(libuser.itoa(win.line[at:], i64(win.want_h)))
		_ = libuser.write(int(ctl), win.line[:at])
	}
	if win.placed {
		at := copy(win.line[:], "move ")
		at += len(libuser.itoa(win.line[at:], i64(win.at_x)))
		at += copy(win.line[at:], " ")
		at += len(libuser.itoa(win.line[at:], i64(win.at_y)))
		_ = libuser.write(int(ctl), win.line[:at])
	}
	if win.kind != .Normal || (win.want_w > 0 && win.want_h > 0) {
		// At offset zero: the report is a value, and the first read moved
		// this descriptor past it.
		n = libuser.pread(int(ctl), win.geo[:], 0)
		if w2, h2, _, _, ok2 := libdraw.parse_geometry(win.geo[:max(int(n), 0)]); ok2 {
			win.cw, win.ch = w2, h2
		}
	}
	_ = libuser.close(int(ctl))

	// Where the client area is on the screen, off `wctl`, so a popup opened
	// at a point in this window lands under the pointer.
	window_locate(win)

	// This window's own /dev, when the program is the window's alone, so a
	// program it starts inherits the window as its console. The files open
	// by their path either way, which is how a program holds several.
	if win.bind_dev {
		if libuser.bind(libdraw.win_dir(win.path[:], win.base, mine), "/dev", abi.ORDER_BEFORE) < 0 {
			return unopened(win, "the window's directory will not bind over /dev")
		}
	}
	cons := libuser.open(libdraw.win_path(win.path[:], win.base, mine, "cons"), abi.O_RDONLY)
	if cons < 0 {
		return unopened(win, "the window's cons will not open")
	}
	win.cons_fd = int(cons)
	// Raw mode lasts while a consctl descriptor is open, `/dev/consctl`'s
	// rule, so the window keeps its own for as long as it lives. Closed
	// here, the server would cook the keys into lines, and a hotkey would
	// wait for a Return.
	win.consctl_fd = -1
	ccl := libuser.open(libdraw.win_path(win.path[:], win.base, mine, "consctl"), abi.O_WRONLY)
	if ccl >= 0 {
		raw := "rawon"
		_ = libuser.write(int(ccl), transmute([]u8)raw)
		win.consctl_fd = int(ccl)
	}
	mouse := libuser.open(libdraw.win_path(win.path[:], win.base, mine, "mouse"), abi.O_RDONLY)
	if mouse >= 0 {
		win.mouse_fd = int(mouse)
	} else {
		win.mouse_fd = -1
	}
	win.done = false
	win.pressed = nil
	win.last_press = nil
	win.last_buttons = 0

	// The store the tree is painted into.
	if !store_attach(win, mine) {
		window_close(win)
		return false
	}

	// The tree in the client area, and the first paint.
	fit(root, &win.theme)
	window_bounds(win, mine)
	lay(root, 0, 0, win.cw, win.ch, &win.theme)
	set_focus_first(win)
	window_paint(win)
	if follows && win.kind != .Popup {
		theme_follow(win)
	}
	return true
}

// unopened gives back what a `window_open` that failed part way had opened,
// its files and its store, so a program that asks again has not lost them,
// and answers the refusal.
@(private = "file")
unopened :: proc "contextless" (win: ^Window, why: string) -> bool {
	window_close(win)
	return refused(why)
}

// refused says on standard error why a window could not be had, and
// answers the false `window_open` returns. A program that said nothing
// was a boot that could not either.
refused :: proc "contextless" (why: string) -> bool {
	libuser.eprint("mui: no window: ", why, "\n")
	return false
}

// window_relayout lays the tree out again in the client area and paints. A
// program whose rows or labels changed calls this, so a longer label takes
// the room it now needs.
window_relayout :: proc "contextless" (win: ^Window) #no_bounds_check {
	fit(win.root, &win.theme)
	lay(win.root, 0, 0, win.cw, win.ch, &win.theme)
	window_paint(win)
}

/*
store_attach opens the window's `store` file and maps the run it names, the
way `sys/libapp` does. A remote window, whose store is the terminal's memory
and does not cross the wire, gets a run of its own instead. False, said on
standard error, when neither can be had.
*/
@(private = "file")
store_attach :: proc "contextless" (win: ^Window, mine: int) -> bool #no_bounds_check {
	sfd := libuser.open(libdraw.win_path(win.path[:], win.base, mine, "store"), abi.O_RDWR)
	if sfd < 0 {
		return refused("the window has no store file")
	}
	win.store_fd = int(sfd)
	if !store_read(win) {
		return refused("the store file named no run to attach")
	}
	addr, aerr := libuser.shmattach(win.store_id)
	if aerr >= 0 {
		win.store = ([^]u32)(addr)
		return true
	}
	win.remote = true
	return local_fit(win)
}

/*
store_read reads the `store` file's line, `id stride cx cy cw ch`, again. The
client area's place moves when a theme changes the frame, and its size when a
person sizes the window, so a paint asks first. False when the line is not
six numbers with an id.
*/
@(private = "file")
store_read :: proc "contextless" (win: ^Window) -> bool #no_bounds_check {
	line: [96]u8
	n := libuser.pread(win.store_fd, line[:], 0)
	data := line[:max(int(n), 0)]
	at := 0
	id, a := libdraw.scan_int(data, &at)
	stride, b := libdraw.scan_int(data, &at)
	cx, c := libdraw.scan_int(data, &at)
	cy, d := libdraw.scan_int(data, &at)
	cw, e := libdraw.scan_int(data, &at)
	ch, f := libdraw.scan_int(data, &at)
	if !a || !b || !c || !d || !e || !f || id == 0 || stride <= 0 {
		return false
	}
	win.store_id = u64(id)
	win.stride, win.cx, win.cy = stride, cx, cy
	win.cw, win.ch = cw, ch
	return true
}

// local_fit makes a remote window's two runs hold the client area, grown when
// the area grew. `sent` starts unlike anything painted, so the first paint
// sends every row.
@(private = "file")
local_fit :: proc "contextless" (win: ^Window) -> bool #no_bounds_check {
	need := win.cw * win.ch
	if need <= win.local_n && win.local != nil {
		return true
	}
	if win.local != nil {
		libuser.heap_free(win.local)
		libuser.heap_free(win.sent)
	}
	win.local = ([^]u32)(libuser.heap_alloc(need * size_of(u32)))
	win.sent = ([^]u32)(libuser.heap_alloc(need * size_of(u32)))
	if win.local == nil || win.sent == nil {
		win.local_n = 0
		return refused("no memory for the window's pixels")
	}
	win.local_n = need
	for i in 0 ..< need {
		win.sent[i] = 0xFF000000
	}
	return true
}

/*
window_paint redraws the whole tree into the store and shows it. The store's
line is read first: a size the server gave the window lays the tree out again,
and a frame of another size moves where the client area sits in the run.
*/
window_paint :: proc "contextless" (win: ^Window) #no_bounds_check {
	if win.store_fd < 0 {
		return
	}
	ow, oh := win.cw, win.ch
	if !store_read(win) {
		return
	}
	if (win.cw != ow || win.ch != oh) && win.root != nil {
		lay(win.root, 0, 0, win.cw, win.ch, &win.theme)
	}
	if win.remote {
		if !local_fit(win) {
			return
		}
		c := libraster.canvas(win.local, win.cw, win.cw, win.ch)
		paint(&c, win.root, &win.theme)
		present_rows(win)
		return
	}
	if win.store == nil {
		return
	}
	c := libraster.canvas(win.store[win.cy * win.stride + win.cx:], win.stride, win.cw, win.ch)
	paint(&c, win.root, &win.theme)
	// The whole client area, which the server moves in past the frame.
	line: [48]u8
	a, b: [16]u8
	_ = libuser.write(win.store_fd, transmute([]u8)libuser.cat_into(line[:], "0 0 ", libuser.itoa(a[:], i64(win.cw)), " ", libuser.itoa(b[:], i64(win.ch))))
}

/*
present_rows sends a remote window's paint: each row that differs from what the
terminal has, from its first changed pixel to its last, as `load` commands into
image zero, a wire slot or less each. Then a `flush` composites them. A click
that lights one button sends that button's rows, not the window.
*/
@(private = "file")
present_rows :: proc "contextless" (win: ^Window) #no_bounds_check {
	slot := win.scratch[:]
	max_px := max((SLOT - libdraw.HEADER - 20) / 4, 1)
	pix: [SLOT]u8 = ---
	for y in 0 ..< win.ch {
		row := win.local[y * win.cw:]
		was := win.sent[y * win.cw:]
		lo, hi := -1, -1
		for x in 0 ..< win.cw {
			if row[x] != was[x] {
				if lo < 0 {
					lo = x
				}
				hi = x
			}
		}
		if lo < 0 {
			continue
		}
		x := lo
		for x <= hi {
			run := min(max_px, hi + 1 - x)
			for i in 0 ..< run {
				libdraw.put_u32(pix[:], i * 4, row[x + i])
			}
			end := libdraw.put_load(slot, 0, 0, u32(x), u32(y), u32(run), 1, pix[:run * 4])
			if end > 0 {
				_ = libuser.write(win.data_fd, slot[:end])
			}
			x += run
		}
		for k in lo ..= hi {
			was[k] = row[k]
		}
	}
	if end := libdraw.put_flush(slot, 0); end > 0 {
		_ = libuser.write(win.data_fd, slot[:end])
	}
}

/*
window_run is the event loop. It makes a thread for the mouse and reads the
keys itself, each through an io proc, and returns when the window is done. Both
threads are one proc's, so the tree they share needs no lock.
*/
window_run :: proc "contextless" (win: ^Window) #no_bounds_check {
	if win.mouse_fd >= 0 {
		// The channel the mouse reader answers on when it is off its io
		// proc. A window given back must not free what the reader still
		// reads. A program of one window never waits, and needs none.
		if !win.own_exit && win.mouse_done == nil {
			win.mouse_done = libthread.chancreate(size_of(u64), 0)
		}
		_ = libthread.threadcreate(mouse_thread, win)
	}
	if win.key_io == nil {
		win.key_io = libthread.ioproc()
	}
	if win.key_io == nil {
		return
	}
	loop: for {
		got := libthread.ioread(win.key_io, win.cons_fd, win.keys[:])
		// A read that ends means the window's files are gone: the server
		// hung it up, or closed. The window is done either way.
		if got <= 0 {
			break
		}
		for i in 0 ..< int(got) {
			key_event(win, win.keys[i])
			if win.done {
				break loop
			}
		}
	}
	win.done = true
	// A program of one window comes down whole here, its other threads and
	// all. A program of several gives this one back and goes on.
	if win.own_exit {
		libthread.threadexitsall("")
	}
	// The files first, so the mouse reader's read ends and it answers on
	// `mouse_done`. Then both io procs, now idle, go back with the window.
	window_close(win)
	if win.mouse_done != nil {
		_ = libthread.recvul(win.mouse_done)
		libthread.chanfree(win.mouse_done)
		win.mouse_done = nil
	}
	if win.mouse_io != nil {
		libthread.ioclose(win.mouse_io)
		win.mouse_io = nil
	}
	if win.key_io != nil {
		libthread.ioclose(win.key_io)
		win.key_io = nil
	}
}

/*
window_close gives the window back: its files are closed, and the server
takes the window off the glass when the `data` fid is gone. The mouse
thread's read ends with the file and the thread leaves on its own. A
program of several windows calls this for a window it is done with. A
program of one never needs to, since its exit is the close.
*/
window_close :: proc "contextless" (win: ^Window) {
	win.done = true
	theme_unfollow(win)
	if win.mouse_fd >= 0 {
		_ = libuser.close(win.mouse_fd)
		win.mouse_fd = -1
	}
	if win.consctl_fd >= 0 {
		_ = libuser.close(win.consctl_fd)
		win.consctl_fd = -1
	}
	if win.cons_fd >= 0 {
		_ = libuser.close(win.cons_fd)
		win.cons_fd = -1
	}
	if win.data_fd >= 0 {
		_ = libuser.close(win.data_fd)
		win.data_fd = -1
	}
	// The store back: the mapping of the shared run, or a remote window's
	// own two runs.
	if win.store != nil {
		_ = libuser.segdetach(uintptr(win.store))
		win.store = nil
	}
	if win.local != nil {
		libuser.heap_free(win.local)
		libuser.heap_free(win.sent)
		win.local, win.sent, win.local_n = nil, nil, 0
	}
	if win.store_fd >= 0 {
		_ = libuser.close(win.store_fd)
		win.store_fd = -1
	}
	win.remote = false
}

// mouse_thread reads the window's pointer and turns each line into an event.
// It leaves when the file ends or the window is done.
mouse_thread :: proc "contextless" (arg: rawptr) #no_bounds_check {
	win := (^Window)(arg)
	if win.mouse_io == nil {
		win.mouse_io = libthread.ioproc()
	}
	if win.mouse_io != nil {
		for {
			fd := win.mouse_fd
			if fd < 0 || win.done {
				break
			}
			got := libthread.ioread(win.mouse_io, fd, win.line[:])
			if got <= 0 {
				break
			}
			mouse_event(win, win.line[:int(got)])
			if win.done {
				// A handler ended the window from here. `window_run` is
				// parked in the key read and would learn it only from a
				// key, which a popup, never focused, never gets: a menu
				// item chosen by the mouse stayed chosen and undone. A
				// close of the files would end nothing, since a read in
				// flight outlives its descriptor. So the server is asked
				// to hang the window up, which answers the key read with
				// nothing, and `window_run` takes it from there.
				window_end(win)
				break
			}
		}
	}
	// A program of one window ends here with the rest. A program of several
	// answers `window_run`, which is waiting to close the io proc and give
	// the window back, and then this thread touches the window no more.
	if win.own_exit {
		libthread.threadexitsall("")
	}
	if win.mouse_done != nil {
		libthread.sendul(win.mouse_done, 1)
	}
}

/*
window_end ends a window from any thread but its own: it asks the server
to hang the window up, `close` on its wctl, the chord alt-w's own word.
The window's key read answers nothing after it, `window_run` returns, and
the window's threads leave the way they do for a close gadget. This is
the call for a thread that wants a window it does not run gone -- a
sleeper taking a toast down, a menu closing a drawer. `window_close` is
not: it closes the files, and a read in flight outlives its descriptor,
so the window's own threads would stay parked on a window that is gone,
and a record reused under them is a record two windows share.
*/
window_end :: proc "contextless" (win: ^Window) {
	wctl := libuser.open(libdraw.win_path(win.path[:], win.base, win.id, "wctl"), abi.O_WRONLY)
	if wctl < 0 {
		return
	}
	_ = libuser.write(int(wctl), transmute([]u8)string("close"))
	_ = libuser.close(int(wctl))
}

// -- Dispatch ----------------------------------------------------------------

/*
mouse_event turns one mouse line into what it means to the tree. A button
1 press lands on a gadget, which takes the focus, and a list or a grid
selects the row or cell under it. A release on the same gadget activates
it. A second press on the same gadget within `DOUBLE_MS` of the first
makes the activation a double click, by the line's own clock, and `clicks`
says so. A button 3 press is the program's, through `on_menu`, with the point
it landed on, which is where a menu opens.
*/
mouse_event :: proc "contextless" (win: ^Window, data: []u8) #no_bounds_check {
	// A `c` line is the desktop asking the window to close. `on_close` says
	// whether it ends now, and with none it does.
	if len(data) >= 1 && data[0] == 'c' {
		if win.on_close == nil || win.on_close(win) {
			win.done = true
		}
		return
	}
	if len(data) < 1 || data[0] != 'm' {
		return
	}
	at := 1
	x, xok := libdraw.scan_int(data, &at)
	y, yok := libdraw.scan_int(data, &at)
	b, bok := libdraw.scan_int(data, &at)
	if !xok || !yok || !bok {
		return
	}
	ms, _ := libdraw.scan_int(data, &at)
	buttons := u8(b)
	down := buttons & 1 != 0
	was := win.last_buttons & 1 != 0
	menu_down := buttons & 4 != 0
	menu_was := win.last_buttons & 4 != 0
	win.last_buttons = buttons
	if menu_down && !menu_was && win.on_menu != nil {
		win.on_menu(win, x, y)
		return
	}
	if down && !was {
		win.pressed = hit(win.root, x, y)
		if win.pressed != nil {
			win.focus = win.pressed
			#partial switch win.pressed.class {
			case .List:
				if row := list_row_at(win.pressed, y, &win.theme); row >= 0 {
					win.pressed.sel = row
				}
			case .Icons:
				win.pressed.sel = icons_cell_at(win.pressed, x, y, &win.theme)
			}
			if win.pressed == win.last_press && ms >= win.last_ms && ms - win.last_ms < DOUBLE_MS {
				win.clicks = 2
			} else {
				win.clicks = 1
			}
			win.last_press = win.pressed
			win.last_ms = ms
			win.press_x = x
			win.press_y = y
			window_paint(win)
		}
	} else if !down && was {
		// A press on an icon that moved before it released is a drag, not a
		// click: the program hears the drop rather than an activation. The
		// grab keeps the release coming here even when the pointer has left
		// the window, so `x`/`y` may be outside it, which is a drop elsewhere.
		moved := abs(x - win.press_x) + abs(y - win.press_y)
		if win.pressed != nil && win.pressed.class == .Icons && win.pressed.sel >= 0 && moved > DRAG_MIN && win.on_drop != nil {
			win.on_drop(win, win.pressed.sel, x, y)
		} else {
			g := hit(win.root, x, y)
			if g != nil && g == win.pressed {
				activate(win, g)
			}
		}
		win.pressed = nil
	}
}

// DRAG_MIN is how far a press must move before a release is a drag and not a
// click, in pixels of the two axes added. Below it a shaky hand still clicks.
DRAG_MIN :: 6

// key_event routes one key. A string gadget with the focus takes the typing
// first, and its handler hears the id as the text changes. Tab moves the
// focus, Return and Space press it, Escape is the cancel, and any other
// key is a hotkey or nothing.
key_event :: proc "contextless" (win: ^Window, k: u8) #no_bounds_check {
	if win.on_key != nil && (win.focus == nil || win.focus.class != .String) && win.on_key(win, k) {
		if !win.done {
			window_paint(win)
		}
		return
	}
	if win.focus != nil && win.focus.class == .String && k != KEY_RETURN_N && k != KEY_RETURN_R && k != KEY_ESCAPE && k != '\t' {
		if string_key(win.focus, k) {
			win.clicks = 0
			if win.handler != nil {
				win.handler(win, win.focus.id)
			}
			if !win.done {
				window_paint(win)
			}
		}
		return
	}
	switch k {
	case '\t':
		focus_next(win)
		window_paint(win)
	case KEY_RETURN_N, KEY_RETURN_R, ' ':
		if win.focus != nil {
			win.clicks = 1
			activate(win, win.focus)
		}
	case KEY_ESCAPE:
		if win.handler != nil {
			win.handler(win, -1)
		}
	case:
		if g := hotkey_gadget(win.root, k); g != nil {
			win.clicks = 1
			activate(win, g)
		}
	}
}

// hotkey_gadget finds the button whose label's `_` marks the letter `k`,
// either case, in tree order.
hotkey_gadget :: proc "contextless" (o: ^Object, k: u8) -> ^Object {
	if o == nil {
		return nil
	}
	if o.class == .Button {
		if h, ok := hotkey_of(o.label); ok && lower(h) == lower(k) {
			return o
		}
	}
	for c := o.first; c != nil; c = c.next {
		if got := hotkey_gadget(c, k); got != nil {
			return got
		}
	}
	return nil
}

// hotkey_of answers the letter after a label's first `_`, if one is there.
hotkey_of :: proc "contextless" (label: string) -> (u8, bool) {
	for i in 0 ..< len(label) - 1 {
		if label[i] == '_' {
			d := label[i + 1]
			if (d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z') {
				return d, true
			}
		}
	}
	return 0, false
}

lower :: proc "contextless" (c: u8) -> u8 {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

// activate does what a press means for a gadget: a checkmark flips, and then
// the program's handler hears the gadget's id.
activate :: proc "contextless" (win: ^Window, g: ^Object) #no_bounds_check {
	// The relay's tick, the one place a gadget acts. See `sound.odin`.
	relay_click()
	if g.class == .Checkmark {
		g.on = !g.on
		window_paint(win)
	}
	win.arg = g.sel
	if win.handler != nil {
		win.handler(win, g.id)
	}
}

// -- Focus -------------------------------------------------------------------

// set_focus_first points the focus at the first interactive gadget, so a
// keyboard has somewhere to start.
set_focus_first :: proc "contextless" (win: ^Window) {
	win.focus = first_interactive(win.root)
}

first_interactive :: proc "contextless" (o: ^Object) -> ^Object {
	if o == nil {
		return nil
	}
	if interactive(o.class) {
		return o
	}
	for c := o.first; c != nil; c = c.next {
		if got := first_interactive(c); got != nil {
			return got
		}
	}
	return nil
}

// focus_next moves the focus to the next interactive gadget in tree order, and
// wraps to the first. It walks the tree twice, once to find the current and
// once past it, which a tree this small does not feel.
focus_next :: proc "contextless" (win: ^Window) {
	first: ^Object
	found_current := false
	next: ^Object
	walk_interactive(win.root, win.focus, &first, &found_current, &next)
	if next != nil {
		win.focus = next
	} else {
		win.focus = first
	}
}

walk_interactive :: proc "contextless" (
	o: ^Object,
	current: ^Object,
	first: ^^Object,
	found_current: ^bool,
	next: ^^Object,
) {
	if o == nil {
		return
	}
	if interactive(o.class) {
		if first^ == nil {
			first^ = o
		}
		if found_current^ && next^ == nil {
			next^ = o
		}
		if o == current {
			found_current^ = true
		}
	}
	for c := o.first; c != nil; c = c.next {
		walk_interactive(c, current, first, found_current, next)
	}
}

/*
window_locate reads where the window's client area is on the screen into
`sx` and `sy`, off its `wctl` line: the window's corner, and the frame's
left and top insets after the workspace. The server says the insets, so a
theme with another frame moves no client by a number it copied.

A window moves, and a `reload` may change its frame, so a program asks
again before it turns a point in its window into a point on the screen:
a popup's place, or a drop's. False when the line cannot be read, and
`sx`/`sy` keep what they held.
*/
window_locate :: proc "contextless" (win: ^Window) -> bool #no_bounds_check {
	// Buffers of its own: a program calls this from whichever thread holds
	// the event, and the window's own buffers belong to the loop.
	path: [128]u8
	buf: [96]u8
	wfd := libuser.open(libdraw.win_path(path[:], win.base, win.id, "wctl"), abi.O_RDONLY)
	if wfd < 0 {
		return false
	}
	wn := libuser.read(int(wfd), buf[:])
	_ = libuser.close(int(wfd))
	line := buf[:max(int(wn), 0)]
	// The numbers in order, the two focus words skipped: x y w h, the
	// workspace, then the insets left, top, right and bottom.
	nums: [9]int
	got := 0
	at := 0
	for at < len(line) && got < len(nums) {
		for at < len(line) && (line[at] == ' ' || line[at] == '\t' || line[at] == '\n') {
			at += 1
		}
		start := at
		for at < len(line) && line[at] != ' ' && line[at] != '\t' && line[at] != '\n' {
			at += 1
		}
		if at == start {
			break
		}
		if v, ok := libdraw.scan_int_str(line[start:at]); ok {
			nums[got] = v
			got += 1
		}
	}
	if got < 2 {
		return false
	}
	win.sx, win.sy = nums[0], nums[1]
	if got == len(nums) {
		// x y w h, the workspace at 4, then left at 5 and top at 6.
		win.sx += nums[5]
		win.sy += nums[6]
	}
	return true
}
