/*
Chords: a key with a modifier held, caught before any window sees it.

`docs/WORKBENCH.md` section 4. The keys file, `$home/lib/keys` and then
`/lib/keys`, is one chord per line and what it does. The server reads the
`kbd` file `kbdfs` serves, which reports the keys held on every change as
runes. A modifier held with a key is a thing this can see and `/dev/cons`
never could. A non-modifier key going down while a modifier is held is a
chord. The server matches it against the file, does the actions it knows
itself, and sends the rest on `/srv/draw/hotkey` for the desktop.

    close cycle zoom back            the window in front
    workspace N next prev            the workspaces
    send N overview                  the window in front, and the picture
    mode NAME                        into a mode, below
    any wctl word                    the window in front: `snap left`,
                                     `move +0 -16` (a signed number is
                                     relative, a bare one absolute)

Everything else -- `window rc -i`, `execute`, `menu` -- the server does
not know, and the desktop reads off `hotkey` and runs.

Four more shapes, each a line of the file:

    mode resize alt-r 1500      # alt-r enters; 1.5 s of no key leaves
    [resize] left  size -16 +0  # a key in the mode, no modifier needed
    repeat alt-equal  size +32 +0   # fires again while the key is held
    release alt  menu           # a modifier tapped alone, on its release
    alt-button1  drag move      # a mouse bind: alt and a drag moves

A key typed in a mode goes to no window: the mode takes it, and Escape or
a key the mode does not bind leaves it. The mode lamp under the workspace
lamps is lit while one is on, because a mode a person cannot see is a
trap, and the server's `ctl` says which. That is
Commodities' Exchange in one file. The window manager does what a window
manager does, the desktop what a desktop does, and a person edits one
file for both.

A key with a modifier the file does not name reaches the window in
front like any other, which lets a program bind its own.
*/
package intuition

import "core:unicode/utf8"
import "vsys:libkey"
import "vsys:vectra9"

MOD_ALT :: u8(1)
MOD_CTL :: u8(2)
MOD_SHIFT :: u8(4)

MAX_CHORDS :: 64
MAX_ACTION :: 64

Chord :: struct {
	mods:    u8,
	key:     rune,
	action:  [MAX_ACTION]u8,
	n:       int,
	mode:    int, // 0 a chord anywhere; i + 1 a key of mode i
	repeat:  bool, // Fires again on the keyboard's own repeat while held
	release: bool, // A modifier tapped alone, fired on its release
}

chords: [MAX_CHORDS]Chord
nchords: int

// A mode: a set of keys that act with no modifier, entered by a chord,
// left by Escape, a key it does not bind, or `timeout` of no key.
MAX_MODES :: 8

Mode :: struct {
	name:    [16]u8,
	n:       int,
	timeout: u64, // Milliseconds
}

modes: [MAX_MODES]Mode
nmodes: int
mode_on: int // 0 none, or i + 1
mode_until: u64

// A mouse bind: a button pressed with modifiers held begins a drag of the
// window under the pointer, which the server does itself.
Mouse_Bind :: struct {
	mods:   u8,
	button: u8, // rio's bits: 1, 2, 4
	size:   bool, // A size drag, not a move
}

MAX_MOUSE_BINDS :: 4
mouse_binds: [MAX_MOUSE_BINDS]Mouse_Bind
nmouse_binds: int

chords_text: [4096]u8

/*
keys_load reads the keys file, the user's first and the machine's second,
and keeps the chords that parse. A line whose first word is not a chord,
or that has no action, is skipped. A comment and a blank line are both
of those.
*/
keys_load :: proc "contextless" () #no_bounds_check {
	nchords = 0
	nmodes = 0
	nmouse_binds = 0
	mode_on = 0
	n := read_user_file("keys", chords_text[:])
	at := 0
	for at < n && nchords < MAX_CHORDS {
		end := at
		for end < n && chords_text[end] != '\n' {
			end += 1
		}
		line := chords_text[at:end]
		at = end + 1
		if hash := index_byte(line, '#'); hash >= 0 {
			line = line[:hash]
		}
		spec, rest := word(line)
		if len(spec) == 0 {
			continue
		}
		c := Chord{}
		switch {
		case string(spec) == "mode":
			// `mode NAME CHORD [ms]`: the mode, and the chord into it.
			name, r1 := word(rest)
			enter, r2 := word(r1)
			ms, _ := word(r2)
			if len(name) == 0 || len(name) > 16 || nmodes >= MAX_MODES {
				continue
			}
			m := &modes[nmodes]
			m.n = copy(m.name[:], name)
			m.timeout = 3000
			if v, vok := number(ms); vok && v > 0 {
				m.timeout = u64(v)
			}
			nmodes += 1
			mods, key, ok := parse_chord(enter)
			if !ok {
				continue
			}
			c.mods = mods
			c.key = key
			k := copy(c.action[:], "mode ")
			c.n = k + copy(c.action[k:], name)
			chords[nchords] = c
			nchords += 1
			continue
		case len(spec) > 2 && spec[0] == '[' && spec[len(spec) - 1] == ']':
			// `[NAME] KEY ACTION`: a key of a mode declared above.
			c.mode = mode_index(spec[1:len(spec) - 1]) + 1
			if c.mode == 0 {
				continue
			}
			spec, rest = word(rest)
		case string(spec) == "repeat":
			c.repeat = true
			spec, rest = word(rest)
		case string(spec) == "release":
			c.release = true
			spec, rest = word(rest)
		}
		// A mouse bind: `alt-button1 drag move`.
		if mods, button, ok := parse_button(spec); ok {
			verb, r1 := word(rest)
			what, _ := word(r1)
			if string(verb) == "drag" && (string(what) == "move" || string(what) == "size") && nmouse_binds < MAX_MOUSE_BINDS {
				mouse_binds[nmouse_binds] = Mouse_Bind{mods = mods, button = button, size = string(what) == "size"}
				nmouse_binds += 1
			}
			continue
		}
		mods, key, ok := parse_chord(spec)
		if !ok {
			continue
		}
		action := trim(rest)
		if len(action) == 0 {
			continue
		}
		c.mods = mods
		c.key = key
		c.n = copy(c.action[:], action)
		chords[nchords] = c
		nchords += 1
	}
}

// mode_index is the mode of that name's index, or -1.
mode_index :: proc "contextless" (name: []u8) -> int #no_bounds_check {
	for i in 0 ..< nmodes {
		if string(modes[i].name[:modes[i].n]) == string(name) {
			return i
		}
	}
	return -1
}

// parse_button reads `alt-button1`: modifiers and a mouse button, rio's bit.
parse_button :: proc "contextless" (spec: []u8) -> (mods: u8, button: u8, ok: bool) #no_bounds_check {
	last := 0
	for i in 0 ..< len(spec) {
		if spec[i] == '-' {
			last = i + 1
		}
	}
	part := spec[last:]
	switch string(part) {
	case "button1":
		button = 1
	case "button2":
		button = 2
	case "button3":
		button = 4
	case:
		return 0, 0, false
	}
	if last > 0 {
		mods = mods_only(spec[:last - 1])
	}
	return mods, button, true
}

@(private = "file")
mods_only :: proc "contextless" (spec: []u8) -> u8 #no_bounds_check {
	mods := u8(0)
	at := 0
	for at <= len(spec) {
		dash := at
		for dash < len(spec) && spec[dash] != '-' {
			dash += 1
		}
		switch string(spec[at:dash]) {
		case "alt":
			mods |= MOD_ALT
		case "ctrl", "control":
			mods |= MOD_CTL
		case "shift":
			mods |= MOD_SHIFT
		}
		at = dash + 1
	}
	return mods
}

/*
parse_chord reads `alt-shift-n` into its modifier mask and its key. The
words before the last are modifiers, and the last is the key, a name or
a single character. False for a spec with an unknown modifier or no key.
*/
parse_chord :: proc "contextless" (spec: []u8) -> (mods: u8, key: rune, ok: bool) #no_bounds_check {
	at := 0
	for at < len(spec) {
		dash := at
		for dash < len(spec) && spec[dash] != '-' {
			dash += 1
		}
		part := spec[at:dash]
		if dash >= len(spec) {
			// The last part is the key.
			k, kok := key_of(part)
			return mods, k, kok
		}
		switch string(part) {
		case "alt":
			mods |= MOD_ALT
		case "ctrl", "control":
			mods |= MOD_CTL
		case "shift":
			mods |= MOD_SHIFT
		case:
			return 0, 0, false
		}
		at = dash + 1
	}
	return 0, 0, false
}

// key_of is a chord's key: a name for one with no character, or a single
// character otherwise.
key_of :: proc "contextless" (part: []u8) -> (rune, bool) #no_bounds_check {
	switch string(part) {
	case "alt":
		return libkey.KALT, true
	case "ctrl", "control":
		return libkey.KCTL, true
	case "shift":
		return libkey.KSHIFT, true
	case "equal":
		return '=', true
	case "minus":
		return '-', true
	case "tab":
		return '\t', true
	case "space":
		return ' ', true
	case "esc":
		return libkey.KESC, true
	case "del":
		return libkey.KDEL, true
	case "up":
		return libkey.KUP, true
	case "down":
		return libkey.KDOWN, true
	case "left":
		return libkey.KLEFT, true
	case "right":
		return libkey.KRIGHT, true
	case "home":
		return libkey.KHOME, true
	case "end":
		return libkey.KEND, true
	}
	if len(part) >= 2 && (part[0] == 'f' || part[0] == 'F') {
		n, ok := number(part[1:])
		if ok && n >= 1 && n <= 12 {
			return libkey.KF1 + rune(n - 1), true
		}
	}
	if len(part) == 1 {
		return canon(rune(part[0]), false), true
	}
	return 0, false
}

/*
canon is a key's rune with shift's effect removed, so `alt-shift-1`
in the file matches the `!` the `kbd` file reports. A letter lowercases,
and the number row's symbols map back to their digit. Everything else is
itself.
*/
canon :: proc "contextless" (r: rune, shift: bool) -> rune {
	if r >= 'A' && r <= 'Z' {
		return r + 32
	}
	if shift {
		switch r {
		case '!': return '1'
		case '@': return '2'
		case '#': return '3'
		case '$': return '4'
		case '%': return '5'
		case '^': return '6'
		case '&': return '7'
		case '*': return '8'
		case '(': return '9'
		case ')': return '0'
		}
	}
	return r
}

// -- Detecting a chord from the keys held --------------------------------------------

// The keys held now, as the `kbd` file's `k`/`K` messages report them. A
// new press is what is in the set and was not before.
held_keys: [16]rune
nheld_keys: int

// The modifier down alone, a candidate for a `release` chord, or 0.
tap_mod: rune

// mods_held is the modifiers held now, for a mouse bind.
mods_held :: proc "contextless" () -> u8 {
	return mods_of(held_keys[:nheld_keys])
}

/*
keys_update takes a `k` or `K` message's runes, every key held after the
change. It fires a chord for a non-modifier key newly down while a
modifier is held. A modifier press fires nothing itself.
*/
keys_update :: proc "contextless" (down: bool, runes: []rune) #no_bounds_check {
	mods := mods_of(runes)
	// Locked, no chord acts: the keys are the lock's.
	if down && mods != 0 && !locked {
		for r in runes {
			if is_mod(r) {
				continue
			}
			if !was_held(r) {
				chord_fire(mods, canon(r, mods & MOD_SHIFT != 0), false)
			} else {
				// The keyboard's own repeat: the key held, reported again.
				chord_fire(mods, canon(r, mods & MOD_SHIFT != 0), true)
			}
		}
	}
	// A modifier tapped alone: down with nothing else, then up with
	// nothing else pressed between.
	nonmod := false
	for r in runes {
		if !is_mod(r) {
			nonmod = true
		}
	}
	if down {
		if nonmod {
			tap_mod = 0
		} else if len(runes) == 1 && nheld_keys == 0 {
			tap_mod = runes[0]
		}
	} else if tap_mod != 0 && !locked {
		still := false
		for r in runes {
			if r == tap_mod {
				still = true
			}
		}
		if !still {
			t := tap_mod
			tap_mod = 0
			if len(runes) == 0 {
				release_fire(t)
			}
		}
	}
	nheld_keys = 0
	for r in runes {
		if nheld_keys < len(held_keys) {
			held_keys[nheld_keys] = r
			nheld_keys += 1
		}
	}
}

@(private = "file")
was_held :: proc "contextless" (r: rune) -> bool #no_bounds_check {
	for i in 0 ..< nheld_keys {
		if held_keys[i] == r {
			return true
		}
	}
	return false
}

@(private = "file")
mods_of :: proc "contextless" (runes: []rune) -> u8 {
	m := u8(0)
	for r in runes {
		switch r {
		case libkey.KALT:
			m |= MOD_ALT
		case libkey.KCTL:
			m |= MOD_CTL
		case libkey.KSHIFT:
			m |= MOD_SHIFT
		}
	}
	return m
}

@(private = "file")
is_mod :: proc "contextless" (r: rune) -> bool {
	return r == libkey.KALT || r == libkey.KCTL || r == libkey.KSHIFT ||
	       r == libkey.KCAPS || r == libkey.KNUM || r == libkey.KMOD4
}

/*
chord_fire matches one chord against the file and acts. A match the server knows it does. A match it does not it sends on
`hotkey`. A chord in no line does nothing here, and the key reached the
window in front as its `c` message already.
*/
chord_fire :: proc "contextless" (mods: u8, key: rune, repeated: bool) #no_bounds_check {
	for i in 0 ..< nchords {
		c := &chords[i]
		if c.mode == 0 && !c.release && c.mods == mods && c.key == key && (!repeated || c.repeat) {
			chord_do(c)
			return
		}
	}
}

// release_fire fires the `release` chord for a modifier tapped alone.
release_fire :: proc "contextless" (key: rune) #no_bounds_check {
	for i in 0 ..< nchords {
		c := &chords[i]
		if c.release && c.key == key {
			chord_do(c)
			return
		}
	}
}

// chord_do does a chord's action, or sends it to the desktop.
chord_do :: proc "contextless" (c: ^Chord) {
	if !chord_act(c.action[:c.n]) {
		hotkey_push(c.action[:c.n])
	}
}

/*
mode_key takes the characters of a `c` message while a mode is on, and
answers whether it took them, so no window sees a key a mode acted on. A
mode past its time is left first, and the key goes on as any key does.
*/
mode_key :: proc "contextless" (body: []u8) -> bool #no_bounds_check {
	if mode_on == 0 {
		return false
	}
	if uptime_ms() > mode_until {
		mode_set(0)
		return false
	}
	at := 0
	for at < len(body) {
		r, size := utf8.decode_rune(body[at:])
		if size <= 0 {
			break
		}
		at += size
		found := false
		for i in 0 ..< nchords {
			c := &chords[i]
			if c.mode == mode_on && c.key == canon(r, false) {
				chord_do(c)
				found = true
				break
			}
		}
		if !found {
			// Escape, or a key the mode does not bind: out of the mode.
			mode_set(0)
			return true
		}
	}
	if mode_on != 0 {
		mode_until = uptime_ms() + modes[mode_on - 1].timeout
	}
	return true
}

// mode_set turns a mode on (i + 1) or off (0), and lights the lamp for it.
mode_set :: proc "contextless" (m: int) {
	mode_on = m
	if m > 0 {
		mode_until = uptime_ms() + modes[m - 1].timeout
	}
	lx, ly := lamp_at(WORKSPACES)
	desk_paint(lx, ly, lx + LAMP, ly + LAMP)
}

/*
chord_act does one of the actions the window manager knows, and answers
whether it was one. The window in front is what most act on. There is
none when no window is up, which is not an error, and the chord did
nothing.
*/
chord_act :: proc "contextless" (action: []u8) -> bool #no_bounds_check {
	verb, rest := word(action)
	front := stack_top()
	switch string(verb) {
	case "close":
		// A backdrop is the desktop, with no close gadget, so the chord
		// leaves it: a close pressed once too often would take the desktop.
		// Its program ends it from its own menu.
		if front >= 0 && windows[front].kind != .Backdrop {
			window_close_request(&windows[front])
		}
	case "zoom":
		if front >= 0 {
			window_zoom(&windows[front])
		}
	case "mode":
		name, _ := word(rest)
		if i := mode_index(name); i >= 0 {
			mode_set(i + 1)
		}
	case "back":
		if front >= 0 {
			window_lower(front)
		}
	case "cycle":
		window_cycle()
	case "move":
		// A signed number is relative, a bare one absolute, axis by axis.
		if front >= 0 {
			win := &windows[front]
			nx, ny, ok := signed_pair(rest, win.x, win.y)
			if ok {
				_ = window_move(win, nx, ny)
			}
		}
	case "size":
		if front >= 0 {
			win := &windows[front]
			_, _, cw, ch := frame_client(win)
			nw, nh, ok := signed_pair(rest, cw, ch)
			if ok {
				_ = window_size(win, nw, nh)
			}
		}
	case "workspace":
		if ws, ok := one_number(rest); ok {
			workspace_switch(ws)
		}
	case "next":
		workspace_switch(current_ws == WORKSPACES ? 1 : current_ws + 1)
	case "prev":
		workspace_switch(current_ws == 1 ? WORKSPACES : current_ws - 1)
	case "send":
		if ws, ok := one_number(rest); ok && front >= 0 {
			window_place(&windows[front], ws)
		}
	case "overview":
		overview_toggle()
	case "lock":
		lock_on()
	case:
		// Any `wctl` word, on the window in front: a word added there is
		// bindable the day it exists. One it does not know is the desktop's.
		if front >= 0 && run_wctl(front, action) == vectra9.Errno(0) {
			return true
		}
		return false
	}
	return true
}

// signed_pair reads two numbers against a base: `+8` and `-8` are the base
// moved, `8` is 8.
@(private = "file")
signed_pair :: proc "contextless" (data: []u8, bx: int, by: int) -> (int, int, bool) {
	a, rest := word(data)
	b, _ := word(rest)
	x, ok1 := number(a)
	y, ok2 := number(b)
	if !ok1 || !ok2 {
		return 0, 0, false
	}
	if a[0] == '+' || a[0] == '-' {
		x += bx
	}
	if b[0] == '+' || b[0] == '-' {
		y += by
	}
	return x, y, true
}

/*
window_cycle moves the focus to the next window on the current
workspace. The front one goes to the back, and whatever was behind it
comes forward.
*/
window_cycle :: proc "contextless" () #no_bounds_check {
	front := stack_top()
	if front < 0 {
		return
	}
	window_lower(front)
}

@(private = "file")
one_number :: proc "contextless" (data: []u8) -> (int, bool) {
	w, _ := word(data)
	return number(w)
}

@(private = "file")
two_numbers :: proc "contextless" (data: []u8) -> (int, int, bool) {
	a, rest := word(data)
	b, _ := word(rest)
	x, ok1 := number(a)
	y, ok2 := number(b)
	return x, y, ok1 && ok2
}

// number reads a signed integer that is the whole of `w`.
number :: proc "contextless" (w: []u8) -> (int, bool) #no_bounds_check {
	if len(w) == 0 {
		return 0, false
	}
	neg := w[0] == '-'
	start := neg || w[0] == '+' ? 1 : 0
	if start >= len(w) {
		return 0, false
	}
	v := 0
	for i in start ..< len(w) {
		if w[i] < '0' || w[i] > '9' {
			return 0, false
		}
		v = v * 10 + int(w[i] - '0')
	}
	return neg ? -v : v, true
}
