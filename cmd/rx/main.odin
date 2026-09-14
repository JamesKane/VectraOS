/*
rx -- run one command on another machine, `docs/FLEET.md` section 7.

`rx big mk all` runs `mk all` on `big` with this terminal's own three
descriptors for the command's -- so `rx big cat f | grep x` puts a remote
stage in a local pipeline. It is `cpu -h big -f -c 'mk all'`: `-f` connects the
far command to the terminal's descriptors (its `/fd`) rather than its console.
The arguments after the host are joined into the one command `cpu -c` takes.
*/
package rx

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	if len(args) < 2 {
		libuser.eprint("usage: rx host command...\n")
		libuser.exits("usage")
	}
	host := args[0]
	// Join the command words with single spaces, the way a shell would show it.
	buf: [1024]u8
	n := 0
	for a, i in args[1:] {
		if i > 0 && n < len(buf) {
			buf[n] = ' '
			n += 1
		}
		n += copy(buf[n:], a)
	}
	cmd := string(buf[:n])
	argv := []string{"cpu", "-h", host, "-f", "-c", cmd}
	_ = libuser.exec("/bin/cpu", argv)
	libuser.eprint("rx: cannot exec cpu\n")
	libuser.exits("exec")
}
