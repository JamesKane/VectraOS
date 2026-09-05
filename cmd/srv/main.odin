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
import "vsys:libauth"
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
	noauth := false
	if len(args) >= 2 && args[1] == "-n" {
		noauth = true
		args = args[1:]
	}
	if len(args) < 3 {
		say("usage: srv [-n] addr name\n")
		libuser.exits("usage")
	}
	fd, ok := libnet.dial(args[1])
	if !ok {
		say("srv: cannot dial ")
		say(args[1])
		say("\n")
		libuser.exits("dial")
	}
	// The handshake, before anything is posted: the host proves itself by
	// the key its record carries, and this session proves itself as the
	// user it runs as. What is posted is the sealed stream.
	// `-n` posts the stream in the clear, with no handshake: the far side
	// then names this session `none`, and what `none` may have is its
	// decision. It is the control the plan asks for, and nothing else.
	sealed := fd
	aerr := ""
	if !noauth {
		sealed, aerr = authenticate(fd, host_of(args[1]))
	}
	if aerr != "" {
		say("srv: ")
		say(aerr)
		say("\n")
		libuser.exits("auth")
	}
	if !post(args[2], sealed) {
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

// host_of is the middle of `proto!host!service`.
host_of :: proc "contextless" (addr: string) -> string #no_bounds_check {
	a := 0
	for a < len(addr) && addr[a] != '!' {a += 1}
	if a >= len(addr) {
		return addr
	}
	b := a + 1
	for b < len(addr) && addr[b] != '!' {b += 1}
	return addr[a + 1:b]
}

// authenticate runs the handshake with `host` on `fd` and answers the sealed
// descriptor, or why not.
authenticate :: proc "contextless" (fd: int, host: string) -> (int, string) {
	who: [128]u8
	user, dom, ok := libauth.whoami(who[:])
	if !ok {
		return -1, "no user in the environment: /env/user and /env/dom"
	}
	keybuf: [64]u8
	key, has := libauth.host_key(host, keybuf[:])
	if !has {
		return -1, "no key= for that host in /lib/ndb/local"
	}
	sess, done := libauth.auth_client(fd, user, dom, key)
	if !done {
		return -1, "the handshake with the host failed"
	}
	return sess.fd, ""
}
