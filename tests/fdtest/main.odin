/*
fdtest -- the descriptor device `#d`, `docs/FLEET.md` section 7, proven.

The kernel's self-test spawns this and reads the word it exits with: `ok`, or
the name of the first check that did not hold. It makes a pipe, writes a token
into one end, and reads it back through `/fd/<n>` -- the other end named as a
file. That is exactly what `cpu -f` and `rx` lean on: a descriptor reached by
name, which the terminal exports so a remote command's three are its own.
*/
package fdtest

import "vsys:abi"
import "vsys:libuser"

want :: proc "contextless" (cond: bool, what: string) {
	if !cond {
		libuser.exits(what)
	}
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()

	packed := libuser.pipe()
	want(packed >= 0, "a pipe is made")
	e0, e1 := abi.pipe_ends(packed)

	// A token into one end of the pipe.
	msg := "fdok"
	want(libuser.write(e1, transmute([]u8)msg) == i64(len(msg)), "the pipe takes a token")

	// The other end, named as a file under /fd, opens and reads that token.
	path: [24]u8
	num: [16]u8
	fd := libuser.open(libuser.cat_into(path[:], "/fd/", libuser.itoa(num[:], i64(e0))), abi.O_RDONLY)
	want(fd >= 0, "/fd/<n> opens the descriptor")

	buf: [16]u8
	got := libuser.read(int(fd), buf[:])
	want(got == i64(len(msg)) && string(buf[:got]) == msg, "reading /fd/<n> reads the descriptor")

	libuser.exits("ok")
}
