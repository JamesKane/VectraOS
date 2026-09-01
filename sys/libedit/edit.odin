/*
The line under construction, and the keys that edit it.

**One line discipline, worn by both sides of a window's `cons`.**
`servers/intuition` cooks a line per window and hands the finished one to
whoever reads that window's keyboard. `apps/terminal` takes its own window raw
and cooks the line itself, because it is the program that draws the text and a
person has to see the characters as they are typed. Those are two different
reasons to hold a line, and exactly one set of rules about what the keys mean.

**The rules are `rio`'s `wbswidth`**, which is the procedure in
`/sys/src/cmd/rio/wind.c` that decides how far back an erase goes. It has three
answers and no more:

    ^H, DEL     one character
    ^U          the whole line
    ^W          one word: the letters and digits before the cursor, and any
                spaces between them and it

`kernel/devfs` has its own copy of the first two and has never had the third,
and **that is not a defect to go and fix.** 9front's kernel does no line
editing at all -- `devcons.c` reads a queue -- and its two userland disciplines
disagree on purpose: `aux/kbdfs` erases back to whitespace, `rio` erases back
over letters and digits. A discipline belongs to the layer that serves a
`cons`, and two layers are allowed to mean different things by a word.

So this package is what ring 3 shares, and `kernel/devfs` keeps its own for the
console it serves before any of this exists.

**There is a cursor, and both kinds of key move it.** `rio` moves by a whole
line with two ordinary control bytes, and by one character with the arrows --
which in Plan 9 are *runes* in the private Unicode space rather than bytes.
`core:unicode/utf8` is that encoding and `kernel/drivers/kbd` is what emits them, so
both kinds arrive down the same `/dev/cons` and this is where they are told
apart:

    ^A, Khome       to the beginning of the line
    ^E, Kend        to the end of it
    Kleft, Kright   one character

A character is inserted *at* the cursor and an erase takes what is before it,
which is `winsert` and `wdelete` in one line's worth of buffer.

**Decoding happens here because a caller feeds this one byte at a time.** A
rune above `0x7F` arrives as two or three, so `put` holds the ones it has and
answers `.Pending` until the sequence is whole. Every caller already has a
branch for a byte that changed nothing.

The arithmetic is `core:unicode/utf8`'s, which compiles freestanding and is
allocator-free. What `sys/libkey` adds is the half a standard library cannot
have: which numbers Plan 9 gives to which keys.

**Only ASCII is ever stored.** A rune this line does not act on is dropped
rather than inserted: `sys/libfont` is an 8x16 table of 7-bit characters, so
there is no glyph for anything else and a caller that drew one would draw a
question mark of its own invention. What that costs is named in
`docs/DRAW.md` section 17.
*/
package libedit

import "core:unicode/utf8"

import "vsys:libkey"

// The three keys, named because `0x17` in a switch is a number somebody has to
// look up. `kernel/devfs` names the same bytes for the same reason.
BACKSPACE :: u8(0x08)
DEL :: u8(0x7F)
KILL :: u8(0x15) // ^U
WORD :: u8(0x17) // ^W

// And the two that move rather than erase, which are `rio`'s `Ksoh` and
// `Kenq` and carry those values there too. The arrows are runes and live in
// `sys/libkey`, beside the rest of what `keyboard.h` names.
HOME :: u8(0x01) // ^A
END :: u8(0x05)  // ^E

// is_erase reports whether a byte edits the line rather than joining it.
is_erase :: proc "contextless" (b: u8) -> bool {
	return b == BACKSPACE || b == DEL || b == KILL || b == WORD
}

// alnum is `rio`'s `isalnum`, for the one place a word's edge is decided.
alnum :: proc "contextless" (b: u8) -> bool {
	return (b >= '0' && b <= '9') || (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z')
}

/*
erase_back is `rio`'s `wbswidth`: how many bytes one erase key removes from the
end of a line.

A character is one. A kill is all of it. A word skips whatever is not a letter
or a digit, then takes the run that is -- so erasing a word from `ls -l foo `
leaves `ls -l `, and again leaves `ls -`.

Answers zero for an empty line and for a byte that is not an erase key, so a
caller may hand it anything.
*/
erase_back :: proc "contextless" (line: []u8, key: u8) -> int #no_bounds_check {
	n := len(line)
	if n == 0 {
		return 0
	}
	switch key {
	case KILL:
		return n
	case WORD:
		q := n
		for q > 0 && !alnum(line[q - 1]) {
			q -= 1
		}
		for q > 0 && alnum(line[q - 1]) {
			q -= 1
		}
		return n - q
	case BACKSPACE, DEL:
		return 1
	}
	return 0
}

/*
What one byte did to a line, so a caller can act on the answer rather than
re-derive it.

`Edited` covers both an inserted character and an erased one, because both
mean the same thing to a program that echoes: draw the line again. `Done` is a
newline and the line is ready. `Full` is a character that did not fit, which
neither caller treats as an error -- the beginning of a command is the part
somebody meant.
*/
Result :: enum {
	Edited,
	Done,
	Full,
	Pending,
}

/*
Line is a fixed buffer, how much of it is in use, and where the cursor is.

The storage is the caller's, because neither caller has an allocator and both
already own static space. `put` never grows it.

`pos` is an index into `buf` and is always between zero and `n`. A caller that
draws reads it to put a caret somewhere. A caller that does not still has a
cursor and cannot show one, so `^A` and `^E` move something its client cannot
see -- which is `rio`'s arrangement, where a program that wants those bytes
literally asks for raw.
*/
Line :: struct {
	buf: []u8,
	n:   int,
	pos: int,

	// The bytes of a rune that has not finished arriving. `put` takes one
	// byte at a time and a rune above `0x7F` is two or three, so the ones
	// already in hand wait here. Never longer than one rune.
	pend:   [utf8.UTF_MAX]u8,
	pend_n: int,
}

/*
put gives one byte to a line and answers what it did.

A newline is not stored. A caller that wants it -- `servers/intuition` does,
because `/dev/cons` always delivered one and a reader stops at it -- appends it
to `text` itself. A caller that draws the line does not.
*/
put :: proc "contextless" (l: ^Line, b: u8) -> Result #no_bounds_check {
	/*
	A rune first, because a byte above `0x7F` is part of one.

	Everything below this deals in ASCII, where a byte and a rune are the same
	number. A sequence that is still arriving waits in `pend`. A whole one is
	either motion or something with no glyph, and neither reaches the buffer.
	*/
	if b > 0x7F || l.pend_n > 0 {
		return put_rune_byte(l, b)
	}

	switch b {
	case HOME:
		l.pos = 0
		return .Edited
	case END:
		l.pos = l.n
		return .Edited
	case '\n':
		return .Done
	}

	/*
	An erase takes what is before the cursor, which is `rio`'s `wdelete` over
	`wbswidth` of the text behind it. At the beginning of a line there is
	nothing behind it, `erase_back` answers zero, and the moves below are all
	empty -- so the case needs no branch of its own.
	*/
	if is_erase(b) {
		d := erase_back(l.buf[:l.pos], b)
		copy(l.buf[l.pos - d:], l.buf[l.pos:l.n])
		l.n -= d
		l.pos -= d
		return .Edited
	}

	if l.n >= len(l.buf) {
		return .Full
	}
	// And a character goes in *at* the cursor, which is `winsert`. Odin's
	// `copy` is documented to allow its two slices to overlap, so opening a
	// byte of room is the same call the erase above closes one with.
	copy(l.buf[l.pos + 1:l.n + 1], l.buf[l.pos:l.n])
	l.buf[l.pos] = b
	l.n += 1
	l.pos += 1
	return .Edited
}

/*
put_rune_byte collects one byte of a rune and acts on it once it is whole.

**A rune that is not motion is dropped**, which is the honest answer while
`sys/libfont` is an 8x16 table of 7-bit characters. Storing one would put bytes
in a line that no caller can draw, and a caller that invented a glyph for it
would be inventing the layout too. `docs/DRAW.md` section 17 owns the cost.

A byte that cannot start or continue a sequence resets the collector and is
dropped with it. That is `chartorune` answering `Runeerror` and moving on: a
stream this cannot read is one to make progress through rather than stall on.
*/
@(private)
put_rune_byte :: proc "contextless" (l: ^Line, b: u8) -> Result #no_bounds_check {
	if l.pend_n >= len(l.pend) {
		// Longer than any rune, so what is held cannot become one.
		l.pend_n = 0
	}
	l.pend[l.pend_n] = b
	l.pend_n += 1

	/*
	`full_rune_in_bytes` answers the whole question, including the one a
	streaming decoder actually needs: it calls an *invalid* lead byte full, so
	a stream that started mid-rune resolves to `RUNE_ERROR` here rather than
	waiting for bytes that will never make it well-formed.
	*/
	if !utf8.full_rune_in_bytes(l.pend[:l.pend_n]) {
		return .Pending
	}
	r, _ := utf8.decode_rune_in_bytes(l.pend[:l.pend_n])
	l.pend_n = 0

	switch r {
	case libkey.KHOME:
		l.pos = 0
		return .Edited
	case libkey.KEND:
		l.pos = l.n
		return .Edited
	case libkey.KLEFT:
		if l.pos > 0 {
			l.pos -= 1
		}
		return .Edited
	case libkey.KRIGHT:
		if l.pos < l.n {
			l.pos += 1
		}
		return .Edited
	}
	// Every other rune, including the ones a keyboard has and this line has no
	// use for. Nothing changed, so nothing has to be drawn again.
	return .Pending
}

// text is the line so far, and clear empties it.
text :: proc "contextless" (l: ^Line) -> string #no_bounds_check {
	return string(l.buf[:l.n])
}

// cursor is where the next character goes, as an index into `text`.
cursor :: proc "contextless" (l: ^Line) -> int {
	return l.pos
}

clear :: proc "contextless" (l: ^Line) {
	l.n = 0
	l.pos = 0
	// And half a rune goes with the line it was arriving into.
	l.pend_n = 0
}
