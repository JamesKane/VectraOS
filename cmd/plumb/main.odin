/*
plumb -- send a message to the plumber, from the shell.

    plumb [-s src] [-d port] [-t type] [-a 'name=value ...'] [-w dir] data...

The data is the arguments joined by spaces. So `plumb main.odin:31` is a
file and a line for an editor, and `plumb https://example.com/` a page for
the reader. The rules in `/mnt/plumb/rules` say which port takes it, or
`-d` names one. The exit word is empty when a rule took the message, and
says why when none did or there is no plumber. `docs/GHOST.md` section 5.
*/
package plumb

import "vsys:abi"
import "vsys:libplumb"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	m := libplumb.Msg{src = "plumb", type = "text"}
	data: [libplumb.MAX]u8
	n := 0
	i := 1
	for i < len(args) {
		a := args[i]
		if len(a) == 2 && a[0] == '-' && i + 1 < len(args) {
			switch a[1] {
			case 's':
				m.src = args[i + 1]
			case 'd':
				m.dst = args[i + 1]
			case 't':
				m.type = args[i + 1]
			case 'a':
				m.attr = args[i + 1]
			case 'w':
				m.wdir = args[i + 1]
			case:
				libuser.eprint("usage: plumb [-s src] [-d port] [-t type] [-a attrs] [-w dir] data...\n")
				libuser.exits("usage")
			}
			i += 2
			continue
		}
		if n > 0 && n < len(data) {
			data[n] = ' '
			n += 1
		}
		n += copy(data[n:], a)
		i += 1
	}
	if n == 0 {
		libuser.eprint("usage: plumb [-s src] [-d port] [-t type] [-a attrs] [-w dir] data...\n")
		libuser.exits("usage")
	}
	m.data = string(data[:n])
	if fd := libplumb.reach("send", abi.O_WRONLY); fd < 0 {
		libuser.eprint("plumb: no plumber at ", libplumb.PLUMB_DIR, "\n")
		libuser.exits("no plumber")
	} else {
		_ = libuser.close(fd)
	}
	if !libplumb.send(&m) {
		libuser.eprint("plumb: no rule takes it\n")
		libuser.exits("no rule")
	}
	libuser.exits("")
}
