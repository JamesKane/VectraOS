/*
event -- what the pointer and the keyboard mean to a laid-out tree.

A window's event loop reads the pointer from its `mouse` file and the keys from
its `cons`, and turns each into an `Event`. This file says what an event does
to the tree: which gadget a click lands on, and when a requester is dismissed.
The dispatch is pure, a function of the tree's rectangles and the event, so
`tests/mui` drives it with made-up events and no window at all.

`hit` finds the interactive gadget under a point. A button, a checkmark and a
string field take clicks. A label, a group and glue do not, so a click passes
through them to whatever interactive gadget holds the point, or to nothing. A
requester is the modal case the plan names. Return dismisses it and chooses its
default, Escape chooses its cancel, and a click on any button chooses that
button.
*/
package libmui

// An event from a window's files. A mouse event carries a point and the button
// bits `/dev/mouse` reports, one per button with 1 the left. A key event
// carries the byte `cons` delivered.
Event_Kind :: enum u8 {
	Move,
	Press,
	Release,
	Key,
}

Event :: struct {
	kind:    Event_Kind,
	x:       int,
	y:       int,
	buttons: u8,
	key:     u8,
}

// Bytes a key event may carry that mean "accept" or "cancel".
KEY_RETURN_N :: u8('\n')
KEY_RETURN_R :: u8('\r')
KEY_ESCAPE :: u8(0x1b)

// interactive reports whether a class takes a click. A container and a label
// pass a click through to whatever sits under them.
interactive :: proc "contextless" (class: Class) -> bool {
	return class == .Button || class == .Checkmark || class == .String
}

// contains reports whether a node's rectangle holds a point.
contains :: proc "contextless" (o: ^Object, x: int, y: int) -> bool {
	if o == nil {
		return false
	}
	return x >= o.x && x < o.x + o.w && y >= o.y && y < o.y + o.h
}

/*
hit returns the interactive gadget under (x, y), the deepest one, or nil. It
descends into any group that holds the point, so a click finds a gadget nested
inside a row inside a column. A group and a label are transparent to the click,
which is why a point over a label between two buttons hits neither.
*/
hit :: proc "contextless" (root: ^Object, x: int, y: int) -> ^Object {
	if root == nil || !contains(root, x, y) {
		return nil
	}
	// A child's rectangle is inside its parent's, so a deeper hit wins.
	for c := root.first; c != nil; c = c.next {
		if got := hit(c, x, y); got != nil {
			return got
		}
	}
	if interactive(root.class) {
		return root
	}
	return nil
}

/*
A requester is a modal tree with a default button and a cancel button, either
of which may be absent. `root` is laid out by the caller. `handle` returns
whether the event dismissed it and, if so, the id of the button that did.
*/
Requester :: struct {
	root:   ^Object,
	def:    ^Object, // Chosen by Return; nil if the requester has no default
	cancel: ^Object, // Chosen by Escape; nil if it has none
}

/*
req_handle applies one event to a requester. Return chooses the default,
Escape the cancel, and a release over a button chooses that button. It returns
`done` true with the chosen button's `id`, or `done` false when the event left
the requester standing. A press is swallowed so the release is the commit, the
way a gadget waits for the button to come up.
*/
req_handle :: proc "contextless" (req: ^Requester, ev: Event) -> (done: bool, id: int) {
	if req == nil {
		return false, 0
	}
	switch ev.kind {
	case .Key:
		if ev.key == KEY_RETURN_N || ev.key == KEY_RETURN_R {
			if req.def != nil {
				return true, req.def.id
			}
		}
		if ev.key == KEY_ESCAPE {
			if req.cancel != nil {
				return true, req.cancel.id
			}
		}
		return false, 0
	case .Release:
		g := hit(req.root, ev.x, ev.y)
		if g != nil && g.class == .Button {
			return true, g.id
		}
		return false, 0
	case .Move, .Press:
		return false, 0
	}
	return false, 0
}

/*
requester builds the modal tree the plan describes: a message over a row of
buttons pushed to the right by glue. `ok` is the default, chosen by Return, and
its id is 1. When `cancel_label` is not empty a second button is added with id
2, chosen by Escape. The caller fits and lays the returned `root` inside the
rectangle it wants the requester centred in.
*/
requester :: proc "contextless" (message: string, ok_label: string, cancel_label: string) -> Requester {
	col := group(false)
	col.on = true // A requester frames itself; the flag marks it for the painter.
	add(col, text(message))

	row := group(true)
	add(row, space())
	req := Requester {
		root = col,
	}
	if cancel_label != "" {
		cancel_btn := button(cancel_label)
		cancel_btn.id = 2
		add(row, cancel_btn)
		req.cancel = cancel_btn
	}
	ok_btn := button(ok_label)
	ok_btn.id = 1
	add(row, ok_btn)
	req.def = ok_btn
	add(col, row)
	return req
}
