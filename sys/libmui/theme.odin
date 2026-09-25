/*
theme -- the look as data, a file of roles read into a `Theme`.

`docs/WORKBENCH.md` section 5 makes the look a file. A line names a role and
what it is. A metric is a number, and a colour is one of `sys/libpal`'s names
or six hex digits. `parse_theme` reads the text over a copy of `default_theme`. A
file that names nothing is the chassis, and one that names a role changes that
role alone. A `#` starts a comment, and blank lines are skipped, the way
`servers/intuition`'s own rules file reads.

    face        copper          # a raised control, now copper
    ground      slate_deep
    bevel       3

The toolkit and `intuition` read the same file, so a window's frame and the
gadgets inside it are one look. This parser is the toolkit's half. It touches
no file itself: a caller reads the bytes and hands them here, which keeps the
parser testable with a string and no disk.
*/
package libmui

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libodin"
import "vsys:libpal"
import "vsys:libthread"
import "vsys:libuser"

/*
ui_theme is the look every window takes unless it sets its own: the current
theme. It starts at the chassis, `default_theme`, and a program that reads a
theme file sets it with `set_theme`, so a window opened after wears it. A live
window keeps the theme it was opened with until its program lays it out again
with the new one -- `docs/WORKBENCH.md` section 5's "every window lays itself
out again". `default_theme` stays the constant the chassis is, for a reset.
*/
ui_theme := default_theme

// set_theme makes `t` the look new windows take. Apply it to windows already
// open by setting each one's `theme` and laying it out again.
set_theme :: proc "contextless" (t: Theme) {
	ui_theme = t
}

/*
parse_theme fills `t` from the lines in `text`. It starts `t` at the default,
so every role the text leaves out keeps the chassis value. An unknown role or
an unreadable value is skipped rather than an error. A newer theme file that
names a role this build does not know still loads.
*/
parse_theme :: proc "contextless" (t: ^Theme, text: string) #no_bounds_check {
	t^ = default_theme
	theme_colours = {}
	// Three passes. The `colour` lines first, so a role may name a colour
	// defined anywhere in the files. Then the unscoped lines, then the lines
	// scoped to this program, `muidemo/face copper`, so a scoped line wins
	// whatever its order. A line scoped to another program is not this one's.
	app := app_name()
	colour_lines(&theme_colours, text)
	for pass in 0 ..< 2 {
		i := 0
		for i < len(text) {
			start := i
			for i < len(text) && text[i] != '\n' {
				i += 1
			}
			line := text[start:i]
			if i < len(text) {
				i += 1 // Step over the newline.
			}
			scope, rest, scoped := line_scope(line)
			if pass == 0 && !scoped {
				apply_line(t, line)
			} else if pass == 1 && scoped && scope == app && app != "" {
				apply_line(t, rest)
			}
		}
	}
}

/*
line_scope splits a scoped line, `muidemo/face copper`, into its scope and
the line it scopes. A role's own dots are not a scope, and a `/` after the
role's first word is part of the value.
*/
line_scope :: proc "contextless" (line: string) -> (scope: string, rest: string, scoped: bool) #no_bounds_check {
	i := 0
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		i += 1
	}
	start := i
	for i < len(line) && line[i] != ' ' && line[i] != '\t' {
		if line[i] == '/' {
			return line[start:i], line[i + 1:], true
		}
		i += 1
	}
	return "", line, false
}

// apply_line reads one `role value` line into `t`. A comment or a blank line
// leaves `t` untouched.
apply_line :: proc "contextless" (t: ^Theme, line: string) {
	// Cut a trailing comment.
	body := line
	for k in 0 ..< len(body) {
		if body[k] == '#' {
			body = body[:k]
			break
		}
	}
	role, rest := word(body)
	if role == "" {
		return
	}
	value, _ := word(rest)
	if value == "" {
		return
	}

	// A colour role takes a palette name or six hex digits. A metric role
	// takes a number. A job role, `docs/CHROME.md` section 3, is another
	// name for the role it sets: `role_name` says which.
	switch role_name(role) {
	case "ground":
		set_color(&t.ground, value)
	case "face":
		set_color(&t.face, value)
	case "face.lit":
		set_color(&t.lit, value)
	case "face.shade":
		set_color(&t.shade, value)
	case "text":
		set_color(&t.ink, value)
	case "bevel":
		set_metric(&t.bevel, value)
	case "well":
		set_metric(&t.well, value)
	case "pad":
		set_metric(&t.pad, value)
	case "gap":
		set_metric(&t.gap, value)
	case "hpad":
		set_metric(&t.hpad, value)
	case "vpad":
		set_metric(&t.vpad, value)
	case "hot":
		set_color(&t.hot, value)
	case "link":
		set_color(&t.link, value)
	case "dim":
		set_color(&t.dim, value)
	case "focus":
		set_color(&t.focus, value)
	case "warn":
		set_color(&t.warn, value)
	case "ok":
		set_color(&t.ok, value)
	case "fault":
		set_color(&t.fault, value)
	case "bar":
		set_color(&t.metal_hi, value)
	case "bar.shade":
		set_color(&t.metal_lo, value)
	case "lcd.bg":
		set_color(&t.lcd_bg, value)
	case "lcd.fg":
		set_color(&t.lcd_fg, value)
	case "lcd.ghost":
		set_metric(&t.lcd_ghost, value)
	case "font.chrome":
		set_face(&t.faces[.Chrome], value, rest)
	case "font.interface":
		set_face(&t.faces[.Interface], value, rest)
	case "font.readout":
		set_face(&t.faces[.Readout], value, rest)
	case "font.namespace":
		set_face(&t.faces[.Namespace], value, rest)
	case "icons":
		if len(value) <= FACE_PATH {
			t.icons_n = copy(t.icons[:], value)
		}
	}
	// A role this build does not know is skipped here. `font` and `pointer`
	// are left for the half of the toolkit that reads them.
}

// set_color reads a palette name or six hex digits into `dst`, and leaves it
// alone if it can read neither. The grammar is `libpal.parse_color`'s, shared
// with the server that themes the frame.
set_color :: proc "contextless" (dst: ^libpal.RGB, value: string) {
	if c, ok := libpal.colours_parse(&theme_colours, value); ok {
		dst^ = c
	}
}

/*
set_face reads a face role's line: the `.face` file, then `track N` for the
pixels between letters and `caps` for a role set in capitals, in either order.
A path too long for the spec leaves the role as it was.
*/
set_face :: proc "contextless" (dst: ^Face_Spec, path: string, rest: string) {
	if len(path) == 0 || len(path) > FACE_PATH {
		return
	}
	spec := Face_Spec{}
	spec.n = copy(spec.path[:], path)
	_, more := word(rest)
	for {
		w: string
		w, more = word(more)
		if w == "" {
			break
		}
		switch w {
		case "caps":
			spec.caps = true
		case "track":
			n: string
			n, more = word(more)
			v := 0
			for k in 0 ..< len(n) {
				if n[k] < '0' || n[k] > '9' {
					break
				}
				v = v * 10 + int(n[k] - '0')
			}
			spec.track = min(v, 8)
		}
	}
	dst^ = spec
}

// The colours the files being read define, `colour NAME VALUE`. Emptied at
// the start of every parse.
@(private = "file")
theme_colours: libpal.Colours

// theme_colour is a colour by name as the last theme read defines it, or the
// palette's, or six hex digits. An icon names its colours this way.
theme_colour :: proc "contextless" (name: string) -> (libpal.RGB, bool) {
	return libpal.colours_parse(&theme_colours, name)
}

/*
colour_lines reads every unscoped `colour NAME VALUE` line in `text` into `t`,
in order, so a later line wins and a colour may be named in terms of one
defined above it. `servers/intuition` reads the frame's roles with the same
procedure, so the two halves of the look agree on every name.
*/
colour_lines :: proc "contextless" (t: ^libpal.Colours, text: string) #no_bounds_check {
	i := 0
	for i < len(text) {
		start := i
		for i < len(text) && text[i] != '\n' {
			i += 1
		}
		line := text[start:i]
		if i < len(text) {
			i += 1
		}
		for k in 0 ..< len(line) {
			if line[k] == '#' {
				line = line[:k]
				break
			}
		}
		kw, rest := word(line)
		if kw != "colour" {
			continue
		}
		name, after := word(rest)
		value, _ := word(after)
		_ = libpal.colours_define(t, name, value)
	}
}

/*
role_name is the role a name in the file sets. The job roles of
`docs/CHROME.md` section 3 are other names for the roles the toolkit has
always had: `panel` is a window's `ground`, `raised` is a control's `face`,
and `accent` is `hot`. The rest are their own names.
*/
role_name :: proc "contextless" (role: string) -> string {
	switch role {
	case "panel":
		return "ground"
	case "raised":
		return "face"
	case "raised.lit":
		return "face.lit"
	case "raised.shade":
		return "face.shade"
	case "accent":
		return "hot"
	}
	return role
}

// set_metric reads a non-negative number into `dst`, and leaves it alone on
// anything else.
set_metric :: proc "contextless" (dst: ^int, value: string) {
	n := 0
	for k in 0 ..< len(value) {
		c := value[k]
		if c < '0' || c > '9' {
			return
		}
		n = n * 10 + int(c - '0')
	}
	if len(value) > 0 {
		dst^ = n
	}
}

// word returns the first run of non-space characters in `s` and the rest of
// `s` after it, skipping the spaces and tabs on either side.
word :: proc "contextless" (s: string) -> (first: string, rest: string) {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r') {
		i += 1
	}
	start := i
	for i < len(s) && s[i] != ' ' && s[i] != '\t' && s[i] != '\r' {
		i += 1
	}
	return s[start:i], s[i:]
}

// -- The files, and following them -------------------------------------------

/*
The look is read here, once, for every program on the toolkit: `/lib/theme`
is the shipped one, `$home/lib/theme` the person's, and the later line for a
role wins. The personal file may start with `use <name>`, which reads
`/lib/themes/<name>` in place of `/lib/theme` and merges the rest over it.
The draw server's `overlay` comes last: lines a session's `Use` wrote, kept
in the server's memory and in no file, `docs/CHROME.md` section 9.
`window_open` loads it the first time, so a window opens in the person's
theme and not the chassis. `apps/workbench` used to be the only program that
read these files; the reading moved here so none has to.

A change follows. `intuition` serves a generation number, `theme` beside its
`ctl`, which a `reload` bumps, and a read at offset N answers once the number
passes N. The first window a program opens starts `theme_watch`, which waits
there and, on a change, reads the files again and lays out every window of
this program that follows the shared theme. No state is lost, because the
tree holds no look: a theme change takes the path a resize takes.
*/
THEME_MAX :: 4096

theme_loaded: bool
@(private = "file") theme_home_buf: [THEME_MAX]u8
@(private = "file") theme_base_buf: [THEME_MAX]u8
@(private = "file") theme_merge_buf: [3 * THEME_MAX]u8
@(private = "file") theme_over_buf: [THEME_MAX]u8
@(private = "file") overlay_base_buf: [128]u8
@(private = "file") overlay_base_n: int

// theme_base_set names the draw server's mount, where its `overlay` is read:
// the first window's, for every read after.
theme_base_set :: proc "contextless" (base: string) {
	if overlay_base_n == 0 {
		overlay_base_n = copy(overlay_base_buf[:], base)
	}
}

@(private = "file") theme_path_buf: [256]u8
@(private = "file") theme_env_buf: [128]u8

// theme_load reads the two files and the draw server's overlay, merges them in
// that order, and makes the result the look new windows take. It lays no
// open window out. `theme_watch` does that.
theme_load :: proc "contextless" () #no_bounds_check {
	home := theme_read(theme_home_path(), theme_home_buf[:])
	base_path := "/lib/theme"
	body := home
	if name, rest, ok := theme_use(home); ok {
		base_path = theme_themes_path(name)
		body = rest
	}
	base := theme_read(base_path, theme_base_buf[:])
	w := copy(theme_merge_buf[:], base)
	if w < len(theme_merge_buf) {
		theme_merge_buf[w] = '\n'
		w += 1
	}
	w += copy(theme_merge_buf[w:], body)
	// The draw server's overlay last: a session's `Use`, over both files.
	if overlay_base_n > 0 {
		pb: [160]u8
		over := theme_read(libuser.cat_into(pb[:], string(overlay_base_buf[:overlay_base_n]), "/overlay"), theme_over_buf[:])
		if len(over) > 0 && w < len(theme_merge_buf) {
			theme_merge_buf[w] = '\n'
			w += 1
			w += copy(theme_merge_buf[w:], over)
		}
	}
	t: Theme
	parse_theme(&t, string(theme_merge_buf[:w]))
	set_theme(t)
	theme_loaded = true
}

// theme_home is `$home`, or `/usr/glenda` when the environment names none.
theme_home :: proc "contextless" () -> string {
	home := libuser.getenv("home", theme_env_buf[:])
	for len(home) > 0 && (home[len(home) - 1] == '\n' || home[len(home) - 1] == 0) {
		home = home[:len(home) - 1]
	}
	return home != "" ? home : "/usr/glenda"
}

// theme_home_path is `$home/lib/theme`.
theme_home_path :: proc "contextless" () -> string {
	return libuser.cat_into(theme_path_buf[:], theme_home(), "/lib/theme")
}

// theme_themes_path is `/lib/themes/<name>`.
theme_themes_path :: proc "contextless" (name: string) -> string {
	return libuser.cat_into(theme_path_buf[:], "/lib/themes/", name)
}

// theme_read reads a whole file into `buf`, or answers nothing when it will
// not open.
theme_read :: proc "contextless" (path: string, buf: []u8) -> []u8 {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return buf[:0]
	}
	n := libuser.read(int(fd), buf)
	_ = libuser.close(int(fd))
	return buf[:max(int(n), 0)]
}

// theme_use reads a leading `use <name>` line: the base's name and the rest of
// the file after that line. False when the first line is not `use`.
theme_use :: proc "contextless" (text: []u8) -> (name: string, rest: []u8, ok: bool) #no_bounds_check {
	e := 0
	for e < len(text) && text[e] != '\n' {
		e += 1
	}
	next := e < len(text) ? e + 1 : e
	verb, after := word(string(text[:e]))
	if verb != "use" {
		return "", text, false
	}
	nm, _ := word(after)
	if nm == "" {
		return "", text, false
	}
	return nm, text[next:], true
}

// The windows of this program that follow the shared theme, so a change can
// lay each out again. A window leaves when it is done.
MAX_FOLLOWERS :: 32

@(private = "file") followers: [MAX_FOLLOWERS]^Window
@(private = "file") watching: bool

theme_follow :: proc "contextless" (win: ^Window) {
	for i in 0 ..< MAX_FOLLOWERS {
		if followers[i] == win {
			return
		}
	}
	for i in 0 ..< MAX_FOLLOWERS {
		if followers[i] == nil {
			followers[i] = win
			break
		}
	}
	if !watching {
		watching = true
		n := copy(watch_base[:], win.base)
		watch_base_n = n
		if libthread.threadcreate(theme_watch, nil) < 0 {
			watching = false
		}
	}
}

theme_unfollow :: proc "contextless" (win: ^Window) {
	for i in 0 ..< MAX_FOLLOWERS {
		if followers[i] == win {
			followers[i] = nil
		}
	}
}

@(private = "file") watch_base: [128]u8
@(private = "file") watch_base_n: int

/*
theme_watch parks on the draw server's `theme` through an io proc of its own,
and on each new generation reads the files again and lays out every window
that follows. The first read answers at once, with the generation the
program opened under, and changes nothing. A read that ends is a server
without the file, or gone, and the thread leaves.
*/
@(private = "file")
theme_watch :: proc "contextless" (arg: rawptr) #no_bounds_check {
	_ = arg
	io := libthread.ioproc()
	if io == nil {
		watching = false
		return
	}
	pb: [160]u8
	fd := libuser.open(libuser.cat_into(pb[:], string(watch_base[:watch_base_n]), "/theme"), abi.O_RDONLY)
	if fd < 0 {
		libthread.ioclose(io)
		watching = false
		return
	}
	gen: u64 = 0
	buf: [32]u8
	for {
		n := libthread.iopread(io, int(fd), buf[:], gen)
		if n <= 0 {
			break
		}
		at := 0
		now, ok := libdraw.scan_u64(buf[:int(n)], &at)
		if !ok || now <= gen {
			continue
		}
		// The first answer loads too. The files were read when the first
		// window opened, before this watcher's first read, and a `reload`
		// between the two moved the number past a look nobody loaded: the
		// baseline would have swallowed it. One read of the files more, once.
		theme_load()
		for i in 0 ..< MAX_FOLLOWERS {
			w := followers[i]
			if w == nil || w.done {
				continue
			}
			w.theme = ui_theme
			window_relayout(w)
		}
		gen = now
	}
	_ = libuser.close(int(fd))
	libthread.ioclose(io)
	watching = false
}

// -- Asking which line set a value -------------------------------------------

/*
THEME_ROLES is every role the parser knows, in the file's order. A program
that shows the theme walks this, so it stays right when a role is added.
*/
THEME_ROLES := [?]string{
	"ground", "face", "face.lit", "face.shade", "text", "hot", "link", "dim",
	"focus", "warn", "ok", "fault",
	"lcd.bg", "lcd.fg", "lcd.ghost",
	"font.chrome", "font.interface", "font.readout", "font.namespace", "icons",
	"bevel", "well", "pad", "gap", "hpad", "vpad",
}

// theme_value writes a role's value in `t` as the file would: six hex digits
// for a colour, a number for a metric.
theme_value :: proc "contextless" (t: ^Theme, role: string, out: []u8) -> string #no_bounds_check {
	rgb := proc "contextless" (c: libpal.RGB, out: []u8) -> string {
		hex := "0123456789abcdef"
		for k in 0 ..< 3 {
			out[2 * k] = hex[c[k] >> 4]
			out[2 * k + 1] = hex[c[k] & 15]
		}
		return string(out[:6])
	}
	switch role_name(role) {
	case "ground":
		return rgb(t.ground, out)
	case "face":
		return rgb(t.face, out)
	case "face.lit":
		return rgb(t.lit, out)
	case "face.shade":
		return rgb(t.shade, out)
	case "text":
		return rgb(t.ink, out)
	case "hot":
		return rgb(t.hot, out)
	case "link":
		return rgb(t.link, out)
	case "dim":
		return rgb(t.dim, out)
	case "focus":
		return rgb(t.focus, out)
	case "warn":
		return rgb(t.warn, out)
	case "ok":
		return rgb(t.ok, out)
	case "fault":
		return rgb(t.fault, out)
	case "font.chrome", "font.interface", "font.readout", "font.namespace":
		for name, r in FACE_ROLES {
			if name == role {
				f := &t.faces[r]
				return string(out[:copy(out, f.path[:f.n])])
			}
		}
	case "lcd.bg":
		return rgb(t.lcd_bg, out)
	case "lcd.fg":
		return rgb(t.lcd_fg, out)
	case "lcd.ghost":
		return libuser.itoa(out, i64(t.lcd_ghost))
	case "icons":
		return string(out[:copy(out, t.icons[:t.icons_n])])
	case "bevel":
		return libuser.itoa(out, i64(t.bevel))
	case "well":
		return libuser.itoa(out, i64(t.well))
	case "pad":
		return libuser.itoa(out, i64(t.pad))
	case "gap":
		return libuser.itoa(out, i64(t.gap))
	case "hpad":
		return libuser.itoa(out, i64(t.hpad))
	case "vpad":
		return libuser.itoa(out, i64(t.vpad))
	}
	return ""
}

/*
theme_explain says which line set a role and which it beat: every line that
names it, in the two files in the order the parser reads them, the one that
wins marked. A line scoped to this program beats every unscoped line, and a
later line beats an earlier one of the same kind. A line scoped to another
program is shown and marked as that program's. A role named nowhere is the
chassis. The answer is text, a line an entry, into `out`.

    face copper    /usr/glenda/lib/theme:2   wins
    face magnesium /lib/theme:6              beaten
*/
theme_explain :: proc "contextless" (role: string, out: []u8) -> int #no_bounds_check {
	home := theme_read(theme_home_path(), theme_home_buf[:])
	home_path_buf: [256]u8
	home_path := libuser.cat_into(home_path_buf[:], theme_home(), "/lib/theme")
	base_path_buf: [256]u8
	base_path := libuser.cat_into(base_path_buf[:], "/lib/theme")
	body := home
	skipped := 0
	if name, rest, ok := theme_use(home); ok {
		base_path = libuser.cat_into(base_path_buf[:], "/lib/themes/", name)
		body = rest
		skipped = 1
	}
	base := theme_read(base_path, theme_base_buf[:])
	app := app_name()

	Entry :: struct {
		path:   string,
		line:   int,
		value:  string,
		scoped: bool,
		mine:   bool,
	}
	entries: [32]Entry
	n := 0
	sources := [2]string{string(base), string(body)}
	paths := [2]string{base_path, home_path}
	for src, si in sources {
		lineno := si == 1 ? skipped : 0
		i := 0
		for i < len(src) && n < len(entries) {
			start := i
			for i < len(src) && src[i] != '\n' {
				i += 1
			}
			line := src[start:i]
			if i < len(src) {
				i += 1
			}
			lineno += 1
			for k in 0 ..< len(line) {
				if line[k] == '#' {
					line = line[:k]
					break
				}
			}
			scope, rest, scoped := line_scope(line)
			r, after := word(rest)
			v, _ := word(after)
			if role_name(r) != role_name(role) || v == "" {
				continue
			}
			entries[n] = Entry{path = paths[si], line = lineno, value = v, scoped = scoped, mine = !scoped || (scope == app && app != "")}
			n += 1
		}
	}
	// The winner: the last scoped line that is this program's, else the
	// last unscoped one.
	win := -1
	for k in 0 ..< n {
		if entries[k].scoped && entries[k].mine {
			win = k
		}
	}
	if win < 0 {
		for k in 0 ..< n {
			if !entries[k].scoped {
				win = k
			}
		}
	}
	sink := libodin.sink_from(out)
	if n == 0 {
		t := default_theme
		vb: [24]u8
		libodin.put_str(&sink, role)
		libodin.put_str(&sink, " ")
		libodin.put_str(&sink, theme_value(&t, role, vb[:]))
		libodin.put_str(&sink, " chassis wins\n")
		return len(libodin.str(&sink))
	}
	nb: [24]u8
	for k := n - 1; k >= 0; k -= 1 {
		e := &entries[k]
		libodin.put_str(&sink, role)
		libodin.put_str(&sink, " ")
		libodin.put_str(&sink, e.value)
		libodin.put_str(&sink, " ")
		libodin.put_str(&sink, e.path)
		libodin.put_str(&sink, ":")
		libodin.put_str(&sink, libuser.itoa(nb[:], i64(e.line)))
		switch {
		case k == win:
			libodin.put_str(&sink, " wins\n")
		case !e.mine:
			libodin.put_str(&sink, " another program's\n")
		case:
			libodin.put_str(&sink, " beaten\n")
		}
	}
	return len(libodin.str(&sink))
}
