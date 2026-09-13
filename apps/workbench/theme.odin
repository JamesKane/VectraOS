/*
theme -- the look, read from files, `docs/WORKBENCH.md` section 5. The look is
data: `/lib/theme` is the shipped one, `$home/lib/theme` the person's, and the
later line for a role wins. The personal file may start with `use <name>`,
which reads `/lib/themes/<name>` in place of `/lib/theme` and merges the rest
over it. `Workbench > Theme...` writes that line.

`theme_load` reads the two and hands the merged text to `sys/libmui`'s parser,
which starts at the chassis so a role named nowhere keeps the chassis value.
The result is the look every window opened after takes; `theme_apply` also lays
the open windows out again, for a live change. `intuition` reads the same files
for the frame it draws, its own half.
*/
package workbench

import "vsys:abi"
import "vsys:libmui"
import "vsys:libuser"

THEME_MAX :: 2048

@(private = "file") home_buf: [THEME_MAX]u8
@(private = "file") base_buf: [THEME_MAX]u8
@(private = "file") merge_buf: [2 * THEME_MAX]u8
@(private = "file") tpath_buf: [256]u8

// theme_load reads the two files, merges them, and sets the look new windows
// take. It does not lay open windows out; `theme_apply` does that.
theme_load :: proc "contextless" () #no_bounds_check {
	context = wb_ctx
	home := theme_read(home_theme_path(), home_buf[:])

	base_path := "/lib/theme"
	body := home
	if name, rest, ok := theme_use(home); ok {
		base_path = themes_path(name)
		body = rest
	}
	base := theme_read(base_path, base_buf[:])

	// The base first, the personal body after it, so the later line wins. The
	// parser resets to the chassis and applies both in order.
	w := copy(merge_buf[:], base)
	if w < len(merge_buf) {
		merge_buf[w] = '\n';w += 1
	}
	w += copy(merge_buf[w:], body)
	t: libmui.Theme
	libmui.parse_theme(&t, string(merge_buf[:w]))
	libmui.set_theme(t)
}

// theme_read reads a whole file into `buf` and answers the bytes, or nothing
// when it will not open.
@(private = "file")
theme_read :: proc "contextless" (path: string, buf: []u8) -> []u8 {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return buf[:0]
	}
	n := libuser.read(int(fd), buf)
	_ = libuser.close(int(fd))
	return buf[:max(int(n), 0)]
}

// theme_use reads a leading `use <name>` line: the base name and the rest of
// the file after that line. False when the first non-blank line is not `use`.
@(private = "file")
theme_use :: proc "contextless" (text: []u8) -> (name: string, rest: []u8, ok: bool) #no_bounds_check {
	// The first line, and where the next begins.
	e := 0
	for e < len(text) && text[e] != '\n' {e += 1}
	line := text[:e]
	next := e < len(text) ? e + 1 : e
	// `use` then a name.
	verb, after := theme_word(string(line))
	if verb != "use" {
		return "", text, false
	}
	nm, _ := theme_word(after)
	if nm == "" {
		return "", text, false
	}
	return nm, text[next:], true
}

// theme_word returns the first run of non-space in `s` and the rest after it.
@(private = "file")
theme_word :: proc "contextless" (s: string) -> (first: string, rest: string) #no_bounds_check {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r') {i += 1}
	start := i
	for i < len(s) && s[i] != ' ' && s[i] != '\t' && s[i] != '\r' {i += 1}
	return s[start:i], s[i:]
}

// home_theme_path is `$home/lib/theme`.
@(private = "file")
home_theme_path :: proc "contextless" () -> string {
	n := copy(tpath_buf[:], home_path())
	n += copy(tpath_buf[n:], "/lib/theme")
	return string(tpath_buf[:n])
}

// themes_path is `/lib/themes/<name>`, in the same buffer.
@(private = "file")
themes_path :: proc "contextless" (name: string) -> string {
	n := copy(tpath_buf[:], "/lib/themes/")
	n += copy(tpath_buf[n:], name)
	return string(tpath_buf[:n])
}
