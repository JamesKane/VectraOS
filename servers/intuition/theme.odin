/*
theme -- the frame's look, read from files, `docs/WORKBENCH.md` section 5. The
look is data, and `intuition` reads the same two files the workbench does, for
its own half of the desktop: the chassis it draws around every window. The
gadgets inside a window are `sys/libmui`'s to colour; the border and the copper
bar are this server's.

`/lib/theme` is the shipped chassis and `$home/lib/theme` the person's, the
later line for a role winning. The personal file may open with `use <name>`,
which reads `/lib/themes/<name>` in place of `/lib/theme` and merges the rest
over it -- exactly the rule `apps/workbench`'s own reader follows, so the two
halves never disagree about which file is the base.

The roles here are the ones a frame is made of. A role named nowhere keeps the
chassis value, which is the hardcoded constant it had before there were theme
files -- so a bare system, or one whose files name none of these, draws the
frame it always did. `theme_reload` re-reads on the `reload` ctl word, the same
word `Workbench > Theme...` sends after it writes a new `use` line.
*/
package intuition

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libpal"
import "vsys:libuser"

// The chassis defaults: the frame's colours `window_frame` and `frame_bar`
// carried before the look was a file. Named once, so the global initialisers
// and `theme_reload`'s reset cannot drift into disagreeing about what "the
// chassis" is.
CHASSIS_PLINTH_LIT :: libpal.MAGNESIUM_HOT // the border's top-left highlight
CHASSIS_PLINTH_SHADE :: libpal.MAGNESIUM_DARK // its bottom-right shadow
CHASSIS_BAR :: libpal.COPPER // the focused title bar's face
CHASSIS_BAR_LIT :: libpal.COPPER_LIT // its highlight edge
CHASSIS_BAR_SHADE :: libpal.COPPER_DARK // its shadow edge

// The frame's colours now. A theme file names a role to move it; one it does
// not name keeps the chassis default.
th_plinth_lit := CHASSIS_PLINTH_LIT
th_plinth_shade := CHASSIS_PLINTH_SHADE
th_bar := CHASSIS_BAR
th_bar_lit := CHASSIS_BAR_LIT
th_bar_shade := CHASSIS_BAR_SHADE

// The frame's three numbers, `frame.edge`, `frame.title` and `frame.well`.
// A theme that names none draws the chassis's, `FRAME_EDGE` and the rest.
th_frame_edge := FRAME_EDGE
th_frame_title := FRAME_TITLE
th_frame_well := FRAME_WELL

/*
The desktop's ground, by name, `docs/WORKBENCH.md` step 5. The theme file
names a ground once and picks one:

    desk grid   grid  slate_deep void 32    # pattern, ground, line, step
    desk plain  plain slate_deep
    desk dots   dots  slate_deep slate 16
    desk.ground grid

A new ground is then a theme edit and not code. A `desk.ground` naming
nothing defined, or none at all, is the chassis grid.
*/
Desk_Kind :: enum u8 {
	Grid,
	Plain,
	Dots,
}

Desk_Def :: struct {
	name:   [16]u8,
	n:      int,
	kind:   Desk_Kind,
	ground: u32,
	line:   u32,
	step:   int,
}

MAX_DESKS :: 8
desk_defs: [MAX_DESKS]Desk_Def
ndesk_defs: int
desk_pick: [16]u8
desk_pick_n: int

desk_kind := Desk_Kind.Grid
desk_ground := DESK_GROUND
desk_line := DESK_GRID
desk_step := DESK_STEP

// How long a window asked to close has before the desktop offers `Kill`,
// the theme's `closegrace` in seconds. See `window_close_request`.
CLOSE_GRACE_MS :: u64(5000)
th_closegrace_ms := CLOSE_GRACE_MS

@(private = "file") home_buf: [THEME_MAX]u8
@(private = "file") base_buf: [THEME_MAX]u8

// Over the shipped `/lib/theme`, the largest file either buffer holds, with
// room for a scheme's `colour` lines. It was 1024 until the shipped file
// passed it and its last lines, the desk's pick among them, went unread.
THEME_MAX :: 4096

/*
theme_reload reads `$home/lib/theme`, resolves a leading `use <name>` to its
base, reads the base, and applies both in order -- the base first so the
personal line wins. It resets the roles to the chassis constants before it
starts, so a role dropped from the files since last time goes back to default
rather than keeping the value a previous read left in the global.
*/
theme_reload :: proc "contextless" () #no_bounds_check {
	// Back to the chassis, then apply what the files say over it.
	th_plinth_lit = CHASSIS_PLINTH_LIT
	th_plinth_shade = CHASSIS_PLINTH_SHADE
	th_bar = CHASSIS_BAR
	th_bar_lit = CHASSIS_BAR_LIT
	th_bar_shade = CHASSIS_BAR_SHADE
	th_frame_edge, th_frame_title, th_frame_well = FRAME_EDGE, FRAME_TITLE, FRAME_WELL
	th_closegrace_ms = CLOSE_GRACE_MS
	ndesk_defs = 0
	desk_pick_n = 0

	home := theme_read_home(home_buf[:])

	base_path := "/lib/theme"
	body := home
	if name, rest, ok := theme_use(home); ok {
		base_path = themes_path(name)
		body = rest
	}
	base := read_whole(base_path, base_buf[:])

	// The `colour` lines of both files first, so a frame role may name a
	// colour a scheme defines, `docs/CHROME.md` section 3.
	th_colours = {}
	theme_colour_text(base_buf[:base])
	theme_colour_text(body)
	theme_apply_text(base_buf[:base])
	theme_apply_text(body)
	desk_resolve()
}

// desk_resolve makes the ground `desk.ground` names the one `desk_paint`
// lays, or the chassis grid.
desk_resolve :: proc "contextless" () #no_bounds_check {
	desk_kind, desk_ground, desk_line, desk_step = .Grid, DESK_GROUND, DESK_GRID, DESK_STEP
	for i in 0 ..< ndesk_defs {
		d := &desk_defs[i]
		if string(d.name[:d.n]) == string(desk_pick[:desk_pick_n]) {
			desk_kind, desk_ground, desk_line, desk_step = d.kind, d.ground, d.line, d.step
			return
		}
	}
}

// pack is a palette colour as the glass's word.
@(private = "file")
pack :: proc "contextless" (c: libpal.RGB) -> u32 {
	return u32(c[0]) << 16 | u32(c[1]) << 8 | u32(c[2])
}

// desk_define takes a `desk NAME PATTERN GROUND [LINE] [STEP]` line.
@(private = "file")
desk_define :: proc "contextless" (rest: []u8) #no_bounds_check {
	if ndesk_defs >= MAX_DESKS {
		return
	}
	name, r1 := word(rest)
	kind, r2 := word(r1)
	gw, r3 := word(r2)
	lw, r4 := word(r3)
	sw, _ := word(r4)
	d := Desk_Def{step = DESK_STEP, line = DESK_GRID}
	switch string(kind) {
	case "grid":
		d.kind = .Grid
	case "plain":
		d.kind = .Plain
	case "dots":
		d.kind = .Dots
	case:
		return
	}
	g, gok := libpal.parse_color(string(gw))
	if len(name) == 0 || len(name) > len(d.name) || !gok {
		return
	}
	d.ground = pack(g)
	if l, lok := libpal.parse_color(string(lw)); lok {
		d.line = pack(l)
	}
	if st, sok := libdraw.scan_int_str(sw); sok && st >= 2 && st <= 256 {
		d.step = st
	}
	d.n = copy(d.name[:], name)
	desk_defs[ndesk_defs] = d
	ndesk_defs += 1
}

/*
theme_rechrome re-reads the theme and repaints every live window's frame in the
new colours, the server's half of `Workbench > Theme...`'s "every window lays
itself out again". The gadgets inside are the client's to redraw, off the same
`reload`; this is the chassis around them. One full composite at the end brings
the restacked frames to the glass at once.
*/
theme_rechrome :: proc "contextless" () #no_bounds_check {
	ox, oy := inset_x(), inset_y()
	theme_reload()
	// A frame of another size moves every framed window's client area. Each
	// keeps its area's size and its pixels, and the window grows or shrinks
	// around it, so a client that draws nothing new still shows what it drew.
	if ox != inset_x() || oy != inset_y() {
		for i in 0 ..< MAX_WINDOWS {
			if windows[i].used {
				window_reframe(&windows[i], ox, oy)
			}
		}
	}
	// The ground may have changed: lay it again under every window.
	desk_paint(0, 0, scr_w, scr_h)
	for i in 0 ..< MAX_WINDOWS {
		if windows[i].used {
			// The frame alone: a client that paints its store may have
			// painted its new look already, and the well's face is its.
			window_chrome(&windows[i], keep_client = true)
		}
	}
	repaint(0, 0, scr_w, scr_h)
}

// theme_apply_text reads each `role value` line for a frame role into the
// globals. A line naming a role this half does not draw -- a gadget role, a
// metric -- is skipped, left to `sys/libmui`'s own reader.
@(private = "file")
theme_apply_text :: proc "contextless" (text: []u8) #no_bounds_check {
	rest := text
	for len(rest) > 0 {
		line: []u8
		line, rest = theme_line(rest)
		theme_apply_line(line)
	}
}

@(private = "file")
theme_apply_line :: proc "contextless" (line: []u8) #no_bounds_check {
	// Cut a trailing comment.
	body := line
	for k in 0 ..< len(body) {
		if body[k] == '#' {
			body = body[:k]
			break
		}
	}
	role, after := word(body)
	if len(role) == 0 {
		return
	}
	value, _ := word(after)
	if len(value) == 0 {
		return
	}
	switch string(role) {
	case "bar":
		set_color(&th_bar, string(value))
	case "bar.lit":
		set_color(&th_bar_lit, string(value))
	case "bar.shade":
		set_color(&th_bar_shade, string(value))
	case "plinth.lit":
		set_color(&th_plinth_lit, string(value))
	case "plinth.shade":
		set_color(&th_plinth_shade, string(value))
	case "desk":
		desk_define(after)
	case "desk.ground":
		desk_pick_n = copy(desk_pick[:], value)
	case "frame.edge":
		set_metric(&th_frame_edge, value, 1, libdraw.MAX_DEPTH)
	case "frame.title":
		set_metric(&th_frame_title, value, FRAME_TITLE_MIN, FRAME_TITLE_MAX)
	case "frame.well":
		set_metric(&th_frame_well, value, 1, libdraw.MAX_DEPTH)
	case "closegrace":
		if secs, ok := libdraw.scan_int_str(value); ok && secs >= 0 && secs <= 600 {
			th_closegrace_ms = u64(secs) * 1000
		}
	}
}

// set_metric reads a number into `dst` when it is inside `lo..hi`, and leaves
// the chassis value when it is not.
@(private = "file")
set_metric :: proc "contextless" (dst: ^int, value: []u8, lo: int, hi: int) {
	if v, ok := libdraw.scan_int_str(value); ok && v >= lo && v <= hi {
		dst^ = v
	}
}

// set_color reads a palette name or six hex digits into `dst`, and leaves it
// alone when the value is neither -- the chassis constant stands. The grammar
// is `libpal.parse_color`'s, shared with `sys/libmui`'s reader for the gadgets.
@(private = "file")
set_color :: proc "contextless" (dst: ^libpal.RGB, value: string) {
	if c, ok := libpal.colours_parse(&th_colours, value); ok {
		dst^ = c
	}
}

// The colours the theme files define, which a frame role may name.
@(private = "file")
th_colours: libpal.Colours

// theme_colour_text reads every `colour NAME VALUE` line of a file into
// `th_colours`, the rule `sys/libmui`'s `colour_lines` follows for the
// gadgets. A scoped line is a program's own and not the frame's.
@(private = "file")
theme_colour_text :: proc "contextless" (text: []u8) #no_bounds_check {
	rest := text
	for len(rest) > 0 {
		line: []u8
		line, rest = theme_line(rest)
		for k in 0 ..< len(line) {
			if line[k] == '#' {
				line = line[:k]
				break
			}
		}
		kw, after := word(line)
		if string(kw) != "colour" {
			continue
		}
		name, r2 := word(after)
		value, _ := word(r2)
		_ = libpal.colours_define(&th_colours, string(name), string(value))
	}
}

// theme_line takes one line off `text`, and what follows it.
@(private = "file")
theme_line :: proc "contextless" (text: []u8) -> (line: []u8, rest: []u8) #no_bounds_check {
	e := 0
	for e < len(text) && text[e] != '\n' {e += 1}
	next := e < len(text) ? e + 1 : e
	return text[:e], text[next:]
}

// theme_use reads a leading `use <name>` line: the base name and the rest of
// the file after it. False when the first line is not `use <name>`.
@(private = "file")
theme_use :: proc "contextless" (text: []u8) -> (name: string, rest: []u8, ok: bool) #no_bounds_check {
	line, after := theme_line(text)
	verb, tail := word(line)
	if string(verb) != "use" {
		return "", text, false
	}
	nm, _ := word(tail)
	if len(nm) == 0 {
		return "", text, false
	}
	return string(nm), after, true
}

// theme_read_home reads `$home/lib/theme` into `buf`, or nothing. Unlike
// `read_user_file` it does not fall back to `/lib`, because the base is chosen
// separately: the personal file alone decides whether a `use` line redirects
// it.
@(private = "file")
theme_read_home :: proc "contextless" (buf: []u8) -> []u8 #no_bounds_check {
	path: [128]u8
	home: [64]u8
	hn := 0
	if fd := libuser.open("/env/home", abi.O_RDONLY); fd >= 0 {
		if got := libuser.read(int(fd), home[:]); got > 0 {
			hn = int(got)
		}
		_ = libuser.close(int(fd))
	}
	if hn == 0 {
		return buf[:0]
	}
	at := copy(path[:], home[:hn])
	at += copy(path[at:], "/lib/theme")
	n := read_whole(string(path[:at]), buf)
	return buf[:n]
}

// themes_path is `/lib/themes/<name>`.
@(private = "file")
themes_path :: proc "contextless" (name: string) -> string {
	@(static) buf: [128]u8
	at := copy(buf[:], "/lib/themes/")
	at += copy(buf[at:], name)
	return string(buf[:at])
}
