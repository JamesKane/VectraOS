/*
libmui -- a toolkit that places gadgets by weight, never by a number.

A program on Amiga's MUI never wrote a pixel coordinate. It built a tree of
objects, said which stretched and which stayed, and the layout engine solved
for the rest. This is that engine in ring 3. The look draws on the "Cyberpunk
Workstation 1994" chrome from `sys/libpal` and `sys/libdraw`, and the
arithmetic here decides only where each rectangle goes.

**An object is a node in a tree.** A leaf is a `Text`, a `Button`, a
`Checkmark`, a `String` or a `Space`. A `Group` holds children along one axis,
left to right or top to bottom. `fit` walks the tree once from the leaves up
and fills each node's smallest and largest extents. `lay` walks once from the
root down and hands each node a rectangle inside its parent.

**Weight decides who grows.** When a group has more room than its children
need, the extra is shared out along the axis in proportion to each child's
weight. A rigid child, one whose largest extent equals its smallest, takes a
weight of zero and never grows. A stretchy child takes a weight of one unless
the caller sets another. The share is tiled with a running prefix so the pieces
sum to the whole with nothing lost to rounding.

Drawing and the event loop are a separate file. This one is pure geometry, and
`tests/mui` proves the numbers it computes against the same rule worked by
hand.
*/
package libmui

import "vsys:libuser"

// A very large extent, the mark of a node that stretches without limit.
BIG :: 1 << 20

// The font is fixed at one cell, as `sys/libfont` draws it.
FONT_W :: 8
FONT_H :: 16

// -- The theme: the numbers the look is made of ------------------------------

/*
A theme is the metrics a layout reads and the palette a painter reads. Only the
metrics matter to `fit` and `lay`. A face loads from a file at start. The default here is the built-in look, so a
program draws before any file reaches it.
*/
Theme :: struct {
	pad:   int, // A group's inset from its own edge to its children
	gap:   int, // The space left between two siblings
	bevel: int, // The thickness of a raised control's lit and dark edges
	hpad:  int, // A button's inset from its edge to its text, left and right
	vpad:  int, // A button's inset from its edge to its text, top and bottom
	well:  int, // A string gadget's recess around the text it holds
}

default_theme :: Theme{pad = 4, gap = 4, bevel = 2, hpad = 8, vpad = 4, well = 2}

// -- The object model --------------------------------------------------------

Class :: enum u8 {
	Space, // Blank room that stretches, the glue of a layout
	Text, // A rigid run of characters, the size of the string
	Button, // A raised control with a label, stretches both ways
	Checkmark, // A square lamp, on or off, rigid
	String, // A recessed field for typed text, stretches wide
	Group, // A parent that lays its children along one axis
}

/*
One node. A caller builds these, links them with `add`, and reads back the
rectangle each holds after `lay`. The extents `fit` computes and the rectangle
`lay` computes live in the same record so a program never carries a parallel
array of geometry.
*/
Object :: struct {
	class:  Class,
	horiz:  bool, // A group: true lays children left to right, false top to bottom
	label:  string, // Text and Button: the characters drawn
	weight: int, // Along the parent's axis, this node's share of the extra room
	// Filled by fit, the smallest and largest this node accepts.
	minw:   int,
	minh:   int,
	maxw:   int,
	maxh:   int,
	// Filled by lay, the rectangle this node was given.
	x:      int,
	y:      int,
	w:      int,
	h:      int,
	// The tree, a first child and a sibling chain.
	first:  ^Object,
	next:   ^Object,
	parent: ^Object,
	// Widget state a caller reads and writes.
	on:     bool, // Checkmark: lit or dark
	id:     int, // A caller's own tag, returned in events
}

// -- Building a tree ---------------------------------------------------------

/*
`obj` allocates a node from the heap and gives it a class. A leaf is done after
this. A group is filled with `add`.
*/
obj :: proc "contextless" (class: Class) -> ^Object {
	o := (^Object)(libuser.heap_alloc(size_of(Object)))
	if o == nil {
		return nil
	}
	o^ = Object{}
	o.class = class
	return o
}

text :: proc "contextless" (label: string) -> ^Object {
	o := obj(.Text)
	if o != nil {o.label = label}
	return o
}

button :: proc "contextless" (label: string) -> ^Object {
	o := obj(.Button)
	if o != nil {o.label = label}
	return o
}

space :: proc "contextless" () -> ^Object {
	return obj(.Space)
}

checkmark :: proc "contextless" (on: bool) -> ^Object {
	o := obj(.Checkmark)
	if o != nil {o.on = on}
	return o
}

field :: proc "contextless" () -> ^Object {
	return obj(.String)
}

group :: proc "contextless" (horiz: bool) -> ^Object {
	o := obj(.Group)
	if o != nil {o.horiz = horiz}
	return o
}

/*
`add` links `child` as the last child of `parent`. It returns `parent` so a
tree reads as nested calls. A weight set on the child before this call is kept.
*/
add :: proc "contextless" (parent: ^Object, child: ^Object) -> ^Object {
	if parent == nil || child == nil {
		return parent
	}
	child.parent = parent
	child.next = nil
	if parent.first == nil {
		parent.first = child
		return parent
	}
	tail := parent.first
	for tail.next != nil {
		tail = tail.next
	}
	tail.next = child
	return parent
}

// weigh sets a node's stretch weight and returns it, for use inside `add`.
weigh :: proc "contextless" (o: ^Object, w: int) -> ^Object {
	if o != nil {o.weight = w}
	return o
}

// -- fit: the smallest and largest each node accepts -------------------------

// drawn_len counts the cells a label draws. A single `_` before a letter marks
// a hotkey and is not drawn, the way a menu label underlines its key.
drawn_len :: proc "contextless" (label: string) -> int {
	n := 0
	i := 0
	for i < len(label) {
		c := label[i]
		if c == '_' && i + 1 < len(label) {
			d := label[i + 1]
			is_letter := (d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z')
			if is_letter {
				i += 1
				continue
			}
		}
		n += 1
		i += 1
	}
	return n
}

/*
`fit` fills a node's four extents from its class and, for a group, from its
children. It recurses to the leaves first, so a group reads extents its
children already hold. It also sets the default weight. A node that can stretch
takes a weight of one, and a rigid one takes zero, unless a caller set a weight
already.
*/
fit :: proc "contextless" (o: ^Object, t: ^Theme) {
	if o == nil {
		return
	}
	switch o.class {
	case .Space:
		o.minw, o.minh = 0, 0
		o.maxw, o.maxh = BIG, BIG
	case .Text:
		w := drawn_len(o.label) * FONT_W
		o.minw, o.maxw = w, w
		o.minh, o.maxh = FONT_H, FONT_H
	case .Button:
		cw := drawn_len(o.label) * FONT_W + 2 * t.hpad + 2 * t.bevel
		ch := FONT_H + 2 * t.vpad + 2 * t.bevel
		o.minw, o.minh = cw, ch
		o.maxw, o.maxh = BIG, BIG
	case .Checkmark:
		s := FONT_H + 2 * t.bevel
		o.minw, o.maxw = s, s
		o.minh, o.maxh = s, s
	case .String:
		o.minw = 6 * FONT_W + 2 * t.well
		o.maxw = BIG
		o.minh = FONT_H + 2 * t.well
		o.maxh = o.minh
	case .Group:
		// Recurse first, then sum along the axis and take the widest across it.
		n := 0
		sum_min_a := 0
		sum_max_a := 0
		max_min_c := 0
		max_max_c := 0
		any_stretch_a := false
		any_stretch_c := false
		for c := o.first; c != nil; c = c.next {
			fit(c, t)
			n += 1
			mina, maxa := along(o.horiz, c.minw, c.minh), along(o.horiz, c.maxw, c.maxh)
			minc, maxc := across(o.horiz, c.minw, c.minh), across(o.horiz, c.maxw, c.maxh)
			sum_min_a += mina
			sum_max_a += maxa
			if maxa >= BIG {any_stretch_a = true}
			if minc > max_min_c {max_min_c = minc}
			if maxc > max_max_c {max_max_c = maxc}
			if maxc >= BIG {any_stretch_c = true}
		}
		gaps := 0
		if n > 1 {gaps = t.gap * (n - 1)}
		min_a := sum_min_a + gaps + 2 * t.pad
		max_a := sum_max_a + gaps + 2 * t.pad
		if any_stretch_a || max_a > BIG {max_a = BIG}
		min_c := max_min_c + 2 * t.pad
		max_c := max_max_c + 2 * t.pad
		if any_stretch_c || max_c > BIG {max_c = BIG}
		if o.horiz {
			o.minw, o.maxw = min_a, max_a
			o.minh, o.maxh = min_c, max_c
		} else {
			o.minh, o.maxh = min_a, max_a
			o.minw, o.maxw = min_c, max_c
		}
	}
	// A node that can grow and has no weight yet takes a weight of one. Equal
	// siblings then share the room equally.
	if o.weight == 0 && (o.maxw > o.minw || o.maxh > o.minh) {
		o.weight = 1
	}
}

// along returns the extent on a group's own axis, across the other.
along :: proc "contextless" (horiz: bool, w: int, h: int) -> int {
	return w if horiz else h
}
across :: proc "contextless" (horiz: bool, w: int, h: int) -> int {
	return h if horiz else w
}

// -- lay: a rectangle for every node -----------------------------------------

/*
`lay` gives `o` the rectangle `(x, y, w, h)` and, if it is a group, solves for
its children. The room left after every child's smallest extent is shared along
the axis by weight, tiled with a running prefix so the shares sum exactly. On
the other axis each child takes the group's inner extent, clamped to what the
child accepts, and is centred in it.
*/
lay :: proc "contextless" (o: ^Object, x: int, y: int, w: int, h: int, t: ^Theme) {
	if o == nil {
		return
	}
	o.x, o.y, o.w, o.h = x, y, w, h
	if o.class != .Group || o.first == nil {
		return
	}
	inx := x + t.pad
	iny := y + t.pad
	inw := w - 2 * t.pad
	inh := h - 2 * t.pad

	n := 0
	total_min_a := 0
	total_weight := 0
	for c := o.first; c != nil; c = c.next {
		n += 1
		total_min_a += along(o.horiz, c.minw, c.minh)
		total_weight += c.weight
	}
	gaps := 0
	if n > 1 {gaps = t.gap * (n - 1)}
	avail_a := (inw if o.horiz else inh) - gaps
	extra := avail_a - total_min_a
	if extra < 0 {extra = 0}

	// The across extent every child is offered before its own clamp.
	in_c := inh if o.horiz else inw

	cursor := inx if o.horiz else iny
	acc_w := 0
	prev := 0
	for c := o.first; c != nil; c = c.next {
		acc_w += c.weight
		portion := 0
		if total_weight > 0 {
			portion = extra * acc_w / total_weight
		}
		give := portion - prev
		prev = portion

		size_a := along(o.horiz, c.minw, c.minh) + give
		max_a := along(o.horiz, c.maxw, c.maxh)
		if size_a > max_a {size_a = max_a}

		size_c := in_c
		min_c := across(o.horiz, c.minw, c.minh)
		max_c := across(o.horiz, c.maxw, c.maxh)
		if size_c < min_c {size_c = min_c}
		if size_c > max_c {size_c = max_c}
		off_c := (in_c - size_c) / 2
		if off_c < 0 {off_c = 0}

		if o.horiz {
			lay(c, cursor, iny + off_c, size_a, size_c, t)
			cursor += size_a + t.gap
		} else {
			lay(c, inx + off_c, cursor, size_c, size_a, t)
			cursor += size_a + t.gap
		}
	}
}
