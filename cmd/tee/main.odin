// tee -- copy standard input to standard output and to each file. -a
// appends.
package tee

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	appending := false
	if len(args) > 0 && args[0] == "-a" {
		appending = true
		args = args[1:]
	}
	fds := make([dynamic]int)
	append(&fds, 1)
	status := ""
	for name in args {
		fd := appending ? libuser.open_append(name) : libuser.open_or_create(name, abi.O_WRONLY)
		if fd < 0 {
			libuser.eprint("tee: can't open ", name, ": ", libuser.errstr(fd), "\n")
			status = "can't open"
			continue
		}
		append(&fds, int(fd))
	}
	buf: [8192]u8
	for {
		n := libuser.read(0, buf[:])
		if n <= 0 {
			break
		}
		for fd in fds {
			libuser.write_full(fd, buf[:n])
		}
	}
	libuser.exits(status)
}
