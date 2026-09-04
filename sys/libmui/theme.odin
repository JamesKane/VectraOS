/*
theme -- the look as data, a file of roles read into a `Theme`.

`docs/WORKBENCH.md` section 5 makes the look a file. A line names a role and
what it is. A metric is a number, and a colour is one of `sys/libpal`'s names
or six hex digits. `parse_theme` reads the text over a copy of `default_theme`. A
file that names nothing is the chassis, and one that names a role changes that
role alone. A `#` starts a comment, and blank lines are skipped, the way
`servers/intuition`'s own rules file reads.

    face        copper          # a raised control, now copper
    ground      slate_deep
    bevel       3

The toolkit and `intuition` read the same file, so a window's frame and the
gadgets inside it are one look. This parser is the toolkit's half. It touches
no file itself: a caller reads the bytes and hands them here, which keeps the
parser testable with a string and no disk.
*/
package libmui

import "vsys:libpal"

/*
parse_theme fills `t` from the lines in `text`. It starts `t` at the default,
so every role the text leaves out keeps the chassis value. An unknown role or
an unreadable value is skipped rather than an error. A newer theme file that
names a role this build does not know still loads.
*/
parse_theme :: proc "contextless" (t: ^Theme, text: string) #no_bounds_check {
	t^ = default_theme
	i := 0
	for i < len(text) {
		// One line, up to the newline or the end.
		start := i
		for i < len(text) && text[i] != '\n' {
			i += 1
		}
		line := text[start:i]
		if i < len(text) {
			i += 1 // Step over the newline.
		}
		apply_line(t, line)
	}
}

// apply_line reads one `role value` line into `t`. A comment or a blank line
// leaves `t` untouched.
apply_line :: proc "contextless" (t: ^Theme, line: string) {
	// Cut a trailing comment.
	body := line
	for k in 0 ..< len(body) {
		if body[k] == '#' {
			body = body[:k]
			break
		}
	}
	role, rest := word(body)
	if role == "" {
		return
	}
	value, _ := word(rest)
	if value == "" {
		return
	}

	// A colour role takes a palette name or six hex digits. A metric role
	// takes a number.
	switch role {
	case "ground":
		set_color(&t.ground, value)
	case "face":
		set_color(&t.face, value)
	case "face.lit":
		set_color(&t.lit, value)
	case "face.shade":
		set_color(&t.shade, value)
	case "text":
		set_color(&t.ink, value)
	case "bevel":
		set_metric(&t.bevel, value)
	case "well":
		set_metric(&t.well, value)
	case "pad":
		set_metric(&t.pad, value)
	case "gap":
		set_metric(&t.gap, value)
	case "hpad":
		set_metric(&t.hpad, value)
	case "vpad":
		set_metric(&t.vpad, value)
	}
	// A role this build does not know is skipped here. `font` and `pointer`
	// are left for the half of the toolkit that reads them.
}

// set_color reads a palette name or six hex digits into `dst`, and leaves it
// alone if it can read neither.
set_color :: proc "contextless" (dst: ^libpal.RGB, value: string) {
	if c, ok := libpal.by_name(value); ok {
		dst^ = c
		return
	}
	if c, ok := hex_rgb(value); ok {
		dst^ = c
	}
}

// set_metric reads a non-negative number into `dst`, and leaves it alone on
// anything else.
set_metric :: proc "contextless" (dst: ^int, value: string) {
	n := 0
	for k in 0 ..< len(value) {
		c := value[k]
		if c < '0' || c > '9' {
			return
		}
		n = n * 10 + int(c - '0')
	}
	if len(value) > 0 {
		dst^ = n
	}
}

// hex_rgb reads exactly six hex digits, `rrggbb`, into a colour.
hex_rgb :: proc "contextless" (value: string) -> (libpal.RGB, bool) {
	if len(value) != 6 {
		return libpal.RGB{}, false
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
			return libpal.RGB{}, false
		}
	}
	return libpal.RGB{
			nibbles[0] << 4 | nibbles[1],
			nibbles[2] << 4 | nibbles[3],
			nibbles[4] << 4 | nibbles[5],
		},
		true
}

// word returns the first run of non-space characters in `s` and the rest of
// `s` after it, skipping the spaces and tabs on either side.
word :: proc "contextless" (s: string) -> (first: string, rest: string) {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r') {
		i += 1
	}
	start := i
	for i < len(s) && s[i] != ' ' && s[i] != '\t' && s[i] != '\r' {
		i += 1
	}
	return s[start:i], s[i:]
}
