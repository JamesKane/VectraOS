/*
srv -- dial a service and post the connection under a name in /srv.

    srv addr name

Dials `addr`, a dial string such as `tcp!fs!9fs`, and posts the stream as
`/srv/name`. A mount of that name then makes the kernel a 9P client of
whatever answers the far end, the way it is of a posted pipe: `mount /srv/fs
/n/fs`. `9fs`, an rc function in `rcmain`, is the two lines as one. The
conversation outlives this program: the posting holds the connection, and
removing the name is what ends it. `docs/FLEET.md` section 5.
*/
package srv

import "vsys:abi"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libuser"

say :: proc "contextless" (text: string) {
	_ = libuser.write(2, transmute([]u8)text)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	if len(args) < 3 {
		say("usage: srv addr name\n")
		libuser.exits("usage")
	}
	fd, ok := libnet.dial(args[1])
	if !ok {
		say("srv: cannot dial ")
		say(args[1])
		say("\n")
		libuser.exits("dial")
	}
	if !post(args[2], fd) {
		say("srv: cannot post /srv/")
		say(args[2])
		say("\n")
		libuser.exits("post")
	}
	libuser.exits("")
}

// post publishes descriptor `fd` as `/srv/name`: the file is created and the
// descriptor's number written into it, which is how a connection is posted.
post :: proc "contextless" (name: string, fd: int) -> bool {
	path: [96]u8
	cfd := libuser.create(libuser.cat_into(path[:], "/srv/", name), abi.O_WRONLY, 0o600)
	if cfd < 0 {
		return false
	}
	digits: [16]u8
	sink := libodin.sink_from(digits[:])
	libodin.put_uint(&sink, u64(fd))
	text := libodin.str(&sink)
	wrote := libuser.write(int(cfd), transmute([]u8)text) == i64(len(text))
	_ = libuser.close(int(cfd))
	return wrote
}
