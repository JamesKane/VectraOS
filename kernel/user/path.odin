/*
Paths a program names, made absolute.

Every path a program hands the kernel was absolute until `docs/SHELL.md`
step 1. A shell has a current directory, so a program has one too: a string
in its record, `/` at first, changed by `chdir` and inherited by what it
forks and spawns. A path that does not begin with `/` or `#` is joined to
it here, and the result is cleaned the way Plan 9's `cleanname` cleans one:
`.` goes, `..` takes the element before it, and runs of `/` are one.

A string rather than a chan, which is where Plan 9 keeps `dot`. A chan
would follow the directory through a `bind` made after the `chdir`; a
string follows the name. The difference shows only when a program changes
directory into a mount point and then rearranges its namespace above it,
and a shell that does that gets the name it typed, which is what a person
expects to see in `pwd`.
*/
package user

import "vsys:vectra9"

/*
copy_path copies a path in from a program and makes it absolute.

`buf` is the caller's, and the answer points into it. The relative form is
joined to the process's current directory first, so a path that was
`PATH_MAX` long and relative is refused rather than truncated: the whole
name has to fit, because the walker sees the whole name.
*/
@(private)
copy_path :: proc "contextless" (p: ^Process, addr: uintptr, length: int, buf: []u8) -> (path: string, err: vectra9.Errno) {
	raw: [PATH_MAX]u8
	if length <= 0 || length > PATH_MAX || !copy_in(addr, length, raw[:]) {
		return "", vectra9.EFAULT
	}
	return make_absolute(p, string(raw[:length]), buf)
}

// make_absolute joins a relative path to the current directory and cleans
// it. An absolute path or a device path is cleaned and nothing more.
@(private)
make_absolute :: proc "contextless" (p: ^Process, path: string, buf: []u8) -> (string, vectra9.Errno) {
	if path[0] == '#' {
		if len(path) > len(buf) {
			return "", vectra9.ENAMETOOLONG
		}
		for i in 0 ..< len(path) {
			buf[i] = path[i]
		}
		return string(buf[:len(path)]), vectra9.Errno(0)
	}

	joined: [2 * PATH_MAX + 1]u8
	n := 0
	if path[0] != '/' && p != nil {
		cwd := current_directory(p)
		for i in 0 ..< len(cwd) {
			joined[n] = cwd[i]
			n += 1
		}
		joined[n] = '/'
		n += 1
	}
	for i in 0 ..< len(path) {
		joined[n] = path[i]
		n += 1
	}
	return cleanname(string(joined[:n]), buf)
}

/*
cleanname rewrites a path into its shortest equivalent, into `buf`.

Plan 9's rules: every `.` element goes, every `..` removes the element before
it and is itself dropped at the root, and any run of slashes is one. The
answer always begins with `/` and never ends with one, except when it is
the root itself.
*/
@(private)
cleanname :: proc "contextless" (path: string, buf: []u8) -> (string, vectra9.Errno) {
	n := 0
	i := 0
	for i < len(path) {
		// Skip slashes to the start of an element.
		for i < len(path) && path[i] == '/' {
			i += 1
		}
		if i >= len(path) {
			break
		}
		start := i
		for i < len(path) && path[i] != '/' {
			i += 1
		}
		element := path[start:i]
		switch element {
		case ".":
			continue
		case "..":
			// Back to the slash before the last element, or to nothing.
			for n > 0 {
				n -= 1
				if buf[n] == '/' {
					break
				}
			}
			continue
		}
		if n + 1 + len(element) > len(buf) {
			return "", vectra9.ENAMETOOLONG
		}
		buf[n] = '/'
		n += 1
		for k in 0 ..< len(element) {
			buf[n] = element[k]
			n += 1
		}
	}
	if n == 0 {
		if len(buf) == 0 {
			return "", vectra9.ENAMETOOLONG
		}
		buf[0] = '/'
		n = 1
	}
	return string(buf[:n]), vectra9.Errno(0)
}

// current_directory is the process's directory as a string, `/` for a
// process that never changed it.
@(private)
current_directory :: proc "contextless" (p: ^Process) -> string {
	if p.cwd_len == 0 {
		return "/"
	}
	return string(p.cwd_buf[:p.cwd_len])
}

// set_directory records a cleaned absolute path as the current directory.
@(private)
set_directory :: proc "contextless" (p: ^Process, path: string) -> bool {
	if len(path) > PATH_MAX {
		return false
	}
	for i in 0 ..< len(path) {
		p.cwd_buf[i] = path[i]
	}
	p.cwd_len = len(path)
	return true
}
