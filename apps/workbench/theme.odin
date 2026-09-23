/*
theme -- the look, read from files, `docs/WORKBENCH.md` section 5. The look is
data: `/lib/theme` is the shipped one, `$home/lib/theme` the person's, and the
later line for a role wins. The personal file may start with `use <name>`,
which reads `/lib/themes/<name>` in place of `/lib/theme` and merges the rest
over it. `Workbench > Theme...` writes that line.

`theme_load` reads the two and hands the merged text to `sys/libmui`'s parser,
which starts at the chassis so a role named nowhere keeps the chassis value.
The result is the look every window opened after takes; `theme_apply` also lays
the open windows out again, for a live change. `intuition` reads the same files
for the frame it draws, its own half.
*/
package workbench

import "vsys:abi"
import "vsys:libmui"
import "vsys:libthread"
import "vsys:libuser"

// Comfortably over the 769-byte shipped `/lib/theme`, the largest file read;
// a `themes/*` base or a personal file is far smaller. `merge_buf` is twice
// this, holding base + '\n' + body.
THEME_MAX :: 1024
MAX_THEMES :: 32

theme_win: ^libmui.Window // the picker, one at a time
theme_list: ^libmui.Object
theme_names: [MAX_THEMES]string
theme_n: int

@(private = "file") home_buf: [THEME_MAX]u8
@(private = "file") base_buf: [THEME_MAX]u8
@(private = "file") merge_buf: [2 * THEME_MAX]u8
@(private = "file") tpath_buf: [256]u8

// theme_load reads the two files, merges them, and sets the look new windows
// take. It does not lay open windows out; `theme_apply` does that.
theme_load :: proc "contextless" () {
	libmui.theme_load()
}

/*
theme_pick opens `Workbench > Theme...`: a List of the names under
`/lib/themes`. Choosing one writes `use <name>` to `$home/lib/theme` and
applies it, the switcher of `docs/WORKBENCH.md` section 5. One picker at a
time, a window of its own.
*/
theme_pick :: proc "contextless" () {
	context = wb_ctx
	if theme_win == nil {
		theme_win = new(libmui.Window)
	}
	if theme_win == nil {
		return
	}
	theme_n = 0
	if fd := libuser.open("/lib/themes", abi.O_RDONLY); fd >= 0 {
		names := libuser.list_dir(int(fd))
		_ = libuser.close(int(fd))
		libuser.sort_strings(names)
		for nm in names {
			if theme_n < MAX_THEMES {
				theme_names[theme_n] = nm
				theme_n += 1
			}
		}
	}
	theme_list = libmui.list(8)
	theme_list.rows = theme_names[:theme_n]
	theme_list.id = 1
	col := libmui.group(false)
	libmui.add(col, libmui.text("Theme"))
	libmui.add(col, theme_list)

	w := theme_win
	w.kind = .Normal
	w.bind_dev = false
	w.own_exit = false
	w.set_up = true
	w.placed = true
	w.at_x, w.at_y = 120, 80
	w.want_w, w.want_h = 180, 220
	w.handler = theme_chosen
	if !libmui.window_open(w, "Theme", col) {
		return
	}
	_ = libthread.threadcreate(theme_win_thread, w)
}

// theme_win_thread runs the picker window and frees nothing: the record is
// reused for the next open.
theme_win_thread :: proc "contextless" (arg: rawptr) {
	context = wb_ctx
	libmui.window_run((^libmui.Window)(arg))
	libthread.threadexits("")
}

// theme_chosen hears a row picked: it writes the `use` line and applies the
// theme, then closes the picker. A list's selected row is in `w.arg`.
theme_chosen :: proc "contextless" (w: ^libmui.Window, id: int) {
	context = wb_ctx
	if id == 1 && w.arg >= 0 && w.arg < theme_n {
		theme_write_use(theme_names[w.arg])
		theme_apply()
	}
	libmui.window_end(w)
}

/*
theme_apply re-reads the files -- now with the new `use` line -- and lays every
open window out again in the new look, section 5's "every window lays itself
out again". The picker is on its way out, so it is not among them.
*/
theme_apply :: proc "contextless" () {
	// The server re-chromes its frames and bumps the theme's generation, and
	// every program on the toolkit, this one among them, lays itself out.
	server_ctl("reload")
}

/*
theme_write_use writes `use <name>` as the first line of `$home/lib/theme`,
keeping the rest of the personal file after it and replacing any `use` that was
there. So a person's other lines -- a font, a gap -- survive a theme change.
*/
theme_write_use :: proc "contextless" (name: string) #no_bounds_check {
	context = wb_ctx
	old := theme_read(home_theme_path(), home_buf[:])
	// Drop a leading `use` line; keep the rest.
	body := old
	if _, rest, ok := theme_use(old); ok {
		body = rest
	}
	w := copy(merge_buf[:], "use ")
	w += copy(merge_buf[w:], name)
	merge_buf[w] = '\n';w += 1
	w += copy(merge_buf[w:], body)
	theme_mkdir()
	path := home_theme_path()
	_ = libuser.remove(path)
	if fd := libuser.create(path, abi.O_WRONLY, 0o644); fd >= 0 {
		_ = libuser.write(int(fd), merge_buf[:w])
		_ = libuser.close(int(fd))
	}
}

// theme_mkdir makes `$home/lib`, so `$home/lib/theme` has somewhere to land.
@(private = "file")
theme_mkdir :: proc "contextless" () #no_bounds_check {
	b: [256]u8
	n := copy(b[:], home_path())
	n += copy(b[n:], "/lib")
	_ = libuser.mkdir(string(b[:n]))
}

// theme_read reads a whole file into `buf` and answers the bytes, or nothing
// when it will not open.
@(private = "file")
theme_read :: proc "contextless" (path: string, buf: []u8) -> []u8 {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return buf[:0]
	}
	n := libuser.read(int(fd), buf)
	_ = libuser.close(int(fd))
	return buf[:max(int(n), 0)]
}

// theme_use reads a leading `use <name>` line: the base name and the rest of
// the file after that line. False when the first non-blank line is not `use`.
@(private = "file")
theme_use :: proc "contextless" (text: []u8) -> (name: string, rest: []u8, ok: bool) #no_bounds_check {
	// The first line, and where the next begins.
	e := 0
	for e < len(text) && text[e] != '\n' {e += 1}
	line := text[:e]
	next := e < len(text) ? e + 1 : e
	// `use` then a name.
	verb, after := libmui.word(string(line))
	if verb != "use" {
		return "", text, false
	}
	nm, _ := libmui.word(after)
	if nm == "" {
		return "", text, false
	}
	return nm, text[next:], true
}

// home_theme_path is `$home/lib/theme`.
@(private = "file")
home_theme_path :: proc "contextless" () -> string {
	n := copy(tpath_buf[:], home_path())
	n += copy(tpath_buf[n:], "/lib/theme")
	return string(tpath_buf[:n])
}

// themes_path is `/lib/themes/<name>`, in the same buffer.
@(private = "file")
themes_path :: proc "contextless" (name: string) -> string {
	n := copy(tpath_buf[:], "/lib/themes/")
	n += copy(tpath_buf[n:], name)
	return string(tpath_buf[:n])
}
