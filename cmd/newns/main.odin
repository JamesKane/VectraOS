/*
newns -- rebuild this process's namespace from a file, `docs/FLEET.md` step 3.

`newns <file>` replays the `bind` and `mount` lines in the file, `$cputype` and
any other `#e` variable in a path expanded first -- `sys/libuser`'s `newns`, the
work Plan 9's C library does inside `newns()`. `ns` prints a namespace in this
form; this is the inverse. `/lib/init` runs `newns /lib/namespace` so a process's
world is data, the one file a local machine and a diskless one both start from:
the tree is at `/n/fs` either way, mounted off the disk here or imported over the
network there, and the binds that carry `/bin` out of it are the same.
*/
package newns

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	if len(args) != 2 {
		libuser.eprint("usage: newns file\n")
		libuser.exits("usage")
	}
	if !libuser.newns(args[1]) {
		libuser.eprint("newns: ", args[1], ": a line would not apply\n")
		libuser.exits("newns")
	}
	libuser.exits("")
}
