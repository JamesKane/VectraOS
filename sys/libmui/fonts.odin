/*
fonts -- the font a label is drawn in.

A label's glyphs go straight into the window's store, `draw.odin`'s `glyphs`, in
the ink over whatever is under them. So there is nothing to bake. The toolkit
once kept an atlas of glyphs per ink and background, because the draw server's
`blit` is opaque. That went with brick 3 of `docs/CHROME.md`.
What stays is the font past ASCII, opened once for the program.
*/
package libmui

import "vsys:abi"
import "vsys:libfont"
import "vsys:libuser"

// text_font is the font past ASCII, shared by every window a program opens.
// `window_open` fills it once from `/lib/font`. Until then, and if the load
// fails, `loader_glyph` still answers ASCII from the baked table, so a label
// draws its ASCII rather than nothing. A `tests/mui` that never opens a window
// draws ASCII alone.
text_font: libfont.Loader

// text_read is the font loader's I/O: the whole of `path` into `into`, or
// zero. `window_open` gives the loader this reader.
text_read :: proc "contextless" (data: rawptr, path: string, into: []u8) -> int {
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

// font_load opens the shared past-ASCII font once. A failure is not fatal: a
// label still draws ASCII from the baked table. `window_open` calls it.
font_load :: proc "contextless" () {
	if !text_font.ready {
		_ = libfont.loader_open(&text_font, "/lib/font/default.font", text_read, nil)
	}
}
