// pwd -- print the working directory.
package pwd

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	_ = libuser.args(block)
	buf: [1024]u8
	n := libuser.getwd(buf[:])
	if n < 0 {
		libuser.eprint("pwd: ", libuser.errstr(n), "\n")
		libuser.exits("getwd")
	}
	buf[n] = '\n'
	libuser.write_full(1, buf[:n + 1])
	libuser.exits("")
}
