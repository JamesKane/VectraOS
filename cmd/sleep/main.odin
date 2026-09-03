// sleep -- wait a number of seconds.
package sleep

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	if len(args) != 1 {
		libuser.eprint("usage: sleep seconds\n")
		libuser.exits("usage")
	}
	seconds, ok := libuser.atoi(args[0])
	if !ok || seconds < 0 {
		libuser.eprint("sleep: bad count ", args[0], "\n")
		libuser.exits("usage")
	}
	// The kernel's tick is a millisecond; a long sleep goes in pieces so a
	// note can end it between them.
	for seconds > 0 {
		libuser.sleep(1000)
		seconds -= 1
	}
	libuser.exits("")
}
