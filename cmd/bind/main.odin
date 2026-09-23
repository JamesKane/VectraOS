// bind -- make a name appear at another: `bind [-abcr] new old`. -b puts it
// before what is there, -a after; -r makes it read-only, every change under
// it refused; -c is accepted and means nothing yet.
package bind

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	order := abi.ORDER_REPLACE
	readonly := u64(0)
	flag_buf: [8]u8
	letters, rest := libuser.letters(args, flag_buf[:])
	args = rest
	for c in transmute([]u8)letters {
		switch c {
		case 'b':
			order = abi.ORDER_BEFORE
		case 'a':
			order = abi.ORDER_AFTER
		case 'c':
		case 'r':
			readonly = abi.ORDER_READONLY
		}
	}
	if len(args) != 2 {
		libuser.eprint("usage: bind [-abcr] new old\n")
		libuser.exits("usage")
	}
	if r := libuser.bind(args[0], args[1], order | readonly); r < 0 {
		libuser.eprint("bind: ", args[0], " on ", args[1], ": ", libuser.errstr(r), "\n")
		libuser.exits("bind failed")
	}
	libuser.exits("")
}
