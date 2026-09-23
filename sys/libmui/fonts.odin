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

/*
The look's four faces, `docs/CHROME.md` section 5, one a role:

    chrome      title bars, menu titles, group legends, buttons
    interface   labels, and the text a person reads in the chrome
    readout     LCDs and dock tiles, and nowhere else
    namespace   paths, file contents, key equivalents, status lines

The theme names a `.face` file per role, `font.interface /lib/font/...`, and
may set a role in capitals with tracking between letters. A role the theme
names nothing for draws in the 8x16 cells. A list, a field and an icon's name
draw in the cells too, because their layout counts cells. A later brick moves
them to the faces.
*/
Face_Role :: enum u8 {
	Chrome,
	Interface,
	Readout,
	Namespace,
}

FACE_ROLES :: [Face_Role]string {
	.Chrome    = "font.chrome",
	.Interface = "font.interface",
	.Readout   = "font.readout",
	.Namespace = "font.namespace",
}

FACE_PATH :: 64

// What a theme says of one role: the file, the tracking in pixels, and
// whether the role is set in capitals.
Face_Spec :: struct {
	path:  [FACE_PATH]u8,
	n:     int,
	track: int,
	caps:  bool,
}

// The faces a program loads, by path, so two windows and a reload of an
// unchanged theme read each file once. A file's bytes live on the heap for the
// program's life: a face is small, and a program has few.
MAX_LOADED_FACES :: 8
FACE_FILE_MAX :: 96 * 1024

@(private = "file")
Loaded_Face :: struct {
	path: [FACE_PATH]u8,
	n:    int,
	face: libfont.Face,
}

@(private = "file")
loaded: [MAX_LOADED_FACES]Loaded_Face

@(private = "file")
loaded_n: int

/*
face_of is the face a theme names for a role, loaded on first use. It is nil
when the theme names none or the file will not read. A nil face is the 8x16 cells,
so a missing file costs the look and never a label.
*/
face_of :: proc "contextless" (t: ^Theme, role: Face_Role) -> ^libfont.Face #no_bounds_check {
	spec := &t.faces[role]
	if spec.n == 0 {
		return nil
	}
	path := string(spec.path[:spec.n])
	for i in 0 ..< loaded_n {
		if string(loaded[i].path[:loaded[i].n]) == path {
			return loaded[i].face.ready ? &loaded[i].face : nil
		}
	}
	if loaded_n >= MAX_LOADED_FACES {
		return nil
	}
	slot := &loaded[loaded_n]
	loaded_n += 1
	slot.n = copy(slot.path[:], path)
	scratch := libuser.heap_alloc(FACE_FILE_MAX)
	if scratch == nil {
		return nil
	}
	got := text_read(nil, path, ([^]u8)(scratch)[:FACE_FILE_MAX])
	if got <= 0 || got >= FACE_FILE_MAX {
		libuser.heap_free(scratch)
		return nil
	}
	keep := libuser.heap_alloc(got)
	if keep == nil {
		libuser.heap_free(scratch)
		return nil
	}
	data := ([^]u8)(keep)[:got]
	copy(data, ([^]u8)(scratch)[:got])
	libuser.heap_free(scratch)
	if !libfont.face_open(&slot.face, data) {
		return nil
	}
	return &slot.face
}

// text_width is how wide a string draws in a role's face, or in cells when
// the role has none.
text_width :: proc "contextless" (t: ^Theme, role: Face_Role, s: string) -> int {
	if f := face_of(t, role); f != nil {
		spec := &t.faces[role]
		return libfont.face_width(f, s, spec.track, spec.caps)
	}
	return rune_len(s) * FONT_W
}

// text_height is a role's line, or a cell's.
text_height :: proc "contextless" (t: ^Theme, role: Face_Role) -> int {
	if f := face_of(t, role); f != nil {
		return f.height
	}
	return FONT_H
}
