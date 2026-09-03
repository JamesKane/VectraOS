// basename -- the last element of a path; -d prints the directory part.
package basename

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	dir := false
	if len(args) > 0 && args[0] == "-d" {
		dir = true
		args = args[1:]
	}
	if len(args) < 1 {
		libuser.eprint("usage: basename [-d] path [suffix]\n")
		libuser.exits("usage")
	}
	path := args[0]
	out := libuser.basename(path)
	if dir {
		// The directory part: what is left before the last element, `/`
		// for a name at the root and `.` for a bare one.
		end := len(path) - len(out)
		for end > 1 && path[end - 1] == '/' {
			end -= 1
		}
		out = end == 0 ? "." : path[:end]
	} else if len(args) > 1 {
		suffix := args[1]
		if len(suffix) < len(out) && out[len(out) - len(suffix):] == suffix {
			out = out[:len(out) - len(suffix)]
		}
	}
	libuser.write_full(1, transmute([]u8)out)
	libuser.write_full(1, []u8{'\n'})
	libuser.exits("")
}
