/*
status -- the screen bar as status, `docs/CHROME.md` section 12's I.

The bar carries no menus, the docked main menu does. What stays is status,
in the study's layout. The workspace is nine LEDs with the current one lit,
and its number in a compact readout. The display is its mode off
`/dev/fbctl`. The status line is the last notice. The memory stays at the
right.

The workspace is the server's, read off its `ctl` twice a second. A notice
arrives on the notice service's thread. That thread sets the line and
leaves the repaint to the status thread, so the service never waits on a
paint.
*/
package workbench

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libmui"
import "vsys:libthread"
import "vsys:libuser"

WORKSPACE_LEDS :: 9

ws_leds: [WORKSPACE_LEDS]^libmui.Object
ws_number: ^libmui.Object
ws_digit: [2]u8
ws_now: int
status_label: ^libmui.Object
status_buf: [NOTICE_MAX]u8
status_dirty: bool
mode_buf: [32]u8

/*
status_build adds the bar's status to its row: the LEDs and the number, the
display's mode, and the status line, which takes the room left.
*/
status_build :: proc "contextless" (row: ^libmui.Object) {
	libmui.add(row, libmui.strut(16))
	for i in 0 ..< WORKSPACE_LEDS {
		ws_leds[i] = libmui.led(libmui.LED_OFF)
		libmui.add(row, ws_leds[i])
	}
	ws_digit[0] = '1'
	ws_number = libmui.readout(string(ws_digit[:1]), 1)
	if ws_number != nil {
		ws_number.on = true // compact: the bar is short
		libmui.add(row, ws_number)
	}
	libmui.add(row, libmui.strut(16))
	libmui.add(row, libmui.text(display_mode()))
	libmui.add(row, libmui.strut(16))
	status_label = libmui.text("")
	libmui.add(row, status_label)
	libmui.add(row, libmui.space())
	workspace_show(1)
}

// display_mode is the screen's mode off `/dev/fbctl`: `1280x800`.
display_mode :: proc "contextless" () -> string {
	report: [128]u8
	fd := libuser.open("/dev/fbctl", abi.O_RDONLY)
	if fd < 0 {
		return ""
	}
	n := libuser.read(int(fd), report[:])
	_ = libuser.close(int(fd))
	w, h, _, _, ok := libdraw.parse_geometry(report[:max(int(n), 0)])
	if !ok {
		return ""
	}
	a, b: [16]u8
	return libuser.cat_into(mode_buf[:], libuser.itoa(a[:], i64(w)), "x", libuser.itoa(b[:], i64(h)))
}

// workspace_show lights workspace `ws`'s LED and puts its number in the
// readout. False when it was already so.
workspace_show :: proc "contextless" (ws: int) -> bool {
	if ws == ws_now || ws < 1 || ws > WORKSPACE_LEDS {
		return false
	}
	ws_now = ws
	for i in 0 ..< WORKSPACE_LEDS {
		if ws_leds[i] != nil {
			ws_leds[i].sel = i + 1 == ws ? libmui.LED_OK : libmui.LED_OFF
		}
	}
	ws_digit[0] = u8('0' + ws)
	if ws_number != nil {
		ws_number.label = string(ws_digit[:1])
	}
	return true
}

// status_set puts a notice's text on the status line, for the status
// thread to paint.
status_set :: proc "contextless" (text: string) {
	n := copy(status_buf[:], text)
	if status_label != nil {
		status_label.label = string(status_buf[:n])
	}
	status_dirty = true
}

/*
status_thread keeps the bar true. Twice a second it reads the workspace off
the server's `ctl`. It lays the bar out again when that or the status line
changed.
*/
status_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	io := libthread.ioproc()
	if io == nil {
		libthread.threadexits("")
	}
	for !bar.done {
		changed := status_dirty
		status_dirty = false
		report: [64]u8
		if fd := libuser.open("/mnt/ctl", abi.O_RDONLY); fd >= 0 {
			n := libuser.read(int(fd), report[:])
			_ = libuser.close(int(fd))
			// `workspace N of M` first.
			text := string(report[:max(int(n), 0)])
			if len(text) > 10 && text[:10] == "workspace " {
				ws := 0
				for k in 10 ..< len(text) {
					if text[k] < '0' || text[k] > '9' {
						break
					}
					ws = ws * 10 + int(text[k] - '0')
				}
				if workspace_show(ws) {
					changed = true
				}
			}
		}
		if changed {
			libmui.window_relayout(bar)
		}
		_ = libthread.iosleep(io, 500)
	}
	libthread.threadexits("")
}
