// ns -- print a process's namespace as the bind and mount lines that would
// rebuild it. This process's own without a pid.
package ns

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	num: [24]u8
	pid := len(args) > 0 ? args[0] : libuser.itoa(num[:], i64(libuser.getpid()))
	path: [64]u8
	copy(path[:], "/proc/")
	copy(path[6:], pid)
	copy(path[6 + len(pid):], "/ns")
	data, ok := libuser.read_file(string(path[:9 + len(pid)]), context.allocator)
	if !ok {
		libuser.eprint("ns: ", pid, ": can't read namespace\n")
		libuser.exits("no such process")
	}
	libuser.write_full(1, data)
	libuser.exits("")
}
