// kill -- end processes by pid, through /proc/n/ctl. `-n text` posts a note
// instead, which a process may handle.
package kill

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	note := ""
	if len(args) > 1 && args[0] == "-n" {
		note = args[1]
		args = args[2:]
	}
	if len(args) == 0 {
		libuser.eprint("usage: kill [-n note] pid ...\n")
		libuser.exits("usage")
	}
	status := ""
	path: [64]u8
	for pid in args {
		name := libuser.cat_into(path[:], "/proc/", pid, len(note) > 0 ? "/note" : "/ctl")
		fd := libuser.open(name, abi.O_WRONLY)
		if fd < 0 {
			libuser.eprint("kill: ", pid, ": ", libuser.errstr(fd), "\n")
			status = "no such process"
			continue
		}
		text := len(note) > 0 ? note : "kill"
		if !libuser.write_full(int(fd), transmute([]u8)text) {
			libuser.eprint("kill: ", pid, ": write failed\n")
			status = "can't kill"
		}
		libuser.close(int(fd))
	}
	libuser.exits(status)
}
