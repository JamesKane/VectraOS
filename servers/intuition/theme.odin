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
import "vsys:libpal"
import "vsys:libuser"

// The frame's colours, defaulting to the chassis constants `window_frame` and
// `frame_bar` carried before the look was a file. A theme file names a role to
// move it; one it does not name keeps the value set here.
th_plinth_lit := libpal.MAGNESIUM_HOT // the border's top-left highlight
th_plinth_shade := libpal.MAGNESIUM_DARK // its bottom-right shadow
th_bar := libpal.COPPER // the focused title bar's face
th_bar_lit := libpal.COPPER_LIT // its highlight edge
th_bar_shade := libpal.COPPER_DARK // its shadow edge

@(private = "file") home_buf: [THEME_MAX]u8
@(private = "file") base_buf: [THEME_MAX]u8

THEME_MAX :: 2048

/*
theme_reload reads `$home/lib/theme`, resolves a leading `use <name>` to its
base, reads the base, and applies both in order -- the base first so the
personal line wins. It resets the roles to the chassis constants before it
starts, so a role dropped from the files since last time goes back to default
rather than keeping the value a previous read left in the global.
*/
theme_reload :: proc "contextless" () #no_bounds_check {
	// Back to the chassis, then apply what the files say over it.
	th_plinth_lit = libpal.MAGNESIUM_HOT
	th_plinth_shade = libpal.MAGNESIUM_DARK
	th_bar = libpal.COPPER
	th_bar_lit = libpal.COPPER_LIT
	th_bar_shade = libpal.COPPER_DARK

	home := theme_read_home(home_buf[:])

	base_path := "/lib/theme"
	body := home
	if name, rest, ok := theme_use(home); ok {
		base_path = themes_path(name)
		body = rest
	}
	base := read_whole(base_path, base_buf[:])

	theme_apply_text(base_buf[:base])
	theme_apply_text(body)
}

/*
theme_rechrome re-reads the theme and repaints every live window's frame in the
new colours, the server's half of `Workbench > Theme...`'s "every window lays
itself out again". The gadgets inside are the client's to redraw, off the same
`reload`; this is the chassis around them. One full composite at the end brings
the restacked frames to the glass at once.
*/
theme_rechrome :: proc "contextless" () #no_bounds_check {
	theme_reload()
	for i in 0 ..< MAX_WINDOWS {
		if windows[i].used {
			window_chrome(&windows[i])
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
	}
}

// set_color reads a palette name or six hex digits into `dst`, and leaves it
// alone when the value is neither -- the chassis constant stands.
@(private = "file")
set_color :: proc "contextless" (dst: ^libpal.RGB, value: string) {
	if c, ok := libpal.by_name(value); ok {
		dst^ = c
		return
	}
	if c, ok := hex_rgb(value); ok {
		dst^ = c
	}
}

@(private = "file")
hex_rgb :: proc "contextless" (value: string) -> (libpal.RGB, bool) #no_bounds_check {
	if len(value) != 6 {
		return libpal.RGB{}, false
	}
	out: libpal.RGB
	for i in 0 ..< 3 {
		hi, ok0 := hex_digit(value[i * 2])
		lo, ok1 := hex_digit(value[i * 2 + 1])
		if !ok0 || !ok1 {
			return libpal.RGB{}, false
		}
		out[i] = hi << 4 | lo
	}
	return out, true
}

@(private = "file")
hex_digit :: proc "contextless" (c: u8) -> (u8, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
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
