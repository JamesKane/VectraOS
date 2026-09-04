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
    move DX DY size DW DH raise      the window in front, by a delta
    workspace N next prev            the workspaces
    send N overview                  the window in front, and the picture

Everything else -- `window rc -i`, `execute`, `menu` -- the server does
not know, and the desktop reads off `hotkey` and runs. That is
Commodities' Exchange in one file. The window manager does what a window
manager does, the desktop what a desktop does, and a person edits one
file for both.

A key with a modifier the file does not name reaches the window in
front like any other, which lets a program bind its own.
*/
package intuition

import "vsys:libkey"

MOD_ALT :: u8(1)
MOD_CTL :: u8(2)
MOD_SHIFT :: u8(4)

MAX_CHORDS :: 64
MAX_ACTION :: 64

Chord :: struct {
	mods:   u8,
	key:    rune,
	action: [MAX_ACTION]u8,
	n:      int,
}

chords: [MAX_CHORDS]Chord
nchords: int

chords_text: [4096]u8

/*
keys_load reads the keys file, the user's first and the machine's second,
and keeps the chords that parse. A line whose first word is not a chord,
or that has no action, is skipped. A comment and a blank line are both
of those.
*/
keys_load :: proc "contextless" () #no_bounds_check {
	nchords = 0
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
		mods, key, ok := parse_chord(spec)
		if !ok {
			continue
		}
		action := trim(rest)
		if len(action) == 0 {
			continue
		}
		c := &chords[nchords]
		c.mods = mods
		c.key = key
		c.n = copy(c.action[:], action)
		nchords += 1
	}
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

/*
keys_update takes a `k` or `K` message's runes, every key held after the
change. It fires a chord for a non-modifier key newly down while a
modifier is held. A modifier press fires nothing itself.
*/
keys_update :: proc "contextless" (down: bool, runes: []rune) #no_bounds_check {
	mods := mods_of(runes)
	if down && mods != 0 {
		for r in runes {
			if !is_mod(r) && !was_held(r) {
				chord_fire(mods, canon(r, mods & MOD_SHIFT != 0))
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
chord_fire :: proc "contextless" (mods: u8, key: rune) #no_bounds_check {
	for i in 0 ..< nchords {
		c := &chords[i]
		if c.mods == mods && c.key == key {
			if !chord_act(c.action[:c.n]) {
				hotkey_push(c.action[:c.n])
			}
			return
		}
	}
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
		if front >= 0 {
			window_hangup(&windows[front])
		}
	case "zoom":
		if front >= 0 {
			window_zoom(&windows[front])
		}
	case "back":
		if front >= 0 {
			window_lower(front)
		}
	case "cycle":
		window_cycle()
	case "move":
		dx, dy, ok := two_numbers(rest)
		if ok && front >= 0 {
			_ = window_move(&windows[front], windows[front].x + dx, windows[front].y + dy)
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
	case:
		return false
	}
	return true
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
	start := neg ? 1 : 0
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
