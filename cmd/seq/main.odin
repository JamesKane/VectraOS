// seq -- print a sequence of integers: `seq last`, `seq first last`, or
// `seq first incr last`.
package seq

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	first, incr, last: i64 = 1, 1, 0
	ok := true
	switch len(args) {
	case 1:
		last, ok = libuser.atoi(args[0])
	case 2:
		f, fok := libuser.atoi(args[0])
		l, lok := libuser.atoi(args[1])
		first, last, ok = f, l, fok && lok
	case 3:
		f, fok := libuser.atoi(args[0])
		i, iok := libuser.atoi(args[1])
		l, lok := libuser.atoi(args[2])
		first, incr, last, ok = f, i, l, fok && iok && lok && i != 0
	case:
		ok = false
	}
	if !ok {
		libuser.eprint("usage: seq [first [incr]] last\n")
		libuser.exits("usage")
	}
	out: libuser.Bio
	libuser.bio_init(&out, 1)
	num: [24]u8
	for v := first; incr > 0 ? v <= last : v >= last; v += incr {
		libuser.bio_puts(&out, libuser.itoa(num[:], v))
		libuser.bio_putc(&out, '\n')
	}
	libuser.bio_flush(&out)
	libuser.exits("")
}
