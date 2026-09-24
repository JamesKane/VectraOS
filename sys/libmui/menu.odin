/*
menu -- a popup of items, opened at a point, `docs/WORKBENCH.md` section 5 and
`docs/CHROME.md` section 8.

A menu is a window of the `popup` kind holding a column of keys, one per item,
opened where the pointer is. The server closes a popup on a press outside it,
and a key ends it here. So a menu needs nothing of the server but the word. A
program opens one from a button 3 press, `Window.on_menu`, or from a chord. It
hears which item was chosen through `Menu.handler`, with -1 for a menu that
closed on nothing.

**A menu is a tree.** An item may carry a shortcut, drawn at its right, or a
submenu, drawn as an arrow. Choosing an item with a submenu opens the submenu
as a second popup beside it, the cascade the study draws. The program writes
the tree once and hears two numbers. `chosen` is the item in the first menu,
and `sub_chosen` the item in its submenu, or -1. A title, when the tree has one,
sits over the items on a strip of the frame's metal.

**A press in the submenu closes the first menu.** It lands outside that popup,
so the server hangs it up. So a menu that opened a submenu waits for the
submenu before it answers, and answers once for the two.

The menu runs in a thread of its own, on the window it was given, so the
window that opened it keeps taking events. One menu is open at a time on one
`Menu`, which is what a person can use.
*/
package libmui

import "vsys:libthread"
import "vsys:libuser"

MENU_ITEMS :: 16

// One item of a menu's tree: its label and a shortcut to show at its right.
// A submenu shows as an arrow in the shortcut's place.
Menu_Node :: struct {
	label:    string,
	shortcut: string,
	sub:      []Menu_Node,
}

Menu :: struct {
	win:        ^Window,
	items:      []string,
	nodes:      []Menu_Node,
	title:      string,
	chosen:     int,
	sub_chosen: int,
	open:       bool,
	handler:    proc "contextless" (m: ^Menu, item: int),
	user:       rawptr,
	buttons:    [MENU_ITEMS]^Object,
	root:       ^Object,

	// The flat form's items as nodes, for `menu_open`.
	node_buf:   [MENU_ITEMS]Menu_Node,

	// The submenu, made on its first use. It is a menu and a window of its
	// own on the heap, and the channel its end is told on.
	child:      ^Menu,
	child_win:  ^Window,
	waiting:    bool,
	done:       ^libthread.Chan,

	// A docked menu stays up: a choice is told at once and the window
	// stays, `docs/CHROME.md` section 8's main menu.
	docked:     bool,
}

/*
menu_build makes the column a menu draws: its title when it has one, then a
key per item. Each key is as wide as the widest, so the popup is one rectangle
of them. It answers the tree, and the window it goes in takes its extents as its
size.
*/
menu_build :: proc "contextless" (m: ^Menu, nodes: []Menu_Node, t: ^Theme) -> ^Object {
	col := group(false)
	if col == nil {
		return nil
	}
	m.nodes = nodes
	if m.title != "" {
		if tt := title(m.title); tt != nil {
			add(col, tt)
		}
	}
	n := min(len(nodes), MENU_ITEMS)
	for i in 0 ..< n {
		b := item(nodes[i].label, nodes[i].shortcut, nodes[i].sub != nil)
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
menu_open opens a menu of plain items at a point on the screen, the flat form
every program had before menus were trees. It is `menu_open_tree` with no
title and no submenus.
*/
menu_open :: proc "contextless" (m: ^Menu, items: []string, x: int, y: int) -> bool {
	if m == nil || len(items) == 0 {
		return false
	}
	n := min(len(items), MENU_ITEMS)
	for i in 0 ..< n {
		m.node_buf[i] = Menu_Node{label = items[i]}
	}
	m.items = items
	return menu_open_tree(m, "", m.node_buf[:n], x, y)
}

/*
menu_open_tree opens `m` at a point on the screen and hears its choice. `m.win`
is the window the menu draws in, a program's own, opened as a popup at the
point, sized to its column. The thread it runs in ends when an item is chosen,
a key ends it, or the server hangs the popup up. `handler` is told which. A menu
already open is left alone.
*/
menu_open_tree :: proc "contextless" (m: ^Menu, menu_title: string, nodes: []Menu_Node, x: int, y: int) -> bool {
	if m == nil || m.win == nil || m.open || len(nodes) == 0 {
		return false
	}
	win := m.win
	if win.theme.pad == 0 && win.theme.gap == 0 {
		win.theme = ui_theme
	}
	m.title = menu_title
	root := menu_build(m, nodes, &win.theme)
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
	m.sub_chosen = -1
	m.waiting = false
	m.open = true
	if !window_open(win, "menu", root) {
		m.open = false
		return false
	}
	_ = libthread.threadcreate(menu_thread, m)
	return true
}

// menu_press is the popup's handler: an item chosen, or Escape, ends it. An
// item with a submenu opens the submenu and leaves this menu to wait for it.
// A docked menu tells its choice at once and stays up.
@(private = "file")
menu_press :: proc "contextless" (win: ^Window, id: int) {
	m := (^Menu)(win.user)
	if id >= 1 && id - 1 < len(m.nodes) {
		m.chosen = id - 1
		m.sub_chosen = -1
		if m.nodes[id - 1].sub != nil {
			if menu_cascade(m, id - 1) {
				return
			}
		}
		if m.docked {
			if m.handler != nil {
				m.handler(m, m.chosen)
			}
			return
		}
	}
	if !m.docked {
		win.done = true
	}
}

/*
menu_dock opens `m` as a program's docked main menu, NeXT's, `docs/CHROME.md`
section 8. It is a window of the `menu` kind that the server puts at the top
left and shows only while `parent` is in front. It stays up. Each choice is
told to `handler` as it is made, a submenu's through `sub_chosen`, and the menu
goes when the program closes it or ends.
*/
menu_dock :: proc "contextless" (m: ^Menu, parent: ^Window, menu_title: string, nodes: []Menu_Node) -> bool {
	if m == nil || m.win == nil || m.open || len(nodes) == 0 {
		return false
	}
	win := m.win
	if win.theme.pad == 0 && win.theme.gap == 0 {
		win.theme = ui_theme
	}
	m.title = menu_title
	root := menu_build(m, nodes, &win.theme)
	if root == nil {
		return false
	}
	win.kind = .Menu
	win.parent = parent
	win.bind_dev = false
	win.own_exit = false
	win.set_up = true
	win.placed = false
	win.want_w = root.minw
	win.want_h = root.minh
	win.handler = menu_press
	win.user = rawptr(m)
	m.docked = true
	m.chosen = -1
	m.sub_chosen = -1
	m.waiting = false
	m.open = true
	if !window_open(win, menu_title, root) {
		m.open = false
		return false
	}
	_ = libthread.threadcreate(menu_thread, m)
	return true
}

/*
menu_cascade opens item `i`'s submenu beside its key, at the key's top and the
menu's right edge on the screen. The first menu then answers only when the
submenu has, through `done`.
*/
@(private = "file")
menu_cascade :: proc "contextless" (m: ^Menu, i: int) -> bool {
	if m.child == nil {
		m.child = (^Menu)(libuser.heap_alloc(size_of(Menu)))
		m.child_win = (^Window)(libuser.heap_alloc(size_of(Window)))
		if m.child == nil || m.child_win == nil {
			return false
		}
		m.child^ = {}
		m.child_win^ = {}
	}
	if m.done == nil {
		m.done = libthread.chancreate(size_of(u64), 1)
	}
	if m.child.open || m.done == nil {
		return false
	}
	key := m.buttons[i]
	_ = window_locate(m.win)
	m.child.win = m.child_win
	m.child.handler = menu_child_done
	m.child.user = rawptr(m)
	m.child_win.theme = m.win.theme
	m.waiting = true
	if !menu_open_tree(m.child, "", m.nodes[i].sub, m.win.sx + m.win.cw, m.win.sy + key.y) {
		m.waiting = false
		return false
	}
	return true
}

// menu_child_done hears the submenu's choice, gives it to the first menu, and
// ends that menu if the server has not already.
@(private = "file")
menu_child_done :: proc "contextless" (cm: ^Menu, item: int) {
	m := (^Menu)(cm.user)
	m.sub_chosen = item
	if m.docked {
		// The main menu stays up: the choice two deep is told now.
		m.waiting = false
		if item >= 0 && m.handler != nil {
			m.handler(m, m.chosen)
		}
		return
	}
	if item < 0 {
		m.chosen = -1
	}
	if !m.win.done {
		window_end(m.win)
	}
	libthread.sendul(m.done, 1)
}

// menu_thread runs the popup and, when it ends, tells the program: after the
// submenu, when this menu opened one.
@(private = "file")
menu_thread :: proc "contextless" (arg: rawptr) {
	m := (^Menu)(arg)
	window_run(m.win)
	if m.waiting {
		_ = libthread.recvul(m.done)
		m.waiting = false
	}
	m.open = false
	if m.handler != nil && !m.docked {
		m.handler(m, m.chosen)
	}
	libthread.threadexits("")
}

