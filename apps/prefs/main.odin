/*
prefs -- the look's preferences, `docs/CHROME.md` section 9, as MUI drew them.

A page list on the left, and the page it names on the right. A page is a
framed group of the page's roles, each with the gadget for its type.

A colour is a
`Cycle` of the palette's names, with the value in use first. A number is a
`Knob`, its value beside it. A face is a `Cycle` of the files for its role
under `/lib/font`. An effect that is on or off is a `Checkmark`. The roles
come from `sys/libmui`'s `THEME_ROLES`, grouped by the `PAGES` table here,
and a role in no page goes on `Other`, so none is lost.

MUI's three keys run across the foot:

    Save     the changed roles into $home/lib/theme, and a reload
    Use      the changed roles into the draw server's `overlay`, for this
             session and no file
    Cancel   the overlay emptied, and every gadget back as it was

The `Scheme` page chooses a scheme. `Save` writes it as the file's `use`
line. `Use` puts the scheme's own lines into the overlay first, since the
overlay is role lines and not a `use`.

Keys, workspaces and servers are pages the study draws. Each is a file or a
reader of its own, and is not here yet.
*/
package prefs

import "base:runtime"

import "vsys:abi"
import "vsys:libmui"
import "vsys:libthread"
import "vsys:libuser"

ctx: runtime.Context
win: libmui.Window

// A page: its name, and the roles it groups. The server's own roles, the
// effects and the frame's style, are here too, since a line names them the
// same way.
Page :: struct {
	name:  string,
	roles: []string,
}

PAGES := [?]Page {
	{"Scheme", {}},
	{"Colours", {"face", "face.lit", "face.shade", "text", "hot", "link", "dim", "focus", "warn", "ok", "fault", "ground", "lcd.bg", "lcd.fg"}},
	{"Type", {"font.chrome", "font.interface", "font.readout", "font.namespace"}},
	{"Frame", {"bevel", "well", "pad", "gap", "hpad", "vpad", "frame.style"}},
	{"Effects", {"glow", "shadow", "lcd.ghost"}},
	{"Display", {}},
	{"Other", {}},
}

// The kinds of gadget a role takes, by what its value is.
Kind :: enum u8 {
	Colour,
	Number,
	Face,
	Toggle,
}

// A number role's range, which its knob turns through.
Range :: struct {
	role:   string,
	lo, hi: int,
}

RANGES := [?]Range {
	{"bevel", 0, 6}, {"well", 0, 6}, {"pad", 0, 16}, {"gap", 0, 16},
	{"hpad", 0, 24}, {"vpad", 0, 16}, {"lcd.ghost", 0, 40},
	{"glow", 0, 100}, {"shadow", 0, 100},
}

COLOUR_NAMES := [?]string {
	"copper", "copper_lit", "copper_dark", "magnesium", "magnesium_lit",
	"magnesium_dark", "amber", "amber_hot", "amber_dim", "cyan", "phosphor",
	"alert", "slate", "slate_deep", "void",
}

SCHEMES := [?]string{"chassis", "neon", "neon-hc", "daylight", "magnesium", "copper", "cyan", "phosphor"}

MAX_ROLES :: 48
MAX_CHOICES :: 20

// One role's row: the gadget, what it started at, and for a knob the label
// that says its value.
Row :: struct {
	role:    string,
	kind:    Kind,
	obj:     ^libmui.Object,
	number:  ^libmui.Object,
	orig:    int,
	choices: [MAX_CHOICES]string,
	nchoice: int,
	first:   [32]u8, // the value in use, the first choice
	numbuf:  [8]u8,
}

rows: [MAX_ROLES]Row
nrows: int
scheme: ^libmui.Object
scheme_orig: int

ID_SAVE :: 1
ID_USE :: 2
ID_CANCEL :: 3
ID_PAGES :: 4
ID_ROW :: 100

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	ctx = libuser.startup()
	context = ctx
	libthread.main(prefs_main, nil)
}

prefs_main :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = ctx
	libmui.theme_load()
	names: [len(PAGES)]string
	for p, i in PAGES {
		names[i] = p.name
	}
	pages := libmui.page_list(names[:])
	pages.id = ID_PAGES
	for p in PAGES {
		libmui.add(pages, build_page(p))
	}
	save := libmui.button("Save")
	save.id = ID_SAVE
	use := libmui.button("Use")
	use.id = ID_USE
	cancel := libmui.button("Cancel")
	cancel.id = ID_CANCEL
	keys := libmui.group(true)
	libmui.add(keys, save)
	libmui.add(keys, libmui.space())
	libmui.add(keys, use)
	libmui.add(keys, libmui.space())
	libmui.add(keys, cancel)
	col := libmui.group(false)
	libmui.add(col, pages)
	libmui.add(col, keys)
	win.handler = on_press
	win.want_w, win.want_h = 640, 660
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
build_page makes one page: a framed group titled with the page's name, a row
per role. `Scheme` is the scheme's cycle, `Display` the screen's mode, and
`Other` every role no other page names.
*/
build_page :: proc(p: Page) -> ^libmui.Object {
	g := libmui.titled(p.name, false)
	switch p.name {
	case "Scheme":
		row := libmui.group(true)
		libmui.add(row, libmui.text("scheme      "))
		scheme = libmui.cycle(SCHEMES[:])
		scheme.id = ID_ROW - 1
		scheme_orig = scheme_in_use()
		scheme.sel = scheme_orig
		libmui.add(row, scheme)
		libmui.add(row, libmui.space())
		libmui.add(g, row)
	case "Display":
		row := libmui.group(true)
		libmui.add(row, libmui.text("mode        "))
		libmui.add(row, libmui.readout(display_mode(), 9))
		libmui.add(row, libmui.space())
		libmui.add(g, row)
	case "Other":
		for role in libmui.THEME_ROLES {
			if !in_a_page(role) {
				add_row(g, role)
			}
		}
	case:
		for role in p.roles {
			add_row(g, role)
		}
	}
	libmui.add(g, libmui.space())
	return g
}

in_a_page :: proc "contextless" (role: string) -> bool {
	for p in PAGES {
		for r in p.roles {
			if r == role {
				return true
			}
		}
	}
	return false
}

// add_row makes a role's row: its name, and the gadget for its kind with the
// value in use.
add_row :: proc(g: ^libmui.Object, role: string) {
	if nrows >= MAX_ROLES {
		return
	}
	r := &rows[nrows]
	r.role = role
	t := libmui.ui_theme
	vb: [80]u8
	value := libmui.theme_value(&t, role, vb[:])
	row := libmui.group(true)
	label: [12]u8
	n := copy(label[:], role)
	for n < len(label) {
		label[n] = ' '
		n += 1
	}
	libmui.add(row, libmui.text(clone(string(label[:]))))
	lo, hi, ranged := range_of(role)
	switch {
	case role == "frame.style":
		r.kind = .Toggle
		r.obj = libmui.checkmark(false)
		r.orig = 0
		libmui.add(row, r.obj)
		libmui.add(row, libmui.text("metal"))
	case ranged:
		r.kind = .Number
		v := atoi(value)
		r.obj = libmui.knob(lo, hi, v)
		r.orig = r.obj.sel
		r.number = libmui.text(number(r, r.obj.sel))
		libmui.add(row, r.obj)
		libmui.add(row, r.number)
	case len(role) > 5 && role[:5] == "font.":
		r.kind = .Face
		r.nchoice = 0
		add_choice(r, value)
		face_choices(r, role[5:])
		r.obj = libmui.cycle(r.choices[:r.nchoice])
		r.orig = 0
		libmui.add(row, r.obj)
	case:
		r.kind = .Colour
		add_choice(r, value)
		for c in COLOUR_NAMES {
			add_choice(r, c)
		}
		r.obj = libmui.cycle(r.choices[:r.nchoice])
		r.orig = 0
		libmui.add(row, r.obj)
	}
	r.obj.id = ID_ROW + nrows
	libmui.add(row, libmui.space())
	libmui.add(g, row)
	nrows += 1
}

// add_choice adds a choice to a cycle's list, the value in use kept in the
// row's own buffer so it outlives the theme's.
add_choice :: proc "contextless" (r: ^Row, value: string) {
	if r.nchoice >= MAX_CHOICES || value == "" {
		return
	}
	if r.nchoice == 0 {
		n := copy(r.first[:], value)
		r.choices[0] = string(r.first[:n])
	} else {
		r.choices[r.nchoice] = value
	}
	r.nchoice += 1
}

// face_choices adds the faces under `/lib/font/<dir>`, each a path.
face_choices :: proc(r: ^Row, dir: string) {
	pb: [96]u8
	base := libuser.cat_into(pb[:], "/lib/font/", dir)
	fd := libuser.open(base, abi.O_RDONLY)
	if fd < 0 {
		return
	}
	names := libuser.list_dir(int(fd))
	_ = libuser.close(int(fd))
	for name in names {
		add_choice(r, libuser.join(base, name))
	}
}

range_of :: proc "contextless" (role: string) -> (lo: int, hi: int, ok: bool) {
	for rg in RANGES {
		if rg.role == role {
			return rg.lo, rg.hi, true
		}
	}
	return 0, 0, false
}

// number is a knob's value as its label says it.
number :: proc "contextless" (r: ^Row, v: int) -> string {
	return libuser.itoa(r.numbuf[:], i64(v))
}

// scheme_in_use is the scheme `$home/lib/theme` names with `use`, as an
// index into SCHEMES, or the chassis.
scheme_in_use :: proc() -> int {
	pb: [160]u8
	text, ok := libuser.read_file(libuser.cat_into(pb[:], libmui.theme_home(), "/lib/theme"), context.allocator)
	if !ok {
		return 0
	}
	defer delete(text)
	verb, rest := libmui.word(string(text))
	if verb != "use" {
		return 0
	}
	name, _ := libmui.word(rest)
	for i := len(name); i > 0; i -= 1 {
		if name[i - 1] == '\n' {
			name = name[:i - 1]
		}
	}
	for s, i in SCHEMES {
		if s == name {
			return i
		}
	}
	return 0
}

// display_mode is the screen's width and height, off `/dev/fbctl`.
display_mode :: proc "contextless" () -> string {
	@(static) mode: [32]u8
	report: [128]u8
	fd := libuser.open("/dev/fbctl", abi.O_RDONLY)
	if fd < 0 {
		return ""
	}
	n := libuser.read(int(fd), report[:])
	_ = libuser.close(int(fd))
	w, rest := libmui.word(string(report[:max(int(n), 0)]))
	h, _ := libmui.word(rest)
	return libuser.cat_into(mode[:], w, "x", h)
}

// -- The three keys ---------------------------------------------------------------

on_press :: proc "contextless" (w: ^libmui.Window, id: int) {
	context = ctx
	switch {
	case id == -1:
		w.done = true
	case id == ID_SAVE:
		save()
	case id == ID_USE:
		use()
	case id == ID_CANCEL:
		cancel()
	case id >= ID_ROW && id - ID_ROW < nrows:
		r := &rows[id - ID_ROW]
		if r.kind == .Number && r.number != nil {
			r.number.label = number(r, r.obj.sel)
			libmui.window_relayout(w)
		}
	}
}

/*
changed_lines writes a line per role whose gadget moved off the value it
opened with, `role value`, into `out`. With `with_scheme`, the chosen
scheme's own lines come first when it is not the one in use.
*/
changed_lines :: proc(out: []u8, with_scheme: bool) -> string {
	n := 0
	if with_scheme && scheme != nil && scheme.sel != scheme_orig && scheme.sel > 0 {
		pb: [96]u8
		if text, ok := libuser.read_file(libuser.cat_into(pb[:], "/lib/themes/", SCHEMES[scheme.sel]), context.allocator); ok {
			n += copy(out[n:], text)
			if n < len(out) {
				out[n] = '\n'
				n += 1
			}
			delete(text)
		}
	}
	for i in 0 ..< nrows {
		r := &rows[i]
		value := ""
		nb: [16]u8
		switch r.kind {
		case .Colour, .Face:
			if r.obj.sel == r.orig {
				continue
			}
			value = r.choices[r.obj.sel]
		case .Number:
			if r.obj.sel == r.orig {
				continue
			}
			value = libuser.itoa(nb[:], i64(r.obj.sel))
		case .Toggle:
			if int(r.obj.on ? 1 : 0) == r.orig {
				continue
			}
			value = r.obj.on ? "metal" : "flat"
		}
		n += copy(out[n:], r.role)
		n += copy(out[n:], " ")
		n += copy(out[n:], value)
		n += copy(out[n:], "\n")
	}
	return string(out[:n])
}

// overlay_write replaces the draw server's overlay. A blank line empties it.
overlay_write :: proc "contextless" (text: string) -> bool {
	pb: [160]u8
	fd := libuser.open(libuser.cat_into(pb[:], win.base, "/overlay"), abi.O_WRONLY)
	if fd < 0 {
		return false
	}
	body := text == "" ? "\n" : text
	ok := libuser.write(int(fd), transmute([]u8)body) == i64(len(body))
	_ = libuser.close(int(fd))
	return ok
}

// use puts the changed roles in the overlay: this session, no file.
use :: proc() {
	buf: [8192]u8
	_ = overlay_write(changed_lines(buf[:], true))
}

// cancel empties the overlay and puts every gadget back as it opened.
cancel :: proc() {
	_ = overlay_write("")
	for i in 0 ..< nrows {
		r := &rows[i]
		switch r.kind {
		case .Toggle:
			r.obj.on = r.orig != 0
		case .Colour, .Face, .Number:
			r.obj.sel = r.orig
			if r.number != nil {
				r.number.label = number(r, r.obj.sel)
			}
		}
	}
	if scheme != nil {
		scheme.sel = scheme_orig
	}
	libmui.window_relayout(&win)
}

/*
save writes `$home/lib/theme` again. A scheme other than the chassis is its
`use` line. The file's lines that name no changed role stay, and each
changed role gets a line. Then the overlay is emptied and every program reloads.
*/
save :: proc() {
	pb: [160]u8
	path := libuser.cat_into(pb[:], libmui.theme_home(), "/lib/theme")
	changed: [4096]u8
	lines := changed_lines(changed[:], false)
	out := make([dynamic]u8, 0, 4096)
	defer delete(out)
	if scheme != nil && scheme.sel > 0 {
		append(&out, "use ")
		append(&out, SCHEMES[scheme.sel])
		append(&out, "\n")
	}
	if text, ok := libuser.read_file(path, context.allocator); ok {
		defer delete(text)
		rest := string(text)
		for len(rest) > 0 {
			e := 0
			for e < len(rest) && rest[e] != '\n' {
				e += 1
			}
			line := rest[:e]
			rest = rest[min(e + 1, len(rest)):]
			role, _ := libmui.word(line)
			if role == "use" || names_role(lines, role) {
				continue
			}
			append(&out, line)
			append(&out, "\n")
		}
	}
	append(&out, lines)
	_ = libuser.mkdir(libuser.cat_into(pb[:], libmui.theme_home(), "/lib"))
	path = libuser.cat_into(pb[:], libmui.theme_home(), "/lib/theme")
	if fd := libuser.create(path, abi.O_WRONLY, 0o644); fd >= 0 {
		_ = libuser.write_full(int(fd), out[:])
		_ = libuser.close(int(fd))
	}
	_ = overlay_write("")
	cb: [160]u8
	if fd := libuser.open(libuser.cat_into(cb[:], win.base, "/ctl"), abi.O_WRONLY); fd >= 0 {
		_ = libuser.write(int(fd), transmute([]u8)string("reload"))
		_ = libuser.close(int(fd))
	}
	// What is in use now is what the gadgets show.
	for i in 0 ..< nrows {
		r := &rows[i]
		r.orig = r.kind == .Toggle ? int(r.obj.on ? 1 : 0) : r.obj.sel
	}
	if scheme != nil {
		scheme_orig = scheme.sel
	}
}

// names_role answers whether `lines` has a line for `role`.
names_role :: proc "contextless" (lines: string, role: string) -> bool {
	rest := lines
	for len(rest) > 0 {
		r, after := libmui.word(rest)
		if r == role {
			return true
		}
		e := 0
		for e < len(after) && after[e] != '\n' {
			e += 1
		}
		rest = after[min(e + 1, len(after)):]
	}
	return false
}

atoi :: proc "contextless" (s: string) -> int {
	v := 0
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			break
		}
		v = v * 10 + int(c - '0')
	}
	return v
}

clone :: proc(s: string) -> string {
	b := make([]u8, len(s))
	copy(b, s)
	return string(b)
}
