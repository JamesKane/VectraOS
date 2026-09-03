// cleanname -- a path with its `.`, `..` and doubled slashes resolved,
// lexically. -d dir makes a relative name absolute under dir first.
package cleanname

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	dir := ""
	if len(args) > 1 && args[0] == "-d" {
		dir = args[1]
		args = args[2:]
	}
	out: libuser.Bio
	libuser.bio_init(&out, 1)
	for name in args {
		path := name
		if len(dir) > 0 && (len(path) == 0 || path[0] != '/') {
			joined := make([]u8, len(dir) + 1 + len(path))
			copy(joined, dir)
			joined[len(dir)] = '/'
			copy(joined[len(dir) + 1:], path)
			path = string(joined)
		}
		libuser.bio_puts(&out, clean(path))
		libuser.bio_putc(&out, '\n')
	}
	libuser.bio_flush(&out)
	libuser.exits("")
}

// clean is Plan 9's cleanname(2): elements `.` vanish, `..` removes the
// element before it or stays at the front of a relative name, and the
// result never ends in a slash unless it is the root.
clean :: proc(path: string) -> string {
	rooted := len(path) > 0 && path[0] == '/'
	parts := make([dynamic]string)
	start_at := 0
	for i in 0 ..= len(path) {
		if i == len(path) || path[i] == '/' {
			part := path[start_at:i]
			start_at = i + 1
			switch {
			case len(part) == 0 || part == ".":
			case part == "..":
				if len(parts) > 0 && parts[len(parts) - 1] != ".." {
					pop(&parts)
				} else if !rooted {
					append(&parts, part)
				}
			case:
				append(&parts, part)
			}
		}
	}
	if len(parts) == 0 {
		return rooted ? "/" : "."
	}
	total := 0
	for p in parts {
		total += len(p) + 1
	}
	out := make([]u8, total)
	n := 0
	for p, i in parts {
		if i > 0 || rooted {
			out[n] = '/'
			n += 1
		}
		copy(out[n:], p)
		n += len(p)
	}
	return string(out[:n])
}
