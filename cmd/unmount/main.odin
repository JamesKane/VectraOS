// unmount -- undo a bind or mount: `unmount [new] old`. Without `new`,
// everything at `old` goes.
package unmount

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	source, target := "", ""
	switch len(args) {
	case 1:
		target = args[0]
	case 2:
		source, target = args[0], args[1]
	case:
		libuser.eprint("usage: unmount [new] old\n")
		libuser.exits("usage")
	}
	if r := libuser.unmount(source, target); r < 0 {
		libuser.eprint("unmount: ", target, ": ", libuser.errstr(r), "\n")
		libuser.exits("unmount failed")
	}
	libuser.exits("")
}
