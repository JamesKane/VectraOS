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
import "vsys:libdraw"
import "vsys:libmui"
import "vsys:libthread"
import "vsys:libuser"

win: libmui.Window

// The menu and the window it draws in: a button 3 press opens it, the
// toolkit's `Menu` on a program's own window, `docs/WORKBENCH.md` section 5.
// A menu is a popup, so it is a window of its own, separate from the panel's.
menu: libmui.Menu
menu_win: libmui.Window
// The menu is a tree, `docs/CHROME.md` section 8: a title, an item with a
// shortcut, a submenu, and Close.
window_items := [2]libmui.Menu_Node{{label = "Snap left"}, {label = "Snap right"}}
menu_nodes := [3]libmui.Menu_Node{
	{label = "New View", shortcut = "alt-n"},
	{label = "Window", sub = window_items[:]},
	{label = "Close", shortcut = "alt-w"},
}

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

// on_menu is a button 3 press, with the point it landed on in the panel's own
// coordinates. It opens the toolkit's menu there, at the pointer on the
// screen, which is `w.sx`/`w.sy` plus the point.
on_menu :: proc "contextless" (w: ^libmui.Window, x: int, y: int) {
	menu.win = &menu_win
	menu.handler = menu_chosen
	libmui.window_locate(w)
	libmui.menu_open_tree(&menu, "Demo", menu_nodes[:], w.sx + x, w.sy + y)
}

// menu_chosen hears which item was picked, or -1 if the menu closed on
// nothing. `Close` ends the program. `Window`'s submenu snaps the demo's own
// window through its `wctl`, which is how the self-test sees a choice made two
// menus deep.
menu_chosen :: proc "contextless" (m: ^libmui.Menu, item: int) {
	switch item {
	case 1:
		words := [2]string{"snap left", "snap right"}
		if m.sub_chosen >= 0 && m.sub_chosen < len(words) {
			path: [128]u8
			if fd := libuser.open(libdraw.win_path(path[:], win.base, win.id, "wctl"), abi.O_WRONLY); fd >= 0 {
				_ = libuser.write(int(fd), transmute([]u8)words[m.sub_chosen])
				_ = libuser.close(int(fd))
			}
		}
	case 2:
		win.done = true
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
	win.on_menu = on_menu
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
