/*
muidemo -- a panel of gadgets, to show the toolkit is live.

This is the first program on `sys/libmui`. It opens a window, builds a tree of
gadgets the layout places by weight, and runs the toolkit's event loop. It
draws nothing itself: the tree says what the window holds, the theme says what
it looks like, and `libmui` does the rest. A click on a button or a key on the
focus reaches `on_press`, and the Quit button ends it.

`docs/WORKBENCH.md` step 3 asked for a program that proves the toolkit works in
a real window. This is that program, and the desktop screenshot is what it
looks like beside the terminal.
*/
package muidemo

import "vsys:abi"
import "vsys:libmui"
import "vsys:libthread"
import "vsys:libuser"

win: libmui.Window

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = libuser.startup()
	libthread.main(demo_main, nil)
}

// on_press hears a gadget's id when it is clicked or pressed from the keyboard.
// The Quit button ends the program, which closes the window.
on_press :: proc "contextless" (w: ^libmui.Window, id: int) {
	if id == 9 || id == -1 {
		w.done = true
	}
}

demo_main :: proc "contextless" (arg: rawptr) {
	_ = arg

	// A column of rows: a title, a line of buttons, a switch, a field, and the
	// row that dismisses. The weights leave the buttons and the field stretchy
	// and the labels rigid, so the panel grows gracefully with the window.
	col := libmui.group(false)
	libmui.add(col, libmui.text("libmui -- the toolkit, live"))

	tools := libmui.group(true)
	libmui.add(tools, id_button("Open", 1))
	libmui.add(tools, id_button("Save", 2))
	libmui.add(tools, id_button("Copy", 3))
	libmui.add(col, tools)

	snap := libmui.group(true)
	libmui.add(snap, libmui.checkmark(true))
	libmui.add(snap, libmui.text("Snap to grid"))
	libmui.add(snap, libmui.space())
	libmui.add(col, snap)

	named := libmui.group(true)
	libmui.add(named, libmui.text("Name:"))
	libmui.add(named, libmui.field())
	libmui.add(col, named)

	foot := libmui.group(true)
	libmui.add(foot, libmui.space())
	libmui.add(foot, id_button("OK", 1))
	libmui.add(foot, id_button("Quit", 9))
	libmui.add(col, foot)

	win.handler = on_press
	if !libmui.window_open(&win, "Workbench", col) {
		libthread.threadexitsall("open")
	}
	libmui.window_run(&win)
	libthread.threadexits("")
}

// id_button makes a button and tags it, so `on_press` knows which was hit.
id_button :: proc "contextless" (label: string, id: int) -> ^libmui.Object {
	b := libmui.button(label)
	if b != nil {
		b.id = id
	}
	return b
}
