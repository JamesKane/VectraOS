/*
The files `docs/WORKBENCH.md` step 2 added to the tree, and what each
answers.

    /ctl        the server's own. A read says the current workspace. A
                write is `workspace N` or `reload`.
    /hotkey     the chords the server does not act on, one line per read,
                verbatim from the keys file. The desktop holds it open.
    /N/mouse    the pointer over window N, in the client area's own
                coordinates, `rio`'s line, a read parked until a movement
        /N/wctl     `rio`'s. A read answers the geometry, the focus, the
                visibility and the workspace. A write is one of the words
                below
    /N/cursor   the pointer's image over window N, taken for step 2's
                pointer to wear

`ctl` stays for what `docs/DRAW.md` built on it, and `wctl` is its
superset, so the terminal need not change to keep working.
*/
package intuition

import "vsys:libdraw"
import "vsys:vectra9"

// -- The server's ctl --------------------------------------------------------------

// server_report is what a read of `/ctl` answers: the workspace in front
// and how many there are.
server_report :: proc "contextless" (out: []u8) -> int {
	at := put_report(out, 0, "workspace ")
	at = put_number(out, at, current_ws)
	at = put_report(out, at, " of ")
	at = put_number(out, at, WORKSPACES)
	return put_report(out, at, "\n")
}

/*
run_server_ctl takes one line for the server itself.

    workspace N   make N the current workspace
    reload        read the rules file again
*/
run_server_ctl :: proc "contextless" (data: []u8) -> vectra9.Errno #no_bounds_check {
	verb, rest := word(data)
	switch string(verb) {
	case "workspace":
		num, tail := word(rest)
		ws, ok := libdraw.scan_int_str(num)
		if !ok || ws < 1 || ws > WORKSPACES || len(trim(tail)) != 0 {
			return vectra9.EINVAL
		}
		workspace_switch(ws)
		return vectra9.Errno(0)
	case "reload":
		if len(trim(rest)) != 0 {
			return vectra9.EINVAL
		}
		rules_load()
		return vectra9.Errno(0)
	}
	return vectra9.EINVAL
}

// -- hotkey ---------------------------------------------------------------------------

// The lines waiting for the desktop, oldest first. A line is an action from
// the keys file the server did not know, verbatim.
HOTKEY_MAX :: 128
HOTKEYS :: 16

Hotkey :: struct {
	n:    int,
	data: [HOTKEY_MAX]u8,
}

hotkeys: [HOTKEYS]Hotkey
hotkey_head: int
hotkey_tail: int

// hotkey_push queues one action line for whoever reads `hotkey`, and
// answers any read held for it. A full queue drops the oldest.
hotkey_push :: proc "contextless" (line: []u8) #no_bounds_check {
	if hotkey_head - hotkey_tail >= HOTKEYS {
		hotkey_tail += 1
	}
	h := &hotkeys[hotkey_head % HOTKEYS]
	h.n = copy(h.data[:HOTKEY_MAX - 1], line)
	h.data[h.n] = '\n'
	h.n += 1
	hotkey_head += 1
	answer_hotkeys()
}

hotkey_pop :: proc "contextless" (out: []u8) -> int #no_bounds_check {
	if hotkey_tail == hotkey_head {
		return 0
	}
	h := &hotkeys[hotkey_tail % HOTKEYS]
	n := copy(out, h.data[:h.n])
	hotkey_tail += 1
	return n
}

// -- mouse ------------------------------------------------------------------------------

/*
mouse_deliver records one movement over window `w`, in the client area's
coordinates, and answers any read held for it. The line is `rio`'s, the
same 49 bytes `/dev/mouse` writes, so a program reads both by one rule.
*/
mouse_deliver :: proc "contextless" (w: int, x: int, y: int, buttons: u8, msec: u64) #no_bounds_check {
	win := &windows[w]
		cx, cy, _, _ := frame_client(win)
	win.mx = x - win.x - cx
	win.my = y - win.y - cy
	win.mb = buttons
	win.mmsec = msec
	win.mseq += 1
	answer_mouse(w)
}

// mouse_line writes the latest movement over a window as a line and marks
// it read. Zero when nothing is newer than the last line.
mouse_line :: proc "contextless" (win: ^Window, out: []u8) -> int #no_bounds_check {
	if len(out) < MOUSE_LINE || win.mseq == win.mread {
		return 0
	}
	win.mread = win.mseq
	out[0] = 'm'
	at := 1
	at = put_field(out, at, win.mx)
	at = put_field(out, at, win.my)
	at = put_field(out, at, int(win.mb))
	at = put_field(out, at, int(win.mmsec))
	return at
}

MOUSE_LINE :: 49

// put_field is one `%11d` and the space after it, which is how Plan 9
// writes a mouse line. A negative number, which a pointer over the frame
// makes, carries its sign in the same width.
@(private = "file")
put_field :: proc "contextless" (out: []u8, at: int, v: int) -> int #no_bounds_check {
	digits: [20]u8
	n := 0
	u := v < 0 ? u64(-v) : u64(v)
	for {
		digits[n] = '0' + u8(u % 10)
		n += 1
		u /= 10
		if u == 0 {
			break
		}
	}
	width := n + (v < 0 ? 1 : 0)
	p := at
	for _ in width ..< 11 {
		out[p] = ' '
		p += 1
	}
	if v < 0 {
		out[p] = '-'
		p += 1
	}
	for n > 0 {
		n -= 1
		out[p] = digits[n]
		p += 1
	}
	out[p] = ' '
	return p + 1
}

@(private = "file")
wants_mouse :: proc "contextless" (arg: rawptr, request: ^vectra9.Msg) -> bool {
	#partial switch m in request^ {
	case vectra9.Tread:
		node := fid_node(m.fid)
		return node_part(node) == PART_MOUSE && node_win(node) == int(uintptr(arg))
	}
	return false
}

@(private = "file")
drain_mouse :: proc "contextless" (arg: rawptr, buf: []u8) -> int {
	return mouse_line(&windows[int(uintptr(arg))], buf)
}

answer_mouse :: proc "contextless" (w: int) {
	answer_held(rawptr(uintptr(w)), wants_mouse, drain_mouse)
}

@(private = "file")
wants_hotkey :: proc "contextless" (arg: rawptr, request: ^vectra9.Msg) -> bool {
	_ = arg
	#partial switch m in request^ {
	case vectra9.Tread:
		return fid_node(m.fid) == NODE_HOTKEY
	}
	return false
}

@(private = "file")
drain_hotkey :: proc "contextless" (arg: rawptr, buf: []u8) -> int {
	_ = arg
	return hotkey_pop(buf)
}

answer_hotkeys :: proc "contextless" () {
	answer_held(nil, wants_hotkey, drain_hotkey)
}

// -- wctl ----------------------------------------------------------------------------------

/*
wctl_report is what a read of a window's `wctl` answers, which is `rio`'s
line with the workspace after it:

    x y w h current visible 2

The rectangle is the window's, frame and all, on the screen. That is
what a client that moves itself wants to know, and what `ctl` does not
say. `current` or `notcurrent` is the focus, and `visible` or `hidden`.
*/
wctl_report :: proc "contextless" (out: []u8, win: ^Window) -> int {
	at := put_number(out, 0, win.x)
	at = put_report(out, at, " ")
	at = put_number(out, at, win.y)
	at = put_report(out, at, " ")
	at = put_number(out, at, win.w)
	at = put_report(out, at, " ")
	at = put_number(out, at, win.h)
	at = put_report(out, at, focused(win) ? " current" : " notcurrent")
	at = put_report(out, at, win.hidden ? " hidden " : " visible ")
	at = put_number(out, at, win.workspace)
	return put_report(out, at, "\n")
}

/*
run_wctl takes one of `rio`'s lines, or one of the four this server adds.

    move X Y       as `ctl`'s
    size W H       as `ctl`'s
    raise          to the front, with the focus
    lower          to the back
    current        the focus, and to the front with it
    close          the session's `data` fid is hung up
    zoom           the whole screen, or back to where it was
    hide           off the glass, still on its workspace
    unhide         back
    workspace N    onto workspace N
    backdrop       one of the three kinds a desktop needs
    bar
    popup

`close` is refused here for now. A hang up is the client's own clunk,
and the server has no other way to end a session it did not start. The
close gadget is the pointer's path to the same end.
*/
run_wctl :: proc "contextless" (win_at: int, data: []u8) -> vectra9.Errno #no_bounds_check {
	if win_at < 0 || win_at >= MAX_WINDOWS {
		return vectra9.EINVAL
	}
	win := &windows[win_at]
	if !win.used {
		return vectra9.EBADF
	}
	verb, rest := word(data)
	switch string(verb) {
	case "move", "size", "raise":
		return run_ctl(win_at, data)
	case "current":
		if len(trim(rest)) != 0 {
			return vectra9.EINVAL
		}
		window_raise(win, win_at)
	case "lower":
		if len(trim(rest)) != 0 {
			return vectra9.EINVAL
		}
		window_lower(win_at)
	case "zoom":
		if len(trim(rest)) != 0 {
			return vectra9.EINVAL
		}
		window_zoom(win)
	case "hide":
		if len(trim(rest)) != 0 {
			return vectra9.EINVAL
		}
		window_hide(win, true)
	case "unhide":
		if len(trim(rest)) != 0 {
			return vectra9.EINVAL
		}
		window_hide(win, false)
	case "workspace":
		num, tail := word(rest)
		ws, ok := libdraw.scan_int_str(num)
		if !ok || ws < 1 || ws > WORKSPACES || len(trim(tail)) != 0 {
			return vectra9.EINVAL
		}
		window_place(win, ws)
	case "backdrop":
		window_kind(win, win_at, .Backdrop)
	case "bar":
		window_kind(win, win_at, .Bar)
	case "popup":
		window_kind(win, win_at, .Popup)
	case:
		return vectra9.EINVAL
	}
	return vectra9.Errno(0)
}

// trim removes the space at both ends of a line.
trim :: proc "contextless" (data: []u8) -> []u8 #no_bounds_check {
	start := 0
	for start < len(data) && is_space(data[start]) {
		start += 1
	}
	end := len(data)
	for end > start && is_space(data[end - 1]) {
		end -= 1
	}
	return data[start:end]
}

/*
window_lower sends a window to the back of its workspace, and the focus
goes to whatever is in front now.
*/
window_lower :: proc "contextless" (at: int) #no_bounds_check {
	was := stack_top()
	stack_drop(at)
	for i := stack_n; i > 0; i -= 1 {
		stack[i] = stack[i - 1]
	}
	stack[0] = at
	stack_n += 1
	refocus(was)
	win := &windows[at]
	if win.workspace == current_ws && !win.hidden {
		repaint(win.x, win.y, win.w, win.h)
	}
}

/*
window_zoom takes a window to the whole screen below the bar, or back to
where it was. The place it was is kept in the window, so a second zoom
undoes the first.
*/
window_zoom :: proc "contextless" (win: ^Window) {
	if win.zoomed {
		win.zoomed = false
		_ = window_size_at(win, win.zx, win.zy, win.zw, win.zh)
		return
	}
	win.zx, win.zy, win.zw, win.zh = win.x, win.y, win.w, win.h
	win.zoomed = true
	_ = window_size_at(win, 0, bar_height(), scr_w, scr_h - bar_height())
}

// window_size_at moves and resizes a window in one repaint: the frame is
// laid out at the new size, and both places are composited.
window_size_at :: proc "contextless" (win: ^Window, x: int, y: int, w: int, h: int) -> vectra9.Errno {
	cw, ch := w, h
	if framed(win) {
		cw -= 2 * FRAME_INSET_X
		ch -= FRAME_INSET_Y + FRAME_INSET_X
	}
	if err := window_size(win, cw, ch); err != vectra9.Errno(0) {
		return err
	}
	return window_move(win, x, y)
}

// window_hide takes a window off the glass and keeps everything else
// about it, or puts it back.
window_hide :: proc "contextless" (win: ^Window, hidden: bool) {
	if win.hidden == hidden {
		return
	}
	was := stack_top()
	win.hidden = hidden
	refocus(was)
	if win.workspace != current_ws {
		return
	}
	if hidden {
		desk_paint(win.x, win.y, win.x + win.w, win.y + win.h)
	}
	repaint(win.x, win.y, win.w, win.h)
}

/*
window_kind makes a window one of the three a desktop needs, which is a
frame or none and a place in the stack. A backdrop goes to the back and
stays there. A bar goes to the top strip and stays in front. A popup
loses its frame and keeps its place.
*/
window_kind :: proc "contextless" (win: ^Window, at: int, kind: Window_Kind) {
	win.kind = kind
	#partial switch kind {
	case .Backdrop:
		window_lower(at)
	case .Bar:
		window_raise(win, at)
	}
	window_chrome(win)
	if win.workspace == current_ws && !win.hidden {
		repaint(win.x, win.y, win.w, win.h)
	}
}

// bar_height is how much of the top of the screen a bar window holds,
// which is where a zoomed window begins.
bar_height :: proc "contextless" () -> int #no_bounds_check {
	for i in 0 ..< MAX_WINDOWS {
		if windows[i].used && windows[i].kind == .Bar {
			return windows[i].h
		}
	}
	return 0
}
