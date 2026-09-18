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

import "vsys:libdraw"
import "vsys:libpal"
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
	// The palette a painter reads. A theme file's `face` line changes the
	// first of these, which is how the "Cyberpunk 1994" look is themed.
	ground: libpal.RGB, // The window behind the gadgets
	face:   libpal.RGB, // A raised control's face
	lit:    libpal.RGB, // A raised control's top-left highlight
	shade:  libpal.RGB, // A raised control's bottom-right shadow
	ink:    libpal.RGB, // Text, and a lit checkmark
	// The inks a styled row wears, `docs/WEB.md` section 5's "the theme
	// says how": a heading, a link, and a quote.
	hot:    libpal.RGB,
	link:   libpal.RGB,
	dim:    libpal.RGB,
}

default_theme :: Theme {
	pad    = 4,
	gap    = 4,
	bevel  = 2,
	hpad   = 8,
	vpad   = 4,
	well   = 2,
	ground = libpal.SLATE_DEEP,
	face   = libpal.MAGNESIUM,
	lit    = libpal.MAGNESIUM_LIT,
	shade  = libpal.MAGNESIUM_DARK,
	ink    = libpal.AMBER,
	hot    = libpal.AMBER_HOT,
	link   = libpal.CYAN,
	dim    = libpal.AMBER_DIM,
}

// The styles a list's rows may wear, one byte a row in `styles`. A page is
// a list whose rows know what they are.
STYLE_PLAIN :: u8(0)
STYLE_HEADING :: u8(1)
STYLE_LINK :: u8(2)
STYLE_QUOTE :: u8(3)
STYLE_PRE :: u8(4)
STYLE_RULE :: u8(5) // A line across the well, no text
STYLE_PICTURE :: u8(6) // A row a picture stands on, no text

// A picture standing on a list's rows: `tall` rows from `row`, its pixels
// as a picture gadget's. The caller owns the pixels.
Row_Picture :: struct {
	row:  int,
	tall: int,
	pix:  []u8,
	pw:   int,
	ph:   int,
}

// -- The object model --------------------------------------------------------

Class :: enum u8 {
	Space, // Blank room that stretches, the glue of a layout
	Text, // A rigid run of characters, the size of the string
	Button, // A raised control with a label, stretches both ways
	Checkmark, // A square lamp, on or off, rigid
	String, // A recessed field for typed text, stretches wide
	Group, // A parent that lays its children along one axis
	List, // Rows of text in a well, one selected, scrolled by its top row
	Icons, // Cells in a well, a picture and a name each, one selected, scrolled by rows
	Picture, // Pixels in a well, fitted to it, stretches both ways
}

// The kinds an icon is, `docs/WORKBENCH.md` section 6: a directory is a
// drawer, a program is a tool, anything else is a project. Each kind has one
// picture, drawn in the chassis's vocabulary.
ICON_DRAWER :: u8(0)
ICON_TOOL :: u8(1)
ICON_PROJECT :: u8(2)

// An icon's cell: the picture above, the name under it, in a grid the well's
// width divides into.
ICON_W :: 96
ICON_H :: 64
// How many glyph cells a name gets under an icon: the cell width less one, so
// the last column stays a margin. A compile-time constant off two constants.
NAME_CELLS :: ICON_W / FONT_W - 1

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
	// A list's rows, which the caller owns, and how it shows them. An
	// icon grid's rows are its names, and `kinds` says the picture each
	// wears. `top` is then its first row of cells.
	rows:     []string,
	kinds:    []u8,
	top:      int, // The first row drawn
	sel:      int, // The selected row, or -1
	min_rows: int, // The rows `fit` asks room for

	// An icon grid's free placement, for Snapshot: when set, one (x, y) per
	// cell, in the well's interior, rather than the row-and-column grid. A
	// drag places a cell; Clean Up clears it back to `nil` and the grid. The
	// caller owns the slice. See `icons_place` and `docs/WORKBENCH.md`.
	place:    [][2]int,

	// A string gadget's text, in storage the caller owns, and how much of
	// it is written. `string_key` edits it.
	edit:     []u8,
	edit_n:   int,

	// A picture's pixels, `pw` by `ph` of four bytes each, RGBA, which the
	// caller owns. Drawn fitted into the well, never enlarged.
	pix:      []u8,
	pw:       int,
	ph:       int,

	// A list's row styles, one STYLE byte a row, and the pictures standing
	// on its rows. Either may be nil, for a list of plain rows.
	styles:   []u8,
	pics:     []Row_Picture,
}

// row_style answers a row's style, plain when the list has none.
row_style :: proc "contextless" (o: ^Object, row: int) -> u8 {
	if o.styles == nil || row < 0 || row >= len(o.styles) {
		return STYLE_PLAIN
	}
	return o.styles[row]
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

// list makes a list that asks room for `min_rows` rows and stretches past
// them. The caller sets its rows, and none is selected.
list :: proc "contextless" (min_rows: int) -> ^Object {
	o := obj(.List)
	if o != nil {
		o.min_rows = min_rows
		o.sel = -1
	}
	return o
}

// picture makes a gadget that shows pixels. The caller sets `pix`, `pw`
// and `ph`, and may change them between paints.
picture :: proc "contextless" () -> ^Object {
	return obj(.Picture)
}

// list_visible answers how many rows a laid-out list shows.
// icons makes an icon grid that asks room for `min_rows` rows of cells. The
// caller fills `rows` with the names and `kinds` with a kind per name.
icons :: proc "contextless" (min_rows: int) -> ^Object {
	o := obj(.Icons)
	if o != nil {
		o.min_rows = min_rows
		o.sel = -1
	}
	return o
}

// icons_cols is how many cells a row of the grid holds at its laid width.
icons_cols :: proc "contextless" (o: ^Object, t: ^Theme) -> int {
	if o == nil {
		return 0
	}
	return max((o.w - 2 * t.well) / ICON_W, 1)
}

// icons_visible is how many rows of cells the well shows.
icons_visible :: proc "contextless" (o: ^Object, t: ^Theme) -> int {
	if o == nil {
		return 0
	}
	return max((o.h - 2 * t.well) / ICON_H, 0)
}

// icons_cell_at answers the icon under a point, or -1 for the well between.
icons_cell_at :: proc "contextless" (o: ^Object, x: int, y: int, t: ^Theme) -> int #no_bounds_check {
	if o == nil {
		return -1
	}
	// Free placement: the topmost cell whose square holds the point, which is
	// the last drawn, so the search runs from the end.
	if o.place != nil {
		n := min(len(o.rows), len(o.place))
		for i := n - 1; i >= 0; i -= 1 {
			cx, cy := icons_place_xy(o, i, t)
			if x >= cx && x < cx + ICON_W && y >= cy && y < cy + ICON_H {
				return i
			}
		}
		return -1
	}
	if x < o.x + t.well || y < o.y + t.well {
		return -1
	}
	col := (x - o.x - t.well) / ICON_W
	row := (y - o.y - t.well) / ICON_H
	cols := icons_cols(o, t)
	if col >= cols || row >= icons_visible(o, t) {
		return -1
	}
	i := (o.top + row) * cols + col
	if i < 0 || i >= len(o.rows) {
		return -1
	}
	return i
}

// icons_grid_xy is where cell `i` sits in the well's interior under the
// row-and-column grid, so a caller seeding free placement starts from where
// the icons already are. The caller owns the `place` slice; this only says
// where the grid would put a cell.
icons_grid_xy :: proc "contextless" (o: ^Object, i: int, t: ^Theme) -> (x: int, y: int) {
	cols := icons_cols(o, t)
	return (i % cols) * ICON_W, (i / cols) * ICON_H
}

// icons_place_xy is where a freely-placed cell `i` sits: its stored place
// offset past the well inset, in the window's own coordinates. Paint
// (`icon_cells`) and hit-test (`icons_cell_at`) both ask it, so the two never
// disagree about where a placed icon is.
icons_place_xy :: proc "contextless" (o: ^Object, i: int, t: ^Theme) -> (x: int, y: int) {
	return o.x + t.well + o.place[i][0], o.y + t.well + o.place[i][1]
}

/*
icons_set gives cell `i` a free position, `(wx, wy)` in the well's interior.
The first placement allocates the slice from the grid, so every other cell
keeps where it was until it too is moved. The caller owns the slice;
`icons_clear` frees it and returns to the grid. Allocates, so it is not
contextless: the caller's context is the allocator.
*/
icons_set :: proc(o: ^Object, i: int, wx: int, wy: int, t: ^Theme) #no_bounds_check {
	if o == nil || o.class != .Icons || i < 0 || i >= len(o.rows) {
		return
	}
	if o.place == nil {
		o.place = make([][2]int, len(o.rows))
		for k in 0 ..< len(o.rows) {
			o.place[k][0], o.place[k][1] = icons_grid_xy(o, k, t)
		}
	}
	if i >= len(o.place) {
		return
	}
	o.place[i] = {max(wx, 0), max(wy, 0)}
}

// icons_clear drops free placement, so the grid lays the icons out again. Clean
// Up is this, and a caller frees the slice it owned here.
icons_clear :: proc(o: ^Object) {
	if o != nil && o.place != nil {
		delete(o.place)
		o.place = nil
	}
}

// field_text answers what a string gadget holds.
field_text :: proc "contextless" (o: ^Object) -> string {
	if o == nil || o.edit == nil {
		return ""
	}
	return string(o.edit[:o.edit_n])
}

// string_key edits a string gadget by one key: a printable byte is appended,
// a backspace or delete takes the last one off. Answers whether the text
// changed, so a caller knows to repaint. Return and Escape are not its to
// take, and a field with no storage takes nothing.
string_key :: proc "contextless" (o: ^Object, k: u8) -> bool #no_bounds_check {
	if o == nil || o.class != .String || o.edit == nil {
		return false
	}
	switch k {
	case 0x08, 0x7F:
		if o.edit_n > 0 {
			o.edit_n -= 1
			return true
		}
	case 0x20 ..= 0x7E:
		if o.edit_n < len(o.edit) {
			o.edit[o.edit_n] = k
			o.edit_n += 1
			return true
		}
	}
	return false
}

list_visible :: proc "contextless" (o: ^Object, t: ^Theme) -> int {
	if o == nil {
		return 0
	}
	return max((o.h - 2 * t.well) / FONT_H, 0)
}

// list_show scrolls a list so that `row` is drawn, near the middle when the
// list has to move, so the rows around it show too.
list_show :: proc "contextless" (o: ^Object, row: int, t: ^Theme) {
	if o == nil {
		return
	}
	n := list_visible(o, t)
	if n <= 0 || row < 0 {
		return
	}
	if row < o.top || row >= o.top + n {
		o.top = max(row - n / 2, 0)
	}
}

// list_row_at answers the row under a point in a laid-out list, or -1.
list_row_at :: proc "contextless" (o: ^Object, y: int, t: ^Theme) -> int {
	if o == nil || y < o.y + t.well {
		return -1
	}
	k := (y - o.y - t.well) / FONT_H
	if k >= list_visible(o, t) {
		return -1
	}
	row := o.top + k
	if row < 0 || row >= len(o.rows) {
		return -1
	}
	return row
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

// rune_len counts the cells a text draws: one per rune.
rune_len :: proc "contextless" (label: string) -> int {
	n := 0
	i := 0
	for i < len(label) {
		_, size := libdraw.decode_rune(transmute([]u8)label[i:])
		if size <= 0 {
			break
		}
		n += 1
		i += size
	}
	return n
}

// drawn_len counts the cells a button's label draws. A single `_` before a
// letter marks a hotkey and is not drawn, the way a menu label underlines
// its key.
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
		// One cell per rune, so a multi-byte rune counts once, not once a byte.
		_, size := libdraw.decode_rune(transmute([]u8)label[i:])
		if size <= 0 {
			break
		}
		n += 1
		i += size
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
		w := rune_len(o.label) * FONT_W
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
	case .List:
		o.minw = 8 * FONT_W + 2 * t.well
		o.maxw = BIG
		o.minh = max(o.min_rows, 1) * FONT_H + 2 * t.well
		o.maxh = BIG
	case .Picture:
		o.minw = 8 * FONT_W + 2 * t.well
		o.maxw = BIG
		o.minh = 4 * FONT_H + 2 * t.well
		o.maxh = BIG
	case .Icons:
		o.minw = 2 * ICON_W + 2 * t.well
		o.maxw = BIG
		o.minh = max(o.min_rows, 1) * ICON_H + 2 * t.well
		o.maxh = BIG
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
