// mkdir -- make directories. -p makes each missing component and does not
// mind one that exists.
package mkdir

import "vsys:abi"
import "vsys:libuser"
import "vsys:vectra9"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	parents := false
	if len(args) > 0 && args[0] == "-p" {
		parents = true
		args = args[1:]
	}
	status := ""
	for path in args {
		if parents {
			for i in 1 ..= len(path) {
				if i < len(path) && path[i] != '/' {
					continue
				}
				if i == len(path) || i > 0 {
					fd := libuser.mkdir(path[:i])
					if fd >= 0 {
						libuser.close(int(fd))
					} else if fd != -i64(vectra9.EEXIST) && i == len(path) {
						libuser.eprint("mkdir: ", path, ": ", libuser.errstr(fd), "\n")
						status = "can't make"
					}
				}
			}
			continue
		}
		fd := libuser.mkdir(path)
		if fd < 0 {
			libuser.eprint("mkdir: ", path, ": ", libuser.errstr(fd), "\n")
			status = "can't make"
			continue
		}
		libuser.close(int(fd))
	}
	libuser.exits(status)
}
