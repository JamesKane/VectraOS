/*
window -- a `/srv/draw` window a gadget tree lives in, and the loop that runs it.

This is the toolkit made live. `window_open` claims a window, lays the tree out,
bakes the atlases, and paints it once. `window_run` is the event loop the plan
calls `rio`'s. A thread per file that parks reads the mouse and the keys through
a `sys/libthread` io proc, one proc, no lock. A click is hit-tested down the
tree, and a key goes to the focus. Tab moves it, Return presses the default, and
Escape the cancel, so a requester needs no mouse.

The window's own surface is image id zero, and the atlases count up from one. A
paint is pumped to the `data` stream one wire slot at a time, on command
boundaries, the budget `cmd/window` keeps. When a gadget is pressed the window's
`handler` hears its id. So a program on the toolkit learns a button was hit
without knowing a pixel.
*/
package libmui

import "vsys:abi"
import "vsys:libdraw"
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
	mouse_fd:  int,
	cw:        int,
	ch:        int,
	theme:     Theme,
	fonts:     Fonts,
	root:      ^Object,
	focus:     ^Object,
	pressed:   ^Object, // The gadget a mouse press landed on, awaiting release
	done:      bool,
	handler:   proc "contextless" (win: ^Window, id: int),
	scratch:   [SLOT]u8, // One slot, for atlas uploads and paint flushes
	paint_buf: [8192]u8, // A whole tree's commands, pumped from here in slots
	geo:       [160]u8,
	path:      [64]u8,
	keys:      [64]u8,
	line:      [64]u8,
}

// data_sink writes an atlas batch to a window's data stream.
data_sink :: proc "contextless" (user: rawptr, data: []u8) -> bool {
	fd := int(uintptr(user))
	return libuser.write(fd, data) == i64(len(data))
}

/*
window_open claims a window, lays `root` out in the client area, bakes the
atlases, and paints it once. It returns false at the first step that fails,
each of which is a window a program cannot have. It runs inside `libthread`,
because the loop that follows does.
*/
window_open :: proc "contextless" (win: ^Window, title: string, root: ^Object) -> bool #no_bounds_check {
	win.root = root
	if win.theme.pad == 0 && win.theme.gap == 0 {
		win.theme = default_theme
	}
	font_init(&win.fonts, 1)

	if libuser.mount("/srv/draw", "/mnt", 0) < 0 {
		return false
	}
	nfd := libuser.open("/mnt/new", abi.O_RDONLY)
	if nfd < 0 {
		return false
	}
	nn := libuser.read(int(nfd), win.geo[:])
	_ = libuser.close(int(nfd))
	scan := 0
	mine, mok := libdraw.scan_int(win.geo[:max(int(nn), 0)], &scan)
	if !mok {
		return false
	}
	win.id = mine

	fd := libuser.open(libdraw.win_path(win.path[:], "/mnt", mine, "data"), abi.O_WRONLY)
	if fd < 0 {
		return false
	}
	win.data_fd = int(fd)

	ctl := libuser.open(libdraw.win_path(win.path[:], "/mnt", mine, "ctl"), abi.O_RDWR)
	if ctl < 0 {
		return false
	}
	n := libuser.read(int(ctl), win.geo[:])
	w, h, _, _, gok := libdraw.parse_geometry(win.geo[:max(int(n), 0)])
	if !gok {
		_ = libuser.close(int(ctl))
		return false
	}
	win.cw, win.ch = w, h
	// The bar's name.
	name_at := copy(win.line[:], "name ")
	name_at += copy(win.line[name_at:], title)
	_ = libuser.write(int(ctl), win.line[:name_at])
	_ = libuser.close(int(ctl))

	// This window's own /dev, so its cons and mouse are the two files read.
	if libuser.bind(libdraw.win_dir(win.path[:], "/mnt", mine), "/dev", abi.ORDER_BEFORE) < 0 {
		return false
	}
	cons := libuser.open("/dev/cons", abi.O_RDONLY)
	if cons < 0 {
		return false
	}
	win.cons_fd = int(cons)
	ccl := libuser.open("/dev/consctl", abi.O_WRONLY)
	if ccl >= 0 {
		raw := "rawon"
		_ = libuser.write(int(ccl), transmute([]u8)raw)
		_ = libuser.close(int(ccl))
	}
	mouse := libuser.open("/dev/mouse", abi.O_RDONLY)
	if mouse >= 0 {
		win.mouse_fd = int(mouse)
	} else {
		win.mouse_fd = -1
	}

	// The tree in the client area, the atlases it needs, and the first paint.
	fit(root, &win.theme)
	lay(root, 0, 0, win.cw, win.ch, &win.theme)
	set_focus_first(win)
	sink := Sink{write = data_sink, user = rawptr(uintptr(win.data_fd))}
	if !font_prepare(root, &win.fonts, win.scratch[:], sink, &win.theme) {
		return false
	}
	window_paint(win)
	return true
}

// window_paint redraws the whole tree and flushes it to the glass.
window_paint :: proc "contextless" (win: ^Window) #no_bounds_check {
	end := paint(win.paint_buf[:], 0, win.root, 0, &win.fonts, &win.theme)
	if end <= 0 {
		return
	}
	flush_batches(win, win.paint_buf[:], end)
	// One flush command of its own, so the server shows the frame.
	fat := libdraw.put_flush(win.scratch[:], 0)
	if fat > 0 {
		_ = libuser.write(win.data_fd, win.scratch[:fat])
	}
}

// flush_batches writes a command stream to the data fd in wire slots, never
// splitting a command across two writes.
flush_batches :: proc "contextless" (win: ^Window, b: []u8, end: int) #no_bounds_check {
	start := 0
	at := 0
	for at < end {
		size := int(libdraw.get_u16(b, at))
		if size < libdraw.HEADER {
			break
		}
		if at + size - start > SLOT {
			// The command at `at` would overflow the slot, so flush up to it.
			if at > start {
				_ = libuser.write(win.data_fd, b[start:at])
				start = at
			}
		}
		at += size
	}
	if end > start {
		_ = libuser.write(win.data_fd, b[start:end])
	}
}

/*
window_run is the event loop. It makes a thread for the mouse and reads the
keys itself, each through an io proc, and returns when the window is done. Both
threads are one proc's, so the tree they share needs no lock.
*/
window_run :: proc "contextless" (win: ^Window) #no_bounds_check {
	if win.mouse_fd >= 0 {
		_ = libthread.threadcreate(mouse_thread, win)
	}
	io := libthread.ioproc()
	if io == nil {
		return
	}
	for {
		got := libthread.ioread(io, win.cons_fd, win.keys[:])
		// A read that ends means the window's files are gone, the server with
		// them, so the whole program comes down, its other threads and all.
		if got <= 0 {
			libthread.threadexitsall("")
		}
		for i in 0 ..< int(got) {
			key_event(win, win.keys[i])
			if win.done {
				libthread.threadexitsall("")
			}
		}
	}
}

// mouse_thread reads the window's pointer and turns each line into an event.
mouse_thread :: proc "contextless" (arg: rawptr) #no_bounds_check {
	win := (^Window)(arg)
	io := libthread.ioproc()
	if io == nil {
		return
	}
	for {
		got := libthread.ioread(io, win.mouse_fd, win.line[:])
		if got <= 0 {
			libthread.threadexitsall("")
		}
		mouse_event(win, win.line[:int(got)])
		if win.done {
			libthread.threadexitsall("")
		}
	}
}

// -- Dispatch ----------------------------------------------------------------

// mouse_event parses a `rio` mouse line and presses or releases a gadget.
last_buttons: u8

mouse_event :: proc "contextless" (win: ^Window, data: []u8) #no_bounds_check {
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
	buttons := u8(b)
	// The left button going down is a press, coming up a release.
	down := buttons & 1 != 0
	was := last_buttons & 1 != 0
	last_buttons = buttons
	if down && !was {
		win.pressed = hit(win.root, x, y)
		if win.pressed != nil {
			win.focus = win.pressed
			window_paint(win)
		}
	} else if !down && was {
		g := hit(win.root, x, y)
		if g != nil && g == win.pressed {
			activate(win, g)
		}
		win.pressed = nil
	}
}

// key_event routes one key: Tab moves the focus, Return presses it, Escape
// cancels, and a checkmark toggles on a space.
key_event :: proc "contextless" (win: ^Window, k: u8) #no_bounds_check {
	switch k {
	case '\t':
		focus_next(win)
		window_paint(win)
	case KEY_RETURN_N, KEY_RETURN_R, ' ':
		if win.focus != nil {
			activate(win, win.focus)
		}
	case KEY_ESCAPE:
		if win.handler != nil {
			win.handler(win, -1)
		}
	}
}

// activate does what a press means for a gadget: a checkmark flips, and then
// the program's handler hears the gadget's id.
activate :: proc "contextless" (win: ^Window, g: ^Object) #no_bounds_check {
	if g.class == .Checkmark {
		g.on = !g.on
		window_paint(win)
	}
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
