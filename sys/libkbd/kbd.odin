/*
The scancode state machine, once, for both rings.

`kernel/drivers/kbd` translated scancode set 1 to characters, and
`servers/kbdfs` carried a second copy of the same tables to do it one
privilege level out. `docs/KBD.md` said a layout was a table in a driver,
which was the wrong place, and `docs/WORKBENCH.md` step 1 is where it
moved. This package is the one copy. The kernel's driver calls it for
`/dev/cons`, and `kbdfs` calls it for the `cons` and `kbd` files it
serves.

## A key is a position, and a rune is what the position says now

A scancode names a *position* on the keyboard: `0x1E` is the key with `a`
on it. What that key means depends on the modifiers held at the moment,
and on nothing else. So the state machine answers two separate
questions. `step` says which position went down or up, and moves the
modifier state. `rune_of` says what a position means under the state now.

A `kbd` file reports the keys held as runes on every change. It needs
both answers: the set of positions held, and their meaning at the moment
of the report. A key held while shift goes down changes its rune without
moving.

Every key answers a rune, the ones with no character included. An arrow
is `libkey.KLEFT`, alt is `libkey.KALT`, a function key is `KF1` and up.
`sys/libkey` is the wire format and `docs/DRAW.md` section 17 is why the
private space is where a key with no character lives.

## What a cooked stream gets

`char_of` is the rule for a byte stream. A press produces the rune the
position means, unless the key is a modifier or alt is held. A chord is a
key with alt in front of it. A chord makes no character, because the
window manager takes it before any window sees it. That is Commodities'
rule and `rio`'s. It is why `/dev/cons` can never carry a chord: the
character it would carry is the one the chord is not.

Scancode set 1 and a US layout, as before. The table maps a position to
the character a US layout puts there. It is two tables rather than one
and a rule, because `2` shifts to `@` and only a picture of the keyboard
predicts it. Caps lock flips a letter after the table answers and touches
nothing else. Control makes a letter the control character at the same
position. The `0xE0` prefix is remembered for one key, because an
extended code shares its second byte with an ordinary one.
*/
package libkbd

import "vsys:libkey"

// A position on the keyboard: the make code, and bit 8 for a code that
// came behind the extended prefix.
Key :: distinct u16

EXTENDED :: Key(0x100)

// The modifier state, which `step` moves and `rune_of` reads.
State :: struct {
	shift:    bool,
	ctrl:     bool,
	alt:      bool,
	caps:     bool,
	extended: bool, // The last scancode was the 0xE0 prefix
}

SC_EXTENDED :: u8(0xE0)
SC_RELEASE :: u8(0x80) // Set in the code when a key comes back up

// The positions the state machine acts on itself.
SC_LSHIFT :: u8(0x2A)
SC_RSHIFT :: u8(0x36)
SC_CTRL :: u8(0x1D)
SC_ALT :: u8(0x38)
SC_CAPS :: u8(0x3A)

/*
step takes one scancode and answers the position it names and whether the
key went down. `ok` is false for the prefix byte, which names no key on
its own, and the state remembers it for the code that follows.

The modifiers move here, on the press and on the release both, because
they are the keys whose release matters. Caps lock latches on the press
only: a lock that toggled on the release as well would end every
keystroke where it started.
*/
step :: proc "contextless" (s: ^State, code: u8) -> (key: Key, down: bool, ok: bool) {
	if code == SC_EXTENDED {
		s.extended = true
		return 0, false, false
	}
	was_extended := s.extended
	s.extended = false

	down = code & SC_RELEASE == 0
	make := code &~ SC_RELEASE
	key = Key(make)
	if was_extended {
		key |= EXTENDED
	}

	switch key {
	case Key(SC_LSHIFT), Key(SC_RSHIFT):
		s.shift = down
	case Key(SC_CTRL), Key(SC_CTRL) | EXTENDED:
		s.ctrl = down
	case Key(SC_ALT), Key(SC_ALT) | EXTENDED:
		s.alt = down
	case Key(SC_CAPS):
		if down {
			s.caps = !s.caps
		}
	}
	return key, down, true
}

// is_modifier says whether a position is one whose only meaning is what
// it does to the others.
is_modifier :: proc "contextless" (key: Key) -> bool {
	switch key {
	case Key(SC_LSHIFT), Key(SC_RSHIFT), Key(SC_CTRL), Key(SC_CTRL) | EXTENDED,
	     Key(SC_ALT), Key(SC_ALT) | EXTENDED, Key(SC_CAPS), Key(0x45), Key(0x46),
	     Key(0x5B) | EXTENDED, Key(0x5C) | EXTENDED:
		return true
	}
	return false
}

/*
char_of is what a cooked stream delivers for a press: the rune the
position means now, unless the key is a modifier or a chord. `ok` is
false for both, and for a position this layout has no meaning for.
*/
char_of :: proc "contextless" (s: ^State, key: Key) -> (r: rune, ok: bool) {
	if s.alt || is_modifier(key) {
		return 0, false
	}
	return rune_of(s, key)
}

/*
rune_of is what a position means under the modifier state now.

A modifier answers its own rune, so a `kbd` reader sees `KALT` among the
keys held. A key behind the prefix answers the rune Plan 9 gives it. A
function key answers `KF1` and up. A position with a character on it
answers the character, shifted, cased by caps lock, and made a control
character by control, in that order. Anything else answers nothing.
*/
rune_of :: proc "contextless" (s: ^State, key: Key) -> (r: rune, ok: bool) #no_bounds_check {
	switch key {
	case Key(SC_LSHIFT), Key(SC_RSHIFT):
		return libkey.KSHIFT, true
	case Key(SC_CTRL), Key(SC_CTRL) | EXTENDED:
		return libkey.KCTL, true
	case Key(SC_ALT), Key(SC_ALT) | EXTENDED:
		return libkey.KALT, true
	case Key(SC_CAPS):
		return libkey.KCAPS, true
	case Key(0x45):
		return libkey.KNUM, true
	case Key(0x46):
		return libkey.KSCROLL, true
	case Key(0x5B) | EXTENDED, Key(0x5C) | EXTENDED:
		return libkey.KMOD4, true
	case Key(0x01):
		return libkey.KESC, true
	case Key(0x57):
		return libkey.KF1 + 10, true
	case Key(0x58):
		return libkey.KF1 + 11, true
	}
	if key >= Key(0x3B) && key <= Key(0x44) {
		return libkey.KF1 + rune(key - Key(0x3B)), true
	}
	if key & EXTENDED != 0 {
		return extended_rune(u8(key &~ EXTENDED))
	}
	if int(key) >= len(PLAIN) {
		return 0, false
	}

	b := s.shift ? SHIFTED[key] : PLAIN[key]
	if b == 0 {
		return 0, false
	}
	// Caps lock applies to letters and to nothing else. It is not another
	// shift: caps lock plus `2` is `2` on every keyboard anyone ever used,
	// and shift plus `2` is `@`.
	if s.caps {
		if b >= 'a' && b <= 'z' {
			b -= 32
		} else if b >= 'A' && b <= 'Z' {
			b += 32
		}
	}
		// Control makes a letter the control character at the same position.
	// `^A` is 1 through `^Z` is 26, which is what makes a typed `^D` reach
	// a line discipline. Control and anything else is nothing, rather than
	// a byte nobody meant.
	if s.ctrl {
		u := b
		if u >= 'a' && u <= 'z' {
			u -= 32
		}
		if u >= 'A' && u <= 'Z' {
			return rune(u - 'A' + 1), true
		}
		return 0, false
	}
	return rune(b), true
}

/*
The keyboard as positions, unshifted and shifted. Index is the make code.
Zero means the position produces no character: a modifier, a function
key, or the keypad, which answers nothing until num lock means something.
The keypad's `-` and `+` are here because they are always those.
*/
@(private = "file")
PLAIN := [0x60]u8 {
	0, 0x1B, '1', '2', '3', '4', '5', '6',
	'7', '8', '9', '0', '-', '=', '\b', '\t',
	'q', 'w', 'e', 'r', 't', 'y', 'u', 'i',
	'o', 'p', '[', ']', '\n', 0, 'a', 's',
	'd', 'f', 'g', 'h', 'j', 'k', 'l', ';',
	'\'', '`', 0, '\\', 'z', 'x', 'c', 'v',
	'b', 'n', 'm', ',', '.', '/', 0, '*',
	0, ' ', 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, '-', 0, 0, 0, '+', 0,
	0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0,
}

@(private = "file")
SHIFTED := [0x60]u8 {
	0, 0x1B, '!', '@', '#', '$', '%', '^',
	'&', '*', '(', ')', '_', '+', '\b', '\t',
	'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I',
	'O', 'P', '{', '}', '\n', 0, 'A', 'S',
	'D', 'F', 'G', 'H', 'J', 'K', 'L', ':',
	'"', '~', 0, '|', 'Z', 'X', 'C', 'V',
	'B', 'N', 'M', '<', '>', '?', 0, '*',
	0, ' ', 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, '-', 0, 0, 0, '+', 0,
	0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0,
}

/*
extended_rune is the second half of an extended scancode, as the rune
Plan 9 gives that key. The numbers on the left are set 1's, and the names
on the right are `sys/include/keyboard.h`'s. Keypad enter and the keypad
slash are the two keys behind the prefix with a character on them.
*/
@(private = "file")
extended_rune :: proc "contextless" (make: u8) -> (rune, bool) {
	switch make {
	case 0x1C:
		return '\n', true
	case 0x35:
		return '/', true
	case 0x47:
		return libkey.KHOME, true
	case 0x48:
		return libkey.KUP, true
	case 0x49:
		return libkey.KPGUP, true
	case 0x4B:
		return libkey.KLEFT, true
	case 0x4D:
		return libkey.KRIGHT, true
	case 0x4F:
		return libkey.KEND, true
	case 0x50:
		return libkey.KDOWN, true
	case 0x51:
		return libkey.KPGDOWN, true
	case 0x52:
		return libkey.KINS, true
	case 0x53:
		return libkey.KDEL, true
	case 0x37:
		return libkey.KPRINT, true
	}
	return 0, false
}
