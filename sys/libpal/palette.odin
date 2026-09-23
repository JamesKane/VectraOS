/*
The Vectra system palette -- "Cyberpunk Workstation 1994".

**One table, both privilege levels.** It lived in `kernel/drivers/fb`, and
promised there that `intuition` would expose the same table. The boot splash,
the panic screen and the desktop are meant to be visibly the same machine.
Three things had their own copy by the time a desktop existed. This is that
promise kept instead of restated.

The kernel reads these through `fb`, which aliases every name here and adds
the surface painters. Ring 3 reads them through `xrgb`. A program drawing
through `/srv/draw` speaks in packed pixel words, and the one format that
server accepts is 32 bits per pixel.

Surfaces are brushed dark magnesium over deep slate. Accents are the three
phosphor colours a CRT of that era could actually make bloom.
*/
package libpal

RGB :: [3]u8

// -- Structural surfaces -----------------------------------------------------

VOID :: RGB{0x07, 0x09, 0x0C} // Behind everything; true backdrop
SLATE_DEEP :: RGB{0x0E, 0x13, 0x1A} // Desktop ground
SLATE :: RGB{0x18, 0x1F, 0x28} // Recessed wells, sunken panels
MAGNESIUM_DARK :: RGB{0x22, 0x2A, 0x34} // Bevel shadow edge
MAGNESIUM :: RGB{0x3C, 0x45, 0x51} // Face of a raised control
MAGNESIUM_LIT :: RGB{0x60, 0x6C, 0x7A} // Bevel highlight edge
MAGNESIUM_HOT :: RGB{0x84, 0x92, 0xA2} // Specular top edge on tall bevels

// -- Copper trim -------------------------------------------------------------

COPPER_DARK :: RGB{0x5E, 0x33, 0x16}
COPPER :: RGB{0xB4, 0x6C, 0x32}
COPPER_LIT :: RGB{0xE6, 0xA6, 0x62}

// -- Phosphor accents --------------------------------------------------------

AMBER :: RGB{0xFF, 0xB0, 0x28} // Primary text; the terminal's own colour
AMBER_DIM :: RGB{0x8A, 0x5C, 0x14} // Inactive labels, embossed shadow
AMBER_HOT :: RGB{0xFF, 0xDC, 0x9A} // Highlighted / focused text

CYAN :: RGB{0x38, 0xE0, 0xE8} // Data, values, links
CYAN_DIM :: RGB{0x1A, 0x6E, 0x74}

PHOSPHOR :: RGB{0x6C, 0xFF, 0x8A} // Healthy status, "OK"
PHOSPHOR_DIM :: RGB{0x2C, 0x74, 0x3C}

ALERT :: RGB{0xF2, 0x46, 0x3A} // Faults, panics
ALERT_DIM :: RGB{0x7A, 0x1E, 0x18}

/*
xrgb packs one colour into the pixel word ring 3 draws with.

The kernel packs against a `Surface`, reading the channel shifts the bootloader
actually set. It will draw on a 16-bit mode if handed one. Ring 3 has no such
freedom. `/srv/draw` refuses any depth but 32 at start, and `libdraw`'s
command stream carries pixels as `u32`. So the layout is a constant here rather
than a question.
*/
xrgb :: proc "contextless" (c: RGB) -> u32 {
	return u32(c[0]) << 16 | u32(c[1]) << 8 | u32(c[2])
}

/*
**`xrgb` is a procedure, so it cannot be the right-hand side of a constant.**
A program may want a colour as a constant, because it declares one at package
scope the way `apps/terminal` declares its two. It writes the shift out against
the table:

    FG :: u32(libpal.AMBER[0]) << 16 | u32(libpal.AMBER[1]) << 8 | u32(libpal.AMBER[2])

Indexing a constant array is itself a constant, so that folds at compile time
and calls nothing. It is longer than a call and it is the only way to have a
constant. The shape is written down here rather than rediscovered at each call
site.
*/

/*
mix blends two colours, `t` of the way from the first to the second.

A dim indicator is its own colour most of the way to `VOID`. A lit one is its
own colour a little of the way to `AMBER_HOT`. Both are this, and the kernel's
chassis drew them this way before there was a ring 3 to share it with.
*/
mix :: proc "contextless" (a: RGB, b: RGB, t: u8) -> RGB {
	blend :: proc "contextless" (x: u8, y: u8, t: u8) -> u8 {
		return u8((u32(x) * u32(255 - t) + u32(y) * u32(t)) / 255)
	}
	return RGB{blend(a[0], b[0], t), blend(a[1], b[1], t), blend(a[2], b[2], t)}
}

/*
shade lightens or darkens one colour, which is how a bevel gets its two edges
out of one face.

Saturating at both ends rather than wrapping. A face already near white has a
highlight that is white, which is what a real specular edge does.
*/
shade :: proc "contextless" (c: RGB, amount: i16) -> RGB {
	adjust :: proc "contextless" (v: u8, by: i16) -> u8 {
		n := i16(v) + by
		return u8(clamp(n, 0, 255))
	}
	return RGB{adjust(c[0], amount), adjust(c[1], amount), adjust(c[2], amount)}
}

/*
by_name resolves one of the palette's own names, lower case with an underscore
where the constant has one, to its colour. It is how a theme file names a role's
colour in words, as `docs/WORKBENCH.md` section 5 has it. A name the table does
not carry answers `false`, which a caller reads as "try six hex digits instead".
*/
by_name :: proc "contextless" (name: string) -> (RGB, bool) {
	switch name {
	case "void":
		return VOID, true
	case "slate_deep":
		return SLATE_DEEP, true
	case "slate":
		return SLATE, true
	case "magnesium_dark":
		return MAGNESIUM_DARK, true
	case "magnesium":
		return MAGNESIUM, true
	case "magnesium_lit":
		return MAGNESIUM_LIT, true
	case "magnesium_hot":
		return MAGNESIUM_HOT, true
	case "copper_dark":
		return COPPER_DARK, true
	case "copper":
		return COPPER, true
	case "copper_lit":
		return COPPER_LIT, true
	case "amber":
		return AMBER, true
	case "amber_dim":
		return AMBER_DIM, true
	case "amber_hot":
		return AMBER_HOT, true
	case "cyan":
		return CYAN, true
	case "cyan_dim":
		return CYAN_DIM, true
	case "phosphor":
		return PHOSPHOR, true
	case "phosphor_dim":
		return PHOSPHOR_DIM, true
	case "alert":
		return ALERT, true
	case "alert_dim":
		return ALERT_DIM, true
	}
	return RGB{}, false
}

/*
parse_color reads a theme file's way of naming a colour: one of the palette's
own names, or six hex digits `rrggbb`. It is `by_name` with the hex fallback
that name's doc-comment promises a caller would try next, in one call, so every
theme reader -- `sys/libmui`'s for a gadget, `servers/intuition`'s for the
frame -- resolves a colour by the same grammar rather than each carrying its
own copy of it. A value that is neither answers `false`.
*/
parse_color :: proc "contextless" (value: string) -> (RGB, bool) {
	if c, ok := by_name(value); ok {
		return c, true
	}
	return hex_rgb(value)
}

// hex_rgb reads exactly six hex digits, `rrggbb`, into a colour, or answers
// `false`. The digit form `parse_color` falls back to.
hex_rgb :: proc "contextless" (value: string) -> (RGB, bool) {
	if len(value) != 6 {
		return RGB{}, false
	}
	nibbles: [6]u8
	for k in 0 ..< 6 {
		c := value[k]
		switch {
		case c >= '0' && c <= '9':
			nibbles[k] = c - '0'
		case c >= 'a' && c <= 'f':
			nibbles[k] = c - 'a' + 10
		case c >= 'A' && c <= 'F':
			nibbles[k] = c - 'A' + 10
		case:
			return RGB{}, false
		}
	}
	return RGB{nibbles[0] << 4 | nibbles[1], nibbles[2] << 4 | nibbles[3], nibbles[4] << 4 | nibbles[5]}, true
}

/*
Colours is a theme's own names for colours, `docs/CHROME.md` section 3. A
theme file may define one with a line

    colour mag  ff2bd6

and name it after that wherever a role takes a colour. A scheme is a file of
these lines, so a change of scheme changes every colour and moves no role.

Each theme reader holds a table of its own and empties it before a read, so
two readers never share one. A name the table holds wins over the palette's
own, which is how a scheme's `amber` is its own hue and not this table's.
*/
MAX_COLOURS :: 40
COLOUR_NAME :: 16

Colours :: struct {
	names:  [MAX_COLOURS][COLOUR_NAME]u8,
	lens:   [MAX_COLOURS]u8,
	values: [MAX_COLOURS]RGB,
	n:      int,
}

// colours_define adds a name, or replaces the colour a name already has, so
// a later line wins as it does for a role. The value is read by
// `colours_parse`, so a name may be defined in terms of another. False for a
// name too long, a full table, or a value that is not a colour.
colours_define :: proc "contextless" (t: ^Colours, name: string, value: string) -> bool #no_bounds_check {
	if len(name) == 0 || len(name) > COLOUR_NAME {
		return false
	}
	c, ok := colours_parse(t, value)
	if !ok {
		return false
	}
	for i in 0 ..< t.n {
		if string(t.names[i][:t.lens[i]]) == name {
			t.values[i] = c
			return true
		}
	}
	if t.n >= MAX_COLOURS {
		return false
	}
	copy(t.names[t.n][:], name)
	t.lens[t.n] = u8(len(name))
	t.values[t.n] = c
	t.n += 1
	return true
}

// colours_parse reads a colour the way `parse_color` does, with the table's
// names first. A nil table is `parse_color`.
colours_parse :: proc "contextless" (t: ^Colours, value: string) -> (RGB, bool) #no_bounds_check {
	if t != nil {
		for i in 0 ..< t.n {
			if string(t.names[i][:t.lens[i]]) == value {
				return t.values[i], true
			}
		}
	}
	return parse_color(value)
}
