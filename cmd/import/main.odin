/*
import -- mount another machine's tree here.

    import [-a|-b] host mountpoint

Dials `tcp!host!9fs`, where that machine's `listen` runs `exportfs`, posts the
stream as `/srv/host`, and mounts it at `mountpoint`. `-a` and `-b` are the
mount's order, after or before what is there. It is `srv` and `mount` in one,
the reverse of `exportfs`: `import big /n/big` and then `/n/big/proc` is the
other machine's process table. `docs/FLEET.md` section 5.

Plan 9's `import` names the far tree as well, `import big /proc /n/big/proc`,
and asks the far `exportfs` for it by an attach name. There is no attach name
on this wire yet, so the far side exports what its service script names and
this end takes the whole of it; a `bind` after the mount picks the part.
*/
package import_cmd

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
	order := abi.ORDER_REPLACE
	at := 1
	noauth := false
	if at < len(args) && args[at] == "-n" {
		noauth = true
		at += 1
	}
	if at < len(args) && args[at] == "-a" {
		order = abi.ORDER_AFTER
		at += 1
	} else if at < len(args) && args[at] == "-b" {
		order = abi.ORDER_BEFORE
		at += 1
	}
	if len(args) < at + 2 {
		say("usage: import [-n] [-a|-b] host mountpoint\n")
		libuser.exits("usage")
	}
	host := args[at]
	target := args[at + 1]

	spec: [96]u8
	// `-n` dials the control that skips the handshake -- `9fsnone`, the port
	// where `listen` runs `exportfs` with no `-a`. The far side then names
	// this session `none`, and a private file refuses it. Dialled and mounted
	// in this one process, because a posted connection is the mounting
	// process's to complete: `srv` then `mount` posts a stream whose end is
	// gone by the time a separate `mount` speaks 9P over it.
	service := noauth ? "9fsnone" : "9fs"
	fd, ok := libnet.dial(libuser.cat_into(spec[:], "tcp!", host, "!", service))
	if !ok {
		say("import: cannot dial ")
		say(host)
		say("\n")
		libuser.exits("dial")
	}
	stream := fd
	if !noauth {
		who: [128]u8
		user, dom, wok := libauth.whoami(who[:])
		if !wok {
			say("import: no user in the environment: /env/user and /env/dom\n")
			libuser.exits("auth")
		}
		keybuf: [64]u8
		key, has := libauth.host_key(host, keybuf[:])
		if !has {
			say("import: no key= for ")
			say(host)
			say(" in /lib/ndb/local\n")
			libuser.exits("auth")
		}
		sess, done := libauth.auth_client(fd, user, dom, key)
		if !done {
			say("import: the handshake with ")
			say(host)
			say(" failed\n")
			libuser.exits("auth")
		}
		stream = sess.fd
	}
	path: [96]u8
	posted := libuser.cat_into(path[:], "/srv/", host)
	if !post(posted, stream) {
		say("import: cannot post ")
		say(posted)
		say("\n")
		libuser.exits("post")
	}
	if r := libuser.mount(posted, target, order); r < 0 {
		say("import: cannot mount ")
		say(posted)
		say(" at ")
		say(target)
		say(": ")
		say(libuser.errstr(r))
		say("\n")
		_ = libuser.remove(posted)
		libuser.exits("mount")
	}
	libuser.exits("")
}

post :: proc "contextless" (path: string, fd: int) -> bool {
	cfd := libuser.create(path, abi.O_WRONLY, 0o600)
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
