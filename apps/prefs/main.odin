/*
prefs -- the theme's preferences, `docs/WORKBENCH.md` step 5.

A window of every role the toolkit knows, each with the value it has now and
the line that set it: `face  b46c32  /usr/glenda/lib/theme:2`, or `chassis`
for a role no file names. It walks `sys/libmui`'s `THEME_ROLES`, so a role
added to the parser is a row here with no line of this program changed,
which is how MUI's own preferences stayed right. `Reload` asks the draw
server to reload, so every program follows the files as they are now, and
reads the rows again. The files are edited by hand, and `style explain
role` says the rest: every line that named a role and which it beat.
*/
package prefs

import "base:runtime"

import "vsys:abi"
import "vsys:libmui"
import "vsys:libthread"
import "vsys:libuser"

ctx: runtime.Context
win: libmui.Window
rows: [len(libmui.THEME_ROLES)]string
row_buf: [len(libmui.THEME_ROLES)][160]u8
list: ^libmui.Object

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	ctx = libuser.startup()
	context = ctx
	libthread.main(prefs_main, nil)
}

prefs_main :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = ctx
	fill_rows()
	list = libmui.list(len(rows))
	list.rows = rows[:]
	list.id = 1
	reload := libmui.button("Reload")
	reload.id = 2
	col := libmui.group(false)
	libmui.add(col, list)
	libmui.add(col, reload)
	win.handler = on_press
	win.want_w, win.want_h = 52 * libmui.FONT_W + 8, (len(rows) + 4) * libmui.FONT_H + 8
	win.set_up = true
	win.kind = .Normal
	win.bind_dev = true
	win.own_exit = true
	if !libmui.window_open(&win, "Preferences", col) {
		libthread.threadexitsall("open")
	}
	libmui.window_run(&win)
	libthread.threadexits("")
}

/*
fill_rows makes a row per role: its name, its value in the look this program
has now, and where the line that won is, off `theme_explain`.
*/
fill_rows :: proc "contextless" () #no_bounds_check {
	libmui.theme_load()
	t := libmui.ui_theme
	explain: [2048]u8
	for role, i in libmui.THEME_ROLES {
		vb: [24]u8
		value := libmui.theme_value(&t, role, vb[:])
		n := libmui.theme_explain(role, explain[:])
		src := "chassis"
		text := string(explain[:n])
		at := 0
		for at < len(text) {
			e := at
			for e < len(text) && text[e] != '\n' {
				e += 1
			}
			line := text[at:e]
			at = e + 1
			if len(line) > 5 && line[len(line) - 5:] == " wins" {
				// `role value path:line wins`: the third word is the source.
				_, r1 := libmui.word(line[:len(line) - 5])
				_, r2 := libmui.word(r1)
				from, _ := libmui.word(r2)
				src = from
			}
		}
		pad := "            "
		k := copy(row_buf[i][:], role)
		k += copy(row_buf[i][k:], pad[:max(12 - len(role), 1)])
		k += copy(row_buf[i][k:], value)
		k += copy(row_buf[i][k:], "  ")
		k += copy(row_buf[i][k:], src)
		rows[i] = string(row_buf[i][:k])
	}
}

on_press :: proc "contextless" (w: ^libmui.Window, id: int) {
	switch id {
	case -1:
		w.done = true
	case 2:
		// Every program follows the files as they are now, this one among
		// them, and the rows say where each value came from again.
		if fd := libuser.open(libuser.cat_into(path_buf[:], w.base, "/ctl"), abi.O_WRONLY); fd >= 0 {
			_ = libuser.write(int(fd), transmute([]u8)string("reload"))
			_ = libuser.close(int(fd))
		}
		fill_rows()
		libmui.window_relayout(w)
	}
}

path_buf: [160]u8
