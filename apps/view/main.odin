/*
view -- a project has somewhere to open, `docs/WORKBENCH.md` step 4.

`view <path>` shows a text file in a window: a list of its lines in a well,
titled by the file's name. A press on a row selects it, and Escape or `q`
closes the window. A file is read whole, up to a bound, which is what a
person opening a project from the desktop wants to see first. It is the
tool `/lib/wb/types` names for a suffix it has no other tool for, and the
one Workbench falls back to.
*/
package view

import "base:runtime"

import "vsys:abi"
import "vsys:libmui"
import "vsys:libthread"
import "vsys:libuser"

MAX_BYTES :: 256 * 1024
MAX_LINES :: 4096

ctx: runtime.Context
win: libmui.Window
lines: [MAX_LINES]string
line_n: int
path: string

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	ctx = libuser.startup()
	context = ctx
	args := libuser.args(block)
	if len(args) < 2 {
		libuser.eprint("usage: view file\n")
		libuser.exits("usage")
	}
	path = args[1]
	libthread.main(view_main, nil)
}

view_main :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = ctx
	if !read_file() {
		libuser.eprint("view: cannot read ", path, "\n")
		libthread.threadexitsall("read")
	}
	l := libmui.list(20)
	l.rows = lines[:line_n]
	l.id = 1
	col := libmui.group(false)
	libmui.add(col, l)
	win.handler = on_press
	win.want_w, win.want_h = 80 * libmui.FONT_W + 8, 24 * libmui.FONT_H + 8
	win.set_up = true
	win.kind = .Normal
	win.bind_dev = true
	win.own_exit = true
	if !libmui.window_open(&win, base_name(path), col) {
		libthread.threadexitsall("open")
	}
	libmui.window_run(&win)
	libthread.threadexits("")
}

on_press :: proc "contextless" (w: ^libmui.Window, id: int) {
	if id == -1 {
		w.done = true
	}
}

// read_file reads the file whole and splits it into lines on the heap.
read_file :: proc "contextless" () -> bool {
	context = ctx
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return false
	}
	text := make([]u8, MAX_BYTES)
	if text == nil {
		_ = libuser.close(int(fd))
		return false
	}
	total := 0
	for total < len(text) {
		n := libuser.read(int(fd), text[total:])
		if n <= 0 {
			break
		}
		total += int(n)
	}
	_ = libuser.close(int(fd))
	start := 0
	for i in 0 ..< total {
		if text[i] == '\n' {
			if line_n < MAX_LINES {
				lines[line_n] = string(text[start:i])
				line_n += 1
			}
			start = i + 1
		}
	}
	if start < total && line_n < MAX_LINES {
		lines[line_n] = string(text[start:total])
		line_n += 1
	}
	if line_n == 0 {
		lines[0] = "(empty)"
		line_n = 1
	}
	return true
}

base_name :: proc "contextless" (p: string) -> string {
	i := len(p)
	for i > 0 && p[i - 1] != '/' {
		i -= 1
	}
	return p[i:]
}
