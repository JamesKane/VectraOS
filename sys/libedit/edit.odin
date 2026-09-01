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

**There is a cursor, and the arrow keys are not what moves it.** In Plan 9 an
arrow is a *rune* in the private Unicode space -- `Kleft` is `KF|0x11`, which
is U+F011 and three bytes of UTF-8 -- and there is no rune anywhere in this
tree. `kernel/drivers/kbd` consumes the `0xE0` prefix and drops the key on
purpose, because an extended code shares its second byte with a letter.

`rio` moves by a whole line with two ordinary control bytes, and those work
here exactly as they do there:

    ^A          to the beginning of the line
    ^E          to the end of it

A character is inserted *at* the cursor and an erase takes what is before it,
which is `winsert` and `wdelete` in one line's worth of buffer. Moving by a
single character is what still wants the arrows, and the arrows want runes.
*/
package libedit

// The three keys, named because `0x17` in a switch is a number somebody has to
// look up. `kernel/devfs` names the same bytes for the same reason.
BACKSPACE :: u8(0x08)
DEL :: u8(0x7F)
KILL :: u8(0x15) // ^U
WORD :: u8(0x17) // ^W

// And the two that move rather than erase, which are `rio`'s `Ksoh` and
// `Kenq` and carry those values there too.
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
}

/*
put gives one byte to a line and answers what it did.

A newline is not stored. A caller that wants it -- `servers/intuition` does,
because `/dev/cons` always delivered one and a reader stops at it -- appends it
to `text` itself. A caller that draws the line does not.
*/
put :: proc "contextless" (l: ^Line, b: u8) -> Result #no_bounds_check {
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
}
