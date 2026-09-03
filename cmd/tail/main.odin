// tail -- the last lines of a file. `-n N` is the last N (ten without it),
// `+N` is from line N on. One file, or standard input.
package tail

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	last: i64 = 10
	from: i64 = 0
	for len(args) > 0 && len(args[0]) > 0 && (args[0][0] == '-' || args[0][0] == '+') {
		if args[0] == "-n" && len(args) > 1 {
			if v, ok := libuser.atoi(args[1]); ok {
				last = v
			}
			args = args[2:]
			continue
		}
		if v, ok := libuser.atoi(args[0]); ok {
			if args[0][0] == '+' {
				from = v
			} else {
				last = -v
			}
			args = args[1:]
			continue
		}
		break
	}
	fd := 0
	if len(args) > 0 {
		f := libuser.open(args[0], abi.O_RDONLY)
		if f < 0 {
			libuser.eprint("tail: can't open ", args[0], ": ", libuser.errstr(f), "\n")
			libuser.exits("can't open")
		}
		fd = int(f)
	}
	data, ok := libuser.read_all(fd, context.allocator)
	if !ok {
		libuser.exits("read error")
	}
	// Line starts, so either mode is a slice of the data.
	starts := make([dynamic]int)
	append(&starts, 0)
	for c, i in data {
		if c == '\n' && i + 1 < len(data) {
			append(&starts, i + 1)
		}
	}
	if len(data) == 0 {
		libuser.exits("")
	}
	first := 0
	if from > 0 {
		first = int(from) - 1
	} else if int(last) < len(starts) {
		first = len(starts) - int(last)
	}
	if first >= len(starts) {
		libuser.exits("")
	}
	libuser.write_full(1, data[starts[first]:])
	libuser.exits("")
}
