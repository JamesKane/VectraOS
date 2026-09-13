/*
role -- does this machine's `ndb` line carry a role? `docs/FLEET.md` step 3.

`role <sys> <attr>` looks up the record where `sys=<sys>` in `/lib/ndb/local`
and, if it has `<attr>=`, prints the value and exits with the empty status rc
reads as success. A machine's role is `terminal=`, `cpu=` or `fs=` on its own
line, so `/lib/init` starts a service inside `if(role $sysname cpu) ...`. The
value is usually empty; presence is the whole answer, and a machine may be more
than one role at once.
*/
package role

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	if len(args) != 3 {
		libuser.eprint("usage: role sys attr\n")
		libuser.exits("usage")
	}
	buf: [64]u8
	value, ok := libuser.ndb_attr(args[1], args[2], buf[:])
	if !ok {
		libuser.exits("no")
	}
	// The value, when there is one, for a role like `fs=fs` that names a thing.
	out: libuser.Bio
	libuser.bio_init(&out, 1)
	libuser.bio_puts(&out, value)
	libuser.bio_putc(&out, '\n')
	_ = libuser.bio_flush(&out)
	libuser.exits("")
}
