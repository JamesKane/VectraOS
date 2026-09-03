// rm -- remove files. -r removes a directory and everything in it; -f
// says nothing about a file that is not there.
package rm

import "vsys:abi"
import "vsys:libuser"

recursive := false
force := false
status := ""

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	flag_buf: [8]u8
	letters, rest := libuser.letters(args, flag_buf[:])
	args = rest
	for c in transmute([]u8)letters {
		switch c {
		case 'r':
			recursive = true
		case 'f':
			force = true
		}
	}
	for path in args {
		remove(path)
	}
	libuser.exits(status)
}

remove :: proc(path: string) {
	if recursive {
		st: abi.Stat
		if libuser.stat(path, &st) == 0 && st.mode & abi.DMDIR != 0 {
			if names, ok := libuser.read_dir(path); ok {
				for name in names {
					remove(libuser.join(path, name))
				}
			}
		}
	}
	if r := libuser.remove(path); r < 0 && !force {
		libuser.eprint("rm: ", path, ": ", libuser.errstr(r), "\n")
		status = "can't remove"
	}
}
