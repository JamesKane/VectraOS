// cat -- copy each named file, or descriptor 0, to descriptor 1.
package cat

import "vsys:abi"
import "vsys:libfmt"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	if len(args) > 0 {
		args = args[1:]
	}
	status := ""
	if len(args) == 0 {
		if !copy_fd(0) {
			status = "read error"
		}
	}
	for name in args {
		fd := libuser.open(name, abi.O_RDONLY)
		if fd < 0 {
			libfmt.fprint(2, "cat: can't open %s: %s\n", name, libuser.errstr(fd))
			status = "can't open"
			continue
		}
		if !copy_fd(int(fd)) {
			status = "read error"
		}
		libuser.close(int(fd))
	}
	libuser.exits(status)
}

copy_fd :: proc(fd: int) -> bool {
	buf: [4096]u8
	for {
		n := libuser.read(fd, buf[:])
		if n < 0 {
			return false
		}
		if n == 0 {
			return true
		}
		if !libuser.write_full(1, buf[:n]) {
			return false
		}
	}
}
