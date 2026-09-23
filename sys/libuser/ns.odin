/*
The namespace as a file, `docs/FLEET.md` step 3.

`newns` reads a file of the same `bind` and `mount` lines that `ns` (`/proc/n/
ns`) prints and replays them, so the namespace a process starts in is data, not
code. `$cputype` and any other `#e` variable in a path is expanded first, which
is how `/$cputype/bin` in `/lib/namespace` becomes this machine's own tools.
Plan 9's `newns`, the call `login` and `cpu` build a fresh world with.

A line is `[bind|mount] [-a|-b|-c|-r] source target`; a `#` line and a blank
one are skipped. `-a` binds after what is there, `-b` before, `-r` makes the
bind read-only, and `-c` is accepted and does nothing yet, the way `bind`(1)
has it.
*/
package libuser

import "vsys:abi"

// getenv reads `/env/<name>` into `buf` and answers the value, or "" when the
// variable is unset. The environment is `#e`, a file per variable.
getenv :: proc "contextless" (name: string, buf: []u8) -> string #no_bounds_check {
	path: [96]u8
	n := copy(path[:], "/env/")
	n += copy(path[n:], name)
	fd := open(string(path[:n]), abi.O_RDONLY)
	if fd < 0 {
		return ""
	}
	got := read(int(fd), buf)
	_ = close(int(fd))
	if got <= 0 {
		return ""
	}
	return string(buf[:got])
}

/*
newns replays the namespace file at `path`: every `bind`/`mount` line applied
in order, `#` and blank lines skipped, `$var` expanded from `#e`. Answers false
when the file will not open or a line's bind or mount failed, so a caller can
tell a rebuilt world from a broken one.
*/
newns :: proc "contextless" (path: string) -> bool #no_bounds_check {
	fd := open(path, abi.O_RDONLY)
	if fd < 0 {
		return false
	}
	r: Reader
	reader_init(&r, int(fd))
	ok := true
	for {
		line, more := read_line(&r)
		if !more {
			break
		}
		if !ns_apply(line) {
			ok = false
		}
	}
	_ = close(int(fd))
	return ok
}

// ns_apply parses and runs one namespace line. A comment or a blank line is a
// success that does nothing.
@(private = "file")
ns_apply :: proc "contextless" (line: string) -> bool #no_bounds_check {
	verb, rest := ns_word(line)
	if verb == "" || verb[0] == '#' {
		return true
	}
	if verb != "bind" && verb != "mount" {
		return false
	}
	order := abi.ORDER_REPLACE
	readonly := u64(0)
	src: string
	// The flags, then the two names.
	for {
		src, rest = ns_word(rest)
		if len(src) >= 2 && src[0] == '-' {
			switch src[1] {
			case 'a':
				order = abi.ORDER_AFTER
			case 'b':
				order = abi.ORDER_BEFORE
			case 'c':
			// Accepted, and nothing yet -- `bind`(1) says the same.
			case 'r':
				readonly = abi.ORDER_READONLY
			}
			continue
		}
		break
	}
	dst, _ := ns_word(rest)
	if src == "" || dst == "" {
		return false
	}
	sbuf, dbuf: [256]u8
	source := ns_expand(src, sbuf[:])
	target := ns_expand(dst, dbuf[:])
	r := verb == "mount" ? mount(source, target, order) : bind(source, target, order | readonly)
	return r >= 0
}

/*
ns_target answers the target of one namespace line, `$var` expanded into
`buf`, or "" for a comment, a blank line, or a line that is not a `bind` or
a `mount`. The ghost's sandbox keeps the names its class file binds and
unmounts the rest, `docs/GHOST.md` section 4, and this is how it reads a
class file's names the way `newns` applied them.
*/
ns_target :: proc "contextless" (line: string, buf: []u8) -> string #no_bounds_check {
	verb, rest := ns_word(line)
	if verb != "bind" && verb != "mount" {
		return ""
	}
	src: string
	for {
		src, rest = ns_word(rest)
		if len(src) < 2 || src[0] != '-' {
			break
		}
	}
	dst, _ := ns_word(rest)
	if src == "" || dst == "" {
		return ""
	}
	return ns_expand(dst, buf)
}

// ns_word takes the first run of non-space off `s` and answers it and the
// rest, skipping the spaces and tabs on either side.
@(private = "file")
ns_word :: proc "contextless" (s: string) -> (first: string, rest: string) #no_bounds_check {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r') {i += 1}
	start := i
	for i < len(s) && s[i] != ' ' && s[i] != '\t' && s[i] != '\r' {i += 1}
	return s[start:i], s[i:]
}

// ns_expand copies `w` into `buf`, replacing each `$name` with the `#e`
// variable's value. A `$` with no name after it is a literal `$`.
@(private = "file")
ns_expand :: proc "contextless" (w: string, buf: []u8) -> string #no_bounds_check {
	n := 0
	i := 0
	for i < len(w) {
		if w[i] == '$' {
			j := i + 1
			for j < len(w) && ns_is_name(w[j]) {j += 1}
			if j == i + 1 {
				buf[n] = '$';n += 1;i += 1
				continue
			}
			vbuf: [96]u8
			val := getenv(w[i + 1:j], vbuf[:])
			n += copy(buf[n:], val)
			i = j
		} else {
			buf[n] = w[i];n += 1;i += 1
		}
	}
	return string(buf[:n])
}

@(private = "file")
ns_is_name :: proc "contextless" (c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}
