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
	end := len(path)
	for end > 1 && path[end - 1] == '/' {
		end -= 1
	}
	start_at := 0
	for i in 0 ..< end {
		if path[i] == '/' {
			start_at = i + 1
		}
	}
	out := path[start_at:end]
	if dir {
		out = start_at <= 1 ? (start_at == 1 ? "/" : ".") : path[:start_at - 1]
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
