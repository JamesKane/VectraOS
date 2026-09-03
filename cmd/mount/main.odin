// mount -- attach a served tree: `mount [-abc] /srv/name old`.
package mount

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	order := abi.ORDER_REPLACE
	for len(args) > 0 && len(args[0]) > 1 && args[0][0] == '-' {
		for i in 1 ..< len(args[0]) {
			switch args[0][i] {
			case 'b':
				order = abi.ORDER_BEFORE
			case 'a':
				order = abi.ORDER_AFTER
			case 'c':
			}
		}
		args = args[1:]
	}
	if len(args) != 2 {
		libuser.eprint("usage: mount [-abc] /srv/service old\n")
		libuser.exits("usage")
	}
	if r := libuser.mount(args[0], args[1], order); r < 0 {
		libuser.eprint("mount: ", args[0], " on ", args[1], ": ", libuser.errstr(r), "\n")
		libuser.exits("mount failed")
	}
	libuser.exits("")
}
