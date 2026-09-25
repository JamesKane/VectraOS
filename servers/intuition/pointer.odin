/*
The pointer: where it is, what it is over, and what a press does.

`docs/WORKBENCH.md` step 2. The server reads `/dev/mouse` through an io
proc and keeps the pointer's position and buttons. Every movement goes
to the window under the pointer, in that window's own coordinates, on
the window's `mouse` file. A press does one of four things, by where the pointer is against the
frame the server drew. It is on a gadget, the bar, the sizing corner, or
the client's own area.

    close     the window's `cons` is hung up: every read of it answers
              nothing from now on, which is how a program learns its
              window is gone, and the window leaves the glass
    depth     the window goes to the back
    zoom      the whole screen, or back to where it was
    the bar   a drag that ends in a `move`
        the corner
              a drag that ends in a `size`
    anywhere else
              the window comes to the front and takes the focus. That is
              the click-to-front rule Workbench 2 had and rio has

**The cursor is the compositor's last layer.** The compositor draws it after every paint, from a small image with a
mask, so nothing under it has to know it is there. To move it, the
place it was is repainted from the stores and the new place drawn. It is not drawn until the mouse first moves. So a machine whose mouse
nobody touches shows none, and a self-test that reads the glass reads
what it drew.

The image is Plan 9's `/dev/cursor` format, a window's `cursor` file
takes one, and the pointer wears it while it is over that window. Sixteen
by sixteen, a hot spot, and two bit planes. `clr` is the outline and
`set` is the fill, drawn in the void and in amber.
*/
package intuition

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libpal"
import "vsys:libthread"
import "vsys:libuser"

CURSOR_SIZE :: 16

Cursor :: struct {
	hot_x: int,
	hot_y: int,
	clr:   [32]u8,
	set:   [32]u8,
}

// The arrow, as Plan 9 draws it: an outline a pixel wide around a filled
// arrow whose point is the hot spot.
default_cursor := Cursor {
	hot_x = 1,
	hot_y = 1,
	clr = {
		0xC0, 0x00, 0xE0, 0x00, 0xF0, 0x00, 0xF8, 0x00,
		0xFC, 0x00, 0xFE, 0x00, 0xFF, 0x00, 0xFF, 0x80,
		0xFF, 0xC0, 0xFE, 0x00, 0xEF, 0x00, 0xCF, 0x00,
		0x87, 0x80, 0x07, 0x80, 0x03, 0xC0, 0x03, 0xC0,
	},
	set = {
		0x00, 0x00, 0x40, 0x00, 0x60, 0x00, 0x70, 0x00,
		0x78, 0x00, 0x7C, 0x00, 0x7E, 0x00, 0x7F, 0x00,
		0x7C, 0x00, 0x6C, 0x00, 0x46, 0x00, 0x06, 0x00,
		0x03, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00,
	},
}

CURSOR_OUTLINE :: u32(libpal.VOID[0]) << 16 | u32(libpal.VOID[1]) << 8 | u32(libpal.VOID[2])
CURSOR_FILL :: u32(libpal.AMBER_HOT[0]) << 16 | u32(libpal.AMBER_HOT[1]) << 8 | u32(libpal.AMBER_HOT[2])

ptr_x: int
ptr_y: int
ptr_b: u8
ptr_awake: bool // The mouse moved at least once, so there is a cursor to draw

// A drag in progress: which window, which kind, and where it began.
Drag_Kind :: enum u8 {
	None,
	Move,
	Size,
}

Drag :: struct {
	kind: Drag_Kind,
	win:  int,
	x0:   int, // Where the pointer was when the press began
	y0:   int,
	ox:   int, // Where the window was, or how big its client area was
	oy:   int,
	// The pointer's offset from the press that was last applied. An event
	// that has not moved it moves nothing. So a release cannot undo what a
	// `wctl` word did to the window since the last motion.
	dx:   int,
	dy:   int,
}

drag: Drag

/*
A client grab: the window a button press landed in keeps the pointer until
the button is up, wherever it goes. That is what hands a drag between windows
-- a file dragged out of a drawer and dropped on another is one press that
starts in one window and ends over a second, and the server owns the pointer,
so it can keep the whole of it for the window that began it. The window hears
the pointer leave its own bounds as coordinates outside them, `rio`'s way, and
the release comes back to it with the point it landed on, which the program
maps to a drop. `docs/WORKBENCH.md` section 6.

Only a client press grabs. A bar or a gadget has its own press (a window
drag, a close), and a popup is dismissed by a press outside it, each decided
before this.
*/
grabbing: bool
grab_win: int

// The sizing corner: this many pixels square at a window's bottom right,
// which is the border, the well and a corner of the client area.
SIZE_GRIP :: 12

// What a press landed on.
Hit :: enum u8 {
	None,
	Close,
	Depth,
	Zoom,
	Size,
	Bar,
	Client,
}

mouse_fd: int

/*
mouse_thread reads `/dev/mouse` through an io proc for the server's life,
and every line moves the pointer. A failed read is not a loop to break
out of, for the reason `key_thread` gives.
*/
mouse_thread :: proc "contextless" (arg: rawptr) #no_bounds_check {
	_ = arg
	io := libthread.ioproc()
	if io == nil {
		libthread.threadexitsall("ioproc")
	}
	line: [64]u8
	for {
		n := libthread.ioread(io, mouse_fd, line[:])
		if n <= 0 {
			continue
		}
		at := 1
		x, ok1 := libdraw.scan_int(line[:n], &at)
		y, ok2 := libdraw.scan_int(line[:n], &at)
		b, ok3 := libdraw.scan_int(line[:n], &at)
		msec, ok4 := libdraw.scan_int(line[:n], &at)
		if line[0] != 'm' || !ok1 || !ok2 || !ok3 || !ok4 {
			continue
		}
		pointer_move(x, y, u8(b), u64(msec))
	}
}

/*
pointer_move is one movement: the cursor moves, a drag in progress
follows, a press is decided, and the window under the pointer hears the
line.
*/
pointer_move :: proc "contextless" (x: int, y: int, b: u8, msec: u64) #no_bounds_check {
	ox, oy := ptr_x, ptr_y
	was_awake := ptr_awake
	pressed := b &~ ptr_b
	released := ptr_b &~ b
	ptr_x = x
	ptr_y = y
	ptr_b = b
	ptr_awake = true

		// The cursor: the place it was is repainted from the stores, which
	// draws it again at the new place on the way out.
	if was_awake {
		cursor_erase(ox, oy)
	}
	cursor_show()

	// Locked, the pointer moves and nothing else: no window hears it.
	if locked {
		return
	}

	// The overview owns the pointer while it is up: a press begins a gesture
	// and the release decides it -- a tile switched to, or a window dragged to
	// another workspace. See `overview_release`.
	if overview_on {
		if pressed & 1 != 0 {
			overview_press(x, y)
		}
		if released & 1 != 0 {
			overview_release(x, y)
		}
		return
	}

	if drag.kind != .None {
		drag_follow(released)
		return
	}

	// A client grab holds the pointer to the window the press began in, so a
	// drag that leaves it is still delivered there and the release comes back.
	if grabbing {
		if !windows[grab_win].used {
			grabbing = false
		} else {
			mouse_deliver(grab_win, x, y, b, msec)
			if b == 0 {
				grabbing = false
			}
			return
		}
	}

	w := window_at(x, y)
	// A mouse bind: a button with the modifiers it names drags the window
	// under the pointer, wherever on it the press lands. Alt and a drag moves.
	if pressed != 0 && w >= 0 && windows[w].kind == .Normal {
		held := mods_held()
		for i in 0 ..< nmouse_binds {
			mb := &mouse_binds[i]
			if pressed & mb.button == 0 || mb.mods == 0 || held != mb.mods {
				continue
			}
			win := &windows[w]
			window_raise(win, w)
			if mb.size {
				_, _, cw, ch := frame_client(win)
				drag = Drag{kind = .Size, win = w, x0 = x, y0 = y, ox = cw, oy = ch}
			} else {
				drag = Drag{kind = .Move, win = w, x0 = x, y0 = y, ox = win.x, oy = win.y}
			}
			return
		}
	}
	if pressed & 1 != 0 && w >= 0 {
		win := &windows[w]
		switch hit_test(win, x - win.x, y - win.y) {
		case .Close:
			window_close_request(win)
			return
		case .Depth:
			window_lower(w)
			return
		case .Zoom:
			window_zoom(win)
			return
		case .Size:
			_, _, cw, ch := frame_client(win)
			drag = Drag{kind = .Size, win = w, x0 = x, y0 = y, ox = cw, oy = ch}
			return
		case .Bar:
			window_raise(win, w)
			drag = Drag{kind = .Move, win = w, x0 = x, y0 = y, ox = win.x, oy = win.y}
			return
		case .Client:
			// A docked menu is dragged by its title, its top rows, and a
			// press there is the server's and not the menu's.
			if win.kind == .Menu && y - win.y < MENU_GRIP && x - win.x < win.w - MENU_TEAR_W {
				drag = Drag{kind = .Move, win = w, x0 = x, y0 = y, ox = win.x, oy = win.y}
				return
			}
			if win.kind == .Normal {
				window_raise(win, w)
			}
			// The press begins a grab, so a drag out of this window stays its
			// own until the button is up. A plain click is a press and release
			// in place, which the grab delivers to this same window and ends.
			grabbing = true
			grab_win = w
		case .None:
		}
	}
	// A press anywhere outside a popup is what closes one.
	if pressed != 0 {
		popups_dismiss(x, y)
	}
	if w >= 0 {
		mouse_deliver(w, x, y, b, msec)
	}
}

// drag_follow moves or sizes the dragged window with the pointer, and ends
// the drag on the release.
drag_follow :: proc "contextless" (released: u8) #no_bounds_check {
	win := &windows[drag.win]
	if !win.used {
		drag.kind = .None
		return
	}
	dx := ptr_x - drag.x0
	dy := ptr_y - drag.y0
	if dx != drag.dx || dy != drag.dy {
		drag.dx, drag.dy = dx, dy
		#partial switch drag.kind {
		case .Move:
			_ = window_move(win, drag.ox + dx, drag.oy + dy)
		case .Size:
			_ = window_size(win, max(drag.ox + dx, 8), max(drag.oy + dy, 8))
		}
	}
	if released & 1 != 0 {
		drag.kind = .None
	}
}

// window_at is the window under a screen point, on the current workspace,
// from the top of the stack down, or -1.
window_at :: proc "contextless" (x: int, y: int) -> int #no_bounds_check {
	for i := stack_n - 1; i >= 0; i -= 1 {
		w := stack[i]
		win := &windows[w]
		if !win.used || win.workspace != current_ws || win.hidden {
			continue
		}
		if x >= win.x && x < win.x + win.w && y >= win.y && y < win.y + win.h {
			return w
		}
	}
	return -1
}

/*
hit_test says what a point in a window's own coordinates is on. The
frame's layout is here and in `window_frame`, and the two agree because
`gadget_at` is the one place that says where a gadget sits.
*/
hit_test :: proc "contextless" (win: ^Window, lx: int, ly: int) -> Hit {
	if !framed(win) {
		return .Client
	}
	for g in libdraw.Gadget {
		if !has_gadget(win.kind, g) {
			continue
		}
		gx, gy, gs := gadget_at(win, g)
		if lx >= gx && lx < gx + gs && ly >= gy && ly < gy + gs {
			switch g {
			case .Close:
				return .Close
			case .Depth:
				return .Depth
			case .Zoom:
				return .Zoom
			case .Size:
				return .Size
			}
		}
	}
	bx, by, bw, bh := frame_bar_at(0, 0, win.w)
	if lx >= bx && lx < bx + bw && ly >= by && ly < by + bh {
		return .Bar
	}
	return .Client
}

// has_gadget says whether a kind of window wears a gadget. A torn-off panel
// wears the close gadget alone, OPEN LOOK's pushpin: it is closed, and
// neither zoomed, sent back, nor sized.
has_gadget :: proc "contextless" (kind: Window_Kind, g: libdraw.Gadget) -> bool {
	return kind != .Panel || g == .Close
}

// gadget_at is where one gadget sits in a window's own coordinates, and
// how big it is. Close at the bar's left, zoom and depth at its right, and
// the sizing grip at the window's bottom right corner.
gadget_at :: proc "contextless" (win: ^Window, g: libdraw.Gadget) -> (x: int, y: int, size: int) {
	bx, by, bw, _ := frame_bar_at(0, 0, win.w)
	switch g {
	case .Close:
		return bx + 2, by + 2, gadget_size()
	case .Zoom:
		return bx + bw - 2 - gadget_size(), by + 2, gadget_size()
	case .Depth:
		return bx + bw - 4 - 2 * gadget_size(), by + 2, gadget_size()
	case .Size:
		return win.w - SIZE_GRIP, win.h - SIZE_GRIP, SIZE_GRIP
	}
	return 0, 0, 0
}

/*
window_close_request is the close gadget and the `close` chord: the client
is asked, so a program with work to keep can keep it. A `c` line goes on the
window's mouse queue, and a program on `sys/libmui` or `sys/libapp` ends
itself when it reads it. A window nobody reads the pointer of could never
hear the question, so it is hung up at once, as before. One that was asked
and is still up after the theme's `closegrace` is listed on the server's
`ctl`, and the desktop offers a person `Kill`, which is `kill N`. A second
close of a window already asked asks nothing more.
*/
window_close_request :: proc "contextless" (win: ^Window) #no_bounds_check {
	if !win.mouse_held {
		window_hangup(win)
		return
	}
	if win.closing {
		return
	}
	w := int(uintptr(win) - uintptr(&windows[0])) / size_of(Window)
	win.closing = true
	win.close_at = uptime_ms() + th_closegrace_ms
	mouse_close(w)
}

// uptime_ms is the milliseconds since boot, off `/dev/time`'s fifth field.
uptime_ms :: proc "contextless" () -> u64 #no_bounds_check {
	fd := libuser.open("/dev/time", abi.O_RDONLY)
	if fd < 0 {
		return 0
	}
	buf: [96]u8
	n := libuser.read(int(fd), buf[:])
	_ = libuser.close(int(fd))
	// `scan_u64`, not `scan_int`: every field here is past a coordinate's cap.
	at := 0
	for _ in 0 ..< 4 {
		if _, ok := libdraw.scan_u64(buf[:max(int(n), 0)], &at); !ok {
			return 0
		}
	}
	up, ok := libdraw.scan_u64(buf[:max(int(n), 0)], &at)
	if !ok {
		return 0
	}
	return up / 1_000_000
}

/*
window_hangup is the close gadget. The window's `cons` answers nothing
from now on, every read held on it is answered so, and the window leaves
the glass. The session's memory goes back when its client, having read
the end of its keyboard, clunks its `data`.
*/
window_hangup :: proc "contextless" (win: ^Window) #no_bounds_check {
	win.hangup = true
	w := int(uintptr(win) - uintptr(&windows[0])) / size_of(Window)
	answer_cons(w)
	answer_mouse(w)
	window_hide(win, true)
}

// popups_dismiss hangs up every popup the point is not inside, which is
// what a press outside a menu means.
popups_dismiss :: proc "contextless" (x: int, y: int) #no_bounds_check {
	for i in 0 ..< MAX_WINDOWS {
		win := &windows[i]
		if !win.used || win.kind != .Popup || win.hidden {
			continue
		}
		if x >= win.x && x < win.x + win.w && y >= win.y && y < win.y + win.h {
			continue
		}
		window_hangup(win)
	}
}

// -- The cursor ------------------------------------------------------------------------

// cursor_of is the image the pointer wears: the window under it's, when
// that window set one, and the arrow otherwise.
@(private = "file")
cursor_of :: proc "contextless" () -> ^Cursor #no_bounds_check {
	if w := window_at(ptr_x, ptr_y); w >= 0 && windows[w].has_cursor {
		return &windows[w].cursor
	}
	return &default_cursor
}

// cursor_show draws the pointer onto the glass where it is now. The last
// thing every composite and every desktop repaint does.
cursor_show :: proc "contextless" () #no_bounds_check {
	if !ptr_awake {
		return
	}
	c := cursor_of()
	x0 := ptr_x - c.hot_x
	y0 := ptr_y - c.hot_y
	for row in 0 ..< CURSOR_SIZE {
		y := y0 + row
		if y < 0 || y >= scr_h {
			continue
		}
		dst := screen_at(y)
		clr := u16(c.clr[row * 2]) << 8 | u16(c.clr[row * 2 + 1])
		set := u16(c.set[row * 2]) << 8 | u16(c.set[row * 2 + 1])
		for col in 0 ..< CURSOR_SIZE {
			x := x0 + col
			if x < 0 || x >= scr_w {
				continue
			}
			bit := u16(0x8000) >> u16(col)
			if set & bit != 0 {
				dst[x] = CURSOR_FILL
			} else if clr & bit != 0 {
				dst[x] = CURSOR_OUTLINE
			}
		}
	}
}

// cursor_erase repaints the square the cursor was on from the stores.
@(private = "file")
cursor_erase :: proc "contextless" (x: int, y: int) {
	x0 := x - CURSOR_SIZE
	y0 := y - CURSOR_SIZE
	desk_paint(x0, y0, x0 + 2 * CURSOR_SIZE, y0 + 2 * CURSOR_SIZE)
	repaint(x0, y0, 2 * CURSOR_SIZE, 2 * CURSOR_SIZE)
}

/*
cursor_set takes a window's `cursor` write. Plan 9's seventy-two bytes:
the hot spot as two little-endian words and the two planes. An empty
write goes back to the arrow.
*/
cursor_set :: proc "contextless" (win: ^Window, data: []u8) -> bool #no_bounds_check {
	if len(data) == 0 {
		win.has_cursor = false
		cursor_show()
		return true
	}
	if len(data) != 72 {
		return false
	}
	win.cursor.hot_x = int(i32(libdraw.get_u32(data, 0)))
	win.cursor.hot_y = int(i32(libdraw.get_u32(data, 4)))
	copy(win.cursor.clr[:], data[8:40])
	copy(win.cursor.set[:], data[40:72])
	win.has_cursor = true
	cursor_show()
	return true
}

// pointer_open opens the pointer's file, and says whether there is one to
// read. A machine with no mouse has none, and the server runs without.
pointer_open :: proc "contextless" () -> bool {
	fd := libuser.open("/dev/mouse", abi.O_RDONLY)
	if fd < 0 {
		mouse_fd = -1
		return false
	}
	mouse_fd = int(fd)
	return true
}
