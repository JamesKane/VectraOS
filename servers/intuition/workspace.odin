/*
Workspaces: a number on a window, and nothing else.

`docs/WORKBENCH.md` section 4. The Amiga had screens because its hardware
could show one mode at a time. This glass has one mode and enough pixels.
What a person wants is a second *set of windows*, and that is a number
on each window from one to `WORKSPACES`. The compositor paints the windows whose number is the current one, and
`stack_top` answers the front window among them. A switch repaints the
glass from the other set.

A window is born on the current workspace, or on the one a rule names
for its name. `wctl workspace N` moves it, and `send` from a chord is
that for the window in front. The lamps down the desktop's right edge are one per workspace. Hot for
the current one, lit for one that has windows, dark for an empty one. They were a lamp per window slot, which
said nothing a person needed.

## The rules file

`$home/lib/workspaces`, or `/lib/workspaces` when there is none, one rule
per line: a window's name and the workspace it opens on.

    # workspaces: a window's name, and where it opens
    terminal   2
    view       3

The
server reads the file at start and on a `reload` line to its `ctl`, and
applies a rule when a window is named. A window with no rule stays where
it was born. The name is the only thing the server knows about a program,
and it is what a person reads on the bar. So the rule is written in the
words on the screen.

## The three kinds a desktop needs

A `backdrop` is behind every other window, never raised and never
framed, the desktop's own. A `bar` is the strip across the top, never
covered and never focused. A `popup` has no frame and is a menu or a
list. Each is a `wctl` word, and `window_kind` is what it changes.
*/
package intuition

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libpal"
import "vsys:libuser"

WORKSPACES :: 9

Window_Kind :: enum u8 {
	Normal,
	Backdrop,
	Bar,
	Popup,
}

// The current workspace, one to `WORKSPACES`.
current_ws: int

// workspace_has says whether any window is on workspace `ws`.
workspace_has :: proc "contextless" (ws: int) -> bool #no_bounds_check {
	for i in 0 ..< MAX_WINDOWS {
		if windows[i].used && windows[i].workspace == ws {
			return true
		}
	}
	return false
}

/*
workspace_lamp decomposes one workspace's lamp. The current one is lit in
the chassis's phosphor. One with windows on it is the same jewel at half. An empty one is the
unlit lamp, dark in its own colour, which `libdraw.lamp` is the rule
for.
*/
workspace_lamp :: proc "contextless" (out: []libdraw.Piece, x: int, y: int, ws: int) -> int #no_bounds_check {
	n := libdraw.lamp(out, x, y, LAMP, libpal.PHOSPHOR, ws == current_ws)
	if ws != current_ws && workspace_has(ws) && n > 0 {
		out[n - 1].color = libpal.mix(libpal.PHOSPHOR, libpal.VOID, 110)
	}
	return n
}

// lamp_show repaints one workspace's lamp on the glass.
lamp_show :: proc "contextless" (ws: int) {
	if ws < 1 || ws > WORKSPACES {
		return
	}
	lx, ly := lamp_at(ws - 1)
	desk_paint(lx, ly, lx + LAMP, ly + LAMP)
}

/*
workspace_switch makes `ws` the current workspace: the whole glass is
repainted from its windows, and the front one among them takes the focus.
The bars of the two windows that changed hands are repainted before the
composite, so the copper is on the right one.
*/
workspace_switch :: proc "contextless" (ws: int) #no_bounds_check {
	if ws < 1 || ws > WORKSPACES || ws == current_ws {
		return
	}
	was := stack_top()
	old := current_ws
	current_ws = ws
	if was >= 0 && windows[was].used {
		title_paint(&windows[was])
	}
	if now := stack_top(); now >= 0 {
		title_paint(&windows[now])
	}
	desk_paint(0, 0, scr_w, scr_h)
	repaint(0, 0, scr_w, scr_h)
	lamp_show(old)
	lamp_show(ws)
}

/*
window_place puts a window on workspace `ws`. A window that leaves the
current workspace uncovers what was under it, and one that arrives is
painted on top. The focus follows the stack either way.
*/
window_place :: proc "contextless" (win: ^Window, ws: int) #no_bounds_check {
	if ws < 1 || ws > WORKSPACES || ws == win.workspace {
		return
	}
	was := stack_top()
	old := win.workspace
	win.workspace = ws
	if old == current_ws && !win.hidden {
		desk_paint(win.x, win.y, win.x + win.w, win.y + win.h)
		repaint(win.x, win.y, win.w, win.h)
	}
	refocus(was)
	if ws == current_ws && !win.hidden {
		repaint(win.x, win.y, win.w, win.h)
	}
	lamp_show(old)
	lamp_show(ws)
}

// -- The rules file -----------------------------------------------------------------

MAX_RULES :: 32

Rule :: struct {
	name: [MAX_TITLE]u8,
	n:    int,
	ws:   int,
}

rules: [MAX_RULES]Rule
nrules: int

// The file's bytes, read once into a buffer the rules point into.
rules_text: [4096]u8

/*
rules_load reads the rules file, the user's first and the machine's
second, and keeps what parses. A line that is not a name and a number is
skipped, which is what a comment is.
*/
rules_load :: proc "contextless" () #no_bounds_check {
	nrules = 0
	n := read_user_file("workspaces", rules_text[:])
	if n <= 0 {
		return
	}
	at := 0
	for at < n && nrules < MAX_RULES {
		end := at
		for end < n && rules_text[end] != '\n' {
			end += 1
		}
		line := rules_text[at:end]
		at = end + 1
		if hash := index_byte(line, '#'); hash >= 0 {
			line = line[:hash]
		}
		name, rest := word(line)
		if len(name) == 0 {
			continue
		}
		num, _ := word(rest)
		ws, ok := libdraw.scan_int_str(num)
		if !ok || ws < 1 || ws > WORKSPACES {
			continue
		}
		r := &rules[nrules]
		r.n = copy(r.name[:], name)
		r.ws = ws
		nrules += 1
	}
}

// rule_for answers the workspace a rule names for a window's name, or
// zero.
rule_for :: proc "contextless" (name: []u8) -> int #no_bounds_check {
	for i in 0 ..< nrules {
		r := &rules[i]
		if r.n == len(name) && string(r.name[:r.n]) == string(name) {
			return r.ws
		}
	}
	return 0
}

/*
read_user_file reads `$home/lib/<name>`, or `/lib/<name>` when the first
is not there, into `buf`, and answers how many bytes, or zero. `$home` is
`/env/home`, which is the environment as `kernel/env` serves it.
*/
read_user_file :: proc "contextless" (name: string, buf: []u8) -> int #no_bounds_check {
	path: [128]u8
	home: [64]u8
	hn := 0
	if fd := libuser.open("/env/home", abi.O_RDONLY); fd >= 0 {
		if got := libuser.read(int(fd), home[:]); got > 0 {
			hn = int(got)
		}
		_ = libuser.close(int(fd))
	}
	if hn > 0 {
		at := copy(path[:], home[:hn])
		at += copy(path[at:], "/lib/")
		at += copy(path[at:], name)
		if n := read_whole(string(path[:at]), buf); n > 0 {
			return n
		}
	}
	at := copy(path[:], "/lib/")
	at += copy(path[at:], name)
	return read_whole(string(path[:at]), buf)
}

@(private = "file")
read_whole :: proc "contextless" (path: string, buf: []u8) -> int {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return 0
	}
	n := 0
	for n < len(buf) {
		got := libuser.read(int(fd), buf[n:])
		if got <= 0 {
			break
		}
		n += int(got)
	}
	_ = libuser.close(int(fd))
	return n
}

// word takes the next run of non-space bytes off a line, and answers it
// and what follows.
word :: proc "contextless" (line: []u8) -> (w: []u8, rest: []u8) #no_bounds_check {
	at := 0
	for at < len(line) && is_space(line[at]) {
		at += 1
	}
	start := at
	for at < len(line) && !is_space(line[at]) {
		at += 1
	}
	return line[start:at], line[at:]
}

is_space :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n'
}

index_byte :: proc "contextless" (s: []u8, c: u8) -> int #no_bounds_check {
	for i in 0 ..< len(s) {
		if s[i] == c {
			return i
		}
	}
	return -1
}
