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
	for len(args) > 0 && len(args[0]) > 1 && args[0][0] == '-' {
		for i in 1 ..< len(args[0]) {
			switch args[0][i] {
			case 'r':
				recursive = true
			case 'f':
				force = true
			}
		}
		args = args[1:]
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
			fd := libuser.open(path, abi.O_RDONLY)
			if fd >= 0 {
				names := make([dynamic]string)
				entries: [16]abi.Dirent
				for {
					n := libuser.dirread(int(fd), entries[:])
					if n <= 0 {
						break
					}
					for i in 0 ..< int(n) {
						e := &entries[i]
						name := make([]u8, int(e.name_len))
						copy(name, e.name[:e.name_len])
						append(&names, string(name))
					}
				}
				libuser.close(int(fd))
				for name in names {
					child := make([]u8, len(path) + 1 + len(name))
					copy(child, path)
					child[len(path)] = '/'
					copy(child[len(path) + 1:], name)
					remove(string(child))
				}
			}
		}
	}
	if r := libuser.remove(path); r < 0 && !force {
		libuser.eprint("rm: ", path, ": ", libuser.errstr(r), "\n")
		status = "can't remove"
	}
}
