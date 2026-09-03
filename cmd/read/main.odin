// read -- copy one line of standard input to standard output, for
// `x=`{read}` in a script. -m copies the rest. Exits `eof` with nothing.
package read

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	all := len(args) > 0 && args[0] == "-m"
	if all {
		buf: [8192]u8
		got := false
		for {
			n := libuser.read(0, buf[:])
			if n <= 0 {
				break
			}
			got = true
			libuser.write_full(1, buf[:n])
		}
		libuser.exits(got ? "" : "eof")
	}
	// One line: a byte at a time, so nothing past the newline is taken
	// from a shared descriptor. The console hands over whole lines and a
	// pipe may not, and this reads either correctly.
	line := make([dynamic]u8, 0, 256)
	one: [1]u8
	for {
		n := libuser.read(0, one[:])
		if n <= 0 {
			break
		}
		append(&line, one[0])
		if one[0] == '\n' {
			break
		}
	}
	if len(line) == 0 {
		libuser.exits("eof")
	}
	libuser.write_full(1, line[:])
	libuser.exits("")
}
