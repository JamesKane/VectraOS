/*
db -- the debugger's line client, a page of commands over `/mnt/dbg`.

    db run path args...      start the program stopped at its entry, and
                             print the target's number
    db attach pid            stop a running process and take it as a target
    db N word...             write the words to the target's ctl, then print
                             its status: break, delete, cont, stop, step, next,
                             until
    db N print expr          write the expression to eval and print the value
    db N bt|vars|regs|breaks|dis|procs|status
                             print that file
    db detach N

Every command is one read or one write, which is what makes a shell
script the same client. The engine is `servers/dbgfs`, mounted at
`/mnt/dbg`. When it is not, this mounts `/srv/dbg` there first.
*/
package db

import "vsys:abi"
import "vsys:libuser"

usage :: proc "contextless" () -> ! {
	libuser.eprint("usage: db run path args... | db attach pid | db N word... | db N print expr | db N file | db detach N\n")
	libuser.exits("usage")
}

// ensure_mounted mounts the engine when nothing answers at /mnt/dbg/ctl.
ensure_mounted :: proc "contextless" () {
	fd := libuser.open("/mnt/dbg/ctl", abi.O_RDONLY)
	if fd >= 0 {
		_ = libuser.close(int(fd))
		return
	}
	if libuser.mount("/srv/dbg", "/mnt/dbg", abi.ORDER_REPLACE) < 0 {
		libuser.eprint("db: no debugger at /srv/dbg; start dbgfs\n")
		libuser.exits("no engine")
	}
}

write_line :: proc "contextless" (path: string, words: []string) -> bool {
	fd := libuser.open(path, abi.O_WRONLY)
	if fd < 0 {
		libuser.eprint("db: ", path, ": ", libuser.errstr(fd), "\n")
		return false
	}
	defer libuser.close(int(fd))
	line: [512]u8
	at := 0
	for w, i in words {
		if i > 0 && at < len(line) {
			line[at] = ' '
			at += 1
		}
		n := copy(line[at:], w)
		at += n
	}
	if !libuser.write_full(int(fd), line[:at]) {
		libuser.eprint("db: ", path, ": write refused\n")
		return false
	}
	return true
}

cat :: proc "contextless" (path: string) -> bool {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		libuser.eprint("db: ", path, ": ", libuser.errstr(fd), "\n")
		return false
	}
	defer libuser.close(int(fd))
	buf: [4096]u8
	for {
		n := libuser.read(int(fd), buf[:])
		if n <= 0 {
			break
		}
		_ = libuser.write_full(1, buf[:n])
	}
	return true
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	if len(args) == 0 {
		usage()
	}
	ensure_mounted()
	path: [64]u8
	switch args[0] {
	case "run", "attach":
		if len(args) < 2 {
			usage()
		}
		if !write_line("/mnt/dbg/ctl", args) {
			libuser.exits("refused")
		}
		_ = cat("/mnt/dbg/ctl")
		libuser.exits("")
	case "detach":
		if len(args) < 2 || !write_line("/mnt/dbg/ctl", args) {
			libuser.exits("refused")
		}
		libuser.exits("")
	}
	if len(args) < 2 {
		usage()
	}
	n := args[0]
	switch args[1] {
	case "print":
		if len(args) < 3 || !write_line(libuser.cat_into(path[:], "/mnt/dbg/", n, "/eval"), args[2:]) {
			libuser.exits("refused")
		}
		_ = cat(libuser.cat_into(path[:], "/mnt/dbg/", n, "/eval"))
	case "bt", "vars", "regs", "breaks", "dis", "procs", "status":
		_ = cat(libuser.cat_into(path[:], "/mnt/dbg/", n, "/", args[1]))
	case:
		if !write_line(libuser.cat_into(path[:], "/mnt/dbg/", n, "/ctl"), args[1:]) {
			libuser.exits("refused")
		}
		_ = cat(libuser.cat_into(path[:], "/mnt/dbg/", n, "/status"))
	}
	libuser.exits("")
}
