// echo -- print its arguments, separated by spaces, with a newline unless -n.
package echo

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	if len(args) > 0 {
		args = args[1:]
	}
	newline := true
	if len(args) > 0 && args[0] == "-n" {
		newline = false
		args = args[1:]
	}
	out: libuser.Bio
	libuser.bio_init(&out, 1)
	for a, i in args {
		if i > 0 {
			libuser.bio_putc(&out, ' ')
		}
		libuser.bio_puts(&out, a)
	}
	if newline {
		libuser.bio_putc(&out, '\n')
	}
	libuser.exits(libuser.bio_flush(&out) ? "" : "write error")
}
