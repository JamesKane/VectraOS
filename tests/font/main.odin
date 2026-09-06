/*
fonttest -- the font past ASCII, read at run time and proven.

The kernel's self-test spawns this and reads the word it exits with: `ok`, or
the name of the first check that did not hold. `sys/libfont` bakes ASCII and
reads everything past it from `/lib/font`; this opens that index the way the
draw server and the kernel console do, and checks the loader answers the
runes the file promises and refuses the ones it does not. A cell that should
have ink is required to have some, so a subfont of blanks would fail.
*/
package fonttest

import "vsys:abi"
import "vsys:libfont"
import "vsys:libuser"

fail :: proc "contextless" (what: string) -> ! {
	libuser.exits(what)
}

want :: proc "contextless" (cond: bool, what: string) {
	if !cond {
		fail(what)
	}
}

// read_file is the loader's I/O: the whole of `path` into `into`, or zero.
read_file :: proc "contextless" (data: rawptr, path: string, into: []u8) -> int {
	_ = data
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return 0
	}
	at := 0
	for at < len(into) {
		n := libuser.read(int(fd), into[at:])
		if n <= 0 {
			break
		}
		at += int(n)
	}
	_ = libuser.close(int(fd))
	return at
}

// inked reports whether a cell has any lit pixel: an accented letter or an
// arrow must, so a blank one is a subfont that did not load.
inked :: proc "contextless" (cell: []u8, h: int) -> bool {
	for y in 0 ..< h {
		if cell[y] != 0 {
			return true
		}
	}
	return false
}

// A `Loader` is tens of kilobytes -- its subfont cache -- so it lives here,
// not on the stack a fault would find first.
loader: libfont.Loader

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()

	l := &loader
	want(libfont.loader_open(l, "/lib/font/default.font", read_file, nil), "the .font index opens")
	want(loader.idx.height == libfont.FONT_HEIGHT, "its height is the cell height")
	want(loader.idx.n >= 2, "it names at least two ranges past ASCII")

	cell: [libfont.FONT_HEIGHT]u8

	// ASCII comes from the baked table, through the same call.
	w, ok := libfont.loader_glyph(l, 'A', cell[:])
	want(ok && w == libfont.FONT_WIDTH, "an ASCII glyph is the baked one")
	want(inked(cell[:], libfont.FONT_HEIGHT), "and it has ink")

	// A Latin-1 letter: past ASCII, loaded from a subfont, and inked.
	w, ok = libfont.loader_glyph(l, 0xE9, cell[:]) // 'é'
	want(ok && w == libfont.FONT_WIDTH, "a Latin-1 glyph loads from a subfont")
	want(inked(cell[:], libfont.FONT_HEIGHT), "and the accented letter has ink")

	// An arrow, from a second subfont: the loader holds more than one at once.
	w, ok = libfont.loader_glyph(l, 0x2192, cell[:]) // '→' rightwards arrow
	want(ok, "an arrow loads from another subfont")
	want(inked(cell[:], libfont.FONT_HEIGHT), "and the arrow has ink")

	// The first Latin-1 letter still answers after the arrow evicted nothing:
	// two subfonts fit at once, so this is a cache hit, not a reload of a lost
	// one. Correctness either way; it exercises the second range and back.
	_, ok = libfont.loader_glyph(l, 0xF1, cell[:]) // 'ñ'
	want(ok && inked(cell[:], libfont.FONT_HEIGHT), "another Latin-1 letter has ink")

	// A rune no range holds is refused, not drawn as a stray cell.
	_, ok = libfont.loader_glyph(l, 0x4E00, cell[:]) // a CJK ideograph, uncovered
	want(!ok, "a rune no range holds is refused")

	libuser.exits("ok")
}
