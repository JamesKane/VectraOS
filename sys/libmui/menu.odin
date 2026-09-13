/*
menu -- a popup of items, opened at a point, `docs/WORKBENCH.md` section 5.

A menu is a window of the `popup` kind holding a column of buttons, one per
item, opened where the pointer is. The server closes a popup on a press
outside it, and a key ends it here. So a menu needs nothing of the server
but the word. A program opens one from a button 3 press, `Window.on_menu`,
or from a chord. It hears which item was chosen through `Menu.handler`,
with -1 for a menu that closed on nothing.

The menu runs in a thread of its own, on the window it was given, so the
window that opened it keeps taking events. One menu is open at a time on
one `Menu`, which is what a person can use.
*/
package libmui

import "vsys:libthread"

MENU_ITEMS :: 16

Menu :: struct {
	win:     ^Window,
	items:   []string,
	chosen:  int,
	open:    bool,
	handler: proc "contextless" (m: ^Menu, item: int),
	user:    rawptr,
	buttons: [MENU_ITEMS]^Object,
	root:    ^Object,
}

/*
menu_build makes the column a menu draws: a button per item, each as wide
as the longest, so the popup is one rectangle of them. It answers the
tree, and the window it goes in takes its extents as its size.
*/
menu_build :: proc "contextless" (m: ^Menu, items: []string, t: ^Theme) -> ^Object {
	col := group(false)
	if col == nil {
		return nil
	}
	m.items = items
	n := min(len(items), MENU_ITEMS)
	for i in 0 ..< n {
		b := button(items[i])
		if b == nil {
			return nil
		}
		b.id = i + 1
		m.buttons[i] = b
		add(col, b)
	}
	fit(col, t)
	m.root = col
	return col
}

/*
menu_open opens `m` at a point on the screen and hears its choice. `m.win`
is the window the menu draws in, a program's own, opened as a popup at the
point, sized to its column. The thread it runs in ends when an item is
chosen, a key ends it, or the server hangs the popup up. `handler` is told
which. A menu already open is left alone.
*/
menu_open :: proc "contextless" (m: ^Menu, items: []string, x: int, y: int) -> bool {
	if m == nil || m.win == nil || m.open || len(items) == 0 {
		return false
	}
	win := m.win
	if win.theme.pad == 0 && win.theme.gap == 0 {
		win.theme = ui_theme
	}
	root := menu_build(m, items, &win.theme)
	if root == nil {
		return false
	}
	win.kind = .Popup
	win.bind_dev = false
	win.own_exit = false
	win.set_up = true
	win.placed = true
	win.at_x = x
	win.at_y = y
	win.want_w = root.minw
	win.want_h = root.minh
	win.handler = menu_press
	win.user = rawptr(m)
	m.chosen = -1
	m.open = true
	if !window_open(win, "menu", root) {
		m.open = false
		return false
	}
	_ = libthread.threadcreate(menu_thread, m)
	return true
}

// menu_press is the popup's handler: an item chosen, or Escape, ends it.
@(private = "file")
menu_press :: proc "contextless" (win: ^Window, id: int) {
	m := (^Menu)(win.user)
	if id >= 1 {
		m.chosen = id - 1
	}
	win.done = true
}

// menu_thread runs the popup and, when it ends, tells the program.
@(private = "file")
menu_thread :: proc "contextless" (arg: rawptr) {
	m := (^Menu)(arg)
	window_run(m.win)
	m.open = false
	if m.handler != nil {
		m.handler(m, m.chosen)
	}
	libthread.threadexits("")
}
